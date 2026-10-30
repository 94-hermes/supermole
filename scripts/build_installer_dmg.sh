#!/bin/bash
# Build Installer-Supermole.dmg: an app whose executable (cmd/installer-launcher)
# opens Terminal on installer/install-supermole.command, with the fork's icon,
# inside a dmg laid out by dmgbuild (installer/dmg_settings.py).
#
# Usage: scripts/build_installer_dmg.sh <output-dir>
#
# Without signing credentials the app is signed ad hoc: an unsigned app reads
# as "damaged" on Apple silicon, while an ad hoc one gets macOS's "Open Anyway"
# path. With them it is signed for distribution and the dmg is notarized and
# stapled:
#   SUPERMOLE_SIGN_IDENTITY   "Developer ID Application: <name> (<team>)"
#   SUPERMOLE_NOTARY_KEY      path to an App Store Connect API key (.p8)
#   SUPERMOLE_NOTARY_KEY_ID   its key id
#   SUPERMOLE_NOTARY_ISSUER   its issuer id
# Needs Go and dmgbuild on PATH (scripts/install_dmgbuild.sh installs dmgbuild).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_DIR="$PROJECT_ROOT/installer"
INSTALLER_APP_NAME="Installer Supermole"
INSTALLER_EXECUTABLE="installer-launcher"
INSTALLER_ICON_NAME="AppIcon"
INSTALLER_DMG_NAME="Installer-Supermole.dmg"
INSTALLER_VOLUME_NAME="Supermole"
INSTALLER_BUNDLE_ID="com.airkul.supermole.installer"
INSTALLER_MIN_MACOS="12.0"
INSTALLER_GO_ARCHES=(arm64 amd64)
INSTALLER_ICON_SIZES=(16 32 128 256 512)

installer_version() {
    sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole" | head -n 1
}

# One universal launcher at $2. Each slice is checked against the minimum
# macOS before lipo joins them, since check_release_minos.sh reads only the
# first slice of a universal file.
build_launcher() {
    local work_dir="$1" output="$2" arch
    local slices=()
    for arch in "${INSTALLER_GO_ARCHES[@]}"; do
        (cd "$PROJECT_ROOT" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w" -o "$work_dir/launcher-$arch" ./cmd/installer-launcher)
        "$PROJECT_ROOT/scripts/check_release_minos.sh" --max "$INSTALLER_MIN_MACOS" "$work_dir/launcher-$arch"
        slices+=("$work_dir/launcher-$arch")
    done
    /usr/bin/lipo -create "${slices[@]}" -output "$output"
}

build_icon() {
    local work_dir="$1" output="$2" size
    local iconset="$work_dir/$INSTALLER_ICON_NAME.iconset"
    mkdir -p "$iconset"
    for size in "${INSTALLER_ICON_SIZES[@]}"; do
        /usr/bin/sips -z "$size" "$size" "$INSTALLER_DIR/assets/icon.png" \
            --out "$iconset/icon_${size}x${size}.png" > /dev/null
        /usr/bin/sips -z $((size * 2)) $((size * 2)) "$INSTALLER_DIR/assets/icon.png" \
            --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
    done
    /usr/bin/iconutil -c icns "$iconset" -o "$output"
}

write_info_plist() {
    local plist="$1" version="$2"
    # LSUIElement: the launcher exits as soon as Terminal opens, so it never
    # needs a Dock icon.
    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>fr</string>
	<key>CFBundleExecutable</key>
	<string>${INSTALLER_EXECUTABLE}</string>
	<key>CFBundleIconFile</key>
	<string>${INSTALLER_ICON_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${INSTALLER_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${INSTALLER_APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${INSTALLER_MIN_MACOS}</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF
    /usr/bin/plutil -lint "$plist" > /dev/null
}

# The app, signed, at "$1/$INSTALLER_APP_NAME.app".
build_installer_app() {
    local work_dir="$1"
    local app="$work_dir/$INSTALLER_APP_NAME.app"
    local version
    version="$(installer_version)"
    [[ -n "$version" ]] || {
        echo "Could not read VERSION from $PROJECT_ROOT/mole" >&2
        return 1
    }

    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    build_launcher "$work_dir" "$app/Contents/MacOS/$INSTALLER_EXECUTABLE"
    build_icon "$work_dir" "$app/Contents/Resources/$INSTALLER_ICON_NAME.icns"
    cp "$INSTALLER_DIR/install-supermole.command" "$app/Contents/Resources/install-supermole.command"
    chmod 755 "$app/Contents/Resources/install-supermole.command"
    write_info_plist "$app/Contents/Info.plist" "$version"

    if [[ -n "${SUPERMOLE_SIGN_IDENTITY:-}" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp \
            --sign "$SUPERMOLE_SIGN_IDENTITY" "$app"
    else
        /usr/bin/codesign --force --sign - "$app"
    fi
    /usr/bin/codesign --verify --deep --strict "$app"
}

notarization_configured() {
    [[ -n "${SUPERMOLE_SIGN_IDENTITY:-}" && -n "${SUPERMOLE_NOTARY_KEY:-}" &&
        -n "${SUPERMOLE_NOTARY_KEY_ID:-}" && -n "${SUPERMOLE_NOTARY_ISSUER:-}" ]]
}

build_installer_dmg() {
    local output_dir="$1" tool
    for tool in go dmgbuild; do
        command -v "$tool" > /dev/null || {
            echo "$tool not found on PATH; scripts/install_dmgbuild.sh installs dmgbuild" >&2
            return 1
        }
    done
    local work_dir
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/supermole-installer.XXXXXX")"
    # shellcheck disable=SC2064 # Expand now: work_dir is local to this call.
    trap "rm -rf '$work_dir'" EXIT # SAFE: exact mktemp-created build directory

    build_installer_app "$work_dir"

    /usr/bin/tiffutil -cathidpicheck "$INSTALLER_DIR/assets/background.png" \
        "$INSTALLER_DIR/assets/background@2x.png" -out "$work_dir/background.tiff" > /dev/null

    mkdir -p "$output_dir"
    local dmg="$output_dir/$INSTALLER_DMG_NAME"
    rm -f "$dmg" # SAFE: the exact dmg this build is about to write
    PYTHONPATH="$INSTALLER_DIR" dmgbuild \
        -s "$INSTALLER_DIR/dmg_settings.py" \
        -D app="$work_dir/$INSTALLER_APP_NAME.app" \
        -D background="$work_dir/background.tiff" \
        -D icon="$work_dir/$INSTALLER_APP_NAME.app/Contents/Resources/$INSTALLER_ICON_NAME.icns" \
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
