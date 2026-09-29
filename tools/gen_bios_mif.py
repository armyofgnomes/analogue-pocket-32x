#!/usr/bin/env python3
"""Generate the 32X BIOS ROM init files from the gitignored bios/ directory (REQ-APF-03a).

Reads   bios/32X_G_BIOS.BIN (68K, 256 B), bios/32X_M_BIOS.BIN (master SH-2, 2 KB),
        bios/32X_S_BIOS.BIN (slave SH-2, 1 KB)
Writes  src/fpga/core/bios_mif/mdbios.mif  (128 x 16)
        src/fpga/core/bios_mif/shbios.mif  (2048 x 16: master at 0, slave at 1024, rest 0xFFFF)
Layout and byte order match upstream S32X_MiSTer's MDROM/SHROM (big-endian 16-bit words).
The output directory is gitignored: these files contain copyrighted BIOS data.

Usage: gen_bios_mif.py [--optional]
  --optional  exit 0 with a warning if the BIOS files are missing (Genesis-only builds)
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIOS = REPO / "bios"
OUT = REPO / "src/fpga/core/bios_mif"
FILES = {"g": ("32X_G_BIOS.BIN", 256), "m": ("32X_M_BIOS.BIN", 2048), "s": ("32X_S_BIOS.BIN", 1024)}


def words(data: bytes) -> list[int]:
    return [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]


def write_mif(path: Path, depth: int, content: list[int]) -> None:
    lines = [f"WIDTH=16;", f"DEPTH={depth};", "", "ADDRESS_RADIX=HEX;", "DATA_RADIX=HEX;", "",
             "CONTENT BEGIN"]
    lines += [f"    {a:04X} : {w:04X};" for a, w in enumerate(content)]
    lines += ["END;", ""]
    path.write_text("\n".join(lines))


def main() -> int:
    optional = "--optional" in sys.argv[1:]
    data = {}
    for key, (name, size) in FILES.items():
        p = BIOS / name
        if not p.is_file():
            msg = f"missing {p}: the 32X BIOS dumps must be in bios/ (see CLAUDE.md, BIOS policy)"
            if optional:
                # stdout, not stderr: Quartus' Tcl exec treats any stderr output as failure
                print("warning: " + msg)
                return 0
            print("error: " + msg, file=sys.stderr)
            return 1
        b = p.read_bytes()
        if len(b) != size:
            print(f"error: {p} is {len(b)} bytes, expected {size}", file=sys.stderr)
            return 1
        data[key] = b

    OUT.mkdir(parents=True, exist_ok=True)
    write_mif(OUT / "mdbios.mif", 128, words(data["g"]))
    sh = words(data["m"]) + words(data["s"])
    sh += [0xFFFF] * (2048 - len(sh))
    write_mif(OUT / "shbios.mif", 2048, sh)
    print(f"BIOS init files written to {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
