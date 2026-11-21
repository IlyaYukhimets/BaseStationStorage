#!/usr/bin/env python3
"""Release helpers used by .github/workflows/release.yml, runnable locally.

    scripts/ci.py verify-zip .build/BaseStationStorage-1.3.4.zip
    scripts/ci.py notes 1.3.4 > release-notes.md

Why this file exists instead of inline python in the workflow: a heredoc inside a YAML
block scalar keeps the block indentation, so the python source arrives indented and dies
with IndentationError. Keeping the logic here also makes it verifiable outside CI.
"""

from __future__ import annotations

import re
import sys
import zipfile

REQUIRED = (
    "BaseStationStorage/common/mod.info",
    "BaseStationStorage/common/media/AnimSets/",
    "BaseStationStorage/common/media/actiongroups/",
)


def verify_zip(path: str) -> int:
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [i.filename for i in infos]

        missing = [n for n in REQUIRED if n not in names]
        if missing:
            print("missing entries: %s" % ", ".join(missing), file=sys.stderr)
            return 1

        # Windows unpacks non-UTF-8 names as mojibake: УСТАНОВКА.txt must carry the flag.
        broken = [i.filename for i in infos
                  if any(ord(c) > 127 for c in i.filename) and not i.flag_bits & 0x800]
        if broken:
            print("names without the UTF-8 flag: %s" % ", ".join(broken), file=sys.stderr)
            return 1

        info = archive.read("BaseStationStorage/common/mod.info").decode("utf-8")
        version = next((l.split("=", 1)[1].strip() for l in info.splitlines()
                        if l.startswith("modversion=")), "")
        if not version:
            print("mod.info has no modversion", file=sys.stderr)
            return 1

    print("ok: %d entries, modversion=%s, version dir present, utf-8 names, empty dirs recorded"
          % (len(names), version))
    return 0


def notes(version: str) -> int:
    try:
        text = open("CHANGELOG.md", encoding="utf-8").read()
    except OSError as exc:
        print("cannot read CHANGELOG.md: %s" % exc, file=sys.stderr)
        return 1
    match = re.search(r"^## " + re.escape(version) + r"\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    body = match.group(1).strip() if match else "Base Station Storage %s" % version
    sys.stdout.write(body + "\n")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "verify-zip":
        return verify_zip(argv[2])
    if len(argv) == 3 and argv[1] == "notes":
        return notes(argv[2])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
