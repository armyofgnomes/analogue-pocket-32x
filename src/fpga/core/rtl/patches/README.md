# Local patches to S32X_MiSTer

`src/fpga/core/rtl/S32X_MiSTer` is a git submodule of https://github.com/MiSTer-devel/S32X_MiSTer
pinned to a specific commit (see `git submodule status`). We never commit changes inside it.
Instead, each local modification is a patch here, applied in name order by
`tools/prepare_upstream.sh`. Quartus runs that script automatically before every compile
(`core/pre_flow.tcl`).

| Patch | Why |
|---|---|
| `0001-bram-no-runtime-mod.patch` | Turn off `ENABLE_RUNTIME_MOD` in `bram.vhd`. That MiSTer debug aid pulls a JTAG hub into the design (~58 ALMs, REQ-ARCH-04) |
| `0002-sdram-pocket-timing.patch` | `sdram.sv`: tRCD 3 cycles and CAS latency 3 at 107 MHz for the Pocket's SDRAM (the values openFPGA-Genesis uses on hardware) |
| `0003-bios-from-generated-mif.patch` | `MDROM.v`/`SHROM.v` load `core/bios_mif/*.mif`, generated from the gitignored `bios/` by `tools/gen_bios_mif.py`, instead of upstream's bundled BIOS `.mif` files (REQ-LEGAL-03, REQ-APF-03a). Since patch 0011 the `.mif` preload is used by the simulations only (`BIOS_MIF`) |
| `0004-export-fb-swap.patch` | `VDP.sv`/`32X.sv`: export the VDP's framebuffer-swap bit `FS` as `FB_FS`, so `fb_sram.sv` knows which framebuffer is being drawn and can prioritize it (REQ-MEM-02) |
| `0006-vdp-fill-after-fifo.patch` | `VDP.sv`: an auto-fill starts only after queued FIFO framebuffer writes have drained, the FIFO doesn't drain during a fill, and `FEN` also covers a fill that is pending. With the SRAM framebuffers, a FIFO write that overlapped a fill start was cut short; upstream also drops such writes (found by `sim/vdp`, REQ-MEM-02) |
| `0007-sdram-mid-edge-sampling.patch` | `sdram.sv`: new `mid` input. Requests come from the clk_sys domain; on the clk_ram edge in mid clk_sys cycle (derived in `s32x_system.sv`) every port's address, data and strobes go straight into input registers, and requests are recognized from those on the next edge. The edge coinciding with clk_sys only re-sampled them under a zero-margin hold check (failed by 0.36 ns), and the long requester paths (68K bus arbiter through the cart mapper) didn't fit in half a cycle with the edge-detect logic in front (failed setup by 0.38 ns). `busy` also covers a sampled request not yet recognized, so it rises when it did before. `core_constraints.sdc` relaxes the hold check on the input registers (REQ-CLK-01) |
| `0008-sdram-line-read.patch` | `sdram.sv`: a port-0 read with `line0` set fetches 8 words with one row activation and 8 back-to-back column reads (auto-precharge on the last), returned on `dout0_line`. `s32x_sdram_front.sv` maps the 32X SDRAM so a 16-byte SH-2 cache line is 8 columns of one row, and fills its line buffer with one such read: a read miss drops from about 72 MCLK (8 single-word requests) to about 14 MCLK (REQ-MEM-03, REQ-S32X-08) |
| `0009-if-rom-wait-rising-edge.patch` | `IF.sv`: `ROM_WAIT` (busy of the cart ROM or cart SRAM port) is sampled on the rising clk_sys edge instead of the falling one. The path from the SH-2 bus address through the cart mapper's SRAM decode had half a cycle and failed setup (−0.43 ns) once the per-game cart quirks were wired up. The arbiter only waits for `ROM_WAIT` to rise and then fall, so this only shifts when the edges are seen (REQ-CLK-01) |
| `0010-cart-eeprom-external.patch` | `cart.sv`: the serial EEPROM's 1 KB storage (an internal `spram`) becomes ports (`EEPROM_A/D/WE/Q`), so `s32x_save_ram.sv` can hold it in the save RAM that the Pocket loads and saves (REQ-SAVE-01). Same one-clock read latency as the `spram` |
| `0011-bios-load-port.patch` | `MDROM.v`/`SHROM.v` become dual-port RAMs with a load port, plumbed out through `IF.sv` and `32X.sv` (`BIOS_WE/A/D`), so the Pocket loads the BIOS from the SD card and the bitstream carries none (REQ-APF-03b). The `.mif` preload remains only under the simulation define `BIOS_MIF`. Supersedes patch 0003's init-file path for synthesis |
| `0012-export-aden.patch` | `IF.sv`/`32X.sv`: export the adapter-enable bit `ADEN`, so `core_top.v` can show the missing-BIOS screen only when a game actually switches to 32X mode (Genesis games don't need the BIOS) |

Removed: `0005-sh2-ubc-disable.patch` turned off both SH-2s' User Break Controller (UBC) to save
~245 ALMs, assuming only debuggers use it. Upstream's UBC is just its registers (the break
interrupt is tied off), and After Burner Complete keeps its PWM sample-buffer index in the UBC's
BARA register at 0xFFFFFF40; with the UBC disabled the index never advanced and the PWM-played
sounds (cannon, missiles) were silent. Number 0005 stays unused.

To add a patch: start from a clean checkout (`git -C src/fpga/core/rtl/S32X_MiSTer checkout -- .`,
not the patched tree, or the diff will include the existing patches), edit files in the submodule, `git -C src/fpga/core/rtl/S32X_MiSTer diff > src/fpga/core/rtl/patches/NNNN-name.patch`,
then run `tools/prepare_upstream.sh` to confirm the full series applies to a clean checkout.

Licensing: S32X_MiSTer has no top-level LICENSE. fx68k, jt12/jt89 and `sdram.sv` are GPLv3,
`gen.sv` is BSD-style, and the SH-2/32X sources carry no license header. Keeping upstream as a
submodule means this repo points at that code rather than redistributing it.
