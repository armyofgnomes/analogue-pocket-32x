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
- `docs/hardware-testing.md`: how builds get onto a Pocket, results, the regression set, releases.
- `docs/game-matrix.md`: 32X games and their status (REQ-QA-03).
- `CHANGELOG.md`: per-version changes (add an entry with each release).
- `docs/references.md`: upstream cores, datasheets and specs.

When a requirement is completed or changes, update its status in `docs/requirements.md` in
the same commit.

## Current state

M0 through M4 are done, and M6 (polish) is mostly done. Known-good builds are tagged and
published as GitHub releases from `v0.4.3`, the first public one (list in
`docs/hardware-testing.md`; v0.4.0 to v0.4.2 exist only in the private development repo).
What works on hardware:
- **Games:** most tested 32X and Genesis games play.
- **Saves:** cart SRAM/EEPROM in `s32x_save_ram.sv`, served to the APF save slot.
- **BIOS:** loaded from the SD card, with none in the bitstream; a 32X game shows a
  missing-BIOS screen if a file is absent.
- **Settings:** the full `interact.json` menu.
- **Dock:** HDMI output and player 2.
- **Look:** the "32X" icon and platform banner, and Analogue OS display modes.

Open:
- **M5:** no known open game issues (the last one, After Burner Complete's PWM weapon sounds,
  was fixed by restoring the SH-2 UBC; see `docs/m4-debug-notes.md`). `docs/game-matrix.md`
  lists the library; several games the owner has still need a first try.
- **Owner's pending hardware checks:** power-off saves, interlace, 240-line modes, SSF2, soak
  test, Pocket B (requirements marked WIP).
