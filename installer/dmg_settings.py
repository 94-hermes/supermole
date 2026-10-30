# dmgbuild layout of Installer-Supermole.dmg, read by
# scripts/build_installer_dmg.sh. The build passes three paths through -D:
# app (the built Supermole.app), background (a HiDPI tiff) and icon (the
# volume icon), and puts this folder on PYTHONPATH for installer_layout.
import os.path

from installer_layout import (
    APP_ICON_CENTER,
    APPLICATIONS_ICON_CENTER,
    ICON_SIZE,
    WINDOW_ORIGIN,
    WINDOW_SIZE,
)

application = defines["app"]  # noqa: F821 - provided by dmgbuild
APPLICATIONS_LINK = "Applications"

format = "UDZO"
files = [application]
symlinks = {APPLICATIONS_LINK: "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = (WINDOW_ORIGIN, WINDOW_SIZE)
default_view = "icon-view"
icon_size = ICON_SIZE
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(application): APP_ICON_CENTER,
    APPLICATIONS_LINK: APPLICATIONS_ICON_CENTER,
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
