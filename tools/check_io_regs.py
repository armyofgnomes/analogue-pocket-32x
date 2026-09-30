#!/usr/bin/env python3
"""Check that every SDRAM and SRAM pin register sits in its I/O cell (REQ-CLK-03).

The memory interfaces are timed by design (fixed command-to-capture cycles, SDRAM clock at 180
degrees, SRAM access lengths proven by the memtest sweeps), which only holds if the pin
registers are in the I/O cells, so their clock-to-pin delay doesn't depend on placement. A build
without them (bc7ce5c) blanked every game. The QSF's FAST_*_REGISTER assignments request this;
this script, run by tools/build.sh, fails the build if the fitter didn't honor them.
Usage: check_io_regs.py [path/to/ap_core.fit.rpt]"""
import re, sys
from pathlib import Path

rpt = Path(sys.argv[1] if len(sys.argv) > 1 else
           Path(__file__).resolve().parent.parent / "src/fpga/output_files/ap_core.fit.rpt")
lines = rpt.read_text(encoding="latin-1").split("\n")


def table(title):
    i = next(k for k, l in enumerate(lines) if l.startswith("; " + title) and l.rstrip().endswith(";"))
    hdr = [h.strip() for h in lines[i + 2].split(";")]
    rows = []
    for l in lines[i + 4:]:
        if not l.startswith(";"):
            break
        rows.append(dict(zip(hdr, [x.strip() for x in l.split(";")])))
    return rows


OUT = ("dram_a", "dram_ba", "dram_dqm", "dram_ras_n", "dram_cas_n", "dram_we_n", "dram_clk",
       "sram_a", "sram_oe_n", "sram_we_n", "sram_ub_n", "sram_lb_n")
BIDIR = ("dram_dq", "sram_dq")
bad, seen = [], 0
for r in table("Output Pins"):
    base = re.sub(r"\[.*", "", r["Name"])
    if base in OUT:
        seen += 1
        if r["Output Register"] != "yes":
            bad.append(f"{r['Name']}: output register not in the I/O cell")
for r in table("Bidir Pins"):
    base = re.sub(r"\[.*", "", r["Name"])
    if base in BIDIR:
        seen += 1
        for col in ("Input Register", "Output Register", "Output Enable Register"):
            if r[col] != "yes":
                bad.append(f"{r['Name']}: {col.lower()} not in the I/O cell")
if seen != 13 + 2 + 2 + 3 + 1 + 17 + 4 + 16 + 16:
    bad.append(f"expected 74 memory pins in the fit report, found {seen}")
if bad:
    print("error: memory pin registers:\n  " + "\n  ".join(bad), file=sys.stderr)
    sys.exit(1)
print(f"memory pins: all {seen} have their registers in the I/O cells")
