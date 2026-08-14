#!/usr/bin/env python3
"""把打版流水線的測試產出彙整成一份人看得懂的錯誤報表。

輸入是 ship-report/ 目錄（由 _reusable-ship.yml 準備）：
    smoke.log          smoke 階段的逐行紀錄
    regression.log     regression 階段的 stdout/stderr
    service.log        服務容器的 docker logs
    out/junit.xml      （可選）逐項測試結果

輸出是 Markdown，同時貼進 job summary 與失敗 issue。

設計取捨：**報表產生器本身不能是失敗點。** 缺檔、XML 壞掉、編碼異常一律
降級成「少一段」而不是丟例外——測試已經紅了，這時再噴一個 traceback 只會
把真正的失敗原因洗掉。純 stdlib，沒有安裝步驟。
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

MAX_LOG_LINES = 60


def tail(path: Path, n: int = MAX_LOG_LINES) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return lines[-n:]


# junit.xml 是**被測容器**寫出來的，也就是不受信任的輸入。xml.etree 不會展開
# 外部實體，但會展開內部實體，所以擋不住 billion laughs（一個幾 KB 的檔案展開
# 成數 GB，把報表步驟吃掉記憶體）。
#
# 正解是 defusedxml，但本檔的前提是「純 stdlib、沒有安裝步驟」——報表產生器多
# 一個安裝步驟就多一個失敗點，而它的職責正是「不能是失敗點」。
#
# 用 stdlib 能做到的等效防護：合法的 JUnit XML 從來不需要 DTD，所以看到
# DOCTYPE 或 ENTITY 宣告就直接拒收。這擋掉整類實體展開攻擊，代價是拒絕一種
# 現實中不存在的合法輸入。另外加檔案大小上限擋掉單純的巨大檔。
MAX_JUNIT_BYTES = 20 * 1024 * 1024
_DTD_MARKERS = (b"<!DOCTYPE", b"<!ENTITY")


def parse_junit(path: Path) -> tuple[dict, list[dict]]:
    """回傳 (統計, 失敗案例清單)。解析失敗就回空的，不中斷報表。"""
    stats = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0, "time": 0.0}
    failures: list[dict] = []
    try:
        raw = path.read_bytes()
    except OSError:
        return stats, failures
    if len(raw) > MAX_JUNIT_BYTES:
        return stats, failures
    head = raw[:4096].upper()
    if any(m in head for m in _DTD_MARKERS):
        return stats, failures
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return stats, failures

    suites = [root] if root.tag == "testsuite" else root.findall(".//testsuite")
    for s in suites:
        for k in ("tests", "failures", "errors", "skipped"):
            stats[k] += int(s.get(k, 0) or 0)
        try:
            stats["time"] += float(s.get("time", 0) or 0)
        except ValueError:
            pass
        for case in s.findall("testcase"):
            for kind in ("failure", "error"):
                node = case.find(kind)
                if node is None:
                    continue
                failures.append({
                    "name": f"{case.get('classname', '')}::{case.get('name', '')}".strip(":"),
                    "kind": kind,
                    "message": (node.get("message") or "").strip(),
                    "detail": (node.text or "").strip(),
                })
    return stats, failures


def code_block(lines: list[str], lang: str = "") -> list[str]:
    if not lines:
        return []
    return [f"```{lang}", *lines, "```"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report_dir")
    ap.add_argument("--image", default="")
    ap.add_argument("--smoke-rc", default="0")
    ap.add_argument("--regression-rc", default="0")
    ap.add_argument("--repo", default="")
    ap.add_argument("--sha", default="")
    ap.add_argument("--run-url", default="")
    a = ap.parse_args()

    d = Path(a.report_dir)
    smoke_ok = a.smoke_rc in ("0", "")
    regr_ok = a.regression_rc in ("0", "")
    passed = smoke_ok and regr_ok

    stats, failures = parse_junit(d / "out" / "junit.xml")

    out: list[str] = []
    icon = "✅" if passed else "❌"
    out += [f"## {icon} 打版測試報表", ""]

    out += ["| 項目 | 結果 |", "|---|---|"]
    out.append(f"| smoke test | {'✅ 通過' if smoke_ok else '❌ 失敗'} |")
    # 空字串 = 這一趟沒跑 regression（step 被 skip 或呼叫端沒設 regression_cmd）。
    # 明寫「未執行」而不是省略這一列：省略會讓讀報表的人以為沒有 regression 這回事，
    # 但真正該知道的是「有這道關卡，只是這次沒過關卡」。更不能印成通過。
    if a.regression_rc in ("", None):
        out.append("| regression test | ⏭ 未執行（未設定 regression_cmd） |")
    else:
        out.append(f"| regression test | {'✅ 通過' if regr_ok else f'❌ 失敗（exit {a.regression_rc}）'} |")
    if stats["tests"]:
        # skipped 不算通過。JUnit 的 tests 屬性含 skipped，直接拿來當分子會把
        # 「整批被 skip 掉」報成全綠 —— 那正是最需要被看見的失效模式。
        ok = stats["tests"] - stats["failures"] - stats["errors"] - stats["skipped"]
        out.append(f"| 測試案例 | {ok}/{stats['tests']} 通過"
                   f"（skip {stats['skipped']}，{stats['time']:.1f}s）|")
    if a.image:
        out.append(f"| 受測 image | `{a.image}` |")
    if a.sha:
        out.append(f"| commit | `{a.sha[:12]}` |")
    out.append("")

    if passed:
        out += ["這一版通過沙盒測試，可以進入部署。", ""]
    else:
        out += ["> 這一版**沒有**被部署。原有服務仍在跑舊版本。", ""]

    # 逐項失敗：最有用的一段，放最前面
    if failures:
        out += ["### 失敗的測試案例", ""]
        for f in failures[:20]:
            out += [f"**`{f['name']}`** — {f['kind']}", ""]
            if f["message"]:
                out.append(f"> {f['message'][:500]}")
                out.append("")
            if f["detail"]:
                out += code_block(f["detail"].splitlines()[-25:], "text") + [""]
        if len(failures) > 20:
            out += [f"_（另有 {len(failures) - 20} 項失敗，見 artifact 內的 junit.xml）_", ""]

    if not smoke_ok:
        out += ["### smoke 階段紀錄", ""]
        out += code_block(tail(d / "smoke.log"), "text") + [""]
        svc = tail(d / "service.log", 40)
        if svc:
            out += ["<details><summary>服務容器 log（最後 40 行）</summary>", ""]
            out += code_block(svc, "text")
            out += ["", "</details>", ""]

    if not regr_ok and not failures:
        # 沒有 junit.xml 時，至少把 stdout 的尾巴帶出來
        out += ["### regression 階段輸出（無 junit.xml，取最後數十行）", ""]
        out += code_block(tail(d / "regression.log"), "text") + [""]

    if a.run_url:
        out += ["---", f"執行紀錄：{a.run_url}"]

    write_out("\n".join(out) + "\n")
    return 0


def write_out(text: str) -> None:
    """把報表寫到 stdout，且不讓編碼問題變成失敗點。

    報表裡有 ✅ / ❌ 等符號。Linux runner 的 stdout 是 UTF-8 沒問題，但
    Windows self-hosted runner（native-win 那幾個 repo 只能跑在那裡）預設
    是 cp950，寫出去會噴 UnicodeEncodeError —— 測試已經紅了，這時再讓報表
    產生器自己掛掉，就把真正的失敗原因洗掉了，正好違反本檔的設計前提。

    先試著把 stdout 切成 UTF-8；切不動（已被接管、非 TextIO）就退而求其次，
    用 backslashreplace 保住可讀性。兩條路都不會拋例外。
    """
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError, OSError):
        pass
    try:
        sys.stdout.write(text)
    except UnicodeEncodeError:
        enc = sys.stdout.encoding or "ascii"
        sys.stdout.write(text.encode(enc, "backslashreplace").decode(enc))


if __name__ == "__main__":
    raise SystemExit(main())
