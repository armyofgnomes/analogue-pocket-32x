#!/usr/bin/env python3
"""Assemble an SD-card-ready package (Cores/, Platforms/, Assets/) from repo files.

Usage: package.py [--out DIR] [--zip]
Defaults to build/sdcard/ under the repo root. Copy the contents of that directory to the
SD card root. The core folder is Cores/<author>.<shortname> (spaces removed) and the
platform is platform_ids[0], both read from core.json.
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CORE_FILES = ["core.json", "data.json", "video.json", "audio.json", "input.json",
              "interact.json", "variants.json", "info.txt"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=REPO / "build/sdcard")
    ap.add_argument("--zip", action="store_true", help="also write <out>.zip")
    args = ap.parse_args()

    # Validate every JSON file first: the Pocket silently refuses cores with bad JSON.
    for name in CORE_FILES:
        if name.endswith(".json"):
            json.loads((REPO / name).read_text())
    meta = json.loads((REPO / "core.json").read_text())["core"]["metadata"]
    core_dir = f"{meta['author']}.{meta['shortname']}".replace(" ", "")
    platform = meta["platform_ids"][0]

    bitstream = REPO / "output/bitstream.rbf_r"
    if not bitstream.is_file():
        print(f"missing {bitstream}; run tools/reverse_bits.py first", file=sys.stderr)
        return 1

    out = args.out
    if out.exists():
        shutil.rmtree(out)
    core = out / "Cores" / core_dir
    core.mkdir(parents=True)
    for name in CORE_FILES:
        shutil.copy2(REPO / name, core / name)
    shutil.copy2(bitstream, core / "bitstream.rbf_r")
    shutil.copy2(REPO / "dist/icon.bin", core / "icon.bin")

    plat = out / "Platforms"
    (plat / "_images").mkdir(parents=True)
    json.loads((REPO / f"dist/platforms/{platform}.json").read_text())
    shutil.copy2(REPO / f"dist/platforms/{platform}.json", plat / f"{platform}.json")
    shutil.copy2(REPO / f"dist/platforms/_images/{platform}.bin",
                 plat / "_images" / f"{platform}.bin")
    (out / "Assets" / platform / "common").mkdir(parents=True)

    print(f"packaged Cores/{core_dir}, platform {platform} -> {out}")
    if args.zip:
        z = shutil.make_archive(str(out), "zip", out)
        print(f"wrote {z}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
