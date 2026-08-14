"""所有 workflow YAML 必須可解析，且 reusable 呼叫的 ref 要自洽。

為什麼值得一支測試：workflow 檔語法錯誤在 GitHub 上是 **startup_failure**，
而那個狀態的診斷資訊近乎為零——run 裡沒有任何 job，`gh run view` 只會說
「likely failed because of a workflow file issue」，不告訴你哪一行。

實際踩過：`smoke_cmd: echo "TEMP: 說明"; exit 7` 整串是未加引號的 YAML plain
scalar，裡面的「: 」（冒號加空白）讓 YAML 當成 mapping。本機 yaml.safe_load
一秒就指到 line 55 column 28，但推上去只會拿到那句沒有資訊的錯誤。

注意 PyYAML 會把 `on:` 這個 key 解析成布林 True（YAML 1.1 的 y/n/on/off 規則），
所以下面一律用 `_on()` 取，不要寫 d["on"]。
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

WORKFLOW_DIR = Path(__file__).resolve().parents[1] / ".github" / "workflows"
WORKFLOWS = sorted(WORKFLOW_DIR.glob("*.yml")) + sorted(WORKFLOW_DIR.glob("*.yaml"))


def _on(doc: dict):
    """取 `on:` 區段——PyYAML 把它變成布林 True。"""
    return doc.get("on", doc.get(True))


def test_有找到_workflow_檔():
    # 這支測試本身如果因為路徑錯而掃到 0 個檔，會全部「通過」——那是假綠。
    assert WORKFLOWS, f"在 {WORKFLOW_DIR} 找不到任何 workflow"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_workflow_可解析且有必要區段(path: Path):
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        pytest.fail(f"{path.name} YAML 解析失敗（推上去會變 startup_failure）：\n{exc}")

    assert isinstance(doc, dict), f"{path.name} 頂層不是 mapping"
    assert _on(doc) is not None, f"{path.name} 沒有 on: 觸發區段"
    assert doc.get("jobs"), f"{path.name} 沒有 jobs"


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_呼叫_reusable_ship_時_pipeline_ref_要與_uses_的_ref_一致(path: Path):
    """`uses: …@X` 與 `with.pipeline_ref` 指向不同版本 = 腳本與 workflow 配錯版。

    GitHub 沒有提供「被呼叫的 reusable workflow 自己的 ref」這個 context
    （`github.job_workflow_sha` 在此為空），所以兩邊只能各寫一次。既然只能各寫
    一次，就用測試把它們釘在一起——否則不一致時要等到 runner 上「確認輔助腳本
    到位」那步才會發現。
    """
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    for job_name, job in (doc.get("jobs") or {}).items():
        uses = (job or {}).get("uses", "")
        # 容器版與原生版都要檢查。用 startswith 判斷檔名而不是子字串比對——
        # "_reusable-ship.yml@" 這個子字串抓不到 "_reusable-ship-native.yml@"。
        if not any(f"{name}@" in uses for name in
                   ("_reusable-ship.yml", "_reusable-ship-native.yml")):
            continue
        ref = uses.split("@", 1)[1]
        declared = ((job.get("with") or {}).get("pipeline_ref") or "")
        # 同 repo 呼叫（uses: ./…）用 github.ref_name，不是字面值，跳過比對
        if declared.startswith("${{"):
            continue
        assert declared == ref, (
            f"{path.name} 的 job `{job_name}`：uses 釘 @{ref} 但 "
            f"pipeline_ref 是 '{declared}'。兩者必須指向同一版，"
            f"否則會拿到另一個版本的 scripts/ship/。"
        )
