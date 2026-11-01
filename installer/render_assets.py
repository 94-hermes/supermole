#!/usr/bin/env python3
"""Draw the installer's icons and dmg window background.

The art reuses the SUPERMOLE block banner that install.sh prints, so the dmg
and the terminal screen look like one product: each banner character is a
cell two pixels tall, with "▀" the top pixel, "▄" the bottom one and "█" both.
SUPER is purple and MOLE green, as in the terminal. The window offers the two
versions in two panels (installer_layout.py): the app to drag to Applications,
and the Terminal installer to double-click, each with its own icon. Run on a
Mac (it uses the system fonts) and commit the PNGs it writes; the release
build only packs them.

    python3 installer/render_assets.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from installer_layout import (
    APP_ICON_CENTER,
    APP_PANEL,
    APPLICATIONS_ICON_CENTER,
    ICON_SIZE,
    TERMINAL_PANEL,
    VISIBLE_HEIGHT,
    WINDOW_SIZE,
)

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

# The Terminal installer's icon: a prompt, ">" then the same cursor.
ICON_PROMPT = (
    "#....",
    ".#...",
    "..#..",
    "...#.",
    "..#..",
    ".#...",
    "#....",
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
PANEL_FILL = (255, 255, 255, 150)
PANEL_OUTLINE = (*WINDOW_PURPLE, 60)
# The three window buttons drawn on the Terminal icon's title bar.
WINDOW_DOTS = ((237, 106, 94), (245, 191, 79), (98, 197, 84))

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


def draw_arrow(draw: ImageDraw.ImageDraw, scale: int) -> None:
    """A purple arrow from the app icon to the Applications shortcut."""
    gap = ICON_SIZE / 2 + 24
    start_x = (APP_ICON_CENTER[0] + gap) * scale
    end_x = (APPLICATIONS_ICON_CENTER[0] - gap) * scale
    y = APP_ICON_CENTER[1] * scale
    thickness = 6 * scale
    head = 18 * scale
    draw.rectangle([start_x, y - thickness / 2, end_x - head, y + thickness / 2], fill=WINDOW_PURPLE)
    draw.polygon([(end_x - head, y - head), (end_x, y), (end_x - head, y + head)], fill=WINDOW_PURPLE)


# Each panel: its title, what that version is, and under the icons (whose
# Finder labels sit just below them) what to do, in French then English, and
# the macOS it needs. Lines are (text, size in points, colour).
APP_PANEL_TEXT = (
    ("Application", "Une fenêtre, sans Terminal · A window, no Terminal"),
    (
        ("Glisse Supermole dans Applications", 15, WINDOW_TEXT),
        ("Drag Supermole to Applications", 12, WINDOW_MUTED),
        ("macOS 26 ou plus · or later", 11, WINDOW_MUTED),
    ),
)
TERMINAL_PANEL_TEXT = (
    ("Terminal", "La commande mo · The mo command"),
    (
        ("Double-clique pour installer mo", 15, WINDOW_TEXT),
        ("Double-click to install mo", 12, WINDOW_MUTED),
        ("macOS 12 ou plus · or later", 11, WINDOW_MUTED),
    ),
)
# Space between a panel's edge and the widest line it may hold.
PANEL_TEXT_MARGIN = 12
# Where the lines under the icons start: below the icon and its Finder label.
CAPTION_GAP = 34


def draw_panels(image: Image.Image, scale: int) -> Image.Image:
    """The two translucent rounded panels, composited onto the background."""
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for left, top, right, bottom in (APP_PANEL, TERMINAL_PANEL):
        draw.rounded_rectangle([left * scale, top * scale, right * scale, bottom * scale],
                               radius=18 * scale, fill=PANEL_FILL, outline=PANEL_OUTLINE, width=scale)
    return Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")


def draw_panel_text(draw: ImageDraw.ImageDraw, panel, text, scale: int) -> None:
    (title, summary), lines = text
    left, top, right, _ = panel
    centre = (left + right) / 2
    room = right - left - 2 * PANEL_TEXT_MARGIN
    centred_text(draw, centre * scale, (top + 10) * scale, title, 15 * scale, WINDOW_PURPLE)
    centred_text(draw, centre * scale, (top + 30) * scale, summary, 11 * scale, WINDOW_MUTED)
    y = APP_ICON_CENTER[1] + ICON_SIZE / 2 + CAPTION_GAP
    for line, size, colour in lines:
        assert font(size).getlength(line) <= room, f"{line!r} does not fit its panel"
        centred_text(draw, centre * scale, y * scale, line, size * scale, colour)
        y += size + 6
    assert y <= panel[3], "panel text runs past the panel"


def render_background(scale: int) -> Image.Image:
    width, height = (dimension * scale for dimension in WINDOW_SIZE)
    image = vertical_gradient((width, height), WINDOW_TOP, WINDOW_BOTTOM)
    image = draw_panels(image, scale)
    draw = ImageDraw.Draw(image)

    pixels = banner_pixels(WINDOW_PURPLE, WINDOW_GREEN)
    columns = len(BANNER_TOP)
    pixel = 6 * scale
    banner_width = columns * pixel
    # Touching pixels, like the terminal's half blocks; gaps break the letters.
    draw_pixels(draw, ((width - banner_width) / 2, 16 * scale), pixel, 0, pixels)

    centre = width / 2
    centred_text(draw, centre, 48 * scale, "Mole, avec une IA qui t'explique ton disque", 12 * scale, WINDOW_MUTED)
    centred_text(draw, centre, 70 * scale, "Choisis ta version · Choose your version", 17 * scale, WINDOW_TEXT)

    draw_panel_text(draw, APP_PANEL, APP_PANEL_TEXT, scale)
    draw_panel_text(draw, TERMINAL_PANEL, TERMINAL_PANEL_TEXT, scale)
    draw_arrow(draw, scale)

    help_first_line = max(APP_PANEL[3], TERMINAL_PANEL[3]) + 12
    centred_text(draw, centre, help_first_line * scale,
                 "macOS bloque l'ouverture ? Réglages › Confidentialité et sécurité › Ouvrir quand même",
                 11 * scale, WINDOW_MUTED)
    centred_text(draw, centre, (help_first_line + 15) * scale,
                 "Blocked by macOS? System Settings › Privacy & Security › Open Anyway",
                 11 * scale, WINDOW_MUTED)
    assert help_first_line + 15 + 13 <= VISIBLE_HEIGHT, "help text would fall under Finder's bars"
    return image


def icon_tile(size: int) -> Image.Image:
    """The dark rounded square both icons share."""
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
    return image


def draw_glyph_with_cursor(image: Image.Image, glyph, size: int, dy: float = 0) -> None:
    """A purple 5x7 glyph, then a green cursor on its baseline, like a prompt."""
    draw = ImageDraw.Draw(image)
    lit = [(column, row, PURPLE)
           for row, line in enumerate(glyph) for column, cell in enumerate(line) if cell == "#"]
    glyph_rows = len(glyph)
    cursor = [(6, glyph_rows - 1, GREEN), (7, glyph_rows - 1, GREEN)]
    glyph_columns = 8
    pixel = size * 72 / 1024
    origin = ((size - glyph_columns * pixel) / 2, (size - glyph_rows * pixel) / 2 + dy)
    draw_pixels(draw, origin, pixel, size * 6 / 1024, lit + cursor)


def render_icon(size: int = 1024) -> Image.Image:
    """The app's icon: S_."""
    image = icon_tile(size)
    draw_glyph_with_cursor(image, ICON_S, size)
    return image


def render_terminal_icon(size: int = 1024) -> Image.Image:
    """The Terminal installer's icon: a terminal window holding >_."""
    image = icon_tile(size)
    draw = ImageDraw.Draw(image)
    radius = size * 22 / 1024
    for index, colour in enumerate(WINDOW_DOTS):
        x = size * (210 + index * 70) / 1024
        y = size * 215 / 1024
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=colour)
    draw_glyph_with_cursor(image, ICON_PROMPT, size, dy=size * 40 / 1024)
    return image


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    render_icon().save(ASSETS / "icon.png")
    render_terminal_icon().save(ASSETS / "terminal-icon.png")
    render_background(1).save(ASSETS / "background.png")
    render_background(2).save(ASSETS / "background@2x.png")
    print(f"wrote {ASSETS}/icon.png, terminal-icon.png, background.png, background@2x.png")


if __name__ == "__main__":
    main()
