# Sega CD 32X games: fit experiment

Branch `explore/segacd32x`, 2026-09-30. **Verdict: not feasible on the Pocket's FPGA.** The Sega
CD hardware alone needs more logic than the core has left, and more block RAM than the device
has free.

There are six games that need both add-ons: Corpse Killer, Fahrenheit, Night Trap, Slam City with
Scottie Pippen, Supreme Warrior and Surgical Strike. All are full-motion-video titles. Running
them means adding the whole Sega CD to this core:
- a second 68000 (the sub-CPU);
- the graphics ASIC (rotation and scaling);
- the CD controller (CDC) and drive interface (CDD);
- the PCM sound chip and CD audio;
- about 800 KB of RAM;
- CD image streaming from the SD card.

## Measurement

`run.sh` compiles MiSTer MegaCD's Sega CD block (`MCD`: sub-68000, ASIC, CDC, PCM, CD-DA) alone
for the Pocket's FPGA (5CEBA4F23C8, Quartus 25.1std, our core's area-first settings, every port on
a virtual pin, cheats off). It uses `MegaCD_MiSTer` at `a3a3da8`, fetched into `build/upstream`
and not committed.

| Resource | Sega CD block | Our core today | Device |
|---|---|---|---|
| Logic (synthesis estimate) | **5,079 ALMs** | 17,016 | 18,480 |
| Registers | 4,961 | ~22,100 | |
| Block RAM | **2,833,056 bits** | 1,551,762 bits | 3,153,920 bits |

The block RAM breaks down as Word RAM 2 × 1 Mbit, PCM RAM 512 Kbit, CD buffer 128 Kbit, CD-audio
FIFO 40 Kbit, and the sub-68000's microcode ROMs 40 Kbit. **The block doesn't fit the device even
on its own:** the fitter fails with "Can't place all RAM cells".

## What that means

- **Logic:** 17,016 + 5,079 = ~22,100 ALMs, about 120 % of the device, for the Sega CD block alone.
- **Missing pieces, all extra logic:**
  - the CD drive emulation (CDD), which MiSTer runs as ARM software;
  - streaming the disc image over the APF bridge;
  - a PSRAM controller to hold the Word RAM and PCM RAM;
  - the bus glue between the 32X, the Sega CD and the Genesis.
- **Memory:** the Word RAM and PCM RAM must move to the Pocket's unused PSRAM (2 × 16 MB), since
  block RAM can't hold them. Memory is solvable; logic isn't.
- **Nothing large enough to trim:** the core is at 92 %, the Memories study already showed how
  little is left, and none of the 32X or Genesis blocks can be dropped.

For comparison, the Pocket's Sega CD core (openfpga-megacd) fits because it's Genesis + Sega CD
without the 32X (roughly 6,700 + 5,000 ALMs plus drive emulation).

## Files

- `mcd_fit_top.sv`: wrapper with every `MCD` port on a virtual pin.
- `run.sh`: fetches MegaCD_MiSTer, applies the same JTAG-hub removal as our patch 0001, compiles
  and prints the results (~10 minutes). It reports synthesis' estimate; the fit itself fails on
  RAM, which is part of the result.
