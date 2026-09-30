#!/usr/bin/env python3
"""Generate the Pocket UI images from text (REQ-APF-05):
  dist/icon.bin                    core icon, 36x36
  dist/platforms/_images/32x.bin   platform banner, 521x165
Pocket image format (checked against the template's files): 16 bits per pixel, first byte =
inverted brightness (0 = white, 0xFF = black), second byte 0; stored rotated 90 degrees
counter-clockwise. Text is rendered with DejaVu Sans Bold (Bitstream Vera license).
Also writes upright PNG previews to build/images/."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def fit_text(img, text, box, max_size):
    """Largest font size (<= max_size) whose text fits in box = (x0, y0, x1, y1), centered."""
    d = ImageDraw.Draw(img)
    for size in range(max_size, 4, -1):
        f = ImageFont.truetype(FONT, size)
        l, t, r, b = d.textbbox((0, 0), text, font=f)
        if r - l <= box[2] - box[0] and b - t <= box[3] - box[1]:
            x = box[0] + (box[2] - box[0] - (r - l)) // 2 - l
            y = box[1] + (box[3] - box[1] - (b - t)) // 2 - t
            d.text((x, y), text, font=f, fill=255)
            return size
    raise ValueError(text)


def to_pocket(img):
    stored = img.rotate(90, expand=True)                 # 90 degrees counter-clockwise
    return b"".join(bytes((255 - p, 0)) for p in stored.getdata())


def main():
    out = REPO / "build/images"
    out.mkdir(parents=True, exist_ok=True)

    icon = Image.new("L", (36, 36), 0)
    fit_text(icon, "32X", (1, 9, 35, 27), 20)
    (REPO / "dist/icon.bin").write_bytes(to_pocket(icon))
    icon.resize((144, 144), Image.NEAREST).save(out / "icon.png")

    plat = Image.new("L", (521, 165), 0)
    fit_text(plat, "32X", (24, 14, 300, 116), 200)
    fit_text(plat, "GENESIS / MEGA DRIVE ADD-ON", (24, 124, 300, 150), 40)
    (REPO / "dist/platforms/_images/32x.bin").write_bytes(to_pocket(plat))
    plat.save(out / "platform.png")
    print(f"wrote dist/icon.bin, dist/platforms/_images/32x.bin, previews in {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
