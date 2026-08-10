# 教學型 PR review — 使用手冊

`_reusable-pr-review.yml` 是給「協作者多數沒受過正式程式訓練」的 repo 用的 PR review + 軟閘門。
本檔是它的正規說明；prompt 本身住在 workflow 裡，改 prompt 請改那支檔案。

與 `claude-review.yml`（本 repo 自用那支）的差別：

| | `claude-review.yml` | `_reusable-pr-review.yml` |
|---|---|---|
| 讀者 | 資深工程師 | **沒受過程式訓練的協作者** |
| 語氣 | 「Skip style nits, bikeshedding」 | 解釋為什麼、給可複製的修法 |
| blocking 範圍 | 由模型自行拿捏 | **只有安全 / 正確性 / 破壞既有行為** |
| 事件 | `pull_request` | **`pull_request_target`** |
| fork PR | ❌ 跑不動 | ✅ |
| 閘門 | 無 | `needs-work` label → status check |

---

## 怎麼接

呼叫端放一支 `.github/workflows/pr-review.yml`：

```yaml
name: PR review
on:
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize]

jobs:
  review:
    permissions:
      contents: read
      pull-requests: write
      issues: write
    uses: gsinvest017-ai/gs-auto-fix/.github/workflows/_reusable-pr-review.yml@v1
    secrets: inherit
    with:
      project_context: 這個 repo 在做 XXX。
```

四件事不能省：

1. **事件必須是 `pull_request_target`**。用 `pull_request` 的話，來自 fork 的 PR 拿不到
   `CLAUDE_CODE_OAUTH_TOKEN`（GitHub 不對 fork 注入 secret），而唯讀協作者只能走 fork——
   結果就是最該被 review 的 PR 完全跑不到。
2. **釘 tag（`@v1`）不要用 `@main`**。否則改一次 prompt，所有 repo 的 review 行為當場全變。
3. **`secrets: inherit`**，否則 `CLAUDE_CODE_OAUTH_TOKEN` 傳不進去。
4. **`permissions:` 一定要寫在呼叫端。** 被呼叫的 reusable workflow 拿到的權限**不能超過
   呼叫端 token 的上限**。多數 repo 的 `Settings → Actions → Workflow permissions` 是預設的
   `read`，這時 reusable workflow 要求的 `pull-requests: write` 會讓整個 run 變成
   **`startup_failure`——沒有 job、沒有 log、UI 上完全看不出原因**。在呼叫端明確宣告會蓋過
   repo 預設值，爆炸半徑也比去 settings 開全域 write 小。

   查目前設定：
   ```bash
   gh api repos/<owner>/<repo>/actions/permissions/workflow
   ```
   `gs-auto-fix` 自己是 `write`，所以**在它身上測不出這個問題**——三個 pilot repo 全是 `read`，
   是在真實 PR 上才踩出來的。

### secret 怎麼設

**不要用 `~/.claude/.credentials.json` 裡的 token。** 那是 session access token，通常幾小時就過期，
塞進 GitHub secret 會先能動、之後靜默壞掉。CI 要的是長效 token：

```bash
claude setup-token                                              # 互動式，產生長效 token
gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>         # 貼上上一步的輸出
```

**沒設也可以先合 workflow。** 缺 secret 時 review 會乾淨跳過（只留一則 warning annotation），
不會製造紅燈；不需要 token 的 path guard 仍然照跑。補上 secret 後下一個 PR 就會生效。

`gs-auto-fix` 是 public repo，所以 private repo（含跨 org）都呼叫得到。
若哪天它變 private，這條路會直接斷——private repo 的 reusable workflow 只能被同 owner 的 repo 呼叫。

---

## 安全模型（動這支檔案前務必先讀）

`pull_request_target` 是在 **base repo 的 context** 執行的，握有 secret 與寫入權。
代價是：**任何被 checkout 進來並執行的 PR 程式碼，都等同於把 token 交給 PR 作者。**

本 workflow 的四道約束，缺一不可：

有兩類攻擊面，要分開處理。

### A. 執行 PR 的程式碼（RCE）

| 約束 | 為什麼 |
|------|--------|
| `actions/checkout` 不帶 ref（只取 base） | 取 `head.sha` 就是把外人的 code 拉進特權 context |
| diff 走 `gh pr diff` 存成純資料檔，不執行 | 不產生會被執行的東西 |
| 不跑 PR 的 test / build / lint / 安裝依賴 | `pip install` 會執行 `setup.py`、npm 會跑 `postinstall`，都是任意程式碼執行 |

跑 PR 的程式碼是 **CI 的職責**。CI 用 `pull_request` 事件，在沒有 secret 的隔離沙箱裡跑，那才是安全的地方。

### B. 間接 prompt injection（模型被 diff 誘導去濫用自己的工具）

這是**不同的一類**，A 的四道約束一條都擋不到它。

