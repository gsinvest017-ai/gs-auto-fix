<#
  deploy-native.ps1 的端到端驗證 —— 只需要 Python，不需要 docker。

  驗五件事，與 bash 版對應：
    1. 首次部署要能起來並對外服務
    2. artifact sha256 對不上要中止，且什麼都不裝（測的就是部的）
    3. 換版成功時 current 要指向新版，且上一版要留著
    4. 新版不健康要自動回滾，線上救回上一版
    5. 舊 release 要被清掉，但現行版與上一版一律保留

  用法：pwsh -NoProfile -File tests\e2e_ship_deploy_native.ps1
#>
$ErrorActionPreference = 'Stop'

$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Deploy  = Join-Path $Here '..\scripts\ship\deploy-native.ps1'
$Work    = Join-Path ([IO.Path]::GetTempPath()) ("shipnat-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$Root    = Join-Path $Work 'install'
$Python  = (Get-Command python).Source

$script:pass = 0; $script:fail = 0
function Ok  { param($m) Write-Host "  PASS $m" -ForegroundColor Green; $script:pass++ }
function Bad { param($m) Write-Host "  FAIL $m" -ForegroundColor Red;   $script:fail++ }

# port 動態挑（同 bash 版理由：這支會在自架 runner 上跑，那台也是部署目標）
function Get-FreePort {
  foreach ($p in 18300..18399) {
    $l = $null
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p); $l.Start(); return $p }
    catch { } finally { if ($l) { $l.Stop() } }
  }
  return 18300
}
$Port = Get-FreePort
Write-Host "使用 port $Port"

New-Item -ItemType Directory -Force -Path $Root | Out-Null

function New-Artifact {
  param([string]$Ver, [bool]$Healthy)
  $d = Join-Path $Work "src-$Ver"
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  # 用 HTTPServer 而不是裸的 socketserver.TCPServer：前者有設 SO_REUSEADDR。
  # 原生換版是「殺掉舊行程、新行程綁同一個 port」，沒有它會撞 TIME_WAIT，
  # 症狀看起來像「新版不健康」。bash 版踩過同一個坑。
  @"
import http.server, sys
VER, HEALTHY = "$Ver", $(if ($Healthy) { 'True' } else { 'False' })
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz" and not HEALTHY:
            self.send_response(500); self.end_headers(); return
        b = VER.encode()
        self.send_response(200)
        # 一定要送 Content-Type：沒有它時 PowerShell 的 Invoke-WebRequest 會把
        # 回應當二進位，.Content 給的是 byte[] 而不是字串（curl 不在意，所以
        # 只有 Windows 版的測試會炸，症狀是比對到「118 49」這種數字）。
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("", int(sys.argv[1])), H).serve_forever()
"@ | Set-Content -LiteralPath (Join-Path $d 'app.py') -Encoding utf8

  $zip = Join-Path $Work "$Ver.zip"
  Compress-Archive -Path (Join-Path $d '*') -DestinationPath $zip -Force
  return $zip
}

$PidFile = Join-Path $Root 'app.pid'
$LogFile = Join-Path $Root 'app.log'
# 啟動用 Start-Process -PassThru 拿 PID。注意不要加 -RedirectStandardOutput
# 去接常駐服務的輸出——那會讓呼叫端永久卡住（已知坑）；改用 python 自己重導。
$Start = "`$p = Start-Process -FilePath '$Python' -ArgumentList 'app.py','$Port' -PassThru -WindowStyle Hidden; `$p.Id | Set-Content -LiteralPath '$PidFile'; Start-Sleep -Seconds 1"
$Stop  = "if (Test-Path '$PidFile') { Stop-Process -Id (Get-Content '$PidFile') -Force -EA SilentlyContinue; Remove-Item '$PidFile' -Force -EA SilentlyContinue }; Start-Sleep -Seconds 1"

