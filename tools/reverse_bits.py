#!/usr/bin/env python3
"""Bit-reverse each byte of a Quartus .rbf into the .rbf_r format the Analogue Pocket loads.

Usage: reverse_bits.py [input.rbf] [output.rbf_r]
Defaults: src/fpga/output_files/ap_core.rbf -> output/bitstream.rbf_r (relative to repo root).
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_IN = REPO / "src/fpga/output_files/ap_core.rbf"
DEFAULT_OUT = REPO / "output/bitstream.rbf_r"

REVERSE_TABLE = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def reverse_bits(data: bytes) -> bytes:
    return data.translate(REVERSE_TABLE)


def main(argv: list[str]) -> int:
    if len(argv) > 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(argv[1]) if len(argv) > 1 else DEFAULT_IN
    dst = Path(argv[2]) if len(argv) > 2 else DEFAULT_OUT
    data = src.read_bytes()
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(reverse_bits(data))
    print(f"{src} -> {dst} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
