# 進度：機器人 PR 不再被送去 AI review

**起點**：PR #18（dependabot bump `github/codeql-action` 3 → 4.37.3）的 `Claude PR review`
job 紅燈，[run 30699145258](https://github.com/gsinvest017-ai/gs-auto-fix/actions/runs/30699145258)。

## 根因（兩道關卡疊在一起）

從該次 run 的 log 直接讀出來的，不是推測：

**① `allowed_bots` 沒放行 dependabot**

```
allowed_bots: github-actions
##[error]Action failed with error: Workflow initiated by non-human actor:
        dependabot (type: Bot). Add bot to allowed_bots list or use '*' to allow all bots.
```

**② 就算放行也一樣跑不動——secret 根本沒進到 run 裡**

同一份 log：

```
"claude_code_oauth_token": "",
CLAUDE_CODE_OAUTH_TOKEN:
```

而 repo 明明設了這個 secret（`gh secret list` 看得到，2026-05-08 建立）。原因是
**dependabot 觸發的 `pull_request` run 讀的是 Dependabot secrets，不是 Actions secrets**，
而本 repo 的 Dependabot secrets 是空的。

所以「把 dependabot 加進 `allowed_bots`」只會把紅燈從第一道換到第二道。

## 為什麼選「跳過」而不是「讓它跑起來」

要讓它真的跑，得把 token 另外設成 Dependabot secret。但 dependabot 的 PR 改的正是
`.github/workflows/*.yml`——等於把長效 token 交給一個有權改 workflow 的來源。
這個洞 GitHub 本來就是刻意堵上的，不該為了一個版本 bump 的 review 去繞開。

而版本 bump 本來就有 `ci` / `semgrep` / `secret-scan` / `security-sweep` 把關，
LLM review 在這裡的邊際價值接近零。這個 repo 21 個 PR 裡有 8 個是 dependabot 開的，
等於每 3 個 PR 就有 1 個掛著一顆作者無從處理的紅燈。

## 改了什麼

| 檔案 | 做法 | 為什麼是這個層級 |
|------|------|------------------|
| `claude-review.yml` | job 層級 `if:` 白名單 | 沒有其他 step，整個 job 跳過最省 runner |
| `_reusable-pr-review.yml` | `precheck` step 內跳過 | 最後的「閘門判定」要被拿去當 required check，整個 job skip 掉時它算 pass 還是永遠 pending，各家 branch protection 行為不一致；讓 job 照跑、綠燈收尾沒有歧義。附帶好處是不花 token 的敏感路徑檢查對 bot 的 PR 也照樣生效 |

兩邊都是**白名單**（人類 + `github-actions[bot]`）而不是 `!= 'dependabot[bot]'`——
黑名單擋不住下一個接進來的 bot。同 94cbfc5 收窄 claude-fix 白名單的理由。

`github-actions[bot]` 保留放行是刻意的：auto-fix loop 自己寫的 PR 是最需要被審的那批。
（註：截至目前這條 loop 還沒真的產出過 PR，見 c0ce1fe，所以這條路徑尚未在真實流量上驗證過。）

## 驗證

- `pytest tests/` — 26 passed（原 20 + 新增 6 條 precheck 測試）
- 新測試不是空殼：把 bot 判斷從 YAML 拿掉後，3 條測試轉紅，補回去再全綠
- 每個 `run:` block 都通過 `bash -n`
- precheck 腳本直接以 5 種情境實跑：dependabot / renovate → `skip=true`；
  github-actions[bot] / 人類 → `skip=false`；缺 token → `skip=true` + warning

`test_precheck_allowlist_matches_action_allowed_bots` 專門擋「只改一邊」：
precheck 放行的 bot 若不在 action 的 `allowed_bots` 裡，照樣會紅燈。

## 待辦

- [ ] 這個修正合進 `main` 之後，PR #18 需要重跑才會吃到新的 workflow 定義
      （`pull_request` 讀的是 merge ref；base 更新後用 `gh pr update-branch` 或關閉再開啟觸發）。
- [ ] `_reusable-pr-review.yml` 的下游呼叫端釘的是 tag，改動要發新 tag 才會擴散。
