#!/usr/bin/env python3
"""gs-auto-fix 地端先修 gate（PoC1）。

跑測試 → 失敗 → 用 gs-agent-router 的地端模型（Ollama qwen3-coder）試修 traceback
implicated 的檔案；地端修好就回 exit 0，修不掉回 exit 2（由 workflow 升級雲端）。

需在 self-hosted GPU runner（已備 Ollama + qwen3-coder）上跑。純 stdlib + gs-agent-router。
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from gs_agent_router import autofix

VERIFY = "pytest -q"


def run(cmd: str) -> tuple[bool, str]:
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return p.returncode == 0, p.stdout + p.stderr


def candidates(output: str) -> list[Path]:
    """從測試輸出 / traceback 抓出本 repo 內、存在的 .py 候選檔（偏好非 test）。"""
    cwd = Path.cwd().resolve()
    found: list[Path] = []
    for m in re.finditer(r"([\w./\-]+\.py)", output):
        raw = m.group(1)
        p = Path(raw)
        p = p.resolve() if p.is_absolute() else (cwd / raw).resolve()
        if "site-packages" in str(p) or "/.venv/" in str(p):
            continue
        try:
            p.relative_to(cwd)
        except ValueError:
            continue
        if p.exists() and p not in found:
            found.append(p)
    found.sort(key=lambda x: ("test" in x.name, str(x)))
    return found


def main() -> int:
    ok, out = run(VERIFY)
    if ok:
        print("測試已綠，無需修復")
        return 0
    cands = candidates(out)
    if not cands:
        print("無法從 traceback 找出候選檔 → 升級雲端")
        return 2
    for c in cands[:3]:
        print(f"地端試修候選: {c}")
        rc = autofix.main(["--file", str(c), "--verify-cmd", VERIFY, "--max-local", "3"])
        if rc == 0:
            print(f"地端修好: {c}")
            return 0
    print("地端連續修不掉 → 升級雲端")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
