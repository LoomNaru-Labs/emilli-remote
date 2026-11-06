"""Draws the Emilli launcher and notification icons for the Android app (PIL only).

Same drawing as the Google Play icon (play/graphics/make_graphics.py, theme "After closing"):
a Night store front with one lit Lamp window and a row of Night dots on Paper. Writes, for
mdpi to xxxhdpi, into res/mipmap-<density>/ next to this file:
  ic_launcher.png             legacy square icon (48 dp)
  ic_launcher_round.png       legacy round icon (48 dp)
  ic_launcher_foreground.png  adaptive icon foreground (108 dp, drawing inside the 66 dp safe circle);
                              Android also uses it as the monochrome layer
  ic_stat_logo.png            notification icon (24 dp, white on transparent)
The adaptive background colour is set to Paper by patch 06 (values/ic_launcher_background.xml).
build.sh copies res/ over the app's res/ after the patches.

usage: python -I make_icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
PAPER = (250, 247, 242, 255)
NIGHT = (36, 54, 75, 255)
NIGHT_DARK = (26, 40, 56, 255)
LAMP = (242, 165, 65, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
SS = 8  # supersampling for smooth edges
# The drawing in 512 units, as on the Play icon; its bounding box is about x 53..464, y 83..442.
BOX = (53, 83, 464, 442)


def draw(d, tf, mono=False):
    """Draw the store and dots; tf maps 512-unit coordinates to pixels."""
    def r(x0, y0, x1, y1, fill):
        d.rectangle((*tf(x0, y0), *tf(x1, y1)), fill=fill)

    body = WHITE if mono else NIGHT
    x, y, w, h = 170, 206, 280, 236
    roof = h // 9
    r(x - w // 20, y, x + w + w // 20, y + roof, body)
    r(x, y + roof, x + w, y + h, body)
    door_w, door_h = w // 4, int(h * 0.55)
    r(x + w // 8, y + h - door_h, x + w // 8 + door_w, y + h, CLEAR if mono else NIGHT_DARK)
    win = w // 4
    wx0, wy0 = x + w - w // 8 - win, y + roof + (h - roof) // 5
    r(wx0, wy0, wx0 + win, wy0 + win, CLEAR if mono else LAMP)
    bar = max(3, win // 10)
    r(wx0 + win // 2 - bar // 2, wy0, wx0 + win // 2 + bar // 2, wy0 + win, body)
    r(wx0, wy0 + win // 2 - bar // 2, wx0 + win, wy0 + win // 2 + bar // 2, body)
    for i in range(4):
        t = i / 3
        cx, cy = 66 + (178 - 66) * t, 96 + (170 - 96) * t
        (px0, py0), (px1, py1) = tf(cx - 13, cy - 13), tf(cx + 13, cy + 13)
        d.ellipse((px0, py0, px1, py1), fill=body)


def render(size, kind):
    big = size * SS
    img = Image.new("RGBA", (big, big), CLEAR)
    d = ImageDraw.Draw(img)
    if kind == "square":
        d.rectangle((0, 0, big, big), fill=PAPER)
        scale, ox, oy = big / 512, 0.0, 0.0
    elif kind == "round":
        d.ellipse((0, 0, big - 1, big - 1), fill=PAPER)
        # fit the drawing's box into the circle with a margin
        bw, bh = BOX[2] - BOX[0], BOX[3] - BOX[1]
        scale = 0.80 * big / (bw * bw + bh * bh) ** 0.5
        ox = big / 2 - (BOX[0] + bw / 2) * scale
        oy = big / 2 - (BOX[1] + bh / 2) * scale
    else:  # foreground or notification: drawing inside a centred circle
        bw, bh = BOX[2] - BOX[0], BOX[3] - BOX[1]
        frac = 66 / 108 if kind == "foreground" else 0.98
        scale = frac * big / (bw * bw + bh * bh) ** 0.5
        ox = big / 2 - (BOX[0] + bw / 2) * scale
        oy = big / 2 - (BOX[1] + bh / 2) * scale
    tf = lambda x, y: (ox + x * scale, oy + y * scale)  # noqa: E731
    draw(d, tf, mono=(kind == "stat"))
    return img.resize((size, size), Image.LANCZOS)


def main():
    for name, factor in DENSITIES.items():
        out = HERE / "res" / f"mipmap-{name}"
        out.mkdir(parents=True, exist_ok=True)
        render(int(48 * factor), "square").save(out / "ic_launcher.png")
        render(int(48 * factor), "round").save(out / "ic_launcher_round.png")
        render(int(108 * factor), "foreground").save(out / "ic_launcher_foreground.png")
        stat = render(int(24 * factor), "stat")
        stat.convert("LA").save(out / "ic_stat_logo.png")
    for p in sorted((HERE / "res").rglob("*.png")):
        with Image.open(p) as im:
            print(p.relative_to(HERE).as_posix(), im.size, im.mode)


if __name__ == "__main__":
    main()
