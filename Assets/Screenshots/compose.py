#!/usr/bin/env python3
"""Turns raw window captures of the demo (see README, "Screenshots") into the 2000 x 1250 images on leinerud.se:
a headline and a line of text over a dark gradient, with the window below, running off the bottom edge.
shot-5 hangs the menu bar panel (raw-menubar.png, from -WingmanDemoPanel) from a menu bar, and shot-6 puts the
main window (raw-dock.png) above a Dock with the app icon.
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

def shadowed(img, layer, x, y, strength=0.55, blur=40, drop=24):
    """Pastes an RGBA layer at (x, y) on img, with a soft shadow under it."""
    shadow = Image.new("L", (W, H + 600), 0)
    shadow.paste(layer.split()[3].point(lambda a: a * strength), (x, y + drop))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur)).crop((0, 0, W, H))
    img.paste(Image.new("RGB", (W, H), (0, 0, 0)), (0, 0), shadow)
    img.paste(layer, (x, y), layer)

def scaled(path, width):
    im = Image.open(path).convert("RGBA")
    return im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)

def menubar(raw, out):
    """The menu bar panel hanging from its icon in a menu bar along the top, with the text on the left.
    raw-menubar.png is the -WingmanDemoPanel window: the icon in its top 24 points, the panel below."""
    img = background()
    d = ImageDraw.Draw(img)
    scale = 1.15
    panel = scaled(raw, round(Image.open(raw).width * scale))
    bar = round(48 * scale)  # 24 points at 2x
    strip = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(strip).rectangle([0, 0, W, bar], fill=(10, 11, 16, 150))
    img.paste(strip, (0, 0), strip)
    clock = ImageFont.truetype(FONTS.format("SemiBold"), round(26 * scale))
    d.text((W - 60 - d.textlength("Thu 26 Nov  9:41", font=clock), bar / 2), "Thu 26 Nov  9:41",
           font=clock, fill=(235, 237, 245), anchor="lm")
    x = W - panel.width - 130
    shadowed(img, panel, x, 0, strength=0.6)
    bold, medium = ImageFont.truetype(FONTS.format("Bold"), 84), ImageFont.truetype(FONTS.format("Medium"), 36)
    y = 470
    for line in ["In your", "menu bar."]:
        d.text((140, y), line, font=bold, fill=(255, 255, 255)); y += 100
    y += 40
    for line in ["One click away from every session.", "The icon tells you when one needs you,",
                 "and how many are running."]:
        d.text((140, y), line, font=medium, fill=(176, 182, 200)); y += 52
    img.save(out, quality=88, optimize=True, progressive=True)

def dock(raw, out, icon):
    """The main window above a Dock with Wingman's icon, its name above it and the dot that says it's open."""
    img = background()
    d = ImageDraw.Draw(img)
    centered(d, "Or as an app in your Dock.", 92, ImageFont.truetype(FONTS.format("Bold"), 84), (255, 255, 255))
    centered(d, "The full window when you want more room. Use one, or both.", 212,
             ImageFont.truetype(FONTS.format("Medium"), 36), (176, 182, 200))
    win = scaled(raw, 1200)
    shadowed(img, win, (W - win.width) // 2, 310)
    size, pad = 190, 10
    dw, dh = size + pad * 2 + 60, size + pad * 2 - 20
    dx, dy = (W - dw) // 2, H - dh - 26
    plate = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    pd.rounded_rectangle([dx, dy, dx + dw, dy + dh], radius=48, fill=(46, 50, 66, 255), outline=(255, 255, 255, 60), width=2)
    shadowed(img, plate.crop((0, 0, W, H)), 0, 0, strength=0.5, blur=30, drop=12)
    app = scaled(icon, size)
    img.paste(app, ((W - size) // 2, dy + pad - 22), app)
    pd = ImageDraw.Draw(img)
    pd.ellipse([W / 2 - 6, dy + dh - 16, W / 2 + 6, dy + dh - 4], fill=(230, 232, 240))
    label = ImageFont.truetype(FONTS.format("Medium"), 30)
    lw = d.textlength("Wingman", font=label)
    ly = dy - 92
    tip = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(tip).rounded_rectangle([W / 2 - lw / 2 - 26, ly, W / 2 + lw / 2 + 26, ly + 56], radius=14, fill=(40, 43, 56, 235))
    img.paste(tip, (0, 0), tip)
    d.text((W / 2, ly + 28), "Wingman", font=label, fill=(240, 242, 248), anchor="mm")
    img.save(out, quality=88, optimize=True, progressive=True)

src, dst = sys.argv[1], sys.argv[2]
for raw, out, headline, text in SHOTS:
    compose(f"{src}/{raw}", f"{dst}/{out}", headline, text)
    print(out)
menubar(f"{src}/raw-menubar.png", f"{dst}/shot-5.jpg"); print("shot-5.jpg")
dock(f"{src}/raw-dock.png", f"{dst}/shot-6.jpg", "Assets/AppIcon-1024.png"); print("shot-6.jpg")
