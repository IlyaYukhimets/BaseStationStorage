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

for file in $(find common tests -name '*.lua' | sort); do
    if ! luac5.1 -p "$file" 2>&1; then
        echo "SYNTAX FAIL: $file" >&2
        fail=1
    fi
done

for file in $(find common -name '*.json' | sort); do
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file"; then
        echo "JSON FAIL: $file" >&2
        fail=1
    fi
done

# Every getText key used in Lua must exist in both translations, and both languages must
# carry the same key set -- a missing key silently renders as the raw key in game.
if ! python3 - <<'PY'
import glob, json, re, sys

used = set()
for path in glob.glob("common/media/lua/**/*.lua", recursive=True):
    src = open(path, encoding="utf-8").read()
    used |= set(re.findall(r'getText\(\s*"(UI_BSS_[A-Za-z0-9_]+)"', src))
    # keys assembled at runtime: "<prefix>" .. value
    for prefix in re.findall(r'"(UI_BSS_[A-Za-z0-9_]+_)"\s*\.\.', src):
        used.add(prefix)

ru = json.load(open("common/media/lua/shared/Translate/RU/UI.json", encoding="utf-8"))
en = json.load(open("common/media/lua/shared/Translate/EN/UI.json", encoding="utf-8"))

problems = []
for key in sorted(used):
    if key.endswith("_"):
        if not any(k.startswith(key) for k in ru) or not any(k.startswith(key) for k in en):
            problems.append("no translation family for " + key)
        continue
    if key not in ru:
        problems.append("missing in RU: " + key)
    if key not in en:
        problems.append("missing in EN: " + key)
for key in sorted(set(ru) ^ set(en)):
    problems.append("RU/EN mismatch: " + key)

for problem in problems:
    print("TRANSLATION FAIL: " + problem)
sys.exit(1 if problems else 0)
PY
then
    fail=1
fi

# mod.info: id must match the folder and must never require itself.
mod_id=$(sed -n 's/^id=//p' common/mod.info | tr -d '\r')
if [ "$mod_id" != "BaseStationStorage" ]; then
    echo "mod.info FAIL: id is '$mod_id'" >&2
    fail=1
fi
if grep -q '^require=' common/mod.info; then
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
