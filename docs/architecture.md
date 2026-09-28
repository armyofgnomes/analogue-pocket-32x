# Architecture notes

Background on what we're emulating, what the Pocket gives us, and how the two map together.
Numbers marked **(verify)** come from memory or secondary sources. Confirm them against a
datasheet or a fit report before relying on them.

## 1. What a 32X system is

A playable 32X core is really **Genesis + 32X**. The 32X plugs into the Genesis
cartridge slot, uses the Genesis 68000 as a co-processor, and mixes its video over the
Genesis VDP output.

### Genesis / Mega Drive base

| Block | Detail |
|---|---|
| Master clock (MCLK) | 53.693175 MHz NTSC, 53.203424 MHz PAL |
| Main CPU | Motorola 68000 @ MCLK/7 (about 7.67 MHz), 64 KB work RAM |
| Sound CPU | Zilog Z80 @ MCLK/15 (about 3.58 MHz), 8 KB RAM |
| VDP | Yamaha/Sega 315-5313: 64 KB VRAM, 64×9-bit CRAM, 40×10-bit VSRAM, H32 (256 px) / H40 (320 px) modes, 224/240 lines |
| Audio | YM2612 FM + SN76489 PSG (inside the VDP) |
| I/O | 2 controller ports (3/6-button pads), region/version register, TMSS |

### 32X add-on

| Block | Detail |
|---|---|
| CPUs | 2× Hitachi SH-2 (SH7604), master + slave, @ MCLK×3/7 (about 23.01 MHz NTSC). Each has a 4 KB cache, DMA controller, divider, FRT, WDT, SCI, interrupt controller |
| SDRAM | 256 KB, shared by both SH-2s |
| Framebuffer | 2× 128 KB (double-buffered, swapped by the VDP), plus overwrite image window |
| 32X VDP | 320×224/240. Modes: packed pixel (8 bpp via palette), direct color (15 bpp), run-length. 256-entry ×16-bit palette (CRAM). Priority bit for compositing with the Genesis VDP |
| Audio | 2-channel PWM, mixed with Genesis audio |
| Boot ROMs | 68K-side 32X BIOS (256 B), master SH-2 BIOS (2 KB), slave SH-2 BIOS (1 KB). Copyrighted, so the user supplies them |
| 68K interface | Adapter control registers, communication ports, 68K↔SH-2 FIFO (DREQ), ROM banking (68K sees cart through 0x880000/0x900000 windows), SH-2s see cart at 0x02000000 |
| Cartridge | 32X ROMs up to 4 MB. Some carry battery SRAM or EEPROM |

## 2. What the Pocket provides

| Resource | Pocket (Cyclone V **5CEBA4F23C8**) | MiSTer DE10-Nano (5CSEBA6) for comparison |
|---|---|---|
| Logic | ~18,480 ALMs (~49K LE) **(verify)** | ~41,910 ALMs (~110K LE) |
| Block RAM | 308× M10K ≈ 3,080 Kbit (~385 KB) **(verify)** | ~5,570 Kbit (~680 KB) |
| DSP | 66 blocks **(verify)** | 112 blocks |
| External RAM | 64 MB SDRAM, 16-bit (`dram_*`)<br>2× 16 MB PSRAM / CellularRAM, 16-bit (`cram0_*`, `cram1_*`) **(verify sizes)**<br>256 KB async SRAM, 16-bit (`sram_*`, 17 addr bits) | 32/64/128 MB SDRAM add-on + 1 GB DDR3 via HPS |
| Clock in | 74.25 MHz (`clk_74a`, `clk_74b`) | 50 MHz |
| Video out | 24-bit RGB + DE/HS/VS to Analogue's scaler, fixed scaler modes defined in `video.json` | HDMI scaler |
| Audio out | I2S DAC, 48 kHz (`audio_mclk`/`audio_lrck`/`audio_dac`) | |
| Host | APF bridge (SPI-derived, `clk_74a` domain) for file loading, saves, settings, controllers | HPS/ARM |

