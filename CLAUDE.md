# CLAUDE.md

Guidance for Claude (and humans) working in this repository.

## Project goal

Build a **Sega 32X core** (Genesis/Mega Drive + 32X add-on) for the **Analogue Pocket** using
Analogue's openFPGA framework (APF). The owner has multiple physical Pockets and does all
on-device testing; Claude cannot run bitstreams on hardware, so every hardware-facing change
needs a clear test request for the owner (see `docs/hardware-testing.md`).

Planning docs live in `docs/`:

- `docs/requirements.md`: the numbered requirements and milestone plan. **Start here.**
- `docs/architecture.md`: target hardware, Pocket resource budget, memory map plan, risks.
- `docs/hardware-testing.md`: how builds get onto a Pocket and how results come back.
- `docs/references.md`: upstream cores, datasheets and specs.

When a requirement is completed or changes, update its status in `docs/requirements.md` in
the same commit.

## Current state

M0 through M4 are done: tooling, our own build on hardware, Genesis games, the memory subsystem,
and 32X games booting. Core 0.2.0 (hardware-verified at 46d8920) plays most tested 32X and
Genesis games with timing met at about 92% of ALMs. M5 (library playability) is in progress with
one open item, After Burner's weapon sounds, which is postponed. Saves work on hardware
(b94d358): cart SRAM and EEPROM live in `s32x_save_ram.sv`, a dual-clock block RAM that the APF
save slot (data slot 10) reads and writes directly. Next in the owner's priority order: the
remaining requirements. See `docs/test-log.md`
for hardware results and `docs/m4-debug-notes.md` for the debugging history, the simulation
toolkit and the After Burner notes. The repo started as `open-fpga/core-template` v1.3.0 (commit
`da3a021`).

## Repository layout

```
core.json, data.json, video.json, audio.json,   APF core definition JSON files
input.json, interact.json, variants.json         (copied into the SD card's core folder)
info.txt                                          Text shown in the Pocket's core info screen
dist/                                             SD-card staging: icon.bin, platforms/*.json, platform images
output/bitstream.rbf_r                            Bit-reversed bitstream the Pocket loads (latest build)
src/fpga/ap_core.qpf / ap_core.qsf                Quartus project (Cyclone V 5CEBA4F23C8, top = apf_top)
src/fpga/apf/                                     Analogue framework glue. Treat as vendor code; do not edit
src/fpga/core/core_top.v                          APF glue: bridge, ROM loader, input, video formatter, audio
src/fpga/core/s32x_system.sv                      Console: upstream gen + 32X + CART, SDRAM controller, fb_sram
src/fpga/core/s32x_sdram_front.sv                 32X SDRAM front end (line buffer + write queue)
src/fpga/core/s32x_save_ram.sv                    Cart SRAM/EEPROM save RAM, second port on the APF bridge
src/fpga/core/pll_core.v                          PLL: MCLK 53.69, SDRAM 107.39, video 26.85 (+90°) MHz
src/fpga/core/rtl/S32X_MiSTer/                    Upstream submodule (pinned; patched at build time)
src/fpga/core/rtl/patches/                        Our patches to upstream, applied in order
src/fpga/core/rtl/agg23/                          agg23's MIT data_loader / sound_i2s / sync_fifo
tools/                                            reverse_bits.py, package.py, prepare_upstream.sh
experiments/fit_s32x/                             REQ-ARCH-03/04 fit experiment and variants
src/fpga/core/core_bridge_cmd.v                   Host/target command handler (data slots, status). Vendor-provided
```

## Conventions

- **Don't modify `src/fpga/apf/`.** It's Analogue's framework. Put all new RTL under
  `src/fpga/core/` (for example `src/fpga/core/rtl/<block>/`) and add files to `ap_core.qsf`.
- **S32X_MiSTer is a git submodule** at `src/fpga/core/rtl/S32X_MiSTer`, pinned to a commit. Never
  commit changes inside it. Local modifications are patch files in `src/fpga/core/rtl/patches/`,
  applied by `tools/prepare_upstream.sh` (Quartus runs it via `core/pre_flow.tcl`). See that
  directory's README. This avoids redistributing upstream code that has no stated license.
