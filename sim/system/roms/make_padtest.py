#!/usr/bin/env python3
"""Build padtest.bin: a minimal Genesis program (hand-assembled 68K, our own code) that reads pad 1
the way 6-button games do, every ~3 ms, and shows the result as the screen's backdrop color:
  gray   no 6-button pad detected (3-button mode)
  black  6-button pad detected, X/Y/Z/Mode released
  red / green / blue   X / Y / Z held (colors add up)
  white  Mode held
Runs on the Pocket like any .md/.bin, and in sim/system (+pad6 +joy1=<hex>)."""
import struct, sys

prog = []          # items: int (word), or ('bne.s', label), or ('label', name)
def w(*words): prog.extend(words)
def label(n): prog.append(('label', n))
def bne_s(n): prog.append(('bne.s', n))
def vdp_reg(r, v): w(0x33FC, 0x8000 | (r << 8) | v, 0x00C0, 0x0004)   # move.w #$8rvv,$C00004
def th(high): w(0x10BC, 0x0040 if high else 0x0000, 0x4E71, 0x4E71)   # move.b #$40/#0,(a0); nop; nop

vdp_reg(0x00, 0x04)
vdp_reg(0x01, 0x44)                    # display on, mode 5
vdp_reg(0x0C, 0x81)                    # H40
vdp_reg(0x07, 0x00)                    # backdrop = CRAM entry 0
w(0x41F9, 0x00A1, 0x0003)              # lea    $A10003,a0     pad 1 data
w(0x43F9, 0x00C0, 0x0000)              # lea    $C00000,a1     VDP data
w(0x13FC, 0x0040, 0x00A1, 0x0009)      # move.b #$40,$A10009    pad 1 ctrl: TH output
label('loop')
th(1)                                  # TH high: C B R L D U
th(0)                                  # TH low : S A 0 0 D U
th(1)
th(0)
th(1)
th(0); w(0x1610)                       # 3rd TH low: S A 0 0 0 0 on a 6-button pad   move.b (a0),d3
th(1); w(0x1810)                       # TH high: C B M X Y Z                    move.b (a0),d4
th(0)                                  # TH low : S A 1 1 1 1
w(0x10BC, 0x0040)                      # move.b #$40,(a0)      idle high
w(0x303C, 0x0666)                      # move.w #$0666,d0      gray
w(0x0203, 0x000F)                      # andi.b #$0F,d3
bne_s('setc')
w(0x7000)                              # moveq  #0,d0          black
for bit, color, nxt in ((2, 0x000E, 'y'), (1, 0x00E0, 'z'), (0, 0x0E00, 'm')):
    w(0x0804, bit)                     # btst   #bit,d4        (pressed = 0)
    bne_s(nxt)
    w(0x0040, color)                   # ori.w  #color,d0
    label(nxt)
w(0x0804, 0x0003)                      # btst   #3,d4          Mode
bne_s('setc')
w(0x303C, 0x0EEE)                      # move.w #$0EEE,d0      white
label('setc')
w(0x237C, 0xC000, 0x0000, 0x0004)      # move.l #$C0000000,4(a1)   CRAM write, entry 0
w(0x3280)                              # move.w d0,(a1)
w(0x3E3C, 0x0800)                      # move.w #$0800,d7
w(0x51CF, 0xFFFE)                      # dbra   d7,*
w(0x6000, ('loop16',))                 # bra.w  loop

# two passes: label addresses, then encode
addr, labels = 0x200, {}
for it in prog:
    if isinstance(it, tuple) and it[0] == 'label': labels[it[1]] = addr
    elif isinstance(it, tuple) or isinstance(it, int): addr += 2
out, addr = [], 0x200
for it in prog:
    if isinstance(it, tuple) and it[0] == 'label': continue
    if isinstance(it, tuple) and it[0] == 'bne.s':
        d = labels[it[1]] - (addr + 2); assert -128 <= d < 128 and d != 0
        out.append(0x6600 | (d & 0xFF))
    elif isinstance(it, tuple) and it[0] == 'loop16':
        out.append((labels['loop'] - addr) & 0xFFFF)   # bra.w: disp from the address of this word
    else:
        out.append(it)
    addr += 2

rom = bytearray(b'\xff' * 0x400)
struct.pack_into('>II', rom, 0, 0x00FFFE00, 0x200)          # SSP, PC
rom[0x100:0x110] = b'SEGA MEGA DRIVE '
rom[0x120:0x130] = b'PAD TEST        '
rom[0x150:0x160] = b'PAD TEST        '
rom[0x180:0x18E] = b'GM 00000000-00'
struct.pack_into('>II', rom, 0x1A0, 0, len(rom) - 1)        # ROM start/end
rom[0x1F0:0x1F3] = b'JUE'
for i, v in enumerate(out):
    struct.pack_into('>H', rom, 0x200 + 2 * i, v)
open(sys.argv[1] if len(sys.argv) > 1 else 'padtest.bin', 'wb').write(rom)
print(f"{len(out) * 2} bytes of code")