function Invoke-Deploy {
  param([string]$Art, [string]$Sha)
  & pwsh -NoProfile -File $Deploy `
    -Artifact $Art -ArtifactSha $Sha -Service 'nativetest' -InstallRoot $Root `
    -StartCmd $Start -StopCmd $Stop `
    -HealthUrl "http://127.0.0.1:$Port/healthz" -HealthTimeout 20 -KeepReleases 2 2>&1
  return $LASTEXITCODE
}
function Get-Serving {
  try {
    $c = (Invoke-WebRequest "http://127.0.0.1:$Port/" -TimeoutSec 5 -UseBasicParsing).Content
    if ($c -is [byte[]]) { [Text.Encoding]::UTF8.GetString($c) } else { $c }
  } catch { '' }
}
function Get-CurrentSha {
  $c = Join-Path $Root 'current'
  if (-not (Test-Path -LiteralPath $c)) { return 'none' }
  Split-Path -Leaf ([string]((Get-Item -LiteralPath $c -Force).Target | Select-Object -First 1))
}
function Get-Sha { param($f) (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() }

try {
  Write-Host '== 1. 首次部署 =='
  $A1 = New-Artifact -Ver 'v1' -Healthy $true; $S1 = Get-Sha $A1
  $out = Invoke-Deploy $A1 $S1
  if ($LASTEXITCODE -eq 0) {
    if ((Get-Serving) -eq 'v1') { Ok '服務回應 v1' } else { Bad "服務內容不對：$(Get-Serving)" }
    if ((Get-CurrentSha) -eq $S1.Substring(0,12)) { Ok 'current 指向 v1' } else { Bad "current 指錯：$(Get-CurrentSha)" }
  } else { Bad '首次部署失敗'; $out | ForEach-Object { "    $_" } }

  Write-Host '== 2. artifact sha256 對不上要中止，且什麼都不裝 =='
  $A2 = New-Artifact -Ver 'v2' -Healthy $true; $S2 = Get-Sha $A2
  $before = @(Get-ChildItem (Join-Path $Root 'releases') -Directory).Count
  $out = Invoke-Deploy $A2 ('0' * 64)
  if ($LASTEXITCODE -eq 0) { Bad 'sha 不符竟然還是部署了' }
  else {
    Ok 'sha 不符被擋下'
    if ($out -match 'sha256 不符') { Ok '訊息指出 sha 不符' } else { Bad '沒講清楚原因' }
    $after = @(Get-ChildItem (Join-Path $Root 'releases') -Directory).Count
    if ($after -eq $before) { Ok 'releases\ 沒有被塞進半套東西' } else { Bad '留下了殘骸' }
    if ((Get-Serving) -eq 'v1') { Ok '線上仍是 v1（零影響）' } else { Bad "線上被動到：$(Get-Serving)" }
  }

  Write-Host '== 3. 換到新版，上一版保留 =='
  $out = Invoke-Deploy $A2 $S2
  if ($LASTEXITCODE -eq 0) {
    if ((Get-Serving) -eq 'v2') { Ok '服務已換成 v2' } else { Bad "服務沒換：$(Get-Serving)" }
    if ((Get-CurrentSha) -eq $S2.Substring(0,12)) { Ok 'current 指向 v2' } else { Bad 'current 指錯' }
    if (Test-Path (Join-Path $Root "releases\$($S1.Substring(0,12))")) { Ok '上一版 v1 保留（回滾靠它）' }
    else { Bad '上一版被刪了——回滾會失效' }
  } else { Bad '換版失敗'; $out | ForEach-Object { "    $_" } }

  Write-Host '== 4. 新版不健康 → 自動回滾 =='
  $A3 = New-Artifact -Ver 'v3' -Healthy $false; $S3 = Get-Sha $A3
  $out = Invoke-Deploy $A3 $S3
  if ($LASTEXITCODE -eq 0) { Bad '不健康的版本竟然算部署成功' }
  else {
    Ok '部署判定為失敗'
    if ($out -match '已回滾') { Ok '訊息指出已回滾' } else { Bad '沒有回滾訊息' }
    if ((Get-Serving) -eq 'v2') { Ok '線上被救回 v2' } else { Bad "線上沒救回來：$(Get-Serving)" }
    if ((Get-CurrentSha) -eq $S2.Substring(0,12)) { Ok 'current 指回 v2' } else { Bad 'current 沒指回去' }
  }

  Write-Host '== 5. 舊 release 清理，現行版與上一版保留 =='
  $A4 = New-Artifact -Ver 'v4' -Healthy $true; $S4 = Get-Sha $A4
  $out = Invoke-Deploy $A4 $S4
  if ($LASTEXITCODE -eq 0) {
    if (Test-Path (Join-Path $Root "releases\$($S4.Substring(0,12))")) { Ok '現行版 v4 在' } else { Bad '現行版不見了' }
    if (Test-Path (Join-Path $Root "releases\$($S2.Substring(0,12))")) { Ok '上一版 v2 保留' } else { Bad '上一版被清掉了' }
    $n = @(Get-ChildItem (Join-Path $Root 'releases') -Directory).Count
    if ($n -le 3) { Ok "release 數量收斂（$n 個，KeepReleases=2）" } else { Bad "沒有清理，累積了 $n 個" }
  } else { Bad '第四次部署失敗'; $out | ForEach-Object { "    $_" } }
}
finally {
  if (Test-Path $PidFile) { Stop-Process -Id (Get-Content $PidFile) -Force -EA SilentlyContinue }
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like "*app.py $Port*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
  # current 是 junction：一定要先拆掉再刪目錄樹，否則 Remove-Item -Recurse
  # 會穿過 junction 把 releases 裡的東西一起帶走（這裡是暫存目錄所以無害，
  # 但同樣的寫法出現在正式環境就是災難）。
  $c = Join-Path $Root 'current'
  if (Test-Path -LiteralPath $c) { (Get-Item -LiteralPath $c -Force).Delete() }
  Remove-Item -LiteralPath $Work -Recurse -Force -EA SilentlyContinue
}

Write-Host ''
Write-Host "通過 $script:pass，失敗 $script:fail"
if ($script:fail -ne 0) { exit 1 }
