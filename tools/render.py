#!/usr/bin/env python3
"""Rasterize frames dumped by tools/screenshot.lua into PNGs.

Frames are drawn at the handheld's true 318x212 and then scaled up with
nearest-neighbour, so what you see is pixel-for-pixel what the layout code
produced -- just bigger.

  python3 tools/render.py [framedir] [outdir] [scale]
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 318, 212

FONT_DIRS = [
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/truetype/freefont",
]
REGULAR = ["DejaVuSans.ttf", "FreeSans.ttf"]
BOLD = ["DejaVuSans-Bold.ttf", "FreeSansBold.ttf"]


def find_font(names):
    for d in FONT_DIRS:
        for n in names:
            p = Path(d) / n
            if p.exists():
                return str(p)
    return None


_cache = {}


def font(size, style):
    key = (size, style)
    if key not in _cache:
        path = find_font(BOLD if "b" in style else REGULAR)
        try:
            # Same pixel size tools/fontmetrics.py measured, so preview == layout.
            _cache[key] = ImageFont.truetype(path, size) if path else ImageFont.load_default()
        except OSError:
            _cache[key] = ImageFont.load_default()
    return _cache[key]


def render(src: Path, dst: Path, scale: int) -> None:
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)

    # TI.Image sprites the frame uses, keyed by the id its drawImage lines cite.
    # Six hex digits a pixel, or "------" for a pixel the alpha bit leaves out.
    images = {}

    for line in src.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        # drawString's text may contain anything, so split a bounded number of times.
        parts = line.split("\t")
        op = parts[0]

        if op == "image":
            iid, w, h = (int(v) for v in parts[1:4])
            blob = parts[4]
            px = []
            for i in range(w * h):
                cell = blob[i * 6:(i + 1) * 6]
                px.append(None if cell == "------" else
                          (int(cell[0:2], 16), int(cell[2:4], 16), int(cell[4:6], 16)))
            images[iid] = (w, h, px)

        elif op == "drawImage":
            x, y, iid = (int(v) for v in parts[1:4])
            entry = images.get(iid)
            if entry is None:
                continue
            w, h, px = entry
            # A pixel at a time: the sprites are 16x16 and a frame holds at most
            # a board's worth, so this is nothing beside the font rendering.
            for sy in range(h):
                for sx in range(w):
                    c = px[sy * w + sx]
                    if c is None:
                        continue
                    dx, dy = x + sx, y + sy
                    if 0 <= dx < W and 0 <= dy < H:
                        img.putpixel((dx, dy), c)

        elif op == "drawString":
            x, y, r, g, b, size = (int(v) for v in parts[1:7])
            style, text = parts[7], "\t".join(parts[8:])
            d.text((x, y), text, fill=(r, g, b), font=font(size, style))

        elif op == "drawLine":
            x1, y1, x2, y2, r, g, b = (int(v) for v in parts[1:8])
            d.line((x1, y1, x2, y2), fill=(r, g, b))

        elif op == "fillArc":
            x, y, w, h, r, g, b = (int(v) for v in parts[1:8])
            if w > 0 and h > 0:
                d.ellipse((x, y, x + w - 1, y + h - 1), fill=(r, g, b))

        elif op in ("fillRect", "drawRect"):
            x, y, w, h, r, g, b = (int(v) for v in parts[1:8])
            pen = parts[8] if len(parts) > 8 else "smooth"
            if w <= 0 or h <= 0:
                continue
            box = (x, y, x + w - 1, y + h - 1)
            if op == "fillRect":
                d.rectangle(box, fill=(r, g, b))
            elif pen == "dashed":
                # Approximate the Nspire's dashed pen so wrap mode reads correctly.
                for i in range(x, x + w, 4):
                    d.line((i, y, min(i + 1, x + w - 1), y), fill=(r, g, b))
                    d.line((i, y + h - 1, min(i + 1, x + w - 1), y + h - 1), fill=(r, g, b))
                for j in range(y, y + h, 4):
                    d.line((x, j, x, min(j + 1, y + h - 1)), fill=(r, g, b))
                    d.line((x + w - 1, j, x + w - 1, min(j + 1, y + h - 1)), fill=(r, g, b))
            else:
                d.rectangle(box, outline=(r, g, b))

    if scale > 1:
        img = img.resize((W * scale, H * scale), Image.NEAREST)
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst)
    print(f"rendered {dst} ({img.width}x{img.height})")


if __name__ == "__main__":
    framedir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/frames")
    outdir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("build/screenshots")
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    frames = sorted(framedir.glob("*.txt"))
    if not frames:
        sys.exit(f"no frames in {framedir} -- run tools/screenshot.lua first")
    for f in frames:
        render(f, outdir / (f.stem + ".png"), scale)
