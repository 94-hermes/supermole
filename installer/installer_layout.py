"""Layout of the installer dmg window, in points.

render_assets.py draws the background around these values and dmg_settings.py
gives them to dmgbuild, so the icons land where the art expects them: the app
on the left, an arrow, the Applications shortcut on the right. Finder's title
bar takes about 32 pt of the window height and its path bar, when the user
shows it, another 28, so the art keeps to the top VISIBLE_HEIGHT.
"""

WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (640, 420)
VISIBLE_HEIGHT = 360
ICON_SIZE = 128
APP_ICON_CENTER = (170, 180)
APPLICATIONS_ICON_CENTER = (470, 180)
