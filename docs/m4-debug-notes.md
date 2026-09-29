# M4 debug notes (32X games on hardware)

Working notes for getting 32X games running. Newest first. Written so a new session can pick up
where the last one stopped.

## Status (2026-09-29, afternoon)

Latest Pocket build: **6a7d9cb** (SDRAM pins in I/O cells). Hardware results for it:

| Game | Result |
|---|---|
| Sonic (Genesis) | Boots, sound, playable |
| Doom | Boots past SEGA logo; 32X layer corrupted (two half-width title copies, checkerboard menu, flat blue/purple play view) |
| Kolibri | Black screen |
| Spider-Man | Flashing red bar at the bottom |
| Chaotix | Black screen, buzzing noise |
| Pitfall | SEGA logo, then black |
| Primal Rage | SEGA logo offset to the right, then black |
| NBA Jam TE, Virtua Fighter | Black screen |

No Pocket build is pending. The next build comes after the cause below is found and fixed.

## Found (2026-09-29): 32-bit SH-2 accesses to the 32X SDRAM returned the first half twice

The slave bus log (`+slog_ms`) showed the slave reading its header correctly (VBR 0x06000000,
entry 0x06000120), writing "S_OK" and jumping to 0x06000120. Then its reads from the 32X SDRAM
came back with the same 16-bit half twice (`0x06000124 -> d116d116`, `0x06000184 -> 534c534c`),
a literal load sent it to 0x4F224F22, and the exception vector (0x06000010 read as 0x00002010) put
it at 0x2010/0x2014.

Cause (confirmed with an SDRAM port trace): the SH-2 bus controller runs area 3 in SDRAM mode
(`BSC.sv` states TRAS/TRCAS/TRD/TWCAS). It honors WAIT only on the first beat of a read (TRCAS);
the other beats of a burst (a 16-byte cache-line fill is 8 beats, starting at the critical word
and wrapping) follow one per SH-2 cycle. Writes honor WAIT once per beat (TRAS). Our port-0
adapter (953f26c) served one 16-bit word per sdram.sv request (about 9 clk_ram each), so most
burst beats went by while the port was still busy: in the trace only 3 of the 8 addresses of the
first line fill were even requested, and the other beats latched stale data. MiSTer's default
build doesn't hit this because its `ddram.sv` has a 16-byte line cache: a miss holds WAIT until
the whole line is fetched and the remaining beats are served from the cache.

A first fix (1d1c55a: re-issue when the address changes while CS/RD are held) did not help,
because the beats don't wait; the full-system run showed the identical failure.

Fix: `src/fpga/core/s32x_sdram_front.sv` in front of port 0, doing what `ddram.sv` does: a 16-byte
read line buffer (a miss holds WAIT while all 8 words are fetched, then the burst is served from
the buffer), and an 8-entry write queue (write beats are queued, WAIT only when full; a write that
hits the buffer updates it; the queue drains before line fills). `sim/sdram_front` drives it the
way the BSC does (bursts, 1- and 2-beat reads, 1- and 2-beat writes waiting in TRAS, random port-1
traffic) with the real sdram.sv and chip model: about 72k read beats and 12k write beats per seed
match a shadow memory on three seeds. The first version had no backpressure and lost writes when
back-to-back write beats outran the queue; that is why writes now wait on a full queue.
Full-system verification and the Pocket build are next. Performance note: a line miss costs 8
single-word SDRAM reads (about 1.3 us); an sdram.sv burst mode would cut that a lot.

