"""Run the Lua tests in tests/test_*.lua against tests/stubs.lua.

Each test file runs in a fresh Lua state (via lupa) with REPO set to the repository root.

    pip install lupa
    python tests/run.py
"""
import glob
import os
import sys
import tempfile

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def run(path):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    lua.globals().TMP = tempfile.mkdtemp(prefix="sellprices_") + "/"
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    with open(path, encoding="utf-8") as f:
        lua.execute(f.read())
    return [(r["name"], r["ok"]) for r in lua.globals().RESULTS.values()]


def main():
    failed = 0
    total = 0
    for path in sorted(glob.glob(os.path.join(TESTS, "test_*.lua"))):
        print(f"== {os.path.basename(path)}")
        for name, ok in run(path):
            total += 1
            failed += not ok
            print(f"  {'PASS' if ok else 'FAIL'} {name}")
    print(f"{total - failed}/{total} passed")
    return 1 if failed or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
