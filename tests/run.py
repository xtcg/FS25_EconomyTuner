"""Run the Lua tests in tests/test_*.lua against tests/stubs.lua.

Each test file runs in a fresh Lua state (via lupa) with REPO set to the repository root.

    pip install lupa
    python tests/run.py
    LUPA_LUA=54 python tests/run.py      # a specific Lua version (51..55); default is lupa's
"""
import glob
import os
import sys
import tempfile

import importlib

import lupa

LUA_VERSION = os.environ.get("LUPA_LUA")

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)


def run(path):
    runtime = importlib.import_module("lupa.lua" + LUA_VERSION) if LUA_VERSION else lupa
    lua = runtime.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    lua.globals().TMP = tempfile.mkdtemp(prefix="economytuner_") + "/"
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    with open(path, encoding="utf-8") as f:
        lua.execute(f.read())
    return [(r["name"], r["ok"]) for r in lua.globals().RESULTS.values()]


def lupa_version():
    runtime = importlib.import_module("lupa.lua" + LUA_VERSION) if LUA_VERSION else lupa
    return runtime.LuaRuntime().lua_version


def main():
    failed = 0
    total = 0
    for path in sorted(glob.glob(os.path.join(TESTS, "test_*.lua"))):
        print(f"== {os.path.basename(path)}")
        for name, ok in run(path):
            total += 1
            failed += not ok
            print(f"  {'PASS' if ok else 'FAIL'} {name}")
    print(f"{total - failed}/{total} passed (Lua {'.'.join(map(str, lupa_version()))})")
    return 1 if failed or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
