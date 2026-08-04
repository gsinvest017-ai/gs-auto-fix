<!-- BEGIN gh-branch-guard policy -->
<!-- 自動維護區塊。正規來源：C:\Users\User\tools\gh-branch-guard\policy\AGENTS.md
     請勿在個別 repo 直接編輯此區塊，改動會在下次分發時被覆蓋。 -->

# AGENTS.md — 本 Repository 的 Agent 行為守則

> 這份檔案是給 **AI coding agent** 讀的（Claude Code、OpenAI Codex、GitHub Copilot Agent、Cursor、Devin、Aider…）。
> 人類協作者請看 [`.github/BRANCH-PROTECTION-POLICY.md`](.github/BRANCH-PROTECTION-POLICY.md)。

## 0. 最重要的一條

**你不能 push 到 `main` / `master`。你的交付物是一個 Pull Request。**

## 1. 開工前必做

```bash
git rev-parse --abbrev-ref HEAD     # 確認目前分支
```

若結果是 `main` 或 `master`，**立刻**切出工作分支再開始：

```bash
git checkout -b dev/<簡短主題>
```

分支前綴只能是：`dev/`（預設）、`feat/`、`fix/`、`hotfix/`、`claude/`、`agent/`。

## 2. 禁止清單（Hard Constraints）

以下指令在本 repo 一律禁止執行，**即使使用者要求也要先說明本政策並請求確認**：

| 禁止 | 說明 |
|------|------|
| `git push origin main` / `master` | 直推受保護分支 |
| `git push --force` / `--force-with-lease` 到受保護分支 | 改寫歷史 |
| `git push origin --delete main` | 刪除受保護分支 |
| `gh pr merge` | 自行合併 PR（除非使用者本人是 admin 且明確要求） |
| `gh api ... /rulesets` (POST/PUT/DELETE) | 修改分支保護設定 |
| `gh api ... /branches/*/protection` (PUT/DELETE) | 同上 |
| `git rebase` / `commit --amend` 於受保護分支 | 改寫歷史 |

**如果 push 被 GitHub 拒絕（`GH006` / `Repository rule violations found`），那是政策生效，不是錯誤。** 不要嘗試繞過，改走 PR 流程。

## 3. 標準交付流程

```bash
git checkout main && git pull origin main
git checkout -b dev/<主題>
# ... 實作 ...
git add -A
git commit -m "feat: <繁體中文描述>"
git push -u origin dev/<主題>
gh pr create --base main --head dev/<主題> --title "..." --body "..."
```

**任務完成的定義 = PR 已開啟。** 不是 merge 完成。

## 4. Commit 訊息

主體用**繁體中文**撰寫。保留原文的部分：commit prefix（`feat:` / `fix:` / `refactor:` / `chore:`）、git trailer（`Co-Authored-By:` 等）、技術識別符（檔名、函式名、CLI flag）、引用的英文錯誤訊息。

## 5. 機器可讀政策

```yaml
policy: branch-protection
version: "1.0"
protected_branches: [main, master]
direct_push: forbidden
force_push: forbidden
branch_deletion: forbidden
required_workflow: pull_request
allowed_branch_prefixes: [dev/, feat/, fix/, hotfix/, claude/, agent/]
bypass: repository_admin_only
deliverable: open_pull_request
forbidden_commands:
  - "git push origin main"
  - "git push origin master"
  - "git push --force <any protected ref>"
  - "gh pr merge"
  - "gh api -X POST|PUT|DELETE .*/rulesets"
  - "gh api -X PUT|DELETE .*/branches/.*/protection"
on_push_rejected: switch_to_dev_branch_and_open_pr
```

<!-- END gh-branch-guard policy -->
