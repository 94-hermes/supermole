#!/usr/bin/env bats
# Builds Installer-Supermole.dmg for real (about a minute: Supermole.app is
# compiled for both architectures). scripts/test.sh runs this file only when
# dmgbuild is on PATH; CI's Validation job installs it.

load helpers/common

setup_file() {
    mole_test_setup_home dmg-build-home
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    DMG_MOUNT="$HOME/mnt"
    DMG_ATTACHED=0
}

teardown() {
    # A volume left mounted would also stop teardown_file removing HOME.
    if [[ $DMG_ATTACHED -eq 1 ]]; then
        /usr/bin/hdiutil detach "$DMG_MOUNT" -force -quiet
    fi
}

@test "build_installer_dmg.sh puts a signed universal Supermole.app beside Applications in a valid dmg" {
    local out="$HOME/out"
    run env -u SUPERMOLE_SIGN_IDENTITY -u SUPERMOLE_NOTARY_KEY \
        "$PROJECT_ROOT/scripts/build_installer_dmg.sh" "$out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    mkdir -p "$DMG_MOUNT"
    run /usr/bin/hdiutil attach -nobrowse -readonly -noautoopen \
        -mountpoint "$DMG_MOUNT" "$out/Installer-Supermole.dmg"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    DMG_ATTACHED=1
    local app="$DMG_MOUNT/Supermole.app"
    local executable="$app/Contents/MacOS/Supermole"
    local plist="$app/Contents/Info.plist"
    local version
    version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$PROJECT_ROOT/mole")

    # The drag-to-install layout.
    [ "$(readlink "$DMG_MOUNT/Applications")" = "/Applications" ]

    # Unsigned apps read as "damaged"; ad hoc keeps macOS's Open Anyway path.
    run /usr/bin/codesign --verify --deep --strict "$app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run /usr/bin/codesign -dv "$app"
    [[ "$output" == *"Signature=adhoc"* ]] || return 1
    [[ "$output" == *"Identifier=com.airkul.supermole"* ]] || return 1

    run /usr/bin/plutil -extract CFBundleShortVersionString raw "$plist"
    [ "$output" = "$version" ]
    run /usr/bin/plutil -extract CFBundleExecutable raw "$plist"
    [ "$output" = "Supermole" ]
    run /usr/bin/plutil -extract LSMinimumSystemVersion raw "$plist"
    [ "$output" = "26.0" ]
    [ -s "$app/Contents/Resources/AppIcon.icns" ]
    [ -s "$app/Contents/Resources/fr.lproj/Localizable.strings" ]
    [ -s "$app/Contents/Resources/fr.lproj/MoleTerms.strings" ]
    [ -e "$app/Contents/Resources/en.lproj/Localizable.strings" ]

    # Both slices must load on macOS 26, the app's floor (Liquid Glass).
    run /usr/bin/lipo -archs "$executable"
    [[ " $output " == *" x86_64 "* && " $output " == *" arm64 "* ]] || { echo "$output"; return 1; }
    local arch
    for arch in x86_64 arm64; do
        /usr/bin/lipo -thin "$arch" "$executable" -output "$HOME/supermole-$arch"
        run "$PROJECT_ROOT/scripts/check_release_minos.sh" --max 26.0 "$HOME/supermole-$arch"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    done
    [ -s "$DMG_MOUNT/.background.tiff" ]
    [ -s "$DMG_MOUNT/.VolumeIcon.icns" ]
}
