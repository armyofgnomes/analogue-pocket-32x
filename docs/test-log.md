# Hardware test log

One row per test run. Label Pockets A/B/C… and keep the labels stable.

| Date | Build | Pocket | Firmware | Handheld/Dock | Result |
|---|---|---|---|---|---|
| 2026-09-28 | e3dc5e7 | ? | ? | ? | Template core packaged with `package.py` using the original shortname `Core Template`: "Load error in 'core'. Error in core setup." Cause: `Cores/` folder name didn't match `core.json` |
| 2026-09-28 | 4d07269 | ? | ? | ? | **Pass.** Template core loads from "Example Platform" and shows the gray screen. Quartus 25.1std bitstream and packaging confirmed working |
