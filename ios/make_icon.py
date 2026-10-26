"""make_icon.py <outdir>: the app icon (yellow and black TV stripes, a big "4", "P4G") at the sizes Info.plist names.

Drawn here from shapes and the system font, so the icon holds nothing from the game. Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

YELLOW = (255, 228, 0)
INK = (16, 16, 16)
SIZES = {'AppIcon60x60@2x.png': 120, 'AppIcon60x60@3x.png': 180, 'AppIcon76x76@2x~ipad.png': 152,
         'AppIcon83.5x83.5@2x~ipad.png': 167, 'icon-1024.png': 1024}


def font(size):
    for path in ('/System/Library/Fonts/Supplemental/Impact.ttf', '/System/Library/Fonts/Supplemental/Arial Black.ttf',
                 '/System/Library/Fonts/Helvetica.ttc'):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw(n=1024):
    im = Image.new('RGB', (n, n), INK)
    d = ImageDraw.Draw(im)
    for x in range(-n, n, n // 9):  # diagonal TV stripes
        d.polygon([(x, n), (x + n // 22, n), (x + n // 22 + n, 0), (x + n, 0)], fill=(48, 43, 0))
    # the yellow block with the 4, tilted as the game's menus are
    block = Image.new('RGBA', (int(n * 0.62), int(n * 0.62)), YELLOW + (255,))
    bd = ImageDraw.Draw(block)
    f = font(int(n * 0.6))
    w, h = bd.textbbox((0, 0), '4', font=f)[2:]
    bd.text(((block.width - w) / 2, (block.height - h) / 2 - n * 0.06), '4', font=f, fill=INK)
    block = block.rotate(-8, expand=True, resample=Image.BICUBIC)
    im.paste(block, ((n - block.width) // 2, int(n * 0.12)), block)
    f2 = font(int(n * 0.15))
    t = 'P4G'
    w2 = d.textbbox((0, 0), t, font=f2)[2]
    d.text(((n - w2) / 2, n * 0.78), t, font=f2, fill=YELLOW)
    return im


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    big = draw()
    for name, size in SIZES.items():
        big.resize((size, size), Image.LANCZOS).save(os.path.join(out, name))


if __name__ == '__main__':
    main()
