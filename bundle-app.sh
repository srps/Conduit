#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Conduit"
BUNDLE_ID="io.github.srps.Conduit"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Library/LaunchServices"

ARCH="$(uname -m)"
BUILD_CONFIG="debug"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --release) BUILD_CONFIG="release" ;;
    esac
done

BUILD_DIR="$SCRIPT_DIR/.build/${ARCH}-apple-macosx/$BUILD_CONFIG"

echo "Building ($BUILD_CONFIG, $ARCH)..."
cd "$SCRIPT_DIR"
# Do not set SWIFTCI_USE_LOCAL_DEPS here. That flag makes swift-nio depend on
# sibling path checkouts (../swift-atomics, etc.), which SPM treats as
# unstable and rejects when the root package uses a versioned swift-nio dep.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build --disable-sandbox -c release
else
    swift build --disable-sandbox
fi

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$CONTENTS/Resources" "$HELPERS"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp "$BUILD_DIR/ConduitHelper" "$HELPERS/$BUNDLE_ID.Helper"
cp "$BUILD_DIR/pm-dns" "$MACOS/pm-dns"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Conduit</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo "Signing..."
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Built: $APP_DIR"

if $INSTALL; then
    echo ""
    echo "Installing to /Applications..."
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Existing $APP_NAME process is still running; terminating it before replacing the app bundle..."
        pkill -x "$APP_NAME" 2>/dev/null || true
        for _ in {1..30}; do
            if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Could not terminate the running $APP_NAME process. Quit it from Activity Monitor and rerun this installer." >&2
        exit 1
    fi

    rm -rf "$INSTALL_DIR"
    cp -R "$APP_DIR" "$INSTALL_DIR"

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$INSTALL_DIR"
    fi

    echo "Installed to $INSTALL_DIR"
    echo ""
    echo "You can now:"
    echo "  - Find it in Spotlight (Cmd+Space, type Conduit)"
    echo "  - Open from Launchpad or Finder > Applications"
    echo "  - Pin it to the Dock by right-clicking its Dock icon > Options > Keep in Dock"
    echo ""
    echo "To install the privileged helper (eliminates repeated admin prompts):"
    echo "  sudo ./install-helper.sh"
    echo ""
    echo "First launch: if macOS shows \"cannot verify the developer\", right-click the"
    echo "app > Open, then click Open in the dialog. This is only needed once."
else
    echo ""
    echo "Bundled binaries:"
    echo "  Main app:  $MACOS/$APP_NAME"
    echo "  pm-dns:    $MACOS/pm-dns"
    echo "  Helper:    $HELPERS/$BUNDLE_ID.Helper"
    echo ""
    echo "Run with: open $APP_DIR"
    echo "Or directly: $MACOS/$APP_NAME"
    echo ""
    echo "To install as a regular app in /Applications:"
    echo "  ./bundle-app.sh --install"
    echo ""
    echo "For a release build:"
    echo "  ./bundle-app.sh --release --install"
fi
