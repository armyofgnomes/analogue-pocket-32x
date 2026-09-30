# 32X game test matrix (REQ-QA-03)

Status of the 32X library on this core, from hardware tests (`docs/test-log.md`). M5 ("games
playable") is complete when every game here has been tried and none has an open issue.

**Status:** **Plays** = tested on hardware, no known issue (version = the build it was last
confirmed on) · **Issue** = see note · **ROM here** = the owner has the ROM, not yet reported
individually · **Untested** = no ROM tried yet.

**Notes column:** features a game is known to use that are worth re-checking after related
changes. *SCI/WDT/UBC* = found by the on-chip register scan (2026-09-30; lower bound, SDRAM code
only). *Sensitive* = on the requirement's list of titles known to stress SH-2 timing, dual-CPU
sync, PWM or VDP modes.

The library list is from memory and may be incomplete (JP-only and unreleased titles especially);
check it against the MiSTer S32X "Game list.xlsx" (see `docs/references.md`) when convenient.

| Game | Status | Notes |
|---|---|---|
| 36 Great Holes Starring Fred Couples | Untested | |
| After Burner Complete | **Plays** (0.4.2) | PWM samples need the SH-2 UBC registers (fixed in 0.4.2). *UBC, SCI, Sensitive* |
| BC Racers | Untested | |
| Blackthorne | ROM here | |
| Brutal Unleashed: Above the Claw | ROM here | *SCI* |
| Cosmic Carnage / Cyber Brawl | ROM here | 6-button capable. *SCI* |
| Darxide (EU) | Untested | |
| Doom | **Plays** (0.4.1) | *Sensitive* |
| FIFA Soccer 96 | Untested | *Sensitive* |
| Knuckles' Chaotix | **Plays** (0.4.1) | Battery SRAM save verified. *Sensitive* |
| Kolibri | **Plays** (0.4.1) | Regression-set game. *Sensitive* |
| Metal Head | ROM here | *Sensitive* |
| Mortal Kombat II | **Plays** (0.3.0) | 6-button capable. *Sensitive* |
| Motocross Championship | Untested | |
| NBA Jam Tournament Edition | **Plays** (0.2.0) | EEPROM (cart quirk table); its storage moved to the save RAM in 0.3.0: recheck saving. *Sensitive* |
| NFL Quarterback Club | Untested | |
| Pitfall: The Mayan Adventure | **Plays** (0.2.0) | |
| Primal Rage | **Plays** (0.2.0) | H32 SEGA logo fixed in 0.2.0 |
| RBI Baseball '95 | Untested | |
| Shadow Squadron / Stellar Assault | ROM here | *Sensitive* |
| Space Harrier | ROM here | *Sensitive* |
| Spider-Man: Web of Fire | **Plays** (0.2.0) | Brief flashing bar at the bottom at start (seen on 0.1.x/0.2.0; recheck). *Sensitive* |
| Star Trek: Starfleet Academy | Untested | |
| Star Wars Arcade | ROM here | *WDT, Sensitive* |
| T-Mek | Untested | |
| Tempo | ROM here | Uses UBC registers too: recheck on 0.4.2. *UBC, Sensitive* |
| Toughman Contest | Untested | |
| Virtua Fighter | **Plays** (0.2.0) | *Sensitive* |
| Virtua Racing Deluxe | ROM here | *SCI, Sensitive* |
| World Series Baseball Starring Deion Sanders | Untested | |
| WWF Raw | ROM here | |
| WWF WrestleMania: The Arcade Game | ROM here | *WDT* |
| Zaxxon's Motherbase 2000 | Untested | |
| X-Men (prototype) | ROM here | Unreleased |

"Plays" versions are the builds where the owner last reported the game; the regression set
(`docs/hardware-testing.md`) re-checks a few of them every round.