The template's `core_top.v` already has every one of these ports and ties them off.

## 3. Starting point: which upstream code to build on

There's **no existing Pocket 32X core** as of 2026-09. Useful upstream code:

| Project | Why it matters |
|---|---|
| **MiSTer-devel/S32X_MiSTer** (srg320) | Full, working Genesis + 32X, including an SH7604 implementation (`rtl/SH/SH7604`), the 32X interface/VDP/PWM (`rtl/32X`), fx68k, and its own Genesis (`rtl/GEN`). **The primary base.** |
| srg320/SH | Standalone SH-2 core repo (also used in the Saturn core). Newer fixes may land here first |
| sockitfpga/S32X_Sockit | Port of S32X_MiSTer to a different Cyclone V board. Shows which MiSTer-framework dependencies have to be cut |
| opengateware/openFPGA-Genesis (ericlewis) | Working Pocket Genesis core. Reference for APF glue: data slots, H32/H40 video, audio, input, saves |
| neutralinsomniac/openfpga-megacd | Pocket Genesis + Mega CD. Proves a *bigger* Sega add-on fits and runs on Pocket; good reference for memory-controller sharing |

**Recommendation:** port S32X_MiSTer's system logic (Genesis + 32X, which are already
timing-matched to each other), and borrow the Pocket-side plumbing patterns from
openFPGA-Genesis and openfpga-megacd. Decision tracked as REQ-ARCH-01.

**Licensing:** S32X_MiSTer is mixed GPL-2.0-or-later / GPL-3.0 (core `LICENSE` is GPLv3;
fx68k and jt12/jt89 are GPL-3.0-or-later). Any distributed bitstream built from it must be
released under a compatible license with source. This repo needs a `LICENSE` (REQ-LEGAL-01).

## 4. The central problem: memory and logic budget

How the MiSTer 32X core uses memory, from `S32X.sv`:

- **Cart ROM + cart SRAM:** SDRAM.
- **32X SDRAM (256 KB):** DDR3 by default, SDRAM optionally.
- **32X framebuffers (2×128 KB):** **block RAM** (`spram` instances), or a second SDRAM
  board with `DUAL_SDRAM`.
- **BIOS ROMs:** baked into the bitstream as `mdbios.mif` / `shbios.mif`. This is fine for
  our personal-use builds, generated from gitignored local files, since the BIOS is only ~3.3 KB of
  BRAM. It just means the bitstream can't be shared. Runtime loading from data slots is an
  optional later upgrade.

On the Pocket, the framebuffers alone (2 Mbit) would use two-thirds of all block RAM, before
Genesis VRAM (512 Kbit), 68K RAM (512 Kbit), caches and line buffers. So **the framebuffers
must move to external memory**, and the 32X SDRAM has to go somewhere other than DDR3.

### Proposed memory map (to be validated, REQ-ARCH-02)

| Contents | Size | Proposed home | Notes |
|---|---|---|---|
| Cart ROM | ≤ 4 MB | SDRAM | Read-mostly. SH-2 and 68K both read it, so it needs an arbitrated, multi-port controller |
| 32X SDRAM | 256 KB | SDRAM (separate bank) **or** PSRAM | SH-2 caches soften latency; burst/cache-line fills matter |
| 32X framebuffers | 2× 128 KB | **Async SRAM (256 KB)**, an exact fit | 16-bit, low latency. Must sustain VDP scanout + SH-2 writes + auto-fill. Bandwidth analysis required. Fallback: PSRAM (one chip per buffer, or both in one) |
| Cart save RAM / EEPROM | ≤ 64 KB | BRAM or PSRAM | Mirrored to the SD card via APF save slot |
| Genesis VRAM, 68K RAM, Z80 RAM, CRAM, VSRAM | ~136 KB | BRAM | Same as the existing Pocket Genesis cores |
| SH-2 caches, 32X palette, boot ROMs, line buffers, FIFOs | small | BRAM / MLAB | Boot ROMs embedded at build time (personal use) or loaded from data slots |

### Logic budget