前提：這支 workflow 的存在意義就是審查來自 fork 的 PR，所以 **diff 是攻擊者 100% 可控的輸入**，
而它被讀進一個握有 `pull-requests: write` token 的模型的 context。

失敗的做法是給模型 `--allowed-tools "Bash(gh pr comment:*),Bash(gh pr edit:*)"`：

- 那是**指令前綴比對，不是參數限制**。`gh pr edit <別的PR> --remove-label needs-work` 照樣通過。
- 更糟：`gh pr comment $PR --body "$(env)"` 也通過比對，但 `$( )` 會在 shell 展開，
  等於**把 `GH_TOKEN` 與 `CLAUDE_CODE_OAUTH_TOKEN` 貼成一則留言**。若 repo 是 public，
  那就是長效憑證公開外洩。
- 只靠 prompt 說「只能動這個 PR 編號」不是 ACL，是請求。

現在的做法是**讓模型完全沒有 shell**：

| 誰做 | 做什麼 |
|------|--------|
| workflow（固定邏輯） | 抓 diff 存成 `pr.diff`、`pr-meta.txt` |
| 模型（`--allowed-tools "Read,Grep,Glob,Write"`） | 讀那兩個檔，把 review 寫進 `review-output.md`，最後一行給 `NEEDS_WORK: yes\|no` |
| workflow（固定邏輯） | 讀 `review-output.md`、`gh pr comment --body-file`、依判定加 label |

模型能影響的只剩「留言文字」與「一個 yes/no」，影響不到「對哪個 PR 動作」「用什麼參數」。
留言用 `--body-file` 而非 `--body "..."`，內容不經 shell 展開。

**殘留風險（已知並接受）**：注入仍可能讓模型給出錯誤的 `NEEDS_WORK` 判定，或在留言裡寫進誤導文字。
前者用 **fail closed** 降低——判定行缺失或無法辨識時一律標 `needs-work`，所以「把判定行抹掉」
的注入結果是被擋，不是被放行。後者只是文字，人看得到。

這三段 shell 的行為由 `tests/test_pr_review_workflow.py` 覆蓋，該測試**直接從 YAML 抽出
`run:` block 執行**，所以測試與實作不可能漂移；其中兩條是靜態不變式：模型不得有任何 `Bash`
權限、留言必須走 `--body-file`。

---

## 兩道閘門

**① 確定性 path guard（不花 token）**

`guard_paths` 收一組 regex，一行一條。命中就直接擋下並**中止，不呼叫 LLM**。
用途是「這些檔案連送去 review 都不行」——例如含真實個資的 fixtures。

先用 shell 判掉能判的，判不了的才丟給模型。順序倒過來就等於先把敏感內容送出去再說。

**② review 判定 → label → status check**

Claude 發現 blocking 問題時執行 `gh pr edit --add-label needs-work`，
最後一個 step 讀 label 決定 job 紅綠。

每次執行**開頭會先移除 label**——不清的話，作者修好推新 commit 後，上一輪留下的 label 會讓閘門永遠紅著。

閘門強度取決於 repo 方案：

| repo | 強度 | 做法 |
|------|------|------|
| public / 付費 org（Team 以上） | **硬閘門** | ruleset 加 required status check，紅了就 merge 不了 |
| Free 方案的 private repo | **軟閘門** | ruleset 設不了；紅燈 + label 只是自律護欄，擋不住有 write 權的人手動 merge |

Free private repo 的缺口是**方案問題不是技術問題**，三條路是：搬到付費 org、升級 org 到 Team、
或把協作者降權成 read 讓他們走 fork-PR。完整說明在本機工具 `gh-branch-guard` 的 README
（`C:\Users\User\tools\gh-branch-guard\README.md`，不在本 repo 內）。

---

## 已知限制

- **加上這支 workflow 的那個 PR，自己不會被 review。** `pull_request_target` 讀的是 base 分支的
  workflow 定義，而那時 base 還沒有這支檔案。第二個 PR 起才會生效。
- **Claude Max 額度是共用的。** 所有接上的 repo 都吃同一份訂閱額度，會跟你自己的 Claude Code
  session 互搶。擴散到大量 repo 前先量測。
- **`needs-work` label 可以被手動移除。** 這是刻意的——誤判時作者要有辦法繼續。
  代價是軟閘門更軟，硬閘門則不受影響（required check 會重跑）。
- **⚠️ 沒設 secret 又把這個 job 設成 required check ＝ 零保護但看起來像有保護。**
  缺 secret 時 review 乾淨跳過並回綠燈，git 歷史上會看到「每個 PR 都通過 review」，
  但實際一次都沒跑過。設 required check 前先確認 secret 已存在：
  `gh secret list -R <owner>/<repo> | grep CLAUDE_CODE_OAUTH_TOKEN`
