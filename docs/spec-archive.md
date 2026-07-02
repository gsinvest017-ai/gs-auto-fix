# spec-archive workflow

合併帶 `spec-archive` label 的 PR 後，`.github/workflows/spec-archive.yml` 會把 PR body
`Spec: <path>` 指到的 spec，從 gs-vault 的 `specs/` 歸檔到 `archive/`（status→archived、
patch bump），完成 gs-spec-forge 的 brainstorm→spec→dev→CR→PR→CICD 閉環最後一段。

## 啟用條件
- repo secret `SPEC_FORGE_VAULT_REPO`（vault repo）、`SPEC_FORGE_VAULT_TOKEN`（對其 Contents 寫入）
- PR 帶 `spec-archive` label，且 body 有一行 `Spec: <vault 內相對路徑>`

無 label 或未設 secret 時 workflow 完全跳過，對一般開發流程零影響。
