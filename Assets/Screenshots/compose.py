#!/usr/bin/env python3
"""Turns raw window captures of the demo (see README, "Screenshots") into the 2000 x 1250 images on leinerud.se:
a headline and a line of text over a dark gradient, with the window below, running off the bottom edge.
Run from the repo root: python3 Assets/Screenshots/compose.py <folder with raw-*.png> <output folder>  (needs Pillow)"""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS = [  # raw capture, output, headline, text
    ("raw-sessions.png", "shot-1.jpg", "See what Copilot is up to.",
     "Every session in one place, and right away you know which one is waiting for you."),
    ("raw-review.png", "shot-2.jpg", "What changed, in plain words.",
     "Colours, spacing and text, before and after. No code to read."),
    ("raw-overview.png", "shot-3.jpg", "Know which branches are done.",
     "Every branch gets a suggested next step that makes sense without git."),
    ("raw-branches.png", "shot-4.jpg", "What’s in a branch?",
     "What it did, what it touched and what isn’t saved yet."),
]
W, H = 2000, 1250
FONTS = "Resources/Widget/Fonts/Inter-{}.ttf"

def background():
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    top, bottom = (14, 15, 20), (38, 42, 58)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([W * 0.2, H * 0.45, W * 0.8, H * 1.4], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    img.paste(Image.new("RGB", (W, H), (88, 96, 170)), (0, 0), glow)
    return img

def centered(d, text, y, font, fill):
    d.text(((W - d.textlength(text, font=font)) / 2, y), text, font=font, fill=fill)

def compose(raw, out, headline, text):
    img = background()
    d = ImageDraw.Draw(img)
    centered(d, headline, 92, ImageFont.truetype(FONTS.format("Bold"), 84), (255, 255, 255))
    centered(d, text, 212, ImageFont.truetype(FONTS.format("Medium"), 36), (176, 182, 200))
    win = Image.open(raw).convert("RGBA")
    width = 1500
    win = win.resize((width, round(win.height * width / win.width)), Image.LANCZOS)
    x, y = (W - width) // 2, 330
    shadow = Image.new("L", (W, H + 400), 0)
    alpha = win.split()[3].point(lambda a: a * 0.55)
    shadow.paste(alpha, (x, y + 24))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40)).crop((0, 0, W, H))
    img.paste(Image.new("RGB", (W, H), (0, 0, 0)), (0, 0), shadow)
    img.paste(win, (x, y), win)
    img.save(out, quality=88, optimize=True, progressive=True)

src, dst = sys.argv[1], sys.argv[2]
for raw, out, headline, text in SHOTS:
    compose(f"{src}/{raw}", f"{dst}/{out}", headline, text)
    print(out)
