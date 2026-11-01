#!/bin/bash
# Build Installer-Supermole.dmg, which offers two versions side by side
# (installer/dmg_settings.py lays the window out with dmgbuild):
#   - Supermole.app, the SwiftUI app in app/ that installs and drives `mo`,
#     to drag onto the Applications shortcut beside it (macOS 26 or later);
#   - Supermole Terminal.app, whose executable (cmd/installer-launcher) opens
#     Terminal on installer/install-supermole.command for the `mo` command
#     alone (macOS 12 or later).
#
# Usage: scripts/build_installer_dmg.sh <output-dir>
#
# Without signing credentials both apps are signed ad hoc: an unsigned app
# reads as "damaged" on Apple silicon, while an ad hoc one gets macOS's "Open
# Anyway" path. With them they are signed for distribution and the dmg is
# notarized and stapled:
#   SUPERMOLE_SIGN_IDENTITY   "Developer ID Application: <name> (<team>)"
#   SUPERMOLE_NOTARY_KEY      path to an App Store Connect API key (.p8)
#   SUPERMOLE_NOTARY_KEY_ID   its key id
#   SUPERMOLE_NOTARY_ISSUER   its issuer id
# Needs Swift (Xcode), Go and dmgbuild on PATH (scripts/install_dmgbuild.sh
# installs dmgbuild).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_DIR="$PROJECT_ROOT/installer"
APP_PACKAGE_DIR="$PROJECT_ROOT/app"
INSTALLER_DMG_NAME="Installer-Supermole.dmg"
INSTALLER_VOLUME_NAME="Supermole"
INSTALLER_ICON_NAME="AppIcon"
INSTALLER_ICON_SIZES=(16 32 128 256 512)

# The app.
APP_NAME="Supermole"
APP_EXECUTABLE="Supermole"
APP_BUNDLE_ID="com.airkul.supermole"
APP_ICON_SOURCE="$INSTALLER_DIR/assets/icon.png"
# Liquid Glass needs macOS 26; mo itself still runs on macOS 12.
APP_MIN_MACOS="26.0"
APP_SWIFT_ARCHES=(arm64 x86_64)

# The Terminal version's installer.
TERMINAL_NAME="Supermole Terminal"
TERMINAL_EXECUTABLE="installer-launcher"
TERMINAL_BUNDLE_ID="com.airkul.supermole.installer"
TERMINAL_ICON_SOURCE="$INSTALLER_DIR/assets/terminal-icon.png"
TERMINAL_SCRIPT="install-supermole.command"
TERMINAL_MIN_MACOS="12.0"
TERMINAL_GO_ARCHES=(arm64 amd64)

installer_version() {
    sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -n 1
}

# The app's universal executable at $2. Each slice is checked against the
# minimum macOS before lipo joins them, since check_release_minos.sh reads
# only the first slice of a universal file, and the compiler's list of
# displayed text is checked against the translations.
build_app_executable() {
    local work_dir="$1" output="$2" arch bin_dir
    local localized_strings="$work_dir/localized-strings"
    local slices=()
    mkdir -p "$localized_strings"
    for arch in "${APP_SWIFT_ARCHES[@]}"; do
        local swift_args=(-c release --package-path "$APP_PACKAGE_DIR"
            --scratch-path "$work_dir/swift-$arch"
            --triple "${arch}-apple-macosx${APP_MIN_MACOS}"
            --product "$APP_EXECUTABLE")
        swift build "${swift_args[@]}" \
            -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$localized_strings"
        bin_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
        "$PROJECT_ROOT/scripts/check_release_minos.sh" --max "$APP_MIN_MACOS" "$bin_dir/$APP_EXECUTABLE"
        slices+=("$bin_dir/$APP_EXECUTABLE")
    done
    python3 "$PROJECT_ROOT/scripts/check_app_localization.py" "$localized_strings" "$APP_PACKAGE_DIR/Resources"
    /usr/bin/lipo -create "${slices[@]}" -output "$output"
}

