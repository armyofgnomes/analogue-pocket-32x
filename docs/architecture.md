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

**Decision (REQ-ARCH-01, 2026-09-28): port S32X_MiSTer.** The owner approved it after the M0 fit
results (§4). Rationale:
- Genesis and 32X in S32X_MiSTer are already timing-matched to each other. Grafting a 32X onto
  openFPGA-Genesis would mean re-deriving that bus timing by hand.
- The fit experiment shows the S32X_MiSTer system logic fits the Pocket at 85 % ALMs after
  accuracy-neutral or audio-only trims, with timing met (+1.3 ns).
- Its Genesis VDP keeps a single VRAM copy, so block RAM stays at ~41 %. openFPGA-Genesis uses
  97 % of M10K, which would leave no room for 32X caches, palette and FIFOs.
- openFPGA-Genesis and openfpga-megacd remain the reference for the APF plumbing (loaders,
  bridge, I2S, video modes), which we reimplement or borrow around S32X_MiSTer's `gen`.

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

### Fit experiment results (REQ-ARCH-03, 2026-09-28)

Setup: `experiments/fit_s32x/` (`run.sh` fetches S32X_MiSTer at `b438679` and compiles).
The wrapper instantiates `gen` + `S32X` + `CART` as wired in upstream `S32X.sv`, with every
memory bus (cart ROM/SRAM, 32X SDRAM, both framebuffers) on virtual pins, so the
framebuffers aren't in BRAM. Mouse, lightgun, multitap pads 3–5, Game Genie and VDP debug
layers are tied off. Upstream's optimization settings, Quartus 25.1std, 5CEBA4F23C8.

| Resource | Used | Pocket total | % |
|---|---|---|---|
| ALMs needed | 17,377 | 18,480 | **94 %** (fitter reports packing difficulty "High") |
| Registers | 19,410 | | |
| Block RAM | 1,278,832 bits / 171 M10K | 3,153,920 bits / 308 | 41 % / 56 % |
| DSP | 23 | 66 | 35 % |
| Timing @ 53.693 MHz | Met in all corners. Fmax 57.9 MHz, worst setup slack +1.000 ns (slow 0 °C), worst hold +0.101 ns | | |

ALMs by block:

| Block | ALMs | Notes |
|---|---|---|
| SH-2 master (`SH7604:MSH`) | 4,611 | core 1,739 · cache 681 · DIVU 458 · MULT 367 · DMAC 365 · BSC 312 · INTC 145 · UBC 122 · SCI 109 · FRT 91 · WDT 46 |
| SH-2 slave (`SH7604:SSH`) | 4,658 | same breakdown |
| 32X interface (`S32X_IF`) | 634 | |
| 32X VDP | 259 | framebuffers external |
| **32X total** | **10,187** | |
| 68000 (`fx68k`) | 1,881 | |
| YM2612 (`jt12`) | 1,221 | |
| Genesis VDP | 1,209 | |
| Z80 (`T80`) | 954 | |
| Audio mixer/upsampler (`jt12_genmix`) + FM low-pass filters | 675 | |
| Bus arbiter, I/O, PSG, other | ~744 | |
| **Genesis total** | **6,684** | |
| Cart mapper | 222 | |
| Top-level glue + JTAG hub | ~283 | JTAG hub (58) comes from `ENABLE_RUNTIME_MOD` in upstream `bram.vhd`, a MiSTer debug aid |

**Verdict:** the system logic alone fits, but at 94 % it leaves no room for the Pocket side, so
REQ-ARCH-04 is required. Block RAM (41 %) includes 68K RAM, Z80 RAM and VRAM, which are all
on-chip. Cart save RAM (512 Kbit) could also go on-chip (→ ~58 %).

**Pocket-side cost, measured:** openFPGA-Genesis (`0032b2c`) compiled with 25.1std uses 12,375
ALMs in total, of which its Genesis `system` is 11,088. That makes its Pocket plumbing ~1,290
ALMs: bridge command handler 179, ROM/save loaders + unloader 302, lightgun 192, controller
I/O + bridge peripheral 187, I2S 71, single-port SDRAM 56, JTAG hub/cofi/glue ~300. Our core
needs a multi-port SDRAM controller and an SRAM framebuffer controller and can drop the
lightgun, so the planning figure is **~1,300–1,700 ALMs**.

### Reduction experiments (REQ-ARCH-04, 2026-09-28)

Each variant lives in `experiments/fit_s32x/variants/` and is measured against the baseline
(which reproduces exactly: 17,377). Run with e.g.
`experiments/fit_s32x/run.sh area_aggressive+no_debug`.

| Variant | What it does | ALMs | Δ | Setup slack | Decision |
|---|---|---|---|---|---|
| `area_aggressive` | `OPTIMIZATION_MODE "AGGRESSIVE AREA"`, technique AREA, no register duplication | 16,696 | −681 | +1.405 | **Keep** (timing *improved*) |
| `no_genmix` | Replace `jt12_genmix` PSG/FM resampler with a plain registered sum at the same levels | 16,724 | −653 | +0.803 | **Keep**: audio-quality trade-off, verify by ear |
| `no_debug` | SH-2 UBC disabled (`UBC_DISABLE`), no In-System Memory Content Editor hub | 17,162 | −215 | +1.706 | **Keep**: no game-visible effect |
| `audio_lite` | Genesis low-pass filters bypassed (`LPF_MODE=11`), no hi-fi PCM interpolation. Also saves 10 DSP | 17,203 | −174 | +1.199 | **Keep**: audio-quality trade-off |
| `area_balanced` | `OPTIMIZATION_MODE BALANCED` | 17,347 | −30 | +1.063 | Drop |
| `no_wdt` | SH-2 watchdog disabled | 17,361 | −16 | +1.489 | Drop: no saving, accuracy risk |
| **Combined keepers** | `area_aggressive+no_debug+audio_lite+no_genmix` | **15,631 (85 %)** | **−1,746** | **+1.324** | Current best |
| Same without `area_aggressive` | | 16,531 | −846 | +1.770 | (area setting is worth ~900 on the trimmed design) |
| + `jt12_shreg` | YM2612 shift registers without parallel reset → RAM | 15,536 | −95 more | +1.010 | Drop: small gain, small reset-behavior risk |
| + `shreg_always` | Force all shift registers to RAM | 15,764 | +133 | +0.708 | Drop |

Looked at and not pursued: moving SH-2 MULT/DIVU into DSP (the 32×32 multiplies are already
DSP, and the divider is a 1-bit/cycle iterative design; sharing its two 65-bit adders might save
~100 ALMs per CPU). SCI stays, because the 32X wires master↔slave SCI together and games can
use it.

**Where this leaves the budget:** 15,631 (system) + ~1,300–1,700 (Pocket side) ≈
**16,900–17,300 ALMs, 92–94 %**. That's a fit, but ~300–700 ALMs short of the ~10 % headroom
target. Remaining candidates, roughly in order of risk:
1. Fitter seed sweep: ±1–2 % variance is typical at this utilization.
2. Share DIVU adders (~200 for both CPUs). SH-2 cache tag RAMs from MLAB/registers into M10K
   (~100–150 per CPU).
3. Keep the Pocket side lean: no lightgun, one shared dcfifo-based loader.
4. Genesis VDP register usage (1,869 registers, the biggest register block) deserves a look.
5. Only then anything that touches CPU accuracy.

The headroom target is a guideline for routability and timing. openFPGA-Genesis ships at 67 %,
but plenty of Pocket cores ship above 90 %. Timing at 85 % is +1.3 ns, better than the
baseline's.

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
