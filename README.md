# Sega 32X core for Analogue Pocket

An openFPGA core for the Analogue Pocket that runs Sega Genesis / Mega Drive games and, as it
matures, Sega 32X games. It is built on the MiSTer
[S32X core](https://github.com/MiSTer-devel/S32X_MiSTer) (Genesis + 32X), adapted to the Pocket's
memories, clocks, video and the Analogue Pocket Framework (APF).

**Status: work in progress, personal-use builds only.**

- Genesis games run with video, audio and controls.
- 32X games boot (the 32X BIOS runs and both SH-2 CPUs start), but most don't play yet: black
  screens, corrupted 32X graphics or hangs. Fixing that is the current milestone (M4).
- No save support, settings menu or PAL timing yet.

Progress, requirements and hardware test results are tracked in [`docs/`](docs/):
[`requirements.md`](docs/requirements.md) (milestones), [`test-log.md`](docs/test-log.md)
(per-build hardware results), [`m4-debug-notes.md`](docs/m4-debug-notes.md) (current
investigation) and [`architecture.md`](docs/architecture.md) (memory map, timing, fit).

## Using a build

The 32X boot ROMs (BIOS) are **embedded in the bitstream** at build time. A build therefore
contains copyrighted Sega code and must not be shared; build it yourself from your own BIOS dumps.

Copy the contents of `build/sdcard/` (produced by `tools/build.sh`) to the root of the Pocket's SD
card. That adds:

```
Cores/armyofgnomes.32X/     core definition and bitstream
Platforms/32x.json          platform entry ("32X")
Platforms/_images/32x.bin   platform image
Assets/32x/common/          put your ROMs here
```

ROMs: `.32x` for 32X games, `.md`, `.bin` or `.gen` for Genesis games. Load them from the core's
menu on the Pocket.

## Building

Requirements:

- Intel Quartus Prime Lite (built with 25.1std; the Cyclone V device support is needed)
- Python 3
- git (the upstream core is a submodule: `git submodule update --init`)
- Your own 32X BIOS dumps in `bios/` (gitignored): `32X_G_BIOS.BIN` (68K, 256 bytes),
  `32X_M_BIOS.BIN` (master SH-2, 2 KB), `32X_S_BIOS.BIN` (slave SH-2, 1 KB)

Then:

```
tools/build.sh            # compile, bit-reverse the bitstream, stage build/sdcard/
tools/build.sh --memtest  # memory self-test build (bars over the Genesis picture)
```

The build applies our patches to the upstream submodule (`tools/prepare_upstream.sh`), turns the
BIOS files into memory init files (`tools/gen_bios_mif.py`), compiles with Quartus, reverses the
bit order for the Pocket (`tools/reverse_bits.py`) and stages the SD card tree
(`tools/package.py`). See [`CLAUDE.md`](CLAUDE.md) for details.

## Simulation

Questa (Intel FPGA Starter Edition, installed with Quartus) runs the testbenches under `sim/`:
unit benches for the framebuffer controller, the SDRAM controller and the memory test, a
differential bench that checks our framebuffer path against MiSTer's (`sim/vdp`), and a
full-system simulation that runs real cartridges (`sim/system`). See [`CLAUDE.md`](CLAUDE.md)
and [`docs/m4-debug-notes.md`](docs/m4-debug-notes.md) for how to use them.

## Repository layout

```
core.json, data.json, ...   APF core definition files
dist/                       platform JSON and image for the SD card
src/fpga/                   Quartus project (Cyclone V 5CEBA4F23C8)
  apf/                      Analogue's framework glue (unmodified)
  core/core_top.v           APF glue: bridge, ROM loading, input, video, audio
  core/s32x_system.sv       the console: Genesis + 32X + cart, SDRAM and SRAM framebuffer
  core/rtl/S32X_MiSTer/     upstream core (git submodule, patched at build time)
  core/rtl/patches/         our patches to upstream, with a README for each
tools/                      build, packaging and helper scripts
sim/                        testbenches
docs/                       requirements, architecture, hardware test log, debug notes
```

## Credits

- [S32X_MiSTer](https://github.com/MiSTer-devel/S32X_MiSTer) by srg320 and the MiSTer team:
  the Genesis and 32X implementation this core is built on.
- [fx68k](https://github.com/ijor/fx68k) (68000) by Jorge Cwik; [jt12/jt89](https://github.com/jotego)
  (YM2612/SN76489) by Jose Tejada; the SDRAM controller by Sorgelig; the Z80 (T80) authors.
- agg23's openFPGA utilities (data loader, I2S audio, sync FIFO) in `src/fpga/core/rtl/agg23/`.
- [openFPGA-Genesis](https://github.com/opengateware/openFPGA-Genesis), a reference for the
  Pocket's SDRAM timing.
- Analogue's openFPGA core template.

## License

GPL-3.0 (see [`LICENSE`](LICENSE)), compatible with the GPL-licensed parts that end up in every
bitstream (fx68k, jt12/jt89, the SDRAM controller). The upstream submodule has no top-level
license; its files keep their own terms (see `src/fpga/core/rtl/patches/README.md`).

## Legal

Analogue's Development program was created to further video game hardware preservation with FPGA
technology. Analogue Developers have access to Analogue Pocket I/O's so Developers can utilize
cartridge adapters or interface with other pieces of original or bespoke hardware to support
legacy media. Analogue does not support or endorse the unauthorized use or distribution of
material protected by copyright or other intellectual property rights.
