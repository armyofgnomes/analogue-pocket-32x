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

The repo is still the **unmodified Analogue openFPGA core template**. It was verified on
2026-09-28 to be byte-identical to `open-fpga/core-template` tag **v1.3.0** (commit `da3a021`,
the latest tag). It shows a gray test screen and has no 32X logic yet.

## Repository layout

```
core.json, data.json, video.json, audio.json,   APF core definition JSON files
input.json, interact.json, variants.json         (copied into the SD card's core folder)
info.txt                                          Text shown in the Pocket's core info screen
dist/                                             SD-card staging: icon.bin, platforms/*.json, platform images
output/bitstream.rbf_r                            Bit-reversed bitstream the Pocket loads (template's gray screen for now)
src/fpga/ap_core.qpf / ap_core.qsf                Quartus project (Cyclone V 5CEBA4F23C8, top = apf_top)
src/fpga/apf/                                     Analogue framework glue. Treat as vendor code; do not edit
src/fpga/core/core_top.v                          Where the core is instantiated. All our work hooks in here
src/fpga/core/mf_pllbase*                         Template PLL (74.25 MHz in → 12.288 MHz audio, 133 MHz); will be replaced
src/fpga/core/core_bridge_cmd.v                   Host/target command handler (data slots, status). Vendor-provided
```

## Conventions

- **Don't modify `src/fpga/apf/`.** It's Analogue's framework. Put all new RTL under
  `src/fpga/core/` (for example `src/fpga/core/rtl/<block>/`) and add files to `ap_core.qsf`.
- Imported third-party RTL (MiSTer Genesis/S32X, fx68k, T80, jt12, SH-2, etc.) goes in its
  own subdirectory with its original LICENSE file and a short `README.md` recording the
  upstream URL and commit hash. Keep local modifications minimal and noted.
- **Never commit copyrighted ROMs or BIOS images** to git, including `.mif`/`.hex` BIOS
  embeds that some upstream cores ship with. Pushing them to GitHub counts as distributing them.
- BIOS policy: the owner is fine with a personal-use-only core. **Embedding the BIOS in the
  bitstream is allowed** for personal builds. It's the fastest path to first boot. The
  BIOS files must live in a gitignored local directory (`bios/`) and get pulled in at build
  time. Loading the BIOS from APF data slots, which keeps the bitstream shareable, is the
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

1. Open `src/fpga/ap_core.qpf`, compile. Output: `src/fpga/output_files/ap_core.rbf`.
2. Bit-reverse the `.rbf` into `bitstream.rbf_r`. The Pocket requires each byte's bit
   order reversed. A small script for this is a Phase 0 requirement (see
   `docs/requirements.md`, REQ-TOOL-02).
3. Stage onto the SD card per `docs/hardware-testing.md`.

## Working with the owner

- The owner tests on real hardware. After any change that affects the bitstream, end with a
  short, concrete test checklist: which build, which ROM or test, and what to look for.
- Prefer small, independently testable steps (see the milestones in `docs/requirements.md`).
  A core that boots Genesis games first, then adds 32X pieces, is much easier to debug than
  a big-bang port.
- Treat resource usage (ALMs, M10K, PLLs) as a first-class metric. Report it from fit
  reports whenever the owner shares them.
