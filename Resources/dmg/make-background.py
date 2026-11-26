#!/usr/bin/env python3
"""Draws the .dmg window background (background.png at 1x, background@2x.png at 2x).
Run from the repo root: python3 Resources/dmg/make-background.py   (needs Pillow)
The window is 660 x 400 pt; Scripts/direct.sh puts the app at (165, 275) and Applications at (495, 275)."""
import glob
from PIL import Image, ImageDraw, ImageFont

W, H, S = 660, 400, 2            # points, and the 2x scale
INK = (24, 26, 33)
img = Image.new("RGB", (W * S, H * S))
d = ImageDraw.Draw(img)
top, bot = (246, 247, 250), (214, 218, 228)
for y in range(H * S):
    t = y / (H * S - 1)
    d.line([(0, y), (W * S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))

def font(size, name):
    hits = glob.glob(f"**/Inter-{name}.ttf", recursive=True)
    try: return ImageFont.truetype(hits[0], size)
    except Exception: return ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size)

icon = Image.open("Assets/AppIcon-1024.png").convert("RGBA").resize((96 * S, 96 * S), Image.LANCZOS)
img.paste(icon, ((W * S - icon.width) // 2, 22 * S), icon)

def centered(text, y, f, fill=INK):
    w = d.textlength(text, font=f)
    d.text(((W * S - w) / 2, y), text, font=f, fill=fill)

centered("Wingman beta", 124 * S, font(26 * S, "Bold"))
centered("Drag it onto Applications to install", 160 * S, font(14 * S, "Medium"), fill=(70, 74, 86))

cy, x0, x1 = 275 * S, 235 * S, 425 * S
d.line([(x0, cy), (x1 - 8 * S, cy)], fill=INK, width=int(3 * S))
d.polygon([(x1, cy), (x1 - 15 * S, cy - 10 * S), (x1 - 15 * S, cy + 10 * S)], fill=INK)

img.save("Resources/dmg/background@2x.png")
img.resize((W, H), Image.LANCZOS).save("Resources/dmg/background.png")
print("ok")
