# Sega 32X core for Analogue Pocket

An openFPGA core for the Analogue Pocket that runs Sega 32X and Sega Genesis / Mega Drive games.
It is built on the MiSTer
[S32X core](https://github.com/MiSTer-devel/S32X_MiSTer) (Genesis + 32X), adapted to the Pocket's
memories, clocks, video and the Analogue Pocket Framework (APF).

**Status: work in progress.** Hardware-verified builds are published as GitHub releases (the repo is
private for now).

- Genesis games run with video, audio and controls.
- Every 32X game tested so far is playable, including After Burner Complete, Doom, Kolibri,
  Knuckles' Chaotix, Mortal Kombat II, NBA Jam TE, Pitfall, Primal Rage, Spider-Man: Web of Fire
  and Virtua Fighter (per-game status in [`docs/game-matrix.md`](docs/game-matrix.md)). The
  current milestone (M5) is the rest of the library.
- Cartridge saves (battery SRAM and EEPROM) are kept in `.sav` files, in MiSTer's format.
- Settings: region, 6-button pad, audio filter, FM chip, HiFi PCM, composite blend, sprite limit, reset.
- Works handheld and in the Analogue Dock (HDMI, second controller as player 2).
- Analogue OS display modes (CRT and LCD looks).
- No PAL timing: European games run on the NTSC master clock, about 1% fast.

Progress, requirements and hardware test results are tracked in [`docs/`](docs/):
[`requirements.md`](docs/requirements.md) (milestones), [`game-matrix.md`](docs/game-matrix.md)
(32X games and their status), [`test-log.md`](docs/test-log.md) (per-build hardware results),
[`hardware-testing.md`](docs/hardware-testing.md) (test procedure, regression set, releases),
[`m4-debug-notes.md`](docs/m4-debug-notes.md) (debugging history and the simulation toolkit) and
[`architecture.md`](docs/architecture.md) (memory map, clocks, fit).
Version history: [`CHANGELOG.md`](CHANGELOG.md).

## Known issues and limits

- **PAL timing:** European games (and the Europe region setting) run on the NTSC master clock, so
  about 1% fast. PAL clock switching is parked (`experiments/pal_reconfig/`).
- **Not yet seen on hardware:** interlaced video (e.g. Sonic 2's two-player mode), the 240-line
  PAL picture modes, and Super Street Fighter II's cartridge banking.
- **No save states (Memories)** or sleep: they don't fit the Pocket's FPGA alongside the 32X
  (measured in [`experiments/memories/`](experiments/memories/README.md)).
- **No Sega CD 32X games** (Night Trap, Corpse Killer and the other four): the Sega CD hardware
  doesn't fit alongside the 32X in the Pocket's FPGA (measured in
  [`experiments/segacd32x/`](experiments/segacd32x/README.md)).
- **Two players only:** no Team Player / 4-Way Play multitap, so 4-player modes (e.g. NBA Jam TE
  and WWF Raw on 32X, various Genesis games) aren't available. Upstream has the logic; open an
  issue if you'd like it.
- Untested 32X games are listed in [`docs/game-matrix.md`](docs/game-matrix.md).

## Using a build

The core needs the three 32X boot ROMs (BIOS), which you supply from your own dumps. It loads
them from the SD card when a game starts; nothing from Sega is built into the bitstream.

Download the zip from a release (or build one: `build/sdcard/` from `tools/build.sh`) and unzip it
to the root of the Pocket's SD card. That adds:

```
Cores/armyofgnomes.32X/     core definition and bitstream
Platforms/32x.json          platform entry ("32X")
Platforms/_images/32x.bin   platform image
Assets/32x/common/          put your ROMs here
```

Put the BIOS files in `Assets/32x/common/` too, named exactly `32X_G_BIOS.BIN` (68K, 256 bytes),
`32X_M_BIOS.BIN` (master SH-2, 2 KB) and `32X_S_BIOS.BIN` (slave SH-2, 1 KB). If one is missing,
a 32X game shows a screen naming the missing file. Genesis games don't need the BIOS.

ROMs: `.32x` for 32X games, `.md`, `.bin` or `.gen` for Genesis games. Load them from the core's
menu on the Pocket. ROMs must be unzipped: the core reads files as they are on the card and
doesn't list or open `.zip` files. Interleaved `.smd` dumps aren't supported either; convert them
to `.bin` or `.md` first.

## Building

Requirements:

- Intel Quartus Prime Lite (built with 25.1std; the Cyclone V device support is needed)
- Python 3
- git (the upstream core is a submodule: `git submodule update --init`)
- For the full-system simulations only: your own BIOS dumps in `bios/` (gitignored), same names
  as above. The bitstream build doesn't need them.

Then:

```
tools/build.sh            # compile, bit-reverse the bitstream, stage build/sdcard/
tools/build.sh --memtest  # memory self-test build (bars over the Genesis picture)
```

The build applies our patches to the upstream submodule (`tools/prepare_upstream.sh`), compiles
with Quartus, checks the timing constraints and the memory pin registers, reverses the bit order
for the Pocket (`tools/reverse_bits.py`) and stages the SD card tree (`tools/package.py`).
`tools/release.sh vX.Y.Z` publishes a hardware-verified build as a GitHub release. See
[`CLAUDE.md`](CLAUDE.md) for details.

## Simulation

Questa (Intel FPGA Starter Edition, installed with Quartus) runs the testbenches under `sim/`:
- unit benches for the framebuffer controller, the SDRAM controller and its 32X front end, the
  save RAM and the memory test;
- a differential bench that checks our framebuffer path against MiSTer's (`sim/vdp`);
- a full-system simulation that runs real cartridges (`sim/system`);
- a regression script over the full system (`sim/regress/run.sh`).

See [`CLAUDE.md`](CLAUDE.md) and [`docs/m4-debug-notes.md`](docs/m4-debug-notes.md) for how to
use them.

## Repository layout

```
core.json, data.json, ...   APF core definition files
dist/                       platform JSON and image for the SD card
src/fpga/                   Quartus project (Cyclone V 5CEBA4F23C8)
  apf/                      Analogue's framework glue (unmodified)
  core/core_top.v           APF glue: bridge, ROM/BIOS/save loading, settings, input, video, audio
  core/s32x_system.sv       the console: Genesis + 32X + cart, SDRAM and SRAM framebuffer
  core/pll/                 core PLL (generated by Quartus' ip-generate)
  core/rtl/S32X_MiSTer/     upstream core (git submodule, patched at build time)
  core/rtl/patches/         our patches to upstream, with a README for each
tools/                      build, release, packaging and helper scripts (images, message ROM)
sim/                        testbenches and the regression script
experiments/                fit experiment, parked PAL clock switching, Memories and Sega CD studies
docs/                       requirements, architecture, game matrix, hardware testing, debug notes
```

## How this core was made

I'm a programmer, but I had never worked on an FPGA core before this project. However, I really
wanted a 32x core for the Pocket (mainly to play Kolibri). All of the code and documentation
in this repository was written with [Claude Code](https://claude.com/claude-code),
building on the MiSTer S32X core and Analogue's openFPGA framework (see Credits). My part was
deciding what to build and in what order, and testing: every build was tested on real Analogue
Pockets and the Dock, and there was a lot of back and forth (reporting what broke, trying fixes,
retesting, etc.) before games ran correctly. The hardware test history is in [`docs/test-log.md`](docs/test-log.md).

## Credits

- [S32X_MiSTer](https://github.com/MiSTer-devel/S32X_MiSTer) by Sergey Dvodnenko (srg320), with
  contributions from Sorgelig, Kitrinx, Gyorgy Szombathelyi and others in the MiSTer project:
  the Genesis and 32X implementation this core is built on, including srg320's SH-2 (SH7604)
  and 32X VDP. Parts of our `s32x_system.sv` (cart quirks, color table, layer mixing) follow its
  top level, `S32X.sv` (GPL-2.0-or-later).
- The Genesis core inside it: FPGAGen by Gregory Estrade, ported to MiSTer and extended by
  Sorgelig.
- [fx68k](https://github.com/ijor/fx68k) (68000) by Jorge Cwik.
- [JT12/JT89](https://github.com/jotego) (YM2612/SN76489) by Jose Tejada Gomez.
- T80 (Z80) by Daniel Wallner, with fixes by MikeJ, TobiFlex, Sorgelig and others.
- The SDRAM controller and the multitap/Team Player logic by Sorgelig; the audio low-pass filters
  by Gregory Hogan (Soltan_G42); the composite blend, cheat engine and SPI EEPROM by Kitrinx.
- [agg23's openFPGA utilities](https://github.com/agg23/analogue-pocket-utils) (data loader,
  I2S audio, sync FIFO) by Adam Gastineau, in `src/fpga/core/rtl/agg23/`.
- [openFPGA-Genesis](https://github.com/opengateware/openFPGA-Genesis) by Open Gateware, a
  reference for the Pocket's SDRAM timing and button mapping.
- Analogue's [openFPGA core template](https://github.com/open-fpga/core-template) (APF). The
  core PLL and its reconfiguration controller are generated by Quartus (Altera IP).
- The icon and platform banner text is rendered with DejaVu Sans Bold; the on-screen message
  font was drawn for this project.

## License

This project's own code is GPL-3.0 (see [`LICENSE`](LICENSE)), compatible with the GPL-licensed
parts that end up in every bitstream (fx68k, JT12/JT89, the SDRAM controller). Third-party code
keeps its own terms, summarized with the full BSD and MIT notices in
[`NOTICE.txt`](NOTICE.txt); `LICENSE` and `NOTICE.txt` ship in the core folder of every
release, as those licenses require for the synthesized form.

- The upstream submodule has no top-level license; its files keep their own terms (GPL-3.0,
  BSD-style or MIT); srg320's SH-2 and 32X sources and Kitrinx's modules state none (see
  `src/fpga/core/rtl/patches/README.md`).
- `src/fpga/apf/` and `core_bridge_cmd.v` are Analogue's framework, under Analogue's APF license
  (see the file headers).
- `src/fpga/core/pll/` and the other Quartus-generated wrappers are Altera/Intel IP under Intel's
  license terms (see their headers).

## Legal

Analogue's Development program was created to further video game hardware preservation with FPGA
technology. Analogue Developers have access to Analogue Pocket I/O's so Developers can utilize
cartridge adapters or interface with other pieces of original or bespoke hardware to support
legacy media. Analogue does not support or endorse the unauthorized use or distribution of
material protected by copyright or other intellectual property rights.
