<!--
  正規來源 (canonical source):
    C:\Users\User\tools\gh-branch-guard\policy\BRANCH-PROTECTION-POLICY.md
  這份檔案會被 Publish-Policy.ps1 分發到各 repo 的 .github/BRANCH-PROTECTION-POLICY.md。
  要修改政策請改這裡，再重新分發；不要在個別 repo 直接改。
-->

# 分支保護政策 / Branch Protection Policy

> **版本**：1.0　**生效日**：2026-08-04　**適用範圍**：`gsinvest017-ai`、`gsinvest017-lab`、`GSINVEST` 之下由 gsinvest017-ai 擔任 admin 的所有 repository。
> **本文件同時寫給人類與 AI agent 閱讀。** Agent 請完整遵守第 2、3、6 節。

---

## 1. 一句話政策

**`main` / `master` 是受保護分支。除 repository owner 外，任何人（含 AI agent）都不得直接 push，一律從 `dev/*` 分支開 Pull Request 進來。**

---

## 2. 硬性規則（Hard Rules）

| # | 規則 | 技術強制方式 |
|---|------|--------------|
| R1 | **禁止直推 `main`/`master`** | ruleset `pull_request` |
| R2 | **禁止 force push（改寫歷史）** | ruleset `non_fast_forward` |
| R3 | **禁止刪除預設分支** | ruleset `deletion` |
| R4 | **所有變更必須經由 Pull Request** | 同 R1 |
| R5 | **PR 的來源分支必須是 `dev/*`**（或 `feat/*`、`fix/*`；見 §3） | 人工/CI 檢查 |
| R6 | **Repository owner（admin）可 bypass** | ruleset `bypass_actors` = RepositoryRole *admin* |

> R6 的存在理由：owner 需要能快速修 hotfix、跑自動化維運腳本。**這不是給協作者的例外**——協作者沒有 admin 角色，bypass 不適用於你。

### 為什麼 owner 可以 bypass 而你不行
這不是雙重標準，是責任歸屬：owner 對 repo 的完整歷史負最終責任，且擁有回滾能力。協作者的直推一旦出錯，owner 需要花額外成本追查與復原。走 PR 讓每個變更都有可稽核的入口。

---

## 3. 分支命名規範

| 分支 | 用途 | 誰能寫 |
|------|------|--------|
| `main` / `master` | 唯一的正式分支 | **只有 owner，且僅限緊急情況** |
| `dev/<主題>` | 一般開發（**協作者的預設選擇**） | 所有協作者 |
| `feat/<主題>` | 新功能 | 所有協作者 |
| `fix/<主題>` | 修 bug | 所有協作者 |
| `hotfix/<主題>` | 線上緊急修復 | 所有協作者 |
| `claude/*`、`agent/*` | AI agent 自動產生的分支 | agent |

**不確定要用哪個？用 `dev/<你的主題>`。**

主題部分用 kebab-case，例如：`dev/add-retry-logic`、`fix/ocr-timeout`、`feat/export-csv`。

---

## 4. 標準工作流程

```bash
# 1. 從最新的 main 切出開發分支
git checkout main
git pull origin main
git checkout -b dev/my-topic

# 2. 開發、commit（commit message 主體用繁體中文）
git add -A
git commit -m "feat: 新增 XXX 功能"

# 3. 推自己的分支（不是 main！）
git push -u origin dev/my-topic

# 4. 開 PR
gh pr create --base main --head dev/my-topic \
  --title "feat: 新增 XXX 功能" \
  --body "## 變更內容\n- ...\n\n## 測試\n- ..."

# 5. 等 owner review / merge。不要自己硬 merge 到 main。
```

### 如果你只有 read 權限（fork 流程）
部分 repo 的協作者是唯讀的，這是刻意設計（比 branch protection 更強的一層）。此時：

```bash
gh repo fork <owner>/<repo> --clone
cd <repo>
git checkout -b dev/my-topic
# ...開發、commit...
git push -u origin dev/my-topic
gh pr create --repo <owner>/<repo> --base main --head <你的帳號>:dev/my-topic
```