The Pocket has **roughly 44% of the ALMs** of the MiSTer target. The Genesis alone fits on the
Pocket comfortably, and Genesis + Mega CD also fits. Two SH-2s plus the 32X VDP is the unknown.
**The first engineering task is a synthesis-only experiment** (REQ-ARCH-03): compile the
S32X_MiSTer system logic (no MiSTer `sys/` framework) targeting 5CEBA4F23C8 and read the
resource report. If it doesn't fit, options include:

- Trim MiSTer-only features (cheats, COFI, extra video filters, dual-SDRAM paths).
- Share one divider/multiplier between SH-2s, or trim rarely used SH-2 peripherals (SCI,
  UBC, WDT) where no commercial game needs them.
- Convert register-heavy structures to MLAB/M10K.
- As a last resort, time-multiplex a single SH-2 datapath between master and slave. This is
  high risk for accuracy.

## 5. Clocks

- MiSTer uses `clk_sys` = 53.693175 MHz (MCLK) with clock enables for every CPU, and
  `clk_ram` = 107.38635 MHz (2× MCLK) for SDRAM and video.
- Pocket PLLs are fed from 74.25 MHz. We need MCLK (NTSC and ideally PAL), a memory clock,
  12.288 MHz audio MCLK, and a video pixel clock plus 90° phase copy.
- The SH-2 path at MCLK with 3/7 clock enables is the tightest timing path in the MiSTer
  core. Expect timing-closure work on the Pocket's speed grade 8 part.

### Toolchain

- **Quartus Prime Lite 25.1std.0 Build 1129** (Linux), with Cyclone V device support only.
  Questa FPGA Starter Edition is installed alongside it for simulation.
- The template was created with 18.1.1. It compiles unchanged in 25.1std, and the template
  IP (`mf_pllbase`) needed no upgrade. Only `LAST_QUARTUS_VERSION` in `ap_core.qsf` changed.
- Headless build: `cd src/fpga && quartus_sh --flow compile ap_core`, then
  `tools/reverse_bits.py` and `tools/package.py [--zip]`.
- Template baseline (2026-09-28, 25.1std): 413 / 18,480 ALMs (2 %), 718 registers, 2 / 308
  M10K, 0 DSP, 1 / 4 PLL, 224 / 224 pins. Timing met in all corners (worst hold slack
  +0.110 ns on `clk_74a`, fast 0 °C corner). No critical warnings.

## 6. Video path

- Output is either Genesis-only, 32X-only, or a composite based on the 32X priority bit. S32X_MiSTer
  already does this mixing digitally.
- The Pocket scaler needs fixed modes in `video.json`: at minimum 320×224 (H40), 256×224
  (H32), and 240-line PAL variants, selected at runtime via the scaler-slot mechanism
  (`video_rgb` bits during `!video_de` at the start of a frame). openFPGA-Genesis already
  handles H32/H40 switching and is the reference.
- Pixel clock: keep a fixed video clock and use `video_de`/`video_skip` so H32/H40 changes
  don't need PLL reconfiguration.

## 7. Risk register

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Doesn't fit in 18.5K ALMs | Project-blocking | REQ-ARCH-03 before anything else. Trim features. Share logic |
| R2 | Framebuffer bandwidth in SRAM/PSRAM too low | Visual glitches, slowdowns | Bandwidth model from 32X VDP access patterns. Line buffers. Fallbacks in §4 |
| R3 | SH-2 memory latency (non-DDR3) hurts timing-sensitive games | Game bugs | Cycle-accurate wait-state model. Test against the known-sensitive game list |
| R4 | Timing closure at speed grade 8 | Instability across units | Pipeline critical paths. Test on **multiple Pockets** (the owner has several) |
| R5 | GPL obligations | Legal | LICENSE, source availability, attribution (REQ-LEGAL-*) |
| R6 | BIOS handling | Can't publish a bitstream with embedded BIOS | Accepted for personal use. BIOS stays out of git. Runtime loading (REQ-APF-03b) only if we ever publish |