The first build with this fix missed setup by 0.38 ns on SDRAM port 1 (68K bus arbiter through the
cart mapper into `sdram.sv`'s request registers, half a clk_sys cycle). Patch 0007 now copies every
port's inputs into plain registers on the mid edge and recognizes requests one edge later; those
paths have +1.36 ns. The tightest path is now the mid-edge detector (falling-edge `ram_tog_n` into
fb_sram's pending flags, a quarter cycle) at about +0.05-0.14 ns.

## Earlier lead (resolved above): Kolibri's slave SH-2 jumps to garbage after the BIOS hands off

With the simulator fixed (see below), `sim/system` reproduces a failure for Kolibri:

- The master and slave BIOS run correctly. The master SDRAM test, SDRAM clear, cartridge checksum
  and the 128 KB code copy (cart 0x9000 to SDRAM 0x06000000) all work. The master's 60 logged
  cartridge reads during the copy all match the ROM file.
- The master hands off to the game at about 123.5 ms and runs it (PC 0x06000994).
- The slave waits in its BIOS (0x1BE-0x1D0, polling COMM0 at 0x20004020 for "M_OK"), then at
  0x1AE reads the cart header: `r13` = 0x220003E4, VBR from `@(8,r13)` (header 0x3EC, should be
  0x06000000), entry from `@r13` (header 0x3E4, should be 0x06000120), and `jmp @r8`.
- At 124.0 ms the slave's PC is **0x00002014** instead of 0x06000120. So either the header reads
  return wrong data, or it jumps correctly and then takes an exception through a bad VBR.
- Suspect: contention on the shared cartridge path. The 68K is executing from the cart window
  (0x88xxxx) at the same time; both go through the 32X ROM arbiter in `IF.sv` (`ROM_ST` states,
  `ROM_WAIT_SYNC` sampled on the clk_sys falling edge) and SDRAM port 1. Not confirmed yet.
- Doom's sim (normal BIOS) reaches the SEGA logo animation at about 440 ms, but its SH-2 bus
  counters (CS0 cycles, 32X SDRAM accesses) froze at about 250 ms: possibly the same problem.

### Next step

Run Kolibri with the filtered slave bus log (bench change already in `tb_system.sv`, not yet run):

```
cd /home/armyofgnomes/Projects/32x-core && echo "-1 -1 -1 -1" > build/sim/system/trace_cfg.txt && \
FAST_BIOS=1 CHECKPOINT_AT=120 ACC=1 timeout 10800 sim/system/run.sh \
  "+rom=/media/armyofgnomes/128GB/Assets/32x/common/Kolibri (USA, Europe).32x" +frames=200 +shsnap \
  +trace_cfg +slog_ms=123.0 +stop_ms=124.2 -suppress 8315,3015 2>&1 \
  | grep -E "SLOG|SH2 M|Error" | awk '{$1=$1;print}' > build/sim/kolibri_slog3.txt
```

About 1.5 hours. Then look at the `SLOG` lines after the slave leaves its delay loop: the reads
of 0x220003E4/0x220003EC (data received vs. ROM header), the jump, and what follows. If a cart
read is wrong, trace `IF.sv`'s ROM arbiter and SDRAM port 1 around it (bus window
`+win_start/+win_end`, or `trace_cfg.txt` on a restored checkpoint).

## Simulator fix: the 56.8 ms "trap" was a Questa preprocessing difference

Upstream `rtl/SH/core/SH_core.sv` has a bare `` `elsif `` (no macro name) guarding
`assign REGS_RAN = ID_DECI.RA.N;`. Quartus treats it as `` `else ``. Questa takes the next token
(`assign`) as the macro name and drops the line, so the register file's read address A was
undriven in simulation. Every SH-2 `Rn` operand on that port read the wrong register, and the
master crashed at 56.8 ms (illegal instruction after writing its BIOS tables to wrong addresses).
`sim/system/gen_files.py` now applies a sim-only fixup (`` `elsif `` to `` `else ``). Hardware was
never affected (Doom's SH-2 code runs on the Pocket).

Conclusions drawn before this fix about SH-2 behavior in `sim/system` (for example that the
MiSTer-memory reference also trapped) are void.

## Things ruled out

- BIOS images: `tools/gen_bios_mif.py` output is word-for-word identical to upstream's `.mif`.
- Clocks: our PLL matches MiSTer's (53.693175 / 107.38635 MHz, phase 0).
- Top-level wiring against MiSTer's `S32X.sv`: gen, 32X, cart, `ROM_WAIT`, `GEN_DTACK_N`,
  `MEM_RDY`, `rom_sz`, region detection all match.
- The slave reads the SH-2-side adapter register 0x20004000 correctly (0x0200: ADEN=1,
  CART_N=0) and takes the cartridge path, not the CD path.
- The framebuffer path: `sim/vdp` runs upstream's VDP with MiSTer's block RAM framebuffers
  against ours (`fb_sram.sv` + SRAM model) on random traffic; after the ffc0a40 fixes they match
  exactly for 30 frames in all modes.

## Hardware-side fixes made this milestone

- ffc0a40: `fb_sram` display reads before draw writes; patch 0006 (fill waits for the VDP FIFO,
  FEN covers a pending fill).
- 721869c / bc7ce5c: clk_sys to clk_ram requests sampled only on the mid clk_ram edge (fb_sram,
  and `sdram.sv` via patch 0007) with matching SDC multicycle hold.
- 6a7d9cb: SDRAM pin registers in the I/O cells (MiSTer's `sys.tcl` settings). bc7ce5c without
  them was black for every game, Genesis included.

## Simulation toolkit (sim/system)

- `ACC=1`: full visibility (needed for `+shsnap`, core traces); about 1.3 ms simulated per minute.
  Without it, about 2.4 ms per minute.
- `FAST_BIOS=1`: sim-only master BIOS patches. Skips the SDRAM fill/verify test (branch 0x1C0 to
  0x20C) and replaces the cartridge checksum loop with the sum computed from the ROM file (matches
  the header checksum; Kolibri 96CE, Doom D746). Saves about a second of simulated time.
- `WORK=<dir>`: separate run directory, so two simulations can run at once (Doom runs in
  `build/sim/doom`).
- `CHECKPOINT_AT=<ms>` then `RESTORE=1`: resume from a checkpoint (same compiled design only).
  Plusargs are fixed at checkpoint time; with `+trace_cfg`, windows can be changed at run time in
  `trace_cfg.txt`: `win_start win_end core_start core_end [rf_start rf_end [mlog slog]]` in ns,
  -1 = off. Without `+trace_cfg` the file is ignored (an absent file makes `$fopen` warn every
  100 us).
- Traces: `+shsnap` (SH-2 PCs every ms, master PC ring dumped at the 0x13C trap), `+win_start/
  +win_end` (SH-2 bus cycles), `+core_start/+core_end` (master core fetch/bus per clock),
  `+rf_start/+rf_end` (master register-file writes), `+cart_log_ms` (SH-2 cart reads, first 60),
  `+mlog_ms/+slog_ms` (every bus access of the master/slave core; the slave log skips its BIOS
  delay-loop fetches at 0x1C0-0x1D7), R4000 lines (SH-2 reads of 0x20004000).
- Frames: `frame_N.ppm` in the run directory (320x224 header, 223 lines of data; pad when
  converting).
- Gotchas: don't wait on `pgrep -f <text>` from a shell whose own command line contains that text;
  wait on the `vsimk` PID instead. Only one simulation per run directory.

## Useful facts

- Master BIOS (2 KB): exception vectors 4/6/9-12 and 32+ go to 0x13C (`bra .`). SDRAM test
  0x1C0-0x20A, SDRAM clear 0x20C-0x21C, cart checksum 0x258-0x284, header copy 0x286-0x2A2,
  "M_OK" to COMM0 and jump at 0x2A4-0x2AE.
- Slave BIOS (1 KB): cart path 0x1AA-0x1BC (header at cart 0x3E4/0x3EC), CD path 0x1D8-0x1F2
  (entry from framebuffer 0x24000018), wait loop 0x1BE-0x1D0.
- Kolibri header: code at cart 0x9000, 128 KB to SDRAM 0x06000000, master entry 0x06000920,
  slave entry 0x06000120.
- Disassembly: Capstone in a scratch venv (`capstone.Cs(CS_ARCH_SH, CS_MODE_SH2 |
  CS_MODE_BIG_ENDIAN)`).
