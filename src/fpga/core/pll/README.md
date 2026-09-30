# Core PLL (generated)

Generated with Quartus Prime Lite 25.1std's `ip-generate` (Altera IP; see each file's header for
its license). Don't edit by hand: regenerate with the commands below. `../pll_core.v` wraps them.

- `pll_core_reconf.v`: `altera_pll`, reconfigurable, normal mode (global-clock feedback, as the
  fitter chose for the earlier non-reconfigurable PLL; direct mode is rejected by the 25.1 fitter),
  74.25 MHz in; outputs 53.693181,
  107.386363, 26.84659 and 26.84659 MHz (+90 degrees).
- `pll_core_cfg.v`, `altera_pll_reconfig_top.v`, `altera_pll_reconfig_core.v`,
  `altera_std_synchronizer.v`: `altera_pll_reconfig`, the reconfiguration controller.

```
IPG=~/altera_lite/25.1std/quartus/sopc_builder/bin/ip-generate
SYS="--system-info=DEVICE_FAMILY=Cyclone V --system-info=DEVICE=5CEBA4F23C8 --system-info=DEVICE_SPEEDGRADE=8"
$IPG --output-directory=out --file-set=QUARTUS_SYNTH "$SYS" --component-name=altera_pll \
  --output-name=pll_core_reconf \
  --component-parameter=gui_device_speed_grade=8 --component-parameter=gui_pll_mode="Fractional-N PLL" \
  --component-parameter=gui_reference_clock_frequency=74.25 --component-parameter=gui_operation_mode=normal \
  --component-parameter=gui_feedback_clock="Global Clock" \
  --component-parameter=gui_number_of_clocks=4 --component-parameter=gui_use_locked=true \
  --component-parameter=gui_en_reconf=true \
  --component-parameter=gui_output_clock_frequency0=53.693181 --component-parameter=gui_output_clock_frequency1=107.386363 \
  --component-parameter=gui_output_clock_frequency2=26.84659 --component-parameter=gui_output_clock_frequency3=26.84659 \
  --component-parameter=gui_ps_units3=degrees --component-parameter=gui_phase_shift_deg3=90
$IPG --output-directory=cfg --file-set=QUARTUS_SYNTH "$SYS" --component-name=altera_pll_reconfig \
  --output-name=pll_core_cfg
```

The same PLL command with the PAL frequencies (53.203424, 106.406848, 26.601712, 26.601712 MHz)
produces identical settings except the fractional division (`pll_fractional_division`):
2910637732 (NTSC) vs. 2570680340 (PAL), VCO 644.318 vs. 638.441 MHz (REQ-ARCH-06).
