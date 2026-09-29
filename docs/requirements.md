# Requirements and milestone plan

What has to be true for a working Sega 32X core on the Analogue Pocket, grouped by area and
sequenced into milestones. Background and rationale: `architecture.md`.

**Status legend:** `TODO` · `WIP` · `DONE` · `BLOCKED` · `DROPPED`
**Priority:** **P0** = required for a first playable release · **P1** = required for a
quality 1.0 · **P2** = nice to have
**Verify with:** `HW` = owner tests on a Pocket · `SIM` = simulation/lint · `FIT` = Quartus
report · `DOC` = document review

Update the status column in the same commit that completes a requirement.

---

## Milestones

| Milestone | Goal | Exit criteria |
|---|---|---|
| **M0: Tooling & feasibility** (all but REQ-TOOL-04) | Know whether it fits, and have a repeatable build | REQ-TOOL-01..04 done. REQ-ARCH-03 fit report reviewed. Go/no-go on REQ-ARCH-01 |
| **M1: Pipeline proven on hardware** ✅ 2026-09-28 | Build from source → Pocket, end to end | Modified template (e.g. solid color of our choosing) built by us, loads on a Pocket |
| **M2: Genesis on Pocket** ✅ 2026-09-28 | The Genesis half of the system runs, from the S32X codebase with 32X disabled | Several Genesis games boot and play with sound and input |
| **M3: 32X memory subsystem** ✅ 2026-09-28 (memory; BIOS embedding verified in M4) | Framebuffers, 32X SDRAM and BIOS live in Pocket memory | Memory test patterns pass on HW. BIOS present (embedded is fine) |
| **M4: 32X boots** | Both SH-2s run BIOS code | 32X BIOS/security screen shown. A simple 32X homebrew/test ROM runs |
| **M5: Games playable** | Commercial 32X library playable | Test-matrix games (REQ-QA-03) boot and play with correct video/audio |
| **M6: Polish** | Saves, settings, PAL, dock, accuracy fixes | P1 requirements done |
| **M7: Release (optional)** | Public release, only if BIOS is runtime-loaded | REQ-APF-03b and REQ-DIST-* done |

---

