#!/bin/bash
# Builds Tidybyte.app from the Swift package. Signing and notarization live in
# Scripts/package-release.sh. The version comes from the newest mac-v* tag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Configuration
CHANNEL=""
ARCH_FLAGS=()
if [ "${ARCH_ARM64:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64)
fi
while [ $# -gt 0 ]; do
    case "$1" in
        direct|app-store)
            if [ -n "$CHANNEL" ]; then
                echo "Usage: $0 [direct|app-store] [--arch arm64]" >&2
                exit 2
            fi
            CHANNEL="$1"
            shift
            ;;
        --arch)
            if [ $# -lt 2 ]; then
                echo "Usage: $0 [direct|app-store] [--arch arm64]" >&2
                exit 2
            fi
            ARCH_FLAGS=(--arch "$2")
            shift 2
            ;;
        --arch=*)
            ARCH_FLAGS=(--arch "${1#--arch=}")
            shift
            ;;
        *)
            echo "Usage: $0 [direct|app-store] [--arch arm64]" >&2
            exit 2
            ;;
    esac
done
CHANNEL="${CHANNEL:-direct}"

SWIFT_FLAGS=()
# APP_STORE=1 also drops the Sparkle dependency from Package.swift. It needs its
# own scratch path: a shared .build keeps the direct build's link plan (Sparkle).
if [ "$CHANNEL" = app-store ]; then
    SWIFT_FLAGS=(-Xswiftc -DAPP_STORE --scratch-path .build/app-store-scratch)
    export APP_STORE=1
