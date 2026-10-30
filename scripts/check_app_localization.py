#!/usr/bin/env python3
"""Fail when Supermole.app shows text that has no translation.

The Swift compiler lists every localizable literal it compiled when the app is
built with `-emit-localized-strings` (scripts/build_installer_dmg.sh does).
Each key must exist in every non-English table under app/Resources, and a
table must not keep keys the code no longer uses. The list must come from a
clean build: an incremental one emits only the files it recompiled, and every
other key would read as unused.

    check_app_localization.py <stringsdata-dir> <resources-dir>
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

# English is the source language: its keys are the text itself.
SOURCE_LANGUAGE = "en"


def compiled_keys(stringsdata_dir: Path) -> set[str]:
    keys: set[str] = set()
    for path in stringsdata_dir.glob("*.stringsdata"):
        data = json.loads(path.read_text(encoding="utf-8"))
        for entries in data.get("tables", {}).values():
            keys.update(entry["key"] for entry in entries)
    return keys


def table_keys(strings_file: Path) -> set[str]:
    converted = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(strings_file)],
        check=True,
        capture_output=True,
        text=True,
    )
    return set(json.loads(converted.stdout))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    stringsdata_dir, resources_dir = Path(sys.argv[1]), Path(sys.argv[2])
    used = compiled_keys(stringsdata_dir)
    if not used:
        print(f"No localizable strings found in {stringsdata_dir}", file=sys.stderr)
        return 1

    failed = False
    for strings_file in sorted(resources_dir.glob("*.lproj/Localizable.strings")):
        language = strings_file.parent.stem
        if language == SOURCE_LANGUAGE:
            continue
        translated = table_keys(strings_file)
        for key in sorted(used - translated):
            print(f"{language}: missing translation for {key!r}", file=sys.stderr)
            failed = True
        for key in sorted(translated - used):
            print(f"{language}: {key!r} is no longer used", file=sys.stderr)
            failed = True
    if not failed:
        print(f"All {len(used)} strings are translated.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
