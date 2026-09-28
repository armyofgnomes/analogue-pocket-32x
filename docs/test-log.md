# Hardware test log

One row per test run. Label Pockets A/B/C… and keep the labels stable.

| Date | Build | Pocket | Firmware | Handheld/Dock | Result |
|---|---|---|---|---|---|
| 2026-09-28 | e3dc5e7 | ? | ? | ? | Template core packaged with `package.py` using the original shortname `Core Template`: "Load error in 'core'. Error in core setup." Cause: `Cores/` folder name didn't match `core.json` |
| 2026-09-28 | 4d07269 | ? | ? | ? | **Pass.** Template core loads from "Example Platform" and shows the gray screen. Quartus 25.1std bitstream and packaging confirmed working |
| 2026-09-28 | c766128 | ? | ? | ? | **Pass (M2).** Genesis core v0.1.0: US game boots with SEGA logo, title, music, SFX, and working controls. A 256-px (H32) game displays correctly. A Japan-only ROM boots. Switching games works. M1 color-bar build (3018b8b) not needed as a fallback |
