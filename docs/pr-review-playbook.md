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
    uses: gsinvest017-ai/gs-auto-fix/.github/workflows/_reusable-pr-review.yml@v1
    secrets: inherit
    with:
      project_context: 這個 repo 在做 XXX。
```

三件事不能省：

1. **事件必須是 `pull_request_target`**。用 `pull_request` 的話，來自 fork 的 PR 拿不到
   `CLAUDE_CODE_OAUTH_TOKEN`（GitHub 不對 fork 注入 secret），而唯讀協作者只能走 fork——
   結果就是最該被 review 的 PR 完全跑不到。
2. **釘 tag（`@v1`）不要用 `@main`**。否則改一次 prompt，所有 repo 的 review 行為當場全變。
3. **`secrets: inherit`**，否則 `CLAUDE_CODE_OAUTH_TOKEN` 傳不進去。

`gs-auto-fix` 是 public repo，所以 private repo（含跨 org）都呼叫得到。
若哪天它變 private，這條路會直接斷——private repo 的 reusable workflow 只能被同 owner 的 repo 呼叫。

---

## 安全模型（動這支檔案前務必先讀）

`pull_request_target` 是在 **base repo 的 context** 執行的，握有 secret 與寫入權。
代價是：**任何被 checkout 進來並執行的 PR 程式碼，都等同於把 token 交給 PR 作者。**

本 workflow 的四道約束，缺一不可：

| 約束 | 為什麼 |
|------|--------|
| `actions/checkout` 不帶 ref（只取 base） | 取 `head.sha` 就是把外人的 code 拉進特權 context |
| diff 一律走 `gh pr diff`（API），不落地 | 不產生可被執行的檔案 |
| 不跑 PR 的 test / build / lint / 安裝依賴 | `pip install` 會執行 `setup.py`、npm 會跑 `postinstall`，都是任意程式碼執行 |
| `--allowed-tools` 不含通用 `Bash` | 只開 `gh pr diff/view/comment/edit` 與唯讀的 Read/Grep/Glob |

跑 PR 的程式碼是 **CI 的職責**。CI 用 `pull_request` 事件，在沒有 secret 的隔離沙箱裡跑，那才是安全的地方。

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

Free private repo 的缺口是**方案問題不是技術問題**，三條路寫在
`gh-branch-guard/README.md`（搬到付費 org / 升級 org / 協作者降權走 fork-PR）。

---

## 已知限制

- **加上這支 workflow 的那個 PR，自己不會被 review。** `pull_request_target` 讀的是 base 分支的
  workflow 定義，而那時 base 還沒有這支檔案。第二個 PR 起才會生效。
- **Claude Max 額度是共用的。** 所有接上的 repo 都吃同一份訂閱額度，會跟你自己的 Claude Code
  session 互搶。擴散到大量 repo 前先量測。
- **`needs-work` label 可以被手動移除。** 這是刻意的——誤判時作者要有辦法繼續。
  代價是軟閘門更軟，硬閘門則不受影響（required check 會重跑）。
