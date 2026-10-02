# Hardware testing workflow

Claude can't run bitstreams. The owner has several Analogue Pockets and runs all on-device
tests. This doc keeps that loop fast and unambiguous.

## SD card layout

Pocket openFPGA cores are loaded from the SD card root. Replace `<Author>`, `<Core>` and
`<platform>` with the values from `core.json` (currently `armyofgnomes`, `32X`, `32x`).

```
/Cores/<Author>.<Core>/
    bitstream.rbf_r       ← from output/ (bit-reversed build)
    core.json data.json video.json audio.json input.json interact.json variants.json
    info.txt icon.bin
    LICENSE.txt NOTICE.txt  ← GPL-3.0 and third-party notices (not read by the Pocket)
/Platforms/<platform>.json
/Platforms/_images/<platform>.bin
/Assets/<platform>/common/          ← game ROMs (.32x) go here or any subfolder, and the
                                      BIOS files 32X_G_BIOS.BIN, 32X_M_BIOS.BIN, 32X_S_BIOS.BIN
/Saves/<platform>/...               ← created by the Pocket for save data
```

Firmware: keep every test Pocket on the same, current Analogue OS release, and record the
version in the test log. The core requires framework `version_required` ≥ 1.1 (`core.json`).

## Test request format (Claude → owner)

Every change that touches the bitstream ends with a request like this:

```
Build: <git short hash>, <Quartus version>, fit: <ALMs %> / <M10K %>, worst slack <ns>
Install: copy package to SD (or: only bitstream.rbf_r changed)
Test:
  1. Load <ROM / test ROM>. Expect: <exact visual/audio result>
  2. ...
Report: pass/fail per step, photo/video if anything looks wrong, which Pocket(s)
```

## Test result format (owner → Claude)

Short is fine, for example: "Pocket A: step 1 pass, step 2 audio crackles every ~2 s. Pocket B:
same." Photos or phone video of glitches help a lot. Screen captures can come from the
Pocket's screenshot feature or via the Dock's HDMI output.

## Log

Results go in `docs/test-log.md`: date, build hash, Pocket (A/B, see "Multiple Pockets"),
firmware version, handheld/docked, results.

## Debug aids

- **On-screen output:** the memory self-test build (`tools/build.sh --memtest`) draws pass/fail
  bars over the picture, and `s32x_msg_rom.sv` + `tools/gen_msg_rom.py` provide a text screen
  (used for the missing-BIOS message) that a debug build could reuse. A general status overlay
  (CPU PCs, load state) doesn't exist yet.
- **Bridge-readable status registers** (idea, not built): expose counters/state at a bridge
  address so the host side can report them.
- **JTAG + SignalTap** (`src/fpga/core/stp1.stp` exists in the template): every Pocket has
  a JTAG header on the bottom edge next to the USB-C port (see Analogue's openFPGA
  "Getting Started" docs). With a USB Blaster connected you can load a `.sof` directly,
  taking seconds with no SD-card shuffle, and use SignalTap as an on-chip logic analyzer. Use a
  genuine or licensed USB Blaster (Intel or Terasic). Cheap clones have reportedly killed a
  Pocket. Optional for M0–M2, but strongly recommended from M3 on, when dual-SH-2 and
  memory-controller bugs start. On a desktop session, Claude can drive `quartus_pgm` and
  `quartus_stp` itself.
- **Simulation first:** anything testable in simulation (CPU boot sequences, VDP line
  output, memory controller behavior) should be proven there before costing the owner a
  hardware cycle.

## Known-good builds

Hardware-verified builds are tagged `vX.Y.Z` (annotated, with notes), `core.json` carries the
same version, and each is a **GitHub release** with the SD-card zip
(https://github.com/armyofgnomes/analogue-pocket-32x/releases). To go back to one, download its zip and
unzip it to the SD card root; the zip holds the matching JSON files too (they change between
versions, e.g. the BIOS slot addresses between v0.4.0 and v0.4.1).

Publishing, after the owner verifies a build:
1. Bump `core.json`'s version, commit, then `git tag -a vX.Y.Z` with notes and push both.
2. `tools/release.sh vX.Y.Z`. It checks that the bitstream in `output/` was built from the
   tag's sources (`output/build_info.txt`, written by `tools/build.sh`), packages the tag's tree
   with it and creates the release. `DRY_RUN=1` does everything except publishing.

Build outputs (bitstream, `.sof`/`.rbf`, `apf/build_id.mif`) aren't committed: releases are the
archive.

| Tag | Commit | Highlights |
|---|---|---|
| v0.4.3 | see `git show v0.4.3` | First public release: display modes, pin timing constraints, LICENSE/NOTICE in the core folder |

v0.4.0 to v0.4.2 were released only in the private development repository, before this public
one; they aren't published here (their entries remain in `CHANGELOG.md`).

## Regression set (REQ-QA-04)

Checked on every build that changes the bitstream, on top of whatever the change targets. About
ten minutes; each game covers something the others don't.

| Game | What it covers |
|---|---|
| Kolibri (32X) | 32X boot, both SH-2s, framebuffer drawing, PWM |
| Doom (32X) | 32X SDRAM traffic (cache fills), heavy framebuffer writes |
| Knuckles' Chaotix (32X) | Battery SRAM save: load the save |
| After Burner Complete (32X) | PWM samples through the SH-2 UBC registers: fire the cannon |
| Virtua Fighter (32X) | Polygon rendering, speed (in-game clock) |
| Sonic The Hedgehog 3 (Genesis) | Genesis path, FM/PSG audio, battery SRAM save |
| Mega Man: The Wily Wars (Genesis) | H32 (256-pixel) picture timing, EEPROM |

Plus, when relevant: Mystic Defender for the Region setting, the pad test program for the
6-button pad, and a BIOS file renamed for the missing-BIOS screen.

## Known-good test cases

- **Pad test program:** `python3 sim/system/roms/make_padtest.py build/padtest.bin` builds a tiny
  Genesis program (our own code) that reads pad 1 like 6-button games do and colors the screen:
  gray = no 6-button pad, black = detected, red/green/blue = X/Y/Z (Pocket L/X/R), white = Mode
  (Select). Load it like any ROM. It also runs in `sim/system` (`+pad6 +joy1=<hex>`).
- **6-button games:** many (e.g. fighting games) only use X/Y/Z after enabling the 6-button pad in
  their own options menu, so "X/Y/Z do nothing" in a game is not by itself a core bug.
- **Region:** Mystic Defender shows visible differences between regions. Europe also runs games
  and music about 17% slower (50 Hz timing).
- **Saves:** Knuckles' Chaotix (32X) and Sonic 3 (Genesis) for battery SRAM; Mega Man: The Wily
  Wars and NBA Jam TE for EEPROM.

## Multiple Pockets

Owner's units: **A** white original release (primary), **B** transparent orange release.

Marginal timing often shows up on only one unit. For milestone builds and anything
touching clocks, PLLs or memory controllers, test on at least two Pockets (REQ-QA-02).
