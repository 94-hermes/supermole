"""Layout of the installer dmg window, in points.

render_assets.py draws the background around these values and dmg_settings.py
gives them to dmgbuild, so the icon lands where the art expects it. Finder's
title bar takes about 32 pt of the window height and its path bar, when the
user shows it, another 28, so the art keeps to the top VISIBLE_HEIGHT.
"""

WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (640, 400)
VISIBLE_HEIGHT = 340
ICON_CENTER = (320, 180)
ICON_SIZE = 128
