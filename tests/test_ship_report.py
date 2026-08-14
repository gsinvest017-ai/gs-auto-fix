"""report.py 的測試。

重點不是「格式對不對」，而是那條不變量：**報表產生器不能是失敗點**。
測試已經紅了的時候，報表再噴 traceback 只會把真正的失敗原因洗掉。
所以壞掉的 XML、缺檔、空目錄都必須降級成「少一段」，而不是非零離開。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPORT = Path(__file__).resolve().parents[1] / "scripts" / "ship" / "report.py"

JUNIT_OK = """<?xml version="1.0"?>
<testsuites>
  <testsuite name="pytest" tests="3" failures="0" errors="0" skipped="1" time="1.25">
    <testcase classname="t.test_a" name="test_one" time="0.1"/>
    <testcase classname="t.test_a" name="test_two" time="0.2"/>
    <testcase classname="t.test_b" name="test_skipped"><skipped/></testcase>
  </testsuite>
</testsuites>
"""

JUNIT_FAIL = """<?xml version="1.0"?>
<testsuites>
  <testsuite name="pytest" tests="2" failures="1" errors="0" skipped="0" time="0.9">
    <testcase classname="t.test_a" name="test_ok" time="0.1"/>
    <testcase classname="t.test_a" name="test_bad" time="0.8">
      <failure message="assert 1 == 2">E   assert 1 == 2
E    +  where 1 = compute()</failure>
    </testcase>
  </testsuite>
</testsuites>
"""


def run(report_dir: Path, **kw) -> subprocess.CompletedProcess:
    args = [sys.executable, str(REPORT), str(report_dir), "--image", "ghcr.io/x/y@sha256:deadbeef"]
    for k, v in kw.items():
        args += [f"--{k.replace('_', '-')}", str(v)]
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8")


def make(tmp_path: Path, junit: str | None = None, **logs: str) -> Path:
    d = tmp_path / "ship-report"
    (d / "out").mkdir(parents=True)
    for name, content in logs.items():
        (d / f"{name}.log").write_text(content, encoding="utf-8")
    if junit is not None:
        (d / "out" / "junit.xml").write_text(junit, encoding="utf-8")
    return d


def test_全綠時報表說可以部署(tmp_path):
    d = make(tmp_path, JUNIT_OK, smoke="SMOKE: 健康檢查通過")
    r = run(d, smoke_rc=0, regression_rc=0)
    assert r.returncode == 0, r.stderr
    assert "✅ 打版測試報表" in r.stdout
    assert "2/3 通過" in r.stdout          # 3 tests - 0 failures，skip 另計
    assert "可以進入部署" in r.stdout


def test_失敗案例會逐項列出含斷言細節(tmp_path):
    d = make(tmp_path, JUNIT_FAIL, smoke="SMOKE: 健康檢查通過",
             regression="1 failed, 1 passed")
    r = run(d, smoke_rc=0, regression_rc=1)
    assert r.returncode == 0, r.stderr
    assert "❌" in r.stdout
    assert "t.test_a::test_bad" in r.stdout
    assert "assert 1 == 2" in r.stdout
    assert "沒有**被部署" in r.stdout


def test_smoke_失敗時帶出服務容器log(tmp_path):
    d = make(tmp_path, None,
             smoke="SMOKE: 健康檢查在 90s 內未通過",
             service="Traceback: ImportError: no module named foo")
    r = run(d, smoke_rc=1, regression_rc=0)
    assert r.returncode == 0, r.stderr
    assert "smoke 階段紀錄" in r.stdout
    assert "ImportError" in r.stdout


def test_沒有junit時退回regression原始輸出(tmp_path):
    d = make(tmp_path, None, smoke="ok", regression="E   ValueError: boom")
    r = run(d, smoke_rc=0, regression_rc=2)
    assert r.returncode == 0, r.stderr
    assert "無 junit.xml" in r.stdout
    assert "ValueError: boom" in r.stdout


def test_junit壞掉不會讓報表整個掛掉(tmp_path):
    d = make(tmp_path, "<testsuites><this is not xml", smoke="ok")
    r = run(d, smoke_rc=0, regression_rc=1)
    assert r.returncode == 0, r.stderr
    assert "打版測試報表" in r.stdout


def test_空目錄也要產出報表(tmp_path):
    d = tmp_path / "empty"
    d.mkdir()
    r = run(d, smoke_rc=1, regression_rc=0)
    assert r.returncode == 0, r.stderr
    assert "打版測試報表" in r.stdout
