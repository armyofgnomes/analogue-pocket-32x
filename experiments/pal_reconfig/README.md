# PAL MCLK by PLL reconfiguration (REQ-ARCH-06): parked

Tried 2026-09-30 after the reconfigurable core PLL (`src/fpga/core/pll/`, commit f4811b3,
hardware-verified NTSC-only).

**Idea.** PAL (53.203424 MHz) and NTSC (53.693181 MHz) MCLK differ only in the PLL's fractional
division: `ip-generate` gives identical settings except K = 2570680340 (PAL) vs 2910637732
(NTSC), VCO 638.441 vs 644.318 MHz. All outputs scale together, so every clock relationship
(and the timing constraints) stay the same. `pll_core_pal.v` drives Altera's reconfiguration
controller (`pll_core_cfg`) with MODE = 0, DSM (register 7) = K, START (2), holding the console
in reset (`busy`) until the PLL has relocked. `core_top.v` connected `s32x_system`'s `pal` to it
and `busy` (synchronized) into the console reset.

**Why parked.** Once driven, Altera's controller is 561 ALMs (it's generic: every counter, phase
shift, bandwidth). The design needed 18,263 / 18,480 ALMs (99 %) and missed setup by 0.033 ns.
Idle, it prunes to ~33 ALMs.

**Options if revisited:**
- A minimal DPRIO writer for just the fractional-division registers, derived from
  `altera_pll_reconfig_core.v` (which DPRIO addresses/data a DSM write produces) and proven in
  simulation. Probably tens of ALMs; the risk is the undocumented low-level protocol.
- A second, fixed PAL PLL (3 PLLs are free) and clock-control blocks switching the four clocks
  while the console is held in reset. No logic cost; needs care with clock-control legality and
  exclusive clock groups in the SDC.

`sim/` is a bench for `pll_core_pal.v` with Altera's PLL model (`altera_lnsim`, `cyclonev`):
link it as `sim/pll_reconf` and run `sim/run.sh pll_reconf`. The PLL model is very slow; it
hadn't reached a result in ~20 minutes and wasn't finished.
