"""_reusable-pr-review.yml 裡兩段把關 shell 的行為測試。

為什麼要測：這兩段決定了「敏感內容會不會被送去 LLM」與「PR 會不會被放行」，
出錯的代價分別是個資外流與閘門失效，但它們內嵌在 YAML 的 run: block 裡，
沒有測試就沒人會發現改壞了。

為什麼是「從 YAML 抽出來跑」而不是把腳本複製一份到 tests/：
reusable workflow 的 actions/checkout 取的是**呼叫端** repo，本 repo 的
scripts/ 不會出現在執行環境裡，所以邏輯必須內嵌在 YAML。既然不能抽成檔案，
測試就直接讀 YAML 執行，這樣邏輯與測試永遠不可能漂移。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest
import yaml  # 宣告在 requirements.txt；缺了要讓 CI 紅，不要靜默 skip

WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "_reusable-pr-review.yml"
)

GUARD_STEP = "敏感路徑檢查"
PRECHECK_STEP = "決定是否執行 AI review"
VERDICT_STEP = "貼出 review 並套用閘門判定"

GUARD_104 = "\n".join([r"^fixtures/.*\.json$", "^reports/", r"\.db$", r"\.sqlite3?$"])
GUARD_ARENA = "\n".join(["^workspaces/", "^reports/", r"^data/arena\.db"])


def _step_script(step_name: str) -> str:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for step in doc["jobs"]["review"]["steps"]:
        if step.get("name") == step_name:
            return step["run"]
    raise AssertionError(f"workflow 裡找不到名為 {step_name!r} 的 step")


def _fake_gh(tmp_path: Path, changed_files: str = "") -> Path:
    """假的 gh：回傳指定的檔案清單，其餘子指令記錄呼叫後成功返回。

    記錄檔讓測試能斷言「有沒有加 label」這種副作用。
    """
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "gh").write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env bash
            echo "$@" >> "{tmp_path.as_posix()}/gh-calls.log"
            if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
              cat <<'CHANGED'
{changed_files}
CHANGED
              exit 0
            fi
            exit 0
            """
        ),
        encoding="utf-8",
    )
    (bindir / "gh").chmod(0o755)
    return bindir


def _msys(p: Path) -> str:
    """C:\\Users\\x → /c/Users/x（Git Bash 的 PATH 認得的形式）。"""
    s = p.as_posix()
    if os.name == "nt" and len(s) > 1 and s[1] == ":":
        return f"/{s[0].lower()}{s[2:]}"
    return s


def _bash() -> str:
    """在 Windows 上明確挑 Git Bash。

    裸 `bash` 在裝了 WSL 的 Windows 會解析到 WSL 的 bash，它看到的是 /mnt/... 檔案系統，
    測試用的假 gh 不在它的 PATH 上，於是真的 gh 被呼叫、噴 git 錯誤——症狀完全不像
    「PATH 挑錯直譯器」，很容易往邏輯錯誤的方向查。
    """
    if os.name == "nt":
        for candidate in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if Path(candidate).exists():
                return candidate
        pytest.skip("Windows 上找不到 Git Bash；這些測試在 CI（ubuntu）會跑")
    found = shutil.which("bash")
    if not found:
        pytest.skip("環境裡沒有 bash")
    return found


def _run(script: str, cwd: Path, bindir: Path, env: dict[str, str]):
    # 寫成檔案再執行，不要用 bash -c "<多行腳本>"：在 Windows 上 argv 會走 MSVC
    # 的引號規則，單引號與反斜線會被吃掉（printf '%s\n' 變成 printf %sn），
    # 腳本以完全不同的語意執行。
    script_file = cwd / "_step.sh"
    script_file.write_text(script, encoding="utf-8", newline="\n")

    # PATH 在 bash 裡是用 `:` 分隔的，而 Windows 的 PATH 每一項都含磁碟機冒號
    # （C:\Windows;...）。把兩者串起來會被切成一堆碎片，假 gh 進不了搜尋路徑，
    # 真的 gh 被呼叫，錯誤訊息看起來完全像是腳本邏輯壞掉。
    # Windows 上改成只給 MSYS 形式的 bindir + Git Bash 自己的 /usr/bin。
    if os.name == "nt":
        path = f"{_msys(bindir)}:/usr/bin:/bin"
    else:
        path = f"{bindir}{os.pathsep}{os.environ['PATH']}"

    full_env = {
        **os.environ,
        "PR": "1",
        "PATH": path,
        **env,
    }
    return subprocess.run(
        [_bash(), str(script_file)],
        cwd=cwd,
        env=full_env,
        capture_output=True,
        # 不指定就會用系統 locale（Windows 上是 cp950），中文輸出直接 UnicodeDecodeError。
        encoding="utf-8",
        errors="replace",
    )


