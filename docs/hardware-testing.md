# Hardware testing workflow

Claude can't run bitstreams. The owner has several Analogue Pockets and runs all on-device
tests. This doc keeps that loop fast and unambiguous.

## SD card layout

Pocket openFPGA cores are loaded from the SD card root. Replace `<Author>`, `<Core>` and
`<platform>` once REQ-APF-01/02 are settled (the template uses `ex_platform`).

```
/Cores/<Author>.<Core>/
    bitstream.rbf_r       ← from output/ (bit-reversed build)
    core.json data.json video.json audio.json input.json interact.json variants.json
    info.txt icon.bin
/Platforms/<platform>.json
/Platforms/_images/<platform>.bin
/Assets/<platform>/common/          ← game ROMs (.32x) go here or any subfolder
                                      (plus BIOS files only if REQ-APF-03b is ever done)
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

Results go in `docs/test-log.md` (create on first test): date, build hash, Pocket
(label them A/B/C…), firmware version, handheld/docked, results.

## Debug aids

- **On-screen debug:** a debug build flag that overlays status (PC of each CPU, memory
  test result, BIOS present, load state) on the video output. This is the main
  observability tool without JTAG.
- **Bridge-readable status registers:** expose counters/state at a bridge address so the
  host side can report them.
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

## Multiple Pockets

Marginal timing often shows up on only one unit. For milestone builds and anything
touching clocks, PLLs or memory controllers, test on at least two Pockets (REQ-QA-02).