# The Terminal installer's universal launcher at $2, each slice checked
# against its minimum macOS before lipo, like the app's.
build_launcher() {
    local work_dir="$1" output="$2" arch
    local slices=()
    for arch in "${TERMINAL_GO_ARCHES[@]}"; do
        (cd "$PROJECT_ROOT" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w" -o "$work_dir/launcher-$arch" ./cmd/installer-launcher)
        "$PROJECT_ROOT/scripts/check_release_minos.sh" --max "$TERMINAL_MIN_MACOS" "$work_dir/launcher-$arch"
        slices+=("$work_dir/launcher-$arch")
    done
    /usr/bin/lipo -create "${slices[@]}" -output "$output"
}

# An .icns at $3 from the 1024 px PNG $2.
build_icon() {
    local work_dir="$1" source="$2" output="$3" size
    local iconset
    iconset="$(mktemp -d "$work_dir/icon.XXXXXX")/$INSTALLER_ICON_NAME.iconset"
    mkdir -p "$iconset"
    for size in "${INSTALLER_ICON_SIZES[@]}"; do
        /usr/bin/sips -z "$size" "$size" "$source" \
            --out "$iconset/icon_${size}x${size}.png" > /dev/null
        /usr/bin/sips -z $((size * 2)) $((size * 2)) "$source" \
            --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
    done
    /usr/bin/iconutil -c icns "$iconset" -o "$output"
}

# Info.plist at $1 for an app: version, name, executable, bundle id and
# minimum macOS. Each app then adds the keys only it needs with plutil.
write_info_plist() {
    local plist="$1" version="$2" name="$3" executable="$4" bundle_id="$5" min_macos="$6"
    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${executable}</string>
	<key>CFBundleIconFile</key>
	<string>${INSTALLER_ICON_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${name}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${min_macos}</string>
</dict>
</plist>
EOF
    /usr/bin/plutil -lint "$plist" > /dev/null
}

# Signs and verifies an app: Developer ID with the hardened runtime when an
# identity is configured, ad hoc otherwise.
sign_app() {
    local app="$1"
    if [[ -n "${SUPERMOLE_SIGN_IDENTITY:-}" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp \
            --sign "$SUPERMOLE_SIGN_IDENTITY" "$app"
    else
        /usr/bin/codesign --force --sign - "$app"
    fi
    /usr/bin/codesign --verify --deep --strict "$app"
}

# The app, signed, at "$1/$APP_NAME.app".
build_supermole_app() {
    local work_dir="$1" version="$2"
    local app="$work_dir/$APP_NAME.app" localization
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    build_app_executable "$work_dir" "$app/Contents/MacOS/$APP_EXECUTABLE"
    build_icon "$work_dir" "$APP_ICON_SOURCE" "$app/Contents/Resources/$INSTALLER_ICON_NAME.icns"
    for localization in "$APP_PACKAGE_DIR"/Resources/*.lproj; do
        cp -R "$localization" "$app/Contents/Resources/"
    done
    local plist="$app/Contents/Info.plist"
    write_info_plist "$plist" "$version" "$APP_NAME" "$APP_EXECUTABLE" "$APP_BUNDLE_ID" "$APP_MIN_MACOS"
    /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$plist"
    /usr/bin/plutil -insert CFBundleLocalizations -json '["en","fr"]' "$plist"
    /usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.utilities "$plist"
    /usr/bin/plutil -insert NSHighResolutionCapable -bool true "$plist"
    sign_app "$app"
}

# The Terminal installer, signed, at "$1/$TERMINAL_NAME.app". LSUIElement:
# the launcher exits as soon as Terminal opens, so it never needs a Dock icon.
build_terminal_app() {
    local work_dir="$1" version="$2"
    local app="$work_dir/$TERMINAL_NAME.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    build_launcher "$work_dir" "$app/Contents/MacOS/$TERMINAL_EXECUTABLE"
    build_icon "$work_dir" "$TERMINAL_ICON_SOURCE" "$app/Contents/Resources/$INSTALLER_ICON_NAME.icns"
    cp "$INSTALLER_DIR/$TERMINAL_SCRIPT" "$app/Contents/Resources/$TERMINAL_SCRIPT"
    chmod 755 "$app/Contents/Resources/$TERMINAL_SCRIPT"
    local plist="$app/Contents/Info.plist"
    write_info_plist "$plist" "$version" "$TERMINAL_NAME" "$TERMINAL_EXECUTABLE" "$TERMINAL_BUNDLE_ID" "$TERMINAL_MIN_MACOS"
    /usr/bin/plutil -insert CFBundleDevelopmentRegion -string fr "$plist"
    /usr/bin/plutil -insert LSUIElement -bool true "$plist"
    sign_app "$app"
}

notarization_configured() {
    [[ -n "${SUPERMOLE_SIGN_IDENTITY:-}" && -n "${SUPERMOLE_NOTARY_KEY:-}" &&
        -n "${SUPERMOLE_NOTARY_KEY_ID:-}" && -n "${SUPERMOLE_NOTARY_ISSUER:-}" ]]
}

build_installer_dmg() {
    local output_dir="$1" tool
    for tool in swift go python3 dmgbuild; do
        command -v "$tool" > /dev/null || {
            echo "$tool not found on PATH; scripts/install_dmgbuild.sh installs dmgbuild" >&2
            return 1
        }
    done
    local version
    version="$(installer_version)"
    [[ -n "$version" ]] || {
        echo "Could not read VERSION from $PROJECT_ROOT/mole" >&2
        return 1
    }
    local work_dir
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/supermole-installer.XXXXXX")"
    # shellcheck disable=SC2064 # Expand now: work_dir is local to this call.
    trap "rm -rf '$work_dir'" EXIT # SAFE: exact mktemp-created build directory

    build_supermole_app "$work_dir" "$version"
    build_terminal_app "$work_dir" "$version"

    /usr/bin/tiffutil -cathidpicheck "$INSTALLER_DIR/assets/background.png" \
        "$INSTALLER_DIR/assets/background@2x.png" -out "$work_dir/background.tiff" > /dev/null

    mkdir -p "$output_dir"
    local dmg="$output_dir/$INSTALLER_DMG_NAME"
    rm -f "$dmg" # SAFE: the exact dmg this build is about to write
    PYTHONPATH="$INSTALLER_DIR" dmgbuild \
        -s "$INSTALLER_DIR/dmg_settings.py" \
        -D app="$work_dir/$APP_NAME.app" \
        -D terminal_app="$work_dir/$TERMINAL_NAME.app" \
        -D background="$work_dir/background.tiff" \
        -D icon="$work_dir/$APP_NAME.app/Contents/Resources/$INSTALLER_ICON_NAME.icns" \
        "$INSTALLER_VOLUME_NAME" "$dmg"

    if notarization_configured; then
        /usr/bin/codesign --force --timestamp --sign "$SUPERMOLE_SIGN_IDENTITY" "$dmg"
        /usr/bin/xcrun notarytool submit "$dmg" --wait \
            --key "$SUPERMOLE_NOTARY_KEY" --key-id "$SUPERMOLE_NOTARY_KEY_ID" \
            --issuer "$SUPERMOLE_NOTARY_ISSUER"
        /usr/bin/xcrun stapler staple "$dmg"
    fi
    /usr/bin/hdiutil verify "$dmg" > /dev/null
    echo "Built $dmg"
}

[[ $# -eq 1 ]] || {
    echo "Usage: $0 <output-dir>" >&2
    exit 2
}
build_installer_dmg "$1"