- Other imported third-party RTL that has a clear license (e.g. agg23's MIT utilities) goes in its
  own subdirectory with its original LICENSE file and a short `README.md` recording the upstream
  URL and commit hash. Keep local modifications minimal and noted.
- The project license is **GPL-3.0** (`LICENSE`), compatible with fx68k, jt12/jt89 and the GPLv3
  SDRAM controller that end up in every bitstream.
- **Never commit copyrighted ROMs or BIOS images** to git, including `.mif`/`.hex` BIOS
  embeds that some upstream cores ship with. Pushing them to GitHub counts as distributing them.
- BIOS policy: the owner is fine with a personal-use-only core. **Embedding the BIOS in the
  bitstream is allowed** for personal builds. It's the fastest path to first boot. The
  BIOS files must live in a gitignored local directory (`bios/`) and get pulled in at build
  time: `bios/32X_G_BIOS.BIN` (68K, 256 B), `bios/32X_M_BIOS.BIN` (master SH-2, 2 KB) and
  `bios/32X_S_BIOS.BIN` (slave SH-2, 1 KB). `tools/gen_bios_mif.py` turns them into gitignored
  `.mif` files at build time. Loading the BIOS from APF data slots, which keeps the bitstream shareable, is the
  preferred end state but isn't required. See REQ-APF-03 / REQ-LEGAL-03.
- Mixed-language HDL is fine (Quartus handles Verilog, SystemVerilog and VHDL together).
  Upstream code keeps its original language.
- Clock domains: the APF bridge (`bridge_*`) runs on `clk_74a`. Anything crossing into the
  core's system clock must use a proper synchronizer or FIFO. The template's
  `synch_*`/`sync_fifo` helpers in `apf/common.v` are available.
- Keep timing closed. A build with negative slack isn't "done", even if it happens to work
  on one Pocket.
- JSON files must stay valid APF_VER_1 schema; the Pocket silently refuses to load cores
  with bad JSON.

## Build

Requires **Intel Quartus Prime Lite** (the template was created with 18.1.1; newer Lite
releases also work, but record the version used in `docs/architecture.md` once chosen).
Quartus isn't installed in Claude's cloud container, so Claude can edit RTL and run
lint or simulation there, but synthesis and fitting happen on the owner's machine (or a CI
runner with Quartus, if added later).

The owner's machine has Quartus Prime Lite 25.1std at `~/altera_lite/25.1std/quartus/bin/`,
so a local session can run the full build headless.

**One command:** `tools/build.sh` does all of the steps below. `tools/build.sh --memtest` builds the
memory self-test variant (REQ-MEM-06).

1. Compile: `cd src/fpga && quartus_sh --flow compile ap_core` (or open `ap_core.qpf` in the
   GUI). Output: `src/fpga/output_files/ap_core.rbf`. The pre-flow hook patches the upstream
   submodule and generates the BIOS `.mif` files.
2. `tools/reverse_bits.py` bit-reverses each byte of the `.rbf` into `output/bitstream.rbf_r`,
   the format the Pocket requires.
3. `tools/package.py [--zip]` stages an SD-card tree in `build/sdcard/` (layout per
   `docs/hardware-testing.md`). Copy its contents to the SD card root.

## Simulation

Questa FSE (installed with Quartus at `~/altera_lite/25.1std/questa_fse/bin`) runs testbenches:
`sim/run.sh <bench>` (e.g. `sim/run.sh fb_sram`). Each bench lives in `sim/<bench>/` with
`files.f` and `tb_<bench>.sv`. `VSIM_ARGS="-sv_seed N"` picks a seed and `VLOG_DEFS` passes
defines. Needs `SALT_LICENSE_SERVER` pointing at the free license (run.sh defaults it to
`~/.altera.quartus/questa_lic.dat`). Prove memory controllers and other timing-critical logic
here before asking the owner for a hardware test. `sim/vdp` is the reference check for the
32X framebuffer path: it runs the upstream VDP twice (MiSTer's block-RAM setup vs. ours with
`fb_sram.sv`) on the same random traffic and requires identical output
(`VLOG_DEFS="-suppress 2244,2388" VSIM_ARGS="-suppress 7063,7061,10000 +frames=30" sim/run.sh vdp`).

## Working with the owner

- The owner tests on real hardware. After any change that affects the bitstream, end with a
  short, concrete test checklist: which build, which ROM or test, and what to look for.
- Prefer small, independently testable steps (see the milestones in `docs/requirements.md`).
  A core that boots Genesis games first, then adds 32X pieces, is much easier to debug than
  a big-bang port.
- Treat resource usage (ALMs, M10K, PLLs) as a first-class metric. Report it from fit
  reports whenever the owner shares them.
