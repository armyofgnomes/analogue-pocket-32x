# Hardware test log

One row per test run. Label Pockets A/B/C… and keep the labels stable.

| Date | Build | Pocket | Firmware | Handheld/Dock | Result |
|---|---|---|---|---|---|
| 2026-09-28 | e3dc5e7 | ? | ? | ? | Template core packaged with `package.py` using the original shortname `Core Template`: "Load error in 'core'. Error in core setup." Cause: `Cores/` folder name didn't match `core.json` |
| 2026-09-28 | 4d07269 | ? | ? | ? | **Pass.** Template core loads from "Example Platform" and shows the gray screen. Quartus 25.1std bitstream and packaging confirmed working |
| 2026-09-28 | c766128 | ? | ? | ? | **Pass (M2).** Genesis core v0.1.0: US game boots with SEGA logo, title, music, SFX, and working controls. A 256-px (H32) game displays correctly. A Japan-only ROM boots. Switching games works. M1 color-bar build (3018b8b) not needed as a fallback |
| 2026-09-28 | e12263b | ? | ? | ? | **Fail (memtest).** SRAM bar red immediately; SDRAM bar stuck yellow (no pass completed). SDRAM cause found in simulation of the real `sdram.sv` with an SDRAM model: patch 0002's tRCD/CL of 3 made `STATE_READY` = 8, which wrapped the 3-bit state counter to IDLE, turning some requests into refreshes (lost write, `busy` cleared). Fixed by widening the counter (also affects the Genesis build's ROM reads). SRAM cause unknown; next build sweeps SRAM access timing |
| 2026-09-28 | 13d4764 | ? | ? | ? | **Memtest sweep.** SDRAM bar green and growing: the 32X SDRAM port works (state-counter fix confirmed). SRAM: only setting 0 (28 ns read / 19 ns WE) fails; 37/28 ns and slower pass. Speed-limited, not wiring. Next: SRAM registers in I/O cells, and a finer sweep that separates read and write limits |