## 1. Tooling (TOOL)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-TOOL-01 | P0 | Pick and record a Quartus Prime Lite version. The project compiles cleanly with it (`docs/architecture.md` §5 notes version) | FIT | DONE |
| REQ-TOOL-02 | P0 | Script to bit-reverse `ap_core.rbf` → `bitstream.rbf_r` (e.g. `tools/reverse_bits.py`) | SIM | DONE |
| REQ-TOOL-03 | P0 | Script to assemble an SD-card-ready package (`Cores/`, `Platforms/`, `Assets/` layout) from repo files + built bitstream | HW | DONE |
| REQ-TOOL-04 | P1 | Simulation setup for core logic (Verilator and/or GHDL + Icarus/ModelSim for mixed VHDL/Verilog), runnable in Claude's container | SIM | DONE |
| REQ-TOOL-05 | P1 | Build-ID and version stamping (template's `build_id_gen.tcl`) surfaced in `core.json` versions/release notes | DOC | TODO |
| REQ-TOOL-06 | P2 | CI build (GitHub Actions with a Quartus container) producing the `.rbf_r` and zip artifact | FIT | TODO |

## 2. Legal and provenance (LEGAL)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-LEGAL-01 | P0 | Choose a project license compatible with imported GPL code (GPLv3 likely) and add `LICENSE` | DOC | DONE |
| REQ-LEGAL-02 | P0 | Every imported third-party directory keeps its license and records upstream URL + commit | DOC | WIP |
| REQ-LEGAL-03 | P0 | No copyrighted BIOS/ROM data committed to git. Strip upstream `mdbios.mif` / `shbios.mif` from imported code. Local BIOS goes in a gitignored `bios/` dir. A bitstream with embedded BIOS is fine for **personal use** but must never be published | DOC | DONE |
| REQ-LEGAL-04 | P1 | Credits/attribution in `README.md` and `info.txt` (srg320, Jorge Cwik/fx68k, Jose Tejada/jt12/jt89, T80 authors, Genesis core authors, Pocket port authors referenced) | DOC | TODO |

## 3. Architecture decisions (ARCH)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-ARCH-01 | P0 | Decide the base: port S32X_MiSTer system logic (recommended) vs. openFPGA-Genesis + graft 32X. Record the decision and rationale | DOC | DONE |
| REQ-ARCH-02 | P0 | Finalize memory map for cart ROM, 32X SDRAM, framebuffers, save RAM, BIOS (proposal in `architecture.md` §4), including a bandwidth budget per memory | DOC | DONE |
| REQ-ARCH-03 | P0 | **Fit experiment:** synthesize the S32X system logic (no MiSTer `sys/`) for 5CEBA4F23C8 with framebuffers stubbed out of BRAM. Record ALM / M10K / DSP / PLL usage and Fmax | FIT | DONE |
| REQ-ARCH-04 | P0 | If REQ-ARCH-03 is over budget: a reduction plan with estimated savings per item, executed until fit with ≥ ~10% ALM headroom for routing | FIT | DONE |
| REQ-ARCH-05 | P0 | Clock plan: PLL outputs for MCLK (NTSC), memory clock, video clock (+90°), 12.288 MHz audio; CDC points listed | FIT | TODO |
| REQ-ARCH-06 | P1 | PAL MCLK (53.203424 MHz) support: second PLL config or dynamic reconfiguration | HW | TODO |

## 4. APF integration and packaging (APF)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-APF-01 | P0 | `core.json`: real metadata (author, shortname, description, version, URL), `platform_ids` set to our platform, correct framework flags | HW | WIP |
| REQ-APF-02 | P0 | Platform definition: `dist/platforms/<id>.json` (category "Console", name "32X", manufacturer Sega, year 1994) and platform image `.bin`. Replace the `ex_platform` placeholders | HW | WIP |
| REQ-APF-03 | P0 | `data.json` cartridge ROM slot (`.32x`, also `.bin`/`.md`/`.gen` for plain Genesis) | HW | DONE |
| REQ-APF-03a | P0 | BIOS available to the core. **Phase 1 (acceptable end state for personal use):** embedded at build time from gitignored `bios/` files. Build fails clearly if they're missing | FIT | DONE |
| REQ-APF-03b | P2 | BIOS loaded at runtime from data slots instead (68K, master SH-2, slave SH-2 in `Assets/<platform>/common/`), with a visible error if missing. Needed only if the core is ever shared publicly | HW | TODO |
| REQ-APF-04 | P0 | Bridge-driven loading: data-slot writes land in the correct external memory / BRAM, with core held in reset until loading completes (`dataslot_allcomplete`) | HW | DONE |
| REQ-APF-05 | P0 | Replace template `icon.bin` and `info.txt` with project-specific content | HW | TODO |
| REQ-APF-06 | P1 | `interact.json` settings: region (auto/US/EU/JP), 6-button pad toggle, audio options (FM chip variant, lowpass), video options (border, composite blending), reset. Values wired through the bridge | HW | TODO |
| REQ-APF-07 | P1 | Optional Genesis TMSS BIOS slot (off by default) | HW | TODO |
| REQ-APF-08 | P2 | Sleep/wake and save states (`sleep_supported`). Large state: 256 KB SDRAM + 256 KB framebuffer + Genesis state | HW | TODO |

## 5. Clocking and reset (CLK)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-CLK-01 | P0 | New PLL(s) replacing the template's `mf_pllbase` per REQ-ARCH-05. Lock is used in reset | FIT | DONE |
| REQ-CLK-02 | P0 | Clock-enable generator for 68K (/7), Z80 (/15), SH-2 (×3/7), VDP and FM, matching MiSTer's `CEGen` | SIM | TODO |
| REQ-CLK-03 | P0 | All bridge ↔ core crossings synchronized. Timing analysis shows no unconstrained paths. SDC updated | FIT | TODO |
| REQ-CLK-04 | P0 | Positive setup/hold slack on all corners in the final build | FIT | TODO |

## 6. Memory subsystem (MEM)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-MEM-01 | P0 | SDRAM controller for the Pocket's 64 MB SDRAM, multi-port: cart ROM (68K + SH-2 + Z80 bank), loader writes, and (if chosen) 32X SDRAM + save RAM, with bounded latency | HW | DONE |
| REQ-MEM-02 | P0 | Framebuffer storage in external memory (SRAM proposed) supporting 32X VDP scanout, SH-2 reads/writes, and VDP auto-fill, with FB swap semantics | HW | DONE |
| REQ-MEM-03 | P0 | 32X SDRAM (256 KB) in external memory with wait-state behavior close to real hardware | HW | WIP |
| REQ-MEM-04 | P0 | BIOS images in BRAM (initialized at build time, or loaded from data slots per REQ-APF-03b). Correct mapping at SH-2 0x00000000 and 68K vector area | SIM | WIP |
| REQ-MEM-05 | P0 | Genesis internal RAMs (68K 64 KB, Z80 8 KB, VRAM 64 KB, CRAM, VSRAM) in BRAM | FIT | DONE |
| REQ-MEM-06 | P1 | Memory self-test mode (debug build) that exercises each external RAM and reports pass/fail on screen | HW | DONE |

## 7. Genesis base system (GEN), milestone M2

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-GEN-01 | P0 | 68000 (fx68k), Z80 (T80), VDP, YM2612 (jt12), PSG (jt89) integrated from the chosen base | HW | DONE |
| REQ-GEN-02 | P0 | Plain Genesis/Mega Drive ROMs boot and play (non-32X carts pass through when 32X is disabled) | HW | DONE |
| REQ-GEN-03 | P0 | Region/version register from header auto-detect + override | HW | WIP |
| REQ-GEN-04 | P1 | Cart mappers needed by 32X carts and common Genesis carts (SSF2 banking at minimum). EEPROM carts as in base core | HW | TODO |

## 8. 32X hardware (S32X), milestones M3–M5

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-S32X-01 | P0 | Two SH7604 instances (master/slave) with caches, DMAC, DIVU, MULT, FRT, INTC, WDT as needed by games | HW | WIP |
| REQ-S32X-02 | P0 | 68K-side interface: adapter control, interrupt control, bank set, DREQ FIFO, comm ports, SEGA TV register, 68K ROM windows at 0x880000 / 0x900000 | HW | WIP |
| REQ-S32X-03 | P0 | SH-2-side system registers: interrupt mask, standby, H-count, DREQ, comm ports, PWM regs, SH-2 view of cart at 0x02000000 | HW | WIP |
| REQ-S32X-04 | P0 | 32X VDP: packed-pixel, direct-color and run-length modes. Line table. Shift. Auto-fill. FB swap at VBlank. 256-color palette | HW | WIP |
| REQ-S32X-05 | P0 | Video compositing with Genesis VDP using 32X priority bit and "32X layer enable" semantics | HW | WIP |
| REQ-S32X-06 | P0 | PWM audio (2 ch) with cycle register and FIFO/timer interrupt | HW | WIP |
| REQ-S32X-07 | P0 | BIOS boot flow completes: security check, "SEGA" / 32X startup, handoff to game | HW | TODO |
| REQ-S32X-08 | P1 | Correct cycle timing / wait states for SH-2 accesses to cart, SDRAM, FB, VDP registers (the timing-sensitive games in REQ-QA-03 behave) | HW | TODO |
| REQ-S32X-09 | P1 | Running 32X ROMs with no BIOS present, via HLE boot, is **out of scope**. Documented, not implemented | DOC | TODO |

## 9. Video output (VID)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-VID-01 | P0 | `video.json` scaler modes for H40 (320) and H32 (256) × 224, plus 240-line variants; runtime slot selection | HW | WIP |
| REQ-VID-02 | P0 | Stable video timing to the Pocket scaler with no tearing/rolling on H32↔H40 or interlace changes | HW | WIP |
| REQ-VID-03 | P0 | Correct color: Genesis 9-bit → 24-bit LUT, 32X 15-bit → 24-bit | HW | WIP |
| REQ-VID-04 | P1 | Interlace mode 2 (e.g. Sonic 2 2P) handled sensibly | HW | TODO |
| REQ-VID-05 | P1 | Dock output verified (HDMI via Analogue Dock), correct aspect ratio | HW | TODO |
| REQ-VID-06 | P2 | Optional border/overscan and composite-blend options | HW | TODO |

## 10. Audio (AUD)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-AUD-01 | P0 | YM2612 + PSG + PWM mixed with sane relative levels and no clipping | HW | WIP |
| REQ-AUD-02 | P0 | Resampled/delivered as 48 kHz I2S to the Pocket (`audio_mclk` 12.288 MHz) without pops, drift or underrun | HW | WIP |
| REQ-AUD-03 | P1 | Low-pass filter option (Model 1/Model 2 style) | HW | TODO |

## 11. Input (INP)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-INP-01 | P0 | Pocket controls → Genesis 3-button pad (A/B/C/Start) via `input.json` mapping | HW | DONE |
| REQ-INP-02 | P0 | 6-button pad (X/Y/Z/Mode) with correct TH-toggle protocol. Toggle for games that break with 6-button | HW | TODO |
| REQ-INP-03 | P1 | Player 2 via Dock controllers | HW | TODO |

## 12. Saves (SAVE)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-SAVE-01 | P1 | Battery-backed SRAM / EEPROM carts saved to SD via APF save slot (nonvolatile data slot), loaded on start | HW | TODO |
| REQ-SAVE-02 | P1 | Saves survive power-off and core switch. No corruption on quick power cycles | HW | TODO |

## 13. Quality and testing (QA)

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-QA-01 | P0 | Hardware test protocol followed per `hardware-testing.md`; results logged in `docs/test-log.md` | DOC | WIP |
| REQ-QA-02 | P0 | Every release build tested on **at least two different Pockets** (catches marginal timing) | HW | TODO |
| REQ-QA-03 | P0 | Game test matrix covering the 32X library, especially titles known to stress SH-2 timing, dual-CPU sync, PWM and all VDP modes (e.g. Virtua Racing Deluxe, Star Wars Arcade, Doom, Knuckles' Chaotix, Kolibri, Virtua Fighter, Metal Head, Tempo, Mortal Kombat II, Spider-Man: Web of Fire, Shadow Squadron, After Burner Complete, Space Harrier, NBA Jam TE, FIFA 96). Use the MiSTer "Game list.xlsx" for known-issue cross-reference | HW | TODO |
| REQ-QA-04 | P1 | Genesis regression set (a handful of Genesis games) still passes after 32X work | HW | TODO |
| REQ-QA-05 | P1 | Homebrew/test ROMs for 32X VDP modes, PWM, comm ports used as automated-ish checks in sim and on HW | SIM/HW | TODO |
| REQ-QA-06 | P1 | 30-minute soak test with no hangs, audio drift or video loss, in handheld and docked mode | HW | TODO |

## 14. Distribution (DIST)

Public release is optional. The owner is fine with a personal-use-only core. These matter
only if we decide to publish, which also requires REQ-APF-03b (no embedded BIOS).

| ID | Pri | Requirement | Verify | Status |
|---|---|---|---|---|
| REQ-DIST-01 | P1 | Release zip matching the Pocket SD-card layout, installable by unzip-to-root | HW | TODO |
| REQ-DIST-02 | P1 | `README.md` rewritten: features, install, BIOS filenames and placement, known issues, credits | DOC | TODO |
| REQ-DIST-03 | P1 | `updaters.json` / inventory-compatible metadata so the core shows up in community updaters (e.g. pocket_updater, openFPGA Library) | DOC | TODO |
| REQ-DIST-04 | P1 | Semantic versioning and release notes per release | DOC | TODO |

---

## Explicitly out of scope (for now)

- Mega CD + 32X combo (32X CD games). Revisit only if resources allow after 1.0.
- Physical cartridge adapter support (the Pocket's cart slot can't take Genesis carts without
  a custom adapter).
- Link cable / multiplayer between Pockets.
- HLE BIOS replacement (REQ-S32X-09).
- Public distribution is optional (see §14). A personal-use build with embedded BIOS is an
  acceptable final outcome.