- **Not planned:** PAL MCLK (parked, `experiments/pal_reconfig/`), Memories (doesn't fit,
  `experiments/memories/`), Sega CD 32X games (doesn't fit, `experiments/segacd32x/`), 3-4 players
  (on request, REQ-INP-04). CI is deferred by the owner.
- **Area is tight:** synthesis estimate about 17.0k of 18.48k ALMs. Weigh the area cost of
  any new feature.

Hardware results are in `docs/test-log.md`. `docs/m4-debug-notes.md` holds the debugging
history and the simulation toolkit. The repo started as `open-fpga/core-template` v1.3.0
(commit `da3a021`).

## Repository layout

```
core.json, data.json, video.json, audio.json,   APF core definition JSON files
input.json, interact.json, variants.json         (copied into the SD card's core folder)
info.txt                                          Text shown in the Pocket's core info screen
LICENSE, NOTICE.txt                               GPL-3.0 and third-party credits/notices (both shipped in the core folder)
dist/                                             SD-card staging: icon.bin, platforms/*.json, platform images
output/bitstream.rbf_r                            Bit-reversed bitstream of the latest local build (not committed)
src/fpga/ap_core.qpf / ap_core.qsf                Quartus project (Cyclone V 5CEBA4F23C8, top = apf_top)
src/fpga/apf/                                     Analogue framework glue. Treat as vendor code; do not edit
src/fpga/core/core_top.v                          APF glue: bridge, ROM/BIOS loader, save RAM port, settings,
                                                  input, video formatter, messages, audio
src/fpga/core/s32x_system.sv                      Console: upstream gen + 32X + CART, SDRAM controller, fb_sram
src/fpga/core/fb_sram.sv                          32X framebuffers in the async SRAM
src/fpga/core/memtest.sv                          Memory self-test (tools/build.sh --memtest)
src/fpga/core/s32x_sdram_front.sv                 32X SDRAM front end (line buffer + write queue)
src/fpga/core/s32x_save_ram.sv                    Cart SRAM/EEPROM save RAM, second port on the APF bridge
src/fpga/core/pll_core.v                          PLL wrapper: MCLK 53.69, SDRAM 107.39, video 26.85 (+90°) MHz
src/fpga/core/pll/                                Generated reconfigurable PLL + reconfiguration controller (README)
src/fpga/core/s32x_msg_rom.sv                     Font/text ROM for on-screen messages (tools/gen_msg_rom.py)
src/fpga/core/rtl/S32X_MiSTer/                    Upstream submodule (pinned; patched at build time)
src/fpga/core/rtl/patches/                        Our patches to upstream, applied in order
src/fpga/core/rtl/agg23/                          agg23's MIT data_loader / sound_i2s / sync_fifo
tools/                                            build.sh, release.sh, fingerprint.sh, check_io_regs.py,
                                                  prepare_upstream.sh, reverse_bits.py, package.py,
                                                  gen_bios_mif.py (sims), gen_images.py, gen_msg_rom.py
sim/                                              Testbenches (sim/run.sh <bench>; sim/system/run.sh for the
                                                  full system; sim/regress/run.sh for the regression)
experiments/fit_s32x/                             REQ-ARCH-03/04 fit experiment and variants
experiments/pal_reconfig/                         Parked PAL MCLK switching attempt (REQ-ARCH-06)
experiments/memories/                             Memories feasibility study: not feasible for 32X (REQ-APF-08)
experiments/segacd32x/                            Sega CD 32X games fit experiment: not feasible
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
  SDRAM controller that end up in every bitstream. `NOTICE.txt` credits every third-party
  component in the bitstream with its license; when new third-party code goes in, add it there
  and to README's Credits.
- **Never commit copyrighted ROMs or BIOS images** to git, including `.mif`/`.hex` BIOS
  embeds that some upstream cores ship with. Pushing them to GitHub counts as distributing them.
- BIOS policy: the bitstream contains **no BIOS**. The core loads the three BIOS files from the
  SD card through optional data slots (`data.json` ids 20-22, `Assets/32x/common/`:
  `32X_G_BIOS.BIN` 68K 256 B, `32X_M_BIOS.BIN` master SH-2 2 KB, `32X_S_BIOS.BIN` slave SH-2
  1 KB), written into the BIOS memories by patch 0011's load port (REQ-APF-03b). Optional on
  purpose: a required slot with a missing file makes the Pocket open a file browser instead of
  starting the game; this way a 32X game shows the core's missing-BIOS screen (`core_top.v`,
  `s32x_msg_rom.sv`) and Genesis games run without the BIOS. The simulations
  still preload them: local dumps in the gitignored `bios/` become gitignored `.mif` files
  (`tools/gen_bios_mif.py`, `BIOS_MIF` define). See REQ-APF-03 / REQ-LEGAL-03.
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

Requires **Intel Quartus Prime Lite 25.1std** (recorded in `docs/architecture.md`). The owner's
machine has it at `~/altera_lite/25.1std/quartus/bin/`, so a local session can run the full build
headless. There is no CI yet (REQ-TOOL-06, deferred).

**One command:** `tools/build.sh` does all of the steps below. `tools/build.sh --memtest` builds the
memory self-test variant (REQ-MEM-06). The script also:
- fails if a constraint in `core_constraints.sdc` matches nothing, or if any SDRAM/SRAM pin
  register isn't in its I/O cell (`tools/check_io_regs.py`);
- records the sources' fingerprint in `output/build_info.txt`, which `tools/release.sh` checks;
- prints the fit summary and synthesis' ALM estimate, the stable measure of design size (the
  fitter's figure swings by several hundred ALMs with timing effort);
- holds the same lock as `sim/system/run.sh` while it patches the submodule and synthesizes, so
  builds and full-system sims can run in parallel.

1. Compile: `cd src/fpga && quartus_sh --flow compile ap_core` (or open `ap_core.qpf` in the
   GUI). Output: `src/fpga/output_files/ap_core.rbf`. The pre-flow hook patches the upstream
   submodule. (A manual compile skips `build.sh`'s checks and fingerprint, so a release needs a
   `build.sh` build.)
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
A bench's optional `libs.txt` links more precompiled Intel libraries (e.g. `altera_lnsim`).

**Regression before hardware:** `sim/regress/run.sh` (~20 min) checks the pad test program and
Kolibri's BIOS boot against `sim/regress/golden.txt`. Run it after RTL changes; update a golden
value only when a change is meant to alter it.

Full system: `sim/system/run.sh +rom=<file> [+frames=N] [+stop_ms=N] ...` runs real cartridges
(plusargs and trace options are listed at the top of `sim/system/tb_system.sv` and in
`docs/m4-debug-notes.md`). The environment variables are:
- `WORK=<abs dir>`: a separate run directory, so several runs can go in parallel.
- `FAST_BIOS=1`: skips the BIOS's slow SDRAM test and cart checksum.
- `BIOS_LOAD=1`: loads the BIOS through the core's load port instead of the preloaded `.mif`.

It needs the BIOS dumps in `bios/`.

## Working with the owner

- The owner tests on real hardware. After any change that affects the bitstream, end with a
  short, concrete test checklist: which build, which ROM or test, and what to look for.
- Prefer small, independently testable steps (see the milestones in `docs/requirements.md`).
  A core that boots Genesis games first, then adds 32X pieces, is much easier to debug than
  a big-bang port.
- Treat resource usage (ALMs, M10K, PLLs) as a first-class metric and report it with every build
  (synthesis estimate and fitter figure).
- When the owner verifies a build on hardware:
  - bump `core.json`'s version and turn `CHANGELOG.md`'s "Unreleased" into that version, commit;
  - tag the commit `vX.Y.Z` (annotated), push it;
  - run `tools/release.sh vX.Y.Z` to create the GitHub release with the SD zip;
  - add it to "Known-good builds" in `docs/hardware-testing.md`;
  - log every test in `docs/test-log.md` (Pocket A: white original, B: transparent orange).
- Build outputs aren't committed; the owner tests from `build/sdcard/` (or `build/sdcard.zip`).
- Commit directly to `main` and push; no PRs unless asked.
