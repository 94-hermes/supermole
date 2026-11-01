"""Layout of the installer dmg window, in points.

The window offers two versions side by side. The left panel holds the app, an
arrow and the Applications shortcut (drag to install); the right panel holds
the Terminal installer (double-click to install the mo command).
render_assets.py draws the background around these values and dmg_settings.py
gives the icon positions to dmgbuild, so the icons land in their panels.
Finder's title bar takes about 32 pt of the window height and its path bar,
when the user shows it, another 28, so the art keeps to the top VISIBLE_HEIGHT.
"""

WINDOW_ORIGIN = (160, 110)
WINDOW_SIZE = (860, 480)
VISIBLE_HEIGHT = 420
ICON_SIZE = 128

# Panels as (left, top, right, bottom).
APP_PANEL = (24, 104, 516, 372)
TERMINAL_PANEL = (540, 104, 836, 372)

APP_ICON_CENTER = (150, 216)
APPLICATIONS_ICON_CENTER = (390, 216)
TERMINAL_ICON_CENTER = (688, 216)
