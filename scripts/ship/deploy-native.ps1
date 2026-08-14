<#
.SYNOPSIS
  原生（非容器）換版 —— 給 Windows 上「不能容器化」的服務用。

.DESCRIPTION
  deploy-native.sh 的 Windows 對應版本，不變量完全一致：

    * 被測的 artifact 就是被部署的 artifact —— 用 sha256，部署前重算，對不上就中止
    * 舊版在新版健康之前絕不刪除 —— 回滾靠的就是它
    * 任何失敗路徑都以「線上仍有一個健康版本」收尾，寧可不換版

  佈局同 bash 版：
    <InstallRoot>\
      releases\<sha12>\     解開的 artifact
      current               -> junction 指向 releases\<sha12>
      .ship-state.json      ActiveSha / PrevSha

  適用對象是 gs-shipyard 分級中的 native-win：UIA / SendInput / DPAPI /
  實體週邊這些原理上進不了容器的東西。

  StartCmd / StopCmd / HealthCmd 由呼叫端提供，本腳本不綁死 Scheduled Task
  或 Windows Service —— 那是各 repo 自己的事。

.NOTES
  current 用的是 **junction（mklink /J）而不是 symlink**。PowerShell 的
  New-Item -ItemType SymbolicLink 需要開發者模式或管理員權限，在 CI runner 上
  常常兩者都沒有；junction 對目錄有效且不需提權。這條踩過，別改回 New-Item。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Artifact,      # .zip / .tar.gz 路徑
  [Parameter(Mandatory)][string]$ArtifactSha,   # build 階段算的 sha256
  [Parameter(Mandatory)][string]$Service,       # 服務名
  [Parameter(Mandatory)][string]$InstallRoot,   # 安裝根目錄
  [Parameter(Mandatory)][string]$StartCmd,      # 啟動指令（在 current\ 內執行）
  [string]$StopCmd = '',                        # 停止指令（留空 = 不停）
  [string]$HealthCmd = '',                      # 健康檢查指令（非零 = 不健康）
  [string]$HealthUrl = '',                      # HTTP 健康檢查
  [int]$HealthTimeout = 60,
  [int]$KeepReleases = 3
)

$ErrorActionPreference = 'Stop'

$Releases = Join-Path $InstallRoot 'releases'
$Current  = Join-Path $InstallRoot 'current'
$StateFile = Join-Path $InstallRoot '.ship-state.json'

function Write-Log { param([string]$m) Write-Host "[ship-native] $m" }
function Stop-WithError { param([string]$m) Write-Host "::error::$m"; exit 1 }

# ---------------------------------------------------------------- 驗 artifact
if (-not (Test-Path -LiteralPath $Artifact -PathType Leaf)) {
  Stop-WithError "artifact 不存在：$Artifact"
}
$actual = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLower()
$expect = $ArtifactSha.ToLower()
# 這一步就是「測的就是部的」那條不變量。對不上代表中間有人換過東西，
# 或 CI 下載到別的 artifact，兩者都不該繼續。
if ($actual -ne $expect) {
  Stop-WithError "artifact sha256 不符：期望 $expect，實際 $actual"
}
$Sha12 = $expect.Substring(0, 12)
$NewDir = Join-Path $Releases $Sha12
Write-Log "artifact 驗證通過（$Sha12）"

New-Item -ItemType Directory -Force -Path $Releases | Out-Null

# 以 junction 實際指向為準，不是以狀態檔為準：狀態檔可能因上次中斷而過期。
$ActiveSha = ''
if (Test-Path -LiteralPath $Current) {
  $item = Get-Item -LiteralPath $Current -Force
  if ($item.Target) { $ActiveSha = Split-Path -Leaf ([string]($item.Target | Select-Object -First 1)) }
}
Write-Log "目前線上：$(if ($ActiveSha) { $ActiveSha } else { '（無）' })；這次要上：$Sha12"

if ($ActiveSha -eq $Sha12) { Write-Log '線上已經是這一版，不做任何事'; exit 0 }

# ---------------------------------------------------------------- 解開新版
# 解到暫存再搬：解到一半失敗的話，releases\ 底下不會留下半套目錄讓下次
# 誤判成「這版已經解過了」。
$Stage = Join-Path $Releases (".stage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
try {
  switch -Wildcard ($Artifact) {
    '*.zip'    { Expand-Archive -LiteralPath $Artifact -DestinationPath $Stage -Force }
    '*.tar.gz' { & tar.exe -xzf $Artifact -C $Stage; if ($LASTEXITCODE -ne 0) { throw "tar 解壓失敗" } }
    '*.tgz'    { & tar.exe -xzf $Artifact -C $Stage; if ($LASTEXITCODE -ne 0) { throw "tar 解壓失敗" } }
    default    { throw "不支援的 artifact 格式：$Artifact（要 .zip 或 .tar.gz）" }
  }

  # 只有單一頂層目錄就拉平，否則 current\ 底下會多一層，StartCmd 的相對路徑
  # 得跟著 artifact 的打包方式變，很容易錯。
  $entries = @(Get-ChildItem -LiteralPath $Stage -Force)
  if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
    Write-Log "artifact 只有單一頂層目錄（$($entries[0].Name)），拉平"
    Move-Item -LiteralPath $entries[0].FullName -Destination $NewDir
    Remove-Item -LiteralPath $Stage -Recurse -Force
  } else {
    Move-Item -LiteralPath $Stage -Destination $NewDir
  }
} catch {
  if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force -EA SilentlyContinue }
  Stop-WithError "解壓失敗：$($_.Exception.Message)"
}

