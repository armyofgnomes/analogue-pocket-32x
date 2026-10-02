# M4 debug notes (32X games on hardware)

Working notes for getting 32X games running. Newest first. Written so a new session can pick up
where the last one stopped.

## Status (2026-09-30)

M4 is done and most tested 32X games play (see `docs/test-log.md`). This file is now the
debugging history: each "Found" section is a solved problem, kept for the method and the tools.
The simulation toolkit is described at the end.

No known open game issues: After Burner Complete's PWM weapon sounds (below) are fixed and
verified on hardware (66bccc4).

## Found (2026-09-30): After Burner Complete's PWM sounds need the SH-2 UBC registers

The PWM sample routine at SH-2 0x06000390 (probably the PWM timer interrupt) keeps its ring-buffer
index in 0xFFFFFF40: the User Break Controller's BARA register, used as spare RAM. Each call it
reads the index, loads the L/R sample pair from the ring at 0x0603F100, adds 4 and writes the
index back, then writes the pair to the PWM with one 32-bit store (`mov.l r0,@(52,gbr)`, GBR =
0x20004000, so 0x20004034 = LPWR/RPWR). Patch 0005 had disabled both SH-2s' UBC (`UBC_DISABLE`)
to save ~245 ALMs, assuming only debuggers use it; upstream's UBC is nothing but its registers
(the break interrupt is tied off). With it disabled the index never advanced, so the PWM replayed
one sample: silence. Patch 0005 is removed.

How it was found: a word-by-word SH-2 disassembly of the game's SH-2 code (Capstone 6 in a
scratch venv; `mov.l @(disp,pc)` literals resolved to their values), searching for PWM register
stores. The earlier static look (kept below) missed them because it looked for absolute
addresses, not GBR-relative stores, and its "28 DMA base loads" were mostly the byte value
0x80 used as a marker: the game doesn't feed PWM by DMA.

Lesson: SH-2 on-chip registers that "only debuggers use" can be scratch RAM for a game.

### Earlier notes (superseded)

Postponed: After Burner Complete lacks its cannon and missile sounds

Reported on 66c93b5: music and some effects play, the cannon and missile sounds don't. Not a
known upstream issue as far as a search shows; our upstream pin (b438679, 2026-06-22) is upstream's
latest and includes its 2022 PWM fix. Whether it worked on earlier builds is unknown.

Static look at the ROM (SH-2 code at cart 0x53000, 0x1A000 bytes, copied to 0x06000000):
- The SH-2 code sets PWMCR and CYCR once (GBR-relative writes at SDRAM 0x0600031A/0x0600031E) but
  never writes the PWM pulse-width registers (LPWR/RPWR/MONO) itself, and the 68K never touches PWM.
- It loads the DMA channel base (`mov #-128,Rn`, 0xFFFFFF80) 28 times.
So every PWM sample goes through the SH-2 DMAC (probably paced by the PWM timer's DREQ,
`PWMCR.RTP`). The effects that work are likely the Genesis FM/PSG, or DMA transfers that happen
to work.

Suspects, in order: DMA transfer modes that reach paths we changed. 16-byte (burst) DMA reads
through `s32x_sdram_front.sv`'s line buffer, DMA writes through its queue, and DMA reads from the
cartridge after patch 0009 (ROM_WAIT sampled on the rising edge). Also possible: an upstream DMAC or
DREQ issue that MiSTer shares.

Next step when resumed: disassemble the DMA setup around the 28 base loads to get the modes
(TS, AM, DS/DL, source area); then either a `sim/sdram_front`-style bench for that DMA pattern,
or a full-system run of the attract mode (which fires weapons) with the DMA traced. An A/B test on
hardware against 8069503 (before patch 0009) would also separate the cart-path suspect.

## Found (2026-09-29): NBA Jam TE hung at start (bars) because cart quirks weren't ported

`s32x_system.sv` tied the cart module's `eeprom_map`, `noram_quirk`, `realtec_map`, `sf_map`, the
Genesis `FMBUSY_QUIRK` and the port-1 write enable (`schan_quirk`) to 0. Upstream `S32X.sv` sets
them from the header's product code at 0x180 (and the Realtec ID at 0x7E100). NBA Jam TE 32X
(`T-8104B`) needs `eeprom_map = 4'b1011` for its save EEPROM and hangs without it. The table is
now ported (minus lightgun timing, Pier Solar and SVP). It also fixes the same class of problem
for the Genesis carts in the table (EA/Acclaim/Sega EEPROM games, Puggsy, Hellfire, ...).
The EEPROM logic this keeps costs about 420 ALMs (17,023, 92%).

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
adapter (8d6cbb2) served one 16-bit word per sdram.sv request (about 9 clk_ram each), so most
burst beats went by while the port was still busy: in the trace only 3 of the 8 addresses of the
first line fill were even requested, and the other beats latched stale data. MiSTer's default
build doesn't hit this because its `ddram.sv` has a 16-byte line cache: a miss holds WAIT until
the whole line is fetched and the remaining beats are served from the cache.

