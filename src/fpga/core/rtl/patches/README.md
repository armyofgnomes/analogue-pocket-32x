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
| `0003-bios-from-generated-mif.patch` | `MDROM.v`/`SHROM.v` load `core/bios_mif/*.mif`, generated from the gitignored `bios/` by `tools/gen_bios_mif.py`, instead of upstream's bundled BIOS `.mif` files (REQ-LEGAL-03, REQ-APF-03a) |
| `0004-export-fb-swap.patch` | `VDP.sv`/`32X.sv`: export the VDP's framebuffer-swap bit `FS` as `FB_FS`, so `fb_sram.sv` knows which framebuffer is being drawn and can prioritize it (REQ-MEM-02) |
| `0005-sh2-ubc-disable.patch` | `32X.sv`: `UBC_DISABLE(1)` on both SH-2s. The User Break Controller is a debugger aid that no game uses; about 245 ALMs (REQ-ARCH-04, fit experiment `no_debug`) |

To add a patch: start from a clean checkout (`git -C src/fpga/core/rtl/S32X_MiSTer checkout -- .`,
not the patched tree, or the diff will include the existing patches), edit files in the submodule, `git -C src/fpga/core/rtl/S32X_MiSTer diff > src/fpga/core/rtl/patches/NNNN-name.patch`,
then run `tools/prepare_upstream.sh` to confirm the full series applies to a clean checkout.

Licensing: S32X_MiSTer has no top-level LICENSE. fx68k, jt12/jt89 and `sdram.sv` are GPLv3,
`gen.sv` is BSD-style, and the SH-2/32X sources carry no license header. Keeping upstream as a
submodule means this repo points at that code rather than redistributing it.
