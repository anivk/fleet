#!/usr/bin/env python3
# Menubar koala assets, derived from a fal.ai FLUX graphic (koala-source.jpg):
#   koala-template.png  black silhouette w/ negative-space eyes+nose (macOS template)
#   koala-regular.png   white variant (Linux)
#   koala-alert.png     the vermillion graphic (shown on attention)
# Regenerate: python3 koala.py   (needs Pillow)
from PIL import Image, ImageDraw, ImageOps, ImageChops, ImageFilter
im = Image.open("koala-source.jpg").convert("RGBA"); w, h = im.size
for c in [(2, 2), (w-3, 2), (2, h-3), (w-3, h-3)]:
    ImageDraw.floodfill(im, c, (0, 0, 0, 0), thresh=45)      # white bg -> transparent
alpha = im.split()[3]; gray = ImageOps.grayscale(im.convert("RGB"))
th = lambda img, t: img.point(lambda v: 255 if v < t else 0)
holes = ImageChops.multiply(th(gray, 82), alpha.point(lambda v: 255 if v > 128 else 0)).filter(ImageFilter.MaxFilter(3))
body = alpha.point(lambda v: 255 if v > 110 else 0)
sil = ImageChops.subtract(body, holes)                        # silhouette with eye/nose holes
def solid(rgb, m): o = Image.new("RGBA", (w, h), (0, 0, 0, 0)); o.paste(rgb+(255,), (0, 0), m); return o
def fit(icon, n=44):
    bb = icon.split()[3].getbbox(); ic = icon.crop(bb); s = max(ic.size); pad = int(s*0.12); S = s+2*pad
    sq = Image.new("RGBA", (S, S), (0, 0, 0, 0)); sq.paste(ic, ((S-ic.width)//2, (S-ic.height)//2), ic)
    return sq.resize((n, n), Image.LANCZOS)
fit(solid((0, 0, 0), sil)).save("koala-template.png")
fit(solid((255, 255, 255), sil)).save("koala-regular.png")
fit(im.copy()).save("koala-alert.png")
print("wrote koala-{template,regular,alert}.png")
