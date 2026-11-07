#!/bin/sh
# Offline gate for Base Station Storage: syntax of every Lua file, JSON translations,
# mod.info sanity. No game and no network needed.
# Usage: scripts/check.sh
set -eu

cd "$(dirname "$0")/.."

fail=0

if ! command -v luac5.1 >/dev/null 2>&1; then
    echo "luac5.1 is required (apk add lua5.1): it is the dialect Project Zomboid runs (Kahlua 5.1)." >&2
    exit 2
fi

for file in $(find media tests -name '*.lua' | sort); do
    if ! luac5.1 -p "$file" 2>&1; then
        echo "SYNTAX FAIL: $file" >&2
        fail=1
    fi
done

for file in $(find media -name '*.json' | sort); do
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file"; then
        echo "JSON FAIL: $file" >&2
        fail=1
    fi
done

# mod.info: id must match the folder and must never require itself.
mod_id=$(sed -n 's/^id=//p' mod.info | tr -d '\r')
if [ "$mod_id" != "BaseStationStorage" ]; then
    echo "mod.info FAIL: id is '$mod_id'" >&2
    fail=1
fi
if grep -q '^require=' mod.info; then
    echo "mod.info FAIL: require= present; this mod has no dependencies" >&2
    fail=1
fi

if ! lua5.1 tests/logic_test.lua; then
    echo "UNIT TEST FAIL" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "CHECK FAILED" >&2
    exit 1
fi
echo "CHECK OK"
