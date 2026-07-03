# 進度：self-hosted GPU runner 接線（claude-fix-local 打通）

## 目標

把本機（RTX 5090 + Ollama）註冊成 gs-auto-fix 的 self-hosted runner，讓
`claude-fix-local.yml`（地端先修 gate，PoC1）真正排得到機器並跑通端到端，
補上「CI 失敗 → 地端 qwen3-coder 先修 → 修不掉升級雲端」這一環。

## 計畫 milestone

- **M1** 註冊 runner 到 gsinvest017-ai/gs-auto-fix（labels: gpu, ollama）
- **M2** 修 claude-fix-local.yml 的 Windows 相容性 + 防呆，建本進度檔
- **M3** workflow_dispatch 端到端驗證 runner 撿到 job 且步驟跑通

## 進度日誌

### M1 — runner 註冊（2026-07-03）

- 下載 actions-runner v2.335.1 win-x64 → `C:\actions-runner-gsautofix`
- `config.cmd --unattended` 註冊成功：runner 名 `rtx5090-win`，
  labels `self-hosted, Windows, X64, gpu, ollama`
- **服務安裝需管理員權限（shell 未提權）→ 改走使用者登入排程任務**：
  - 任務名 `gh-runner-gsautofix`，AtLogOn 觸發、Interactive logon、
    無執行時限、失敗自動重啟 3 次
  - 用 `run-hidden.vbs`（wscript windowStyle=0）包 `run.cmd` 免彈視窗
    （範本複製自 tw-news-board/tools）
  - 跑在使用者 session = 與現有 gsportal runner 同權限模型，GPU / Ollama
    / 使用者環境直接可用
- **坑：PATH 上的 `bash` 是 WSL bash**（WindowsApps）。`shell: bash` 會把
  job 丟進 WSL 跑，與 setup-python 的 Windows 工具鏈脫節。
  → 在 runner 目錄放 `.path` 檔，把 `C:\Program Files\Git\bin` 排最前，
  重啟 runner 後生效。
- GitHub 端確認 `rtx5090-win` status=online

### M2 — workflow 相容性修正（2026-07-03）

- `claude-fix-local.yml` 三處：
  1. `defaults.run.shell: bash` — 步驟原本就是 bash 語法，Windows runner
     預設 pwsh 會炸；統一走 Git Bash
  2. `concurrency.group: rtx5090-gpu` — 同機單卡，GPU job 序列化，
     之後其他 repo 的 GPU workflow 也用同一個 group 名
  3. 「local solved -> open PR」step 加空變更防呆：repo 測試本來就綠時
     gate 回 0，原版會 `git commit` 空變更而炸；現在直接跳過開 PR
- 建本進度檔

### M3 — 端到端驗證（2026-07-03）

- push 後用 `gh workflow run claude-fix-local.yml` 觸發（workflow_dispatch）
- 結果見最終報告 / 下方補記

## Fallback 指引

- **停用 runner**：`Stop-ScheduledTask gh-runner-gsautofix`；
  永久移除：`Unregister-ScheduledTask gh-runner-gsautofix` +
  `C:\actions-runner-gsautofix\config.cmd remove --token <gh api -X POST
  repos/gsinvest017-ai/gs-auto-fix/actions/runners/remove-token>`
- **runner 掉線排查**：工作排程器看 `gh-runner-gsautofix` LastTaskResult；
  log 在 `C:\actions-runner-gsautofix\_diag\`
- **回滾 workflow**：本次變更只動 `claude-fix-local.yml` 與本檔，
  `git revert` 對應 commit 即可；runner 註冊不受影響
- **相關機器狀態**：同機另有 `C:\actions-runner-gsportal`（GSINVEST/
  GSPortal-latest 用，Windows service），兩者互不相干

## 已知限制 / 後續

- gsinvest017-ai 是個人帳號，runner 無法跨 repo 共用；其他 repo 要 GPU CI
  需在同機各註冊一個 runner instance（建議之後開 gs-runner-fleet 收斂
  註冊腳本與 labels 慣例），GPU job 記得共用 `concurrency.group: rtx5090-gpu`
- runner 監控尚未接 gs-obs-radar（offline 目前是靜默的）
- Mac Studio（arm64）可另註冊補 macOS 測試，未做