A first fix (a986ceb: re-issue when the address changes while CS/RD are held) did not help,
because the beats don't wait; the full-system run showed the identical failure.

Fix: `src/fpga/core/s32x_sdram_front.sv` in front of port 0, doing what `ddram.sv` does: a 16-byte
read line buffer (a miss holds WAIT while all 8 words are fetched, then the burst is served from
the buffer), and an 8-entry write queue (write beats are queued, WAIT only when full; a write that
hits the buffer updates it; the queue drains before line fills). `sim/sdram_front` drives it the
way the BSC does (bursts, 1- and 2-beat reads, 1- and 2-beat writes waiting in TRAS, random port-1
traffic) with the real sdram.sv and chip model: about 72k read beats and 12k write beats per seed
match a shadow memory on three seeds. The first version had no backpressure and lost writes when
back-to-back write beats outran the queue; that is why writes now wait on a full queue.
Full-system check (Kolibri, `FAST_BIOS`): both SH-2s run the game at 127 ms (master 0x06000AEE,
slave 0x06000516, then code in the cart), and all 335 full-width code reads the slave made from the
32X SDRAM match the ROM. Pocket build 69fe0ef. Performance: the first version fetched a line as 8
single-word SDRAM reads (about 72 MCLK per miss). Patch 0008 adds an sdram.sv line read (one row
activation, 8 back-to-back column reads) and the front end maps a line to 8 columns of one row:
misses now average about 14 MCLK in `sim/sdram_front` (worst about 82 MCLK, behind a full write
queue). A real 32X line fill is roughly 12 SH-2 cycles (about 28 MCLK).

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
  against ours (`fb_sram.sv` + SRAM model) on random traffic; after the 0da7aa7 fixes they match
  exactly for 30 frames in all modes.

## Hardware-side fixes made this milestone

- 0da7aa7: `fb_sram` display reads before draw writes; patch 0006 (fill waits for the VDP FIFO,
  FEN covers a pending fill).
- 297165b / c7fecaa: clk_sys to clk_ram requests sampled only on the mid clk_ram edge (fb_sram,
  and `sdram.sv` via patch 0007) with matching SDC multicycle hold.
- f0ad693: SDRAM pin registers in the I/O cells (MiSTer's `sys.tcl` settings). c7fecaa without
  them was black for every game, Genesis included.

## Simulation toolkit (sim/system)

- `ACC=1`: full visibility (needed for `+shsnap`, core traces); about 1.3 ms simulated per minute.
  Without it, about 2.4 ms per minute.
- `FAST_BIOS=1`: sim-only master BIOS patches. Skips the SDRAM fill/verify test (branch 0x1C0 to
  0x20C) and replaces the cartridge checksum loop with the sum computed from the ROM file (matches
  the header checksum; Kolibri 96CE, Doom D746). Saves about a second of simulated time.
- `WORK=<abs dir>`: separate run directory, so several simulations can run at once. The
  submodule patching and compile step takes a lock shared with `tools/build.sh`, so runs and
  builds started together can't re-patch the submodule under each other.
- `BIOS_LOAD=1`: the BIOS memories start empty and the bench loads them through the core's load
  port (patch 0011), as the Pocket does; by default they're preloaded from `.mif` (`BIOS_MIF`).
  Either way the bench writes the BIOS through the port, so both variants have the same timing.
- Length: `+frames=N` (default 3, about 60 ms: pass more for anything past the BIOS boot) or
  `+stop_ms=N`.
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
- More options: `+pad6` (6-button pad on port 1), `+joy1=<hex>` (buttons held, gen JOY bit
  order), `+m68k_start/+m68k_end` (68K bus cycles), `+sig_len=N` (BIOS read signature length,
  default 100000). The progress line also counts save RAM and EEPROM accesses, PWM output
  changes and the master UBC's BARAH changes.
- Frames: `frame_N.ppm` in the run directory (320x224 header, 223 lines of data; pad when
  converting).
- Pad test program: `sim/system/roms/make_padtest.py` (see `docs/hardware-testing.md`).
- Regression: `sim/regress/run.sh` runs the pad test and Kolibri's BIOS boot against
  `sim/regress/golden.txt` (about 20 minutes).
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