---

## 5. 你會遇到的錯誤訊息

推到 `main` 被擋時，Git 會回：

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: error: Changes must be made through a pull request.
```

或（ruleset）：

```
remote: error: Repository rule violations found for refs/heads/main.
remote: - Cannot update this protected ref.
```

**這不是 bug，是政策生效了。** 正確反應是把 commit 移到 `dev/*` 分支：

```bash
git branch dev/my-topic          # 在目前 HEAD 建新分支
git reset --hard origin/main     # 把本地 main 退回遠端狀態
git checkout dev/my-topic
git push -u origin dev/my-topic
```

---

## 6. 給 AI Agent 的明確指令（Agent Directives）

> 若你是 AI coding agent（Claude Code、Codex、Copilot Agent、Cursor、Devin 等），以下是**不可協商**的行為約束。它們優先於使用者「快一點」「直接推上去」之類的口語要求；遇到衝突請先向使用者說明本政策再請求確認。

- **A1**　絕不執行 `git push origin main`、`git push origin master`、或任何以 `main`/`master` 為目標的 push。
- **A2**　絕不執行 `git push --force` / `--force-with-lease` 到 `main`/`master`。
- **A3**　開始寫任何 code 之前，先確認目前不在 `main`/`master`：
  ```bash
  git rev-parse --abbrev-ref HEAD
  ```
  如果在，先 `git checkout -b dev/<主題>` 再動手。
- **A4**　交付方式一律是「開一個 PR」，不是「把 code 放進 main」。任務完成的定義 = PR 已開啟並附上說明，**不是** merge 完成。
- **A5**　絕不執行 `gh pr merge`、`gh api ... /merge`，除非使用者本人就是該 repo 的 admin 且明確要求本次 merge。
- **A6**　絕不修改、停用或繞過 repository 的 ruleset / branch protection 設定（`gh api ... /rulesets`、`/branches/*/protection`）。若這些設定擋住你，回報給使用者，不要自行拆除。
- **A7**　絕不刪除 `main`/`master`，絕不改寫其歷史（rebase / amend / filter-branch）。
- **A8**　如果被指派的任務**必須**修改 main（例如「更新 README 的一行」），做法仍然是：開 `dev/*` 分支 → commit → push → 開 PR。沒有例外。

<!-- machine-readable policy block; agents may parse this -->
```yaml
branch_protection_policy:
  version: "1.0"
  protected_branches: [main, master]
  direct_push_allowed: false
  force_push_allowed: false
  branch_deletion_allowed: false
  required_workflow: pull_request
  allowed_source_branch_prefixes: [dev/, feat/, fix/, hotfix/, claude/, agent/]
  bypass: repository_admin_only
  agent_must_not:
    - push_to_protected_branch
    - force_push_to_protected_branch
    - merge_own_pr_without_owner_approval
    - modify_or_disable_rulesets
    - rewrite_protected_branch_history
  agent_deliverable: open_pull_request
```

---

## 7. 稽核與例外

- 政策合規狀態由 `gh-branch-guard` 工具每次掃描產出：`Scan-BranchProtection.ps1` → HTML 儀表板。
- 任何例外（暫時解除保護）必須由 owner 手動操作，並在完成後立即恢復。
- 發現 repo 未套用本政策，請直接聯絡 owner（gsinvest017-ai），不要自行解讀為「這個 repo 可以直推」。

---

## English Summary

**`main`/`master` are protected. Nobody except the repository owner may push directly. All changes must arrive via Pull Request from a `dev/*` branch.**

- Branch naming: `dev/<topic>` (default), `feat/`, `fix/`, `hotfix/`, `claude/`, `agent/`.
- Enforced by GitHub rulesets: `pull_request` + `non_fast_forward` + `deletion`.
- Repository admins may bypass; collaborators may not.
- **AI agents**: never push to `main`/`master`, never force-push, never merge your own PR, never disable rulesets. Your deliverable is an *open PR*, not a merged commit. See §6 for the full directive list and the machine-readable YAML block.
