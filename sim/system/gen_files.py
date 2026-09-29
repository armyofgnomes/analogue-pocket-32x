#!/usr/bin/env python3
"""Emit the source list for sim/system from ap_core.qsf (expanding .qip files), so the full-system
simulation compiles exactly what Quartus compiles. sdram.sv is replaced by the sim-only hoisted
copy (see sim/sdram/prep.sh). Output lines: '<vlog|vcom> <path>' relative to the repo root."""
import os, re, sys
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
fpga = repo / "src/fpga"
files = []

def add(path: Path):
    kind = {'.v': 'vlog', '.sv': 'vlog', '.vhd': 'vcom', '.vhdl': 'vcom'}.get(path.suffix.lower())
    if kind:
        files.append((kind, path.resolve()))
    elif path.suffix == '.qip':
        for m in re.finditer(r'-name\s+(\w+)_FILE\s+\[file join \$::quartus\(qip_path\)\s+(\S+?)\s*\]',
                             path.read_text()):
            add((path.parent / m.group(2)).resolve())

for line in (fpga / "ap_core.qsf").read_text().splitlines():
    m = re.match(r'set_global_assignment -name (VERILOG|SYSTEMVERILOG|VHDL|QIP)_FILE (\S+)', line)
    if not m:
        continue
    p = fpga / m.group(2)
    if 'apf/' in m.group(2) or 'agg23/' in m.group(2) or \
       m.group(2) in ('core/core_top.v', 'core/core_bridge_cmd.v', 'core/pll_core.v'):
        continue   # APF glue, loader/I2S and PLL live in core_top, outside the system bench
    add(p)

# Quartus accepts direct instantiation written as 'label : work.entity'; strict VHDL needs
# 'label : entity work.entity'. Such files get a fixed sim-only copy in build/sim/vhdl/.
inst = re.compile(r'(\b\w+\s*:\s*)work\.(\w+)', re.I)
def vhdl_fixed(p: Path) -> Path:
    text = p.read_text(errors='replace')
    # bram.vhd defaults mem_init_file to " ": Quartus reads that as 'no init file', but Intel's
    # VHDL altsyncram sim model tries to open it. "UNUSED" means 'none' to both.
    fixed = text.replace('mem_init_file : string := " "', 'mem_init_file : string := "UNUSED"')
    if not inst.search(fixed) and fixed == text:
        return p
    text = fixed
    out = repo / 'build/sim/vhdl' / p.name
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(inst.sub(r'\1entity work.\2', text))
    return out

# File-specific sim fixups, applied to the sim-only copies. Each reproduces what Quartus builds
# from code that strict simulators reject.
FIXUPS = {
    # vdp_vsram declares q_b as 22 bits but the RAM's port B is 11 bits wide; Quartus leaves the
    # upper bits undriven. Questa rejects the width mismatch at the VHDL boundary.
    # SND_MIX is VHDL: an unsized '1' (32 bits) on its std_logic port is a width mismatch.
    'gen.sv': [('\t.CH0_EN(1),', "\t.CH0_EN(1'b1),")],
    # CACHE.sv uses LRU_B_Q/LRU_WE/LRU_WRADDR before declaring them: declare them earlier (the only
    # change), so CACHE.sv can skip the general rewriter.
    'CACHE.sv': [('\tCACHE_TAG tag0(', '\tbit  [5:0] LRU_A_Q,LRU_B_Q;\n\twire [5:0] LRU_WRADDR;\n\twire       LRU_WE;\n\tCACHE_TAG tag0('),
                 ('\twire  [5:0] LRU_WRADDR = CACHE_WR_ADDR[9:4];', '\tassign LRU_WRADDR = CACHE_WR_ADDR[9:4];'),
                 ('\twire        LRU_WE = ', '\tassign LRU_WE = '),
                 ('\tbit  [5:0] LRU_A_Q,LRU_B_Q;\n\tCACHE_LRU lru_a(', '\tCACHE_LRU lru_a(')],
    'vdp_mem.v': [('\t\t.q_b(q_b)\n\t);\n\nendmodule\n\nmodule vdp_obj_visinfo',
                   '\t\t.q_b(q_b[10:0])\n\t);\n\tassign q_b[21:11] = 11\'d0;\n\nendmodule\n\nmodule vdp_obj_visinfo')],
}

# Upstream files that Questa accepts unmodified: keep them byte-for-byte (minus the SIM define),
# so the rewriter can't change their behavior.
NO_HOIST = {'SH_pkg.sv', 'SH_regfile.sv', 'SH_core.sv', 'SH7604_pkg.sv', 'BSC.sv', 'DMAC.sv', 'CACHE.sv',
            'UBC.sv', 'INTC.sv', 'FRT.sv', 'SCI.sv', 'DIVU.sv', 'MULT.sv', 'MSBY.sv', 'SH7604.sv'}

def apply_fixups(name, text):
    for old, new in FIXUPS.get(name, []):
        if old not in text:
            sys.exit(f"sim fixup for {name} no longer matches upstream")
        text = text.replace(old, new)
    return text

# Sim-only behavioral memory models (hardware semantics), compiled after the originals so these
# definitions win. See sim/common/stubs/sh_mem_behav.sv.
if os.environ.get('SH_MEM_BEHAV', '1') == '1':
    files.append(('vlog', (repo / 'sim/common/stubs/sh_mem_behav.sv').resolve()))

seen = set()
for kind, p in files:
    if p.name == 'sdram.sv':
        p = repo / 'build/sim/sdram_hoisted.sv'
    if kind == 'vcom':
        p = vhdl_fixed(p)
    elif p.name == 'cheatcodes.sv':
        p = repo / 'sim/common/stubs/codes_stub.sv'
    elif ('S32X_MiSTer' in str(p) or 'agg23' in str(p)) and p.name != 'sdram.sv':
        # Third-party Verilog: sim-only copy with upstream's `define SIM removed (so the
        # synthesized branch is what gets simulated), preprocessed, then use-before-declaration
        # hoisted.
        out = repo / 'build/sim/hoisted' / p.relative_to(repo / 'src/fpga/core/rtl')
        out.parent.mkdir(parents=True, exist_ok=True)
        nosim = out.with_suffix(out.suffix + '.src')
        src_text = p.read_text(errors='replace').replace('\r\n', '\n')
        src_text = apply_fixups(p.name, src_text)
        nosim.write_text(re.sub(r'^\s*`define\s+SIM\s*$', '', src_text, flags=re.M))
        p_src = nosim
        import subprocess, os
        # Preprocess first (ifdef branches may declare the same names), then hoist.
        pre = out.with_suffix(out.suffix + '.pre')
        q = os.environ.get('QUESTA_BIN', os.path.expanduser('~/altera_lite/25.1std/questa_fse/bin'))
        # vlog -E writes the preprocessed file and then also compiles it, which can fail on the
        # very forward references we are fixing: only the preprocessed output matters.
        if pre.exists():
            pre.unlink()
        subprocess.run([q + '/vlog', '-sv', '-quiet', '-E', str(pre), str(p_src)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(out.parent))
        if not pre.exists():
            sys.exit(f"preprocessing failed: {p}")
        if p.name in NO_HOIST:
            # Compiles in Questa as-is: only the SIM define is removed, nothing is rewritten.
            out.write_text(nosim.read_text())
        else:
            subprocess.run([sys.executable, str(repo / 'sim/common/hoist_decls.py'), str(pre), str(out)], check=True)
        p = out
    if p in seen:
        continue
    seen.add(p)
    print(kind, p.relative_to(repo))