def _calls(tmp_path: Path) -> str:
    log = tmp_path / "gh-calls.log"
    return log.read_text(encoding="utf-8") if log.exists() else ""


# ---------------------------------------------------------------- guard


@pytest.mark.parametrize(
    "changed, guard, blocked, why",
    [
        ("parser.py\napp.py\nfixtures/README.md", GUARD_104, False, "一般改動放行"),
        ("parser.py\nfixtures/sample_detail.json", GUARD_104, True, "真實履歷 fixture"),
        ("talents.sqlite3", GUARD_104, True, "sqlite 資料庫"),
        ("notes.db", GUARD_104, True, "db 副檔名"),
        ("reports/a.md\nfixtures/x.json\nb.db", GUARD_104, True, "多條 pattern 同時命中"),
        ("src/arena/cli.py\nworkspaces/c01/main.py", GUARD_ARENA, True, "考生工作區"),
        ("src/arena/cli.py", GUARD_ARENA, False, "arena 一般改動放行"),
        # guard_paths 是 YAML block scalar，尾端與中間都可能夾空行
        ("parser.py", "^reports/\n\n^workspaces/\n", False, "guard_paths 含空行不誤判"),
    ],
)
def test_guard_blocks_only_sensitive_paths(tmp_path, changed, guard, blocked, why):
    bindir = _fake_gh(tmp_path, changed)
    res = _run(
        _step_script(GUARD_STEP),
        tmp_path,
        bindir,
        {"GUARD_PATHS": guard, "GUARD_REASON": "測試用原因"},
    )
    assert (res.returncode != 0) is blocked, f"{why}: {res.returncode=} {res.stderr=}"
    if blocked:
        # 擋下時必須貼上 needs-work，否則閘門判定那步會誤放行
        assert "pr edit 1 --add-label needs-work" in _calls(tmp_path), why
        body = (tmp_path / "guard-comment.md").read_text(encoding="utf-8")
        assert "不該進版控" in body and "git rm --cached" in body, why


def test_guard_comment_lists_every_hit(tmp_path):
    bindir = _fake_gh(tmp_path, "reports/a.md\nfixtures/x.json\nkeep.py")
    _run(
        _step_script(GUARD_STEP),
        tmp_path,
        bindir,
        {"GUARD_PATHS": GUARD_104, "GUARD_REASON": "r"},
    )
    body = (tmp_path / "guard-comment.md").read_text(encoding="utf-8")
    assert "reports/a.md" in body and "fixtures/x.json" in body
    assert "keep.py" not in body, "沒命中的檔案不該出現在擋下留言裡"


# ------------------------------------------------------------- precheck


def _precheck(tmp_path: Path, author: str, author_type: str, token: str) -> dict[str, str]:
    """跑 precheck step，回傳它寫進 $GITHUB_OUTPUT 的 key/value。"""
    out = tmp_path / "gh-output.txt"
    out.write_text("", encoding="utf-8")
    res = _run(
        _step_script(PRECHECK_STEP),
        tmp_path,
        _fake_gh(tmp_path),
        {
            "GITHUB_OUTPUT": out.as_posix(),
            "PR_AUTHOR": author,
            "PR_AUTHOR_TYPE": author_type,
            "TOKEN": token,
        },
    )
    assert res.returncode == 0, f"precheck 不該非零離開: {res.stderr}"
    parsed = dict(
        line.split("=", 1) for line in out.read_text(encoding="utf-8").splitlines() if line
    )
    return {**parsed, "_stdout": res.stdout}


@pytest.mark.parametrize(
    "author, author_type, skip, why",
    [
        ("gsinvest017-ai", "User", False, "人類的 PR 照常 review"),
        ("github-actions[bot]", "Bot", False, "auto-fix loop 自己開的 PR 最需要被審"),
        ("dependabot[bot]", "Bot", True, "dependabot：allowed_bots 沒放行，會紅燈"),
        ("renovate[bot]", "Bot", True, "白名單而非黑名單——沒列名的 bot 預設跳過"),
    ],
)
def test_precheck_only_reviews_humans_and_github_actions(
    tmp_path, author, author_type, skip, why
):
    """機器人的 PR 必須在呼叫 action 之前就跳過。

    沒擋掉的話 claude-code-action 會以「Workflow initiated by non-human actor」
    exit 1，變成一個 PR 作者無從處理的紅燈——實例見 PR #18 / run 30699145258。
    """
    assert _precheck(tmp_path, author, author_type, "tok")["skip"] == str(skip).lower(), why