fi
APP_NAME="Tidybyte"
MCP_NAME="tidybyte-mcp"
BUNDLE_ID="com.sakshammittal.tidybyte"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$CHANNEL/$APP_NAME.app"
if [ "$CHANNEL" = direct ]; then APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"; fi
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Version from the newest mac-v* tag (iOS releases use plain v* tags in the
# mono repo). Falls back to 1.0.0 outside a tagged repo.
APP_VERSION="$(git describe --tags --abbrev=0 --match 'mac-v*' 2>/dev/null || echo 'mac-v1.0.0')"
APP_VERSION="${APP_VERSION#mac-v}"
# The commit count only grows on main. A release built on a branch that is later
# squash-merged must pass BUILD_NUMBER (main's count) so the next release from
# main still gets a higher number and Sparkle offers it.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo '1')}"

echo "Building $APP_NAME ($CHANNEL)..."

# Build the Swift package
swift build -c release --product "$APP_NAME" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
if [ "$CHANNEL" = direct ]; then
    swift build -c release --product "$MCP_NAME" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
fi
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p "$MACOS_DIR"
# Rebuild generated resources so removed fonts and old target bundles cannot ship.
rm -rf "$RESOURCES_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME.next"
mv -f "$MACOS_DIR/$APP_NAME.next" "$MACOS_DIR/$APP_NAME"

# Direct builds only: the MCP tool, Sparkle, and the autoscan agent. The App
# Store channel is sandboxed and must not carry them.
rm -rf "$CONTENTS/Frameworks" "$CONTENTS/Library"
if [ "$CHANNEL" = direct ]; then
    cp "$BIN_DIR/$MCP_NAME" "$MACOS_DIR/$MCP_NAME"
    # SwiftPM places binary-target frameworks like Sparkle in the bin path.
    # Fail loudly instead of silently shipping a bundle that dies on launch
    # with a missing dynamic library.
    if [ ! -d "$BIN_DIR/Sparkle.framework" ]; then
        echo "error: $BIN_DIR/Sparkle.framework not found; the direct build links Sparkle and cannot run without it" >&2
        exit 1
    fi
    mkdir -p "$CONTENTS/Frameworks"
    ditto "$BIN_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
    # Strip development headers and modulemaps before signing or packaging.
    rm -rf \
        "$CONTENTS/Frameworks/Sparkle.framework/Headers" \
        "$CONTENTS/Frameworks/Sparkle.framework/PrivateHeaders" \
        "$CONTENTS/Frameworks/Sparkle.framework/Modules" \
        "$CONTENTS/Frameworks/Sparkle.framework"/Versions/*/Headers \
        "$CONTENTS/Frameworks/Sparkle.framework"/Versions/*/PrivateHeaders \
        "$CONTENTS/Frameworks/Sparkle.framework"/Versions/*/Modules
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
    # Autoscan agent registered at runtime through SMAppService.agent(plistName:).
    mkdir -p "$CONTENTS/Library/LaunchAgents"
    cp "Configuration/$BUNDLE_ID.autoscan.plist" "$CONTENTS/Library/LaunchAgents/"
else
    rm -f "$MACOS_DIR/$MCP_NAME"
fi

cp Configuration/PrivacyInfo.xcprivacy "$RESOURCES_DIR/"

# Copy the SPM resource bundles (Core + AppKit) into Contents/Resources and
# merge all *.lproj tables into Contents/Resources/*.lproj so Bundle.main,
# String(localized:), SwiftUI labels, and L10n all see every language.
merge_plist_tables() {
    python3 - "$1" "$2" << 'PYEOF'
import os, plistlib, subprocess, sys

src, dst = sys.argv[1], sys.argv[2]

def load_table(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    xml = subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", path])
    data = plistlib.loads(xml)
    return data if isinstance(data, dict) else {}

merged = load_table(dst)
merged.update(load_table(src))
with open(dst, "wb") as f:
    plistlib.dump(merged, f, fmt=plistlib.FMT_BINARY)
PYEOF
}

for bundle in "$BIN_DIR"/"${APP_NAME}"_*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES_DIR/"
        for locale in "$bundle"/Contents/Resources/*.lproj "$bundle"/*.lproj; do
            if [ -d "$locale" ]; then
                locale_name="$(basename "$locale")"
                dest_locale="$RESOURCES_DIR/$locale_name"
                mkdir -p "$dest_locale"
                for item in "$locale"/*; do
                    [ -e "$item" ] || continue
                    item_name="$(basename "$item")"
                    dest_item="$dest_locale/$item_name"
                    if [ -e "$dest_item" ] && { [[ "$item_name" == *.strings ]] || [[ "$item_name" == *.stringsdict ]]; }; then
                        merge_plist_tables "$item" "$dest_item"
                    else
                        cp -R "$item" "$dest_item"
                    fi
                done
            fi
        done
    fi
done

# Compile localized InfoPlist.strings (permission prompts, display name) into
# Contents/Resources/<lang>.lproj/InfoPlist.strings.
if [ -f "Configuration/InfoPlist.xcstrings" ]; then
    if ! xcrun --find xcstringstool >/dev/null 2>&1; then
        echo "error: xcstringstool not found; Xcode is required to compile Configuration/InfoPlist.xcstrings" >&2
        exit 1
    fi
    xcrun xcstringstool compile Configuration/InfoPlist.xcstrings \
        --output-directory "$RESOURCES_DIR" \
        --serialization-format binary
fi

# App icon: compile the Icon Composer bundle (Liquid Glass layers plus a
# legacy .icns) into Assets.car.
if ! xcrun --find actool >/dev/null 2>&1; then
    echo "error: actool not found; Xcode is required to compile Configuration/Tidybyte.icon" >&2
    exit 1
fi
if [ ! -d "Configuration/Tidybyte.icon" ]; then
    echo "error: Configuration/Tidybyte.icon not found" >&2
    exit 1
fi
xcrun actool Configuration/Tidybyte.icon --compile "$RESOURCES_DIR" --app-icon Tidybyte \
    --platform macosx --minimum-deployment-target 26.0 --target-device mac \
    --output-partial-info-plist "$BUILD_DIR/icon-partial.plist" >/dev/null

# Update feed and signing key come from the release environment.
SPARKLE_KEYS=""
if [ "$CHANNEL" = direct ] && [ -z "${SPARKLE_PUBLIC_KEY:-}" ] && [ -z "${NO_SPARKLE:-}" ]; then
    # Without the key the updater silently disables itself (main.swift checks
    # SUPublicEDKey) — a shipped DMG that can never update, indistinguishable
    # from a healthy build. CI smoke builds opt out explicitly with NO_SPARKLE=1.
    echo "error: direct channel without SPARKLE_PUBLIC_KEY produces an app that can never self-update." >&2
    echo "       set SPARKLE_PUBLIC_KEY (release) or NO_SPARKLE=1 (local/CI smoke builds) to continue." >&2
    exit 1
fi
if [ "$CHANNEL" = direct ] && [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
    FEED="${SPARKLE_FEED_URL:-https://tidybyte.yord.si/mac/appcast.xml}"
    SPARKLE_KEYS="
    <key>SUFeedURL</key>
    <string>$FEED</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
fi

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Tidybyte</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>Tidybyte</string>
    <key>CFBundleIconName</key>
    <string>Tidybyte</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Review local photos and videos. Confirmed Photos changes can sync to iCloud and are recoverable in Recently Deleted.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Find large, old, and duplicate files on your Desktop. Nothing changes until you approve it.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Find large, old, and duplicate files in Documents. Nothing changes until you approve it.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Find old installers, large files, and duplicates in Downloads. Nothing changes until you approve it.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Scan external drives that you choose. Nothing changes until you approve it.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>Create verified replacement photos and videos before removing originals.</string>
    <key>CFBundleURLTypes</key>
    <array><dict><key>CFBundleURLName</key><string>Tidybyte navigation</string>
    <key>CFBundleURLSchemes</key><array><string>tidybyte</string></array></dict></array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Saksham Mittal. All rights reserved.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>${SPARKLE_KEYS}
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

if [ "$CHANNEL" = app-store ]; then
    codesign --force --sign - --entitlements Configuration/AppStore.entitlements "$APP_BUNDLE"
else
    FRAMEWORK="$CONTENTS/Frameworks/Sparkle.framework"
    if [ -d "$FRAMEWORK" ]; then
        for ver in "$FRAMEWORK"/Versions/*; do
            [ -d "$ver" ] && [ ! -L "$ver" ] || continue
            [ -d "$ver/XPCServices/Installer.xpc" ] && codesign --force --options runtime --sign - "$ver/XPCServices/Installer.xpc"
            [ -d "$ver/XPCServices/Downloader.xpc" ] && codesign --force --options runtime --preserve-metadata=entitlements --sign - "$ver/XPCServices/Downloader.xpc"
            [ -e "$ver/Autoupdate" ] && codesign --force --options runtime --sign - "$ver/Autoupdate"
            [ -d "$ver/Updater.app" ] && codesign --force --options runtime --sign - "$ver/Updater.app"
        done
        codesign --force --options runtime --sign - "$FRAMEWORK"
    fi
    codesign --force --options runtime --identifier "$BUNDLE_ID.mcp" --sign - "$MACOS_DIR/$MCP_NAME"
    codesign --force --options runtime --sign - --entitlements Configuration/Direct.entitlements "$APP_BUNDLE"
fi

echo "App bundle created at: $APP_BUNDLE"
echo "You can now run: open $APP_BUNDLE"
