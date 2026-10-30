#!/usr/bin/env python3
"""Draw the installer's icon and dmg window background.

The art reuses the SUPERMOLE block banner that install.sh prints, so the dmg
and the terminal screen look like one product: each banner character is a
cell two pixels tall, with "▀" the top pixel, "▄" the bottom one and "█" both.
SUPER is purple and MOLE green, as in the terminal. Run on a Mac (it uses the
system fonts) and commit the PNGs it writes; the release build only packs them.

    python3 installer/render_assets.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from installer_layout import ICON_CENTER, ICON_SIZE, VISIBLE_HEIGHT, WINDOW_SIZE

ASSETS = Path(__file__).resolve().parent / "assets"

# The two banner rows printed by print_install_banner in install.sh.
BANNER_TOP = "▄▀▀ █ █ █▀█ █▀▀ █▀█ █▄ ▄█ █▀█ █   █▀▀"
BANNER_BOTTOM = "▄▄▀ ▀▄▀ █▀▀ ██▄ █▀▄ █ ▀ █ █▄█ █▄▄ ██▄"
SUPER_COLUMNS = len("▄▀▀ █ █ █▀█ █▀▀ █▀█")  # MOLE starts after the next space

# The icon's S: the banner's 3x4 S is too coarse at icon size, so the icon uses
# a classic 5x7 bitmap S, followed by a terminal cursor.
ICON_S = (
    ".###.",
    "#...#",
    "#....",
    ".###.",
    "....#",
    "#...#",
    ".###.",
)

# The terminal's purple and green, for the dark icon tile.
PURPLE = (198, 120, 221)
GREEN = (152, 195, 121)
ICON_TOP = (36, 28, 52)
ICON_BOTTOM = (15, 12, 21)
# The dmg window is light: Finder draws icon labels in black there, and a
# dark background made "Installer Supermole" unreadable. Deeper purple and
# green keep the banner's contrast on it.
WINDOW_PURPLE = (142, 68, 173)
WINDOW_GREEN = (76, 145, 60)
WINDOW_TEXT = (36, 30, 48)
WINDOW_MUTED = (110, 102, 128)
WINDOW_TOP = (250, 248, 253)
WINDOW_BOTTOM = (234, 229, 243)

FONT_REGULAR = "/System/Library/Fonts/SFNS.ttf"
FONT_FALLBACK = "/System/Library/Fonts/Helvetica.ttc"


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in (FONT_REGULAR, FONT_FALLBACK):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    raise SystemExit("No system font found; run this on macOS")


def banner_pixels(purple=PURPLE, green=GREEN) -> list[tuple[int, int, tuple[int, int, int]]]:
    """(column, row, colour) for every lit pixel of the 4-pixel-tall banner."""
    lit = []
    for half, line in enumerate((BANNER_TOP, BANNER_BOTTOM)):
        for column, char in enumerate(line):
            colour = purple if column < SUPER_COLUMNS else green
            if char in "█▀":
                lit.append((column, half * 2, colour))
            if char in "█▄":
                lit.append((column, half * 2 + 1, colour))
    return lit


def vertical_gradient(size: tuple[int, int], top, bottom) -> Image.Image:
    width, height = size
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(height - 1, 1)
        colour = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        draw.line([(0, y), (width, y)], fill=colour)
    return image


def draw_pixels(draw: ImageDraw.ImageDraw, origin, pixel: float, gap: float, pixels) -> None:
    ox, oy = origin
    for column, row, colour in pixels:
        x0 = ox + column * pixel + gap / 2
        y0 = oy + row * pixel + gap / 2
        draw.rectangle([x0, y0, x0 + pixel - gap, y0 + pixel - gap], fill=colour)


def centred_text(draw, centre_x: float, y: float, text: str, size: int, fill) -> None:
    face = font(size)
    width = draw.textlength(text, font=face)
    draw.text((centre_x - width / 2, y), text, font=face, fill=fill)


def render_background(scale: int) -> Image.Image:
    width, height = (dimension * scale for dimension in WINDOW_SIZE)
    image = vertical_gradient((width, height), WINDOW_TOP, WINDOW_BOTTOM)
    draw = ImageDraw.Draw(image)

    pixels = banner_pixels(WINDOW_PURPLE, WINDOW_GREEN)
    columns = len(BANNER_TOP)
    pixel = 9 * scale
    banner_width = columns * pixel
    # Touching pixels, like the terminal's half blocks; gaps break the letters.
    draw_pixels(draw, ((width - banner_width) / 2, 38 * scale), pixel, 0, pixels)

    centre = width / 2
    centred_text(draw, centre, 82 * scale, "Mole, avec une IA qui t'explique ton disque", 15 * scale, WINDOW_MUTED)

    # The app icon sits at ICON_CENTER, with Finder's label just below it.
    call_to_action = ICON_CENTER[1] + ICON_SIZE / 2 + 34
    centred_text(draw, centre, call_to_action * scale, "Double-clique pour installer", 17 * scale, WINDOW_TEXT)

    help_first_line = call_to_action + 26
    centred_text(draw, centre, help_first_line * scale,
                 "macOS bloque l'ouverture ?", 12 * scale, WINDOW_MUTED)
    centred_text(draw, centre, (help_first_line + 16) * scale,
                 "Réglages › Confidentialité et sécurité › Ouvrir quand même", 12 * scale, WINDOW_MUTED)
    assert help_first_line + 16 + 14 <= VISIBLE_HEIGHT, "help text would fall under Finder's bars"
    return image


def render_icon(size: int = 1024) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # Apple's icon grid: an 824 pt rounded square centred in 1024.
    inset = size * 100 / 1024
    radius = size * 185 / 1024
    tile = vertical_gradient((size, size), ICON_TOP, ICON_BOTTOM).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    image.paste(tile, (0, 0), mask)

    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius,
                           outline=(255, 255, 255, 28), width=max(2, size // 256))

    # A purple S, then a green cursor on its baseline, like a terminal prompt.
    s_glyph = [(column, row, PURPLE)
               for row, line in enumerate(ICON_S) for column, cell in enumerate(line) if cell == "#"]
    glyph_rows = len(ICON_S)
    cursor = [(6, glyph_rows - 1, GREEN), (7, glyph_rows - 1, GREEN)]
    glyph_columns = 8
    pixel = size * 72 / 1024
    origin = ((size - glyph_columns * pixel) / 2, (size - glyph_rows * pixel) / 2)
    draw_pixels(draw, origin, pixel, size * 6 / 1024, s_glyph + cursor)
    return image


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    render_icon().save(ASSETS / "icon.png")
    render_background(1).save(ASSETS / "background.png")
    render_background(2).save(ASSETS / "background@2x.png")
    print(f"wrote {ASSETS}/icon.png, background.png, background@2x.png")


if __name__ == "__main__":
    main()