# ---------------------------------------------------------------- 輔助
function Invoke-InDir {
  param([string]$Dir, [string]$Cmd)
  Push-Location -LiteralPath $Dir
  try {
    # 用 cmd 風格的整串指令交給 pwsh 自己 eval；呼叫端給什麼就跑什麼。
    Invoke-Expression $Cmd
    return $true
  } catch {
    return $false
  } finally { Pop-Location }
}

function Test-Healthy {
  param([string]$Dir)
  if (-not $HealthCmd -and -not $HealthUrl) {
    Write-Log '未設 HealthCmd / HealthUrl，只確認服務沒有立刻退出'
    Start-Sleep -Seconds 5
    return $true
  }
  $deadline = (Get-Date).AddSeconds($HealthTimeout)
  while ((Get-Date) -lt $deadline) {
    $ok = $true
    if ($HealthCmd) { if (-not (Invoke-InDir -Dir $Dir -Cmd $HealthCmd)) { $ok = $false } }
    if ($ok -and $HealthUrl) {
      try { Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 5 -UseBasicParsing | Out-Null }
      catch { $ok = $false }
    }
    if ($ok) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Stop-Svc {
  if (-not $StopCmd) { return }
  Write-Log '停止服務'
  Invoke-InDir -Dir $InstallRoot -Cmd $StopCmd | Out-Null
}

function Set-Current {
  param([string]$Sha)
  $target = Join-Path $Releases $Sha
  if (Test-Path -LiteralPath $Current) {
    # junction 要用 Remove-Item -Force 移除連結本身；不要用 -Recurse，
    # 那會連目標目錄裡的東西一起刪掉——等於把 release 砍了。
    (Get-Item -LiteralPath $Current -Force).Delete()
  }
  & cmd.exe /c mklink /J "`"$Current`"" "`"$target`"" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "mklink /J 失敗：$Current -> $target" }
}

function Save-State {
  param([string]$Active, [string]$Prev)
  @{ ActiveSha = $Active; PrevSha = $Prev } |
    ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding utf8
}

# ---------------------------------------------------------------- 換版
# 同 bash 版：原生服務綁固定 port，沒辦法先在旁邊起一份做閘門。
# ⚠ 舊行程被殺後 listening socket 會停在 TIME_WAIT。服務若沒設 SO_REUSEADDR，
#   新行程會拿到 WSAEADDRINUSE，**症狀看起來是「新版不健康」**，接著回滾起
#   舊版也綁不上。容器版沒這問題（各自的 network namespace）。
Stop-Svc
Set-Current -Sha $Sha12

$started = Invoke-InDir -Dir $Current -Cmd $StartCmd
if ($started -and (Test-Healthy -Dir $Current)) {
  Save-State -Active $Sha12 -Prev $ActiveSha
  Write-Log "換版完成：$Service -> $Sha12"
} else {
  Write-Log '新版不健康，開始回滾'
  Stop-Svc
  if ($ActiveSha -and (Test-Path -LiteralPath (Join-Path $Releases $ActiveSha))) {
    Set-Current -Sha $ActiveSha
    if ((Invoke-InDir -Dir $Current -Cmd $StartCmd) -and (Test-Healthy -Dir $Current)) {
      Stop-WithError "新版不健康，已回滾到 $ActiveSha"
    }
    Stop-WithError '新版不健康且回滾也未通過健康檢查 —— 服務目前是壞的，需要人工介入'
  }
  Stop-WithError '新版不健康，且沒有上一版可回滾（這是本服務第一次部署）'
}

# ---------------------------------------------------------------- 清舊版
# 下限比容器更硬：上一版是回滾的唯一依據，所以至少保留 2 個，且現行版與
# 上一版一律不動。
$keep = [Math]::Max(2, $KeepReleases)
$all = @(Get-ChildItem -LiteralPath $Releases -Directory -Force |
         Sort-Object LastWriteTime -Descending)
$removed = 0
foreach ($d in ($all | Select-Object -Skip $keep)) {
  if ($d.Name -eq $Sha12 -or $d.Name -eq $ActiveSha) { continue }
  Remove-Item -LiteralPath $d.FullName -Recurse -Force -EA SilentlyContinue
  $removed++
}
if ($removed -gt 0) { Write-Log "清掉 $removed 個舊 release（保留最近 $keep 個）" }

exit 0