def test_precheck_skips_cleanly_without_token(tmp_path):
    """缺 secret 要乾淨跳過，不是讓整個 job 紅掉。"""
    result = _precheck(tmp_path, "gsinvest017-ai", "User", "")
    assert result["skip"] == "true"
    assert "CLAUDE_CODE_OAUTH_TOKEN" in result["_stdout"], "要留下告訴 repo 主人怎麼補的訊息"


def test_precheck_allowlist_matches_action_allowed_bots():
    """precheck 放行的 bot 必須也在 action 的 allowed_bots 裡，否則照樣紅燈。

    這兩份名單分屬不同檔案區塊，很容易只改一邊。
    """
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    script = _step_script(PRECHECK_STEP)
    for step in doc["jobs"]["review"]["steps"]:
        if step.get("uses", "").startswith("anthropics/claude-code-action"):
            allowed = step["with"]["allowed_bots"]
            assert "github-actions" in allowed
            assert "github-actions[bot]" in script, "precheck 放行的 bot 與 allowed_bots 不一致"
            return
    raise AssertionError("找不到 claude-code-action step")


# -------------------------------------------------------------- verdict


@pytest.mark.parametrize(
    "verdict_line, expect_label",
    [
        ("NEEDS_WORK: no", False),
        ("NEEDS_WORK: yes", True),
        ("NEEDS_WORK:   yes  ", True),
        ("", True),  # 沒有判定行 → fail closed
        ("NEEDS_WORK: maybe", True),  # 無法辨識 → fail closed
    ],
)
def test_verdict_fails_closed(tmp_path, verdict_line, expect_label):
    bindir = _fake_gh(tmp_path)
    (tmp_path / "review-output.md").write_text(
        f"## 這個 PR 做了什麼\n改了一行\n{verdict_line}\n", encoding="utf-8"
    )
    res = _run(_step_script(VERDICT_STEP), tmp_path, bindir, {})
    assert res.returncode == 0, res.stderr
    added = "pr edit 1 --add-label needs-work" in _calls(tmp_path)
    assert added is expect_label, f"{verdict_line!r} -> {added=}"


def test_verdict_line_stripped_from_comment(tmp_path):
    bindir = _fake_gh(tmp_path)
    (tmp_path / "review-output.md").write_text(
        "## 結論\n可以合 ✅\nNEEDS_WORK: no\n", encoding="utf-8"
    )
    _run(_step_script(VERDICT_STEP), tmp_path, bindir, {})
    comment = (tmp_path / "comment.md").read_text(encoding="utf-8")
    assert "NEEDS_WORK" not in comment, "判定標記不該外洩到給作者看的留言裡"
    assert "可以合" in comment


def test_missing_review_output_is_blocked(tmp_path):
    """模型沒產出檔案（逾時、被注入干擾）時必須擋下，不能默默放行。"""
    bindir = _fake_gh(tmp_path)
    res = _run(_step_script(VERDICT_STEP), tmp_path, bindir, {})
    assert res.returncode == 0
    assert "pr edit 1 --add-label needs-work" in _calls(tmp_path)


# ------------------------------------------------------- 靜態安全不變式


def test_model_has_no_shell_access():
    """模型拿到 Bash 就等於 diff 裡的注入文字可以呼叫 gh——這是本 workflow 的核心不變式。

    `Bash(gh pr comment:*)` 之類的白名單是指令前綴比對，不是參數限制：
    `gh pr comment $PR --body "$(env)"` 會通過比對，而 $( ) 在 shell 展開，
    等於把特權 context 的 token 貼成公開留言。
    """
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for step in doc["jobs"]["review"]["steps"]:
        if step.get("uses", "").startswith("anthropics/claude-code-action"):
            args = step["with"]["claude_args"]
            assert "Bash" not in args, f"模型不得擁有任何 Bash 權限: {args}"
            return
    raise AssertionError("找不到 claude-code-action step")


def test_comment_is_posted_via_body_file():
    """--body-file 不經 shell 展開；改用 --body \"$(...)\" 會重新打開注入路徑。"""
    script = _step_script(VERDICT_STEP)
    assert "--body-file" in script
    assert '--body "' not in script
