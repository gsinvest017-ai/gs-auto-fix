<!-- BEGIN gh-branch-guard policy -->
<!-- 自動維護區塊。正規來源：C:\Users\User\tools\gh-branch-guard\policy\CONTRIBUTING.md -->

# 貢獻指南 / Contributing

## TL;DR

**`main` / `master` 受保護，不能直接 push。請從 `dev/<主題>` 分支開 Pull Request。**

```bash
git checkout main && git pull origin main
git checkout -b dev/my-topic
# ... 開發 ...
git commit -m "feat: 說明變更內容"
git push -u origin dev/my-topic
gh pr create --base main --head dev/my-topic
```

## 分支命名

| 前綴 | 用途 |
|------|------|
| `dev/` | 一般開發（**不確定就用這個**） |
| `feat/` | 新功能 |
| `fix/` | 修 bug |
| `hotfix/` | 緊急修復 |
| `claude/`、`agent/` | AI agent 產生 |

主題用 kebab-case：`dev/add-retry-logic`。

## 只有 read 權限？走 fork

部分 repo 的協作者是唯讀的（刻意設計）。此時：

```bash
gh repo fork <owner>/<repo> --clone && cd <repo>
git checkout -b dev/my-topic
git push -u origin dev/my-topic
gh pr create --repo <owner>/<repo> --base main --head <你的帳號>:dev/my-topic
```

## Commit 訊息

主體用繁體中文；prefix（`feat:`/`fix:`/`chore:`…）、trailer、技術識別符保留原文。

## 使用 AI agent 協作？

請確保你的 agent 讀得到 [`AGENTS.md`](AGENTS.md) —— 裡面有給 agent 的硬性行為約束（禁止直推 main、禁止 force push、禁止自行 merge PR）。

## 完整政策

見 [`.github/BRANCH-PROTECTION-POLICY.md`](.github/BRANCH-PROTECTION-POLICY.md)。

<!-- END gh-branch-guard policy -->
