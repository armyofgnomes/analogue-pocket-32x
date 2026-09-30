# Memories (save states) exploration (REQ-APF-08)

Branch `explore/memories`, 2026-09-30. **Verdict: not feasible for 32X games on the Pocket's
FPGA; parked.** A Genesis-only variant bitstream is the one plausible path (see the end).

## What APF asks for

`core_bridge_cmd.v` implements the host side. For a save, the host sets `savestate_start`; the
core acknowledges, stays busy while it writes its whole state into a buffer the host can read
over the bridge (`savestate_addr`, `savestate_size`), then reports ok. For a load, the host writes
a state into the buffer (up to `savestate_maxloadsize`) and sets `savestate_load`; the core
restores it. Sleep/wake uses the same mechanism.

The buffer could live in the ~60 MB of unused SDRAM, and memories can be copied through extra
ports, so neither the protocol nor the memory contents are the problem.

## State to capture

Memory contents, about 700 KB:

| Part | Size |
|---|---|
| 32X SDRAM | 256 KB |
| 32X framebuffers (SRAM) | 256 KB |
| 68K RAM | 64 KB |
| Genesis VRAM | 64 KB |
| Cart save RAM | 32 KB |
| Z80 RAM, SH-2 caches, palettes, CRAM/VSRAM, 68K BIOS RAM | ~16 KB |

Registers are the problem. S32X_MiSTer has no save-state support in any module (no save-state
bus in `gen`, fx68k, T80, the VDP, jt12 or the SH-2s), so every module would need a path to read
out and restore its internal state. Flip-flops per block, from the current fit (v0.4.2 design):

| Block | Registers |
|---|---|
| SH-2 master / slave (core 1,235 each, DIVU ~645, DMAC ~425, MULT ~425, cache tags ~500, other peripherals) | 4,164 / 4,199 |
| YM2612 (`jt12`) | 2,903 |
| Genesis audio resampler (`jt12_genmix`, filter history: could be skipped) | 2,003 |
| Genesis VDP | 1,884 |
| 68000 (`fx68k`) | 1,499 |
| 32X interface + VDP | ~1,100 |
| Z80 (`T80`) | 410 |

Estimated state that must be captured:
- **As built:** ~16,000 bits (everything except audio filter history and pure pipeline copies).
- **Architectural minimum:** ~8,800 bits. This needs all CPUs paused at clean instruction
  boundaries and the SH-2 caches flushed. It means GPRs and control registers, peripheral
  registers, VDP/FM/PSG register files, operator phase/envelope state, and 32X interface/PWM
  state. The pausing itself is extra control logic, and it's risky: some games use the SH-2
  cache as RAM.

## Cost per bit, measured

`cost/run.sh` compiles a synthetic block of 2,048 register bits with typical update logic three
ways (Quartus 25.1std, 5CEBA4F23C8, area-first):

| Variant | ALMs | Extra per bit |
|---|---|---|
| Plain | 6,229 | |
| Save-state bus (64-bit addressed readout + restore write) | 7,778 | **0.76** |
| Scan chain (serial shift in/out, no readout mux) | 7,582 | **0.66** |

Real modules with simpler update logic might come in somewhat lower. Use ~0.5–0.75 ALM per
bit.

## What that means

| Scope | Bits | Estimated ALMs | Available |
|---|---|---|---|
| Genesis + 32X, as built | ~16,000 | 8,000–12,000 | ~1,460 (synthesis estimate 17,016 of 18,480) |
| Genesis + 32X, architectural minimum | ~8,800 | 4,400–6,600 | ~1,460 |
| Genesis part only, in this bitstream | ~7,300 | 3,600–5,500 | ~1,460 |

Even the leanest version is 3–4× over what's left, before the control logic, the memory copy
engine, the bridge buffer port and timing closure at >95 % utilization. There's no partial
reconfiguration to swap logic in, and no area left to reclaim on that scale without removing
features or accuracy.

## The one plausible path: a Genesis-only variant bitstream

APF cores can ship more than one bitstream (`core.json` `cores`, selected per data slot or
variant). Without the 32X, about 9,800 ALMs are free. That's enough for Genesis save states
(~3,600–5,500 ALMs), so Memories could work for Genesis games only, from a second bitstream.

Costs and caveats:
- **Porting:** it's a large port. MiSTer's standalone Genesis core added save states to its
  modules, but S32X_MiSTer's copies of those modules don't have them. We'd bring the
  save-state-capable versions of fx68k, T80, the VDP and jt12 into the Genesis-only build
  (licensing to check), plus our own APF glue.
- **Duplication:** it overlaps with the existing openFPGA-Genesis core, whose Memories support
  would need checking first.
- **Maintenance:** two bitstreams to build, time and test.
- **Scope:** it doesn't help 32X games, which are this core's point.

## Files

- `cost/ss_cost.sv`, `cost/run.sh`: the synthetic cost experiment (`./run.sh`; ~5 minutes).
