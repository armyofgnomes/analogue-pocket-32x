# Changelog

Versions follow `core.json`. Hardware-verified versions from 0.4.0 on are git tags and GitHub
releases with the SD-card zip. Per-build hardware results are in `docs/test-log.md`.

## Unreleased

- Analogue OS display modes: CRT, three LCD styles, pinball neon and vacuum fluorescent.
- Every pin is covered in the timing constraints (the memory, bridge, video and audio pins as
  documented exceptions, so nothing is left unconstrained), and the build checks that the memory
  pin registers are in their I/O cells; a simulation regression script.
- Memories studied and found not to fit alongside the 32X (`experiments/memories/`).
- Sega CD 32X games studied and found not to fit (`experiments/segacd32x/`).
- Credits and licenses reviewed: the core folder now carries `LICENSE.txt` (GPL-3.0) and
  `NOTICE.txt` (third-party credits with the BSD and MIT notices their licenses require), and the
  credits name the Genesis core (Gregory Estrade, Sorgelig), T80, the audio filters (Soltan_G42)
  and Kitrinx's composite blend.

## 0.4.2 (2026-09-30)

- After Burner Complete's cannon and missile sounds play. The game keeps its PWM sample index in
  an SH-2 debug register (the User Break Controller), which an early area-saving patch had
  switched off. Tempo also uses those registers.
- Build outputs are no longer committed; verified builds are published as releases.
- Documentation review; README section on how the core was made.

## 0.4.1 (2026-09-30)

- The core PLL is reconfigurable (still NTSC only; PAL clock switching was tried and parked).
- Timing fixes: the SDRAM/framebuffer request enable, synchronizers, and a build check for
  timing constraints that match nothing.
- The BIOS files load through the ROM loader (one loader less).

## 0.4.0 (2026-09-30)

- The BIOS is loaded from the SD card (`Assets/32x/common/`) instead of being built into the
  bitstream. A 32X game started without the BIOS files shows which file is missing; Genesis
  games run without them.
- Core icon and platform banner.
- Verified in the Analogue Dock (HDMI, second controller) and on a second Pocket.

## 0.3.0 (2026-09-29)

- Settings menu: region, 6-button pad, audio filter, FM chip, HiFi PCM, composite blend, high
  sprite limit, reset.
- Cartridge saves: battery SRAM and EEPROM in `.sav` files (MiSTer's format).

## 0.2.0 (2026-09-29)

- Most tested 32X games playable: 32X SDRAM front end with SDRAM line reads, cartridge quirk
  table (EEPROM carts such as NBA Jam TE), H32 picture timing fixed.

## 0.1.0 (2026-09-28)

- First build on hardware: Genesis games play (video, audio, controls). The 32X followed during
  0.1.x development (framebuffers in the Pocket's SRAM, both SH-2s, BIOS boot).
