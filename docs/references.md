# References

## Analogue openFPGA

- Developer docs: https://www.analogue.co/developer/docs/openfpga/overview
  (core definition JSON, data slots, bridge protocol, video scaler modes, audio, input)
- Core template (this repo's origin): https://github.com/open-fpga/core-template,
  verified identical to tag v1.3.0 / commit `da3a021` on 2026-09-28
- openFPGA core inventory: https://openfpga-library.github.io/analogue-pocket/

## Upstream HDL

| Project | URL | Use |
|---|---|---|
| S32X_MiSTer (official) | https://github.com/MiSTer-devel/S32X_MiSTer | Primary base: Genesis + 32X + SH7604 |
| S32X_MiSTer (srg320 archive) | https://github.com/srg320/S32X_MiSTer | Original author's repo |
| SH (SH-2 core) | https://github.com/srg320/SH | Standalone SH7604, shared with Saturn core |
| Saturn_MiSTer | https://github.com/srg320/Saturn_MiSTer | Newer SH-2 fixes (see S32X PR "SH sync with Saturn") |
| S32X_Sockit | https://github.com/sockitfpga/S32X_Sockit | Example of porting S32X off the MiSTer framework |
| openFPGA-Genesis | https://github.com/opengateware/openFPGA-Genesis | Pocket Genesis core: APF glue reference |
| openfpga-megacd | https://github.com/neutralinsomniac/openfpga-megacd | Pocket Genesis + Mega CD: large Sega add-on on Pocket |
| Analogizer_openFPGA-Genesis | https://github.com/RndMnkIII/Analogizer_openFPGA-Genesis | Another Pocket Genesis variant |
| openfpga-NES (agg23) | https://github.com/agg23/openfpga-NES | Well-documented Pocket port patterns (saves, settings, sleep) |

## Hardware documentation

- Sega *32X Hardware Manual* and *32X Technical Information* (official developer docs,
  widely mirrored)
- Hitachi *SH7604 Hardware Manual* and *SH-1/SH-2 Programming Manual*
- Genesis/Mega Drive: Sega *Genesis Software Manual*, Charles MacDonald's VDP document,
  Plutiedev (https://plutiedev.com)
- SpritesMind forum (32X/Genesis homebrew and hardware research)

## Emulators useful as behavioral references

- ares, PicoDrive, Gens/GS, Kega Fusion (closed source, but a compatibility baseline).
  Note that Genesis Plus GX does **not** emulate the 32X.

## Community

- MiSTer forum 32X threads: https://misterfpga.org/viewtopic.php?t=4569
- S32X_MiSTer issues (known game problems): https://github.com/MiSTer-devel/S32X_MiSTer/issues
