#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Conduit"
APP_VERSION="$(cat "$SCRIPT_DIR/VERSION")"
if [[ ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "VERSION must contain a version such as 0.3.4." >&2
    exit 1
fi
BUNDLE_ID="io.github.srps.Conduit"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Library/LaunchServices"
UPDATER_NAME="Conduit Updater"
UPDATER_ID="$BUNDLE_ID.Updater"
# The update feed (#111): each published release attaches its own
# appcast.xml, and "latest" resolves to the newest published one.
FEED_URL="https://github.com/srps/Conduit/releases/latest/download/appcast.xml"

ARCH="$(uname -m)"
BUILD_CONFIG="debug"
INSTALL=false
SHARE=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --release) BUILD_CONFIG="release" ;;
        --share) SHARE=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if $SHARE; then
    if $INSTALL; then
        echo "--share cannot be combined with --install." >&2
        exit 1
    fi
    BUILD_CONFIG="release"
    APP_DIR="$SCRIPT_DIR/.build/share/$APP_NAME.app"
    CONTENTS="$APP_DIR/Contents"
    MACOS="$CONTENTS/MacOS"
    HELPERS="$CONTENTS/Library/LaunchServices"
fi
UPDATER_APP="$CONTENTS/Helpers/$UPDATER_NAME.app"

echo "Building ($BUILD_CONFIG, $ARCH)..."
cd "$SCRIPT_DIR"
# Do not set SWIFTCI_USE_LOCAL_DEPS here. That flag makes swift-nio depend on
# sibling path checkouts (../swift-atomics, etc.), which SPM treats as
# unstable and rejects when the root package uses a versioned swift-nio dep.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --disable-sandbox -c "$BUILD_CONFIG"

# Ask SwiftPM where it put the products rather than assuming
# `.build/<arch>-apple-macosx/<config>`. Xcode 27's build system writes to
# `.build/out/Products/<Config>` and leaves the old directory untouched, so
# the assumed path kept a binary from 2026-09-06 that every install since
# shipped, helper included, while the build above succeeded.
BUILD_DIR="$(swift build --disable-sandbox -c "$BUILD_CONFIG" --show-bin-path)"
for product in "$APP_NAME" ConduitHelper pm-dns ConduitUpdater; do
    if [[ ! -x "$BUILD_DIR/$product" ]]; then
        echo "Built product missing: $BUILD_DIR/$product" >&2
        exit 1
    fi
done
if [[ ! -d "$BUILD_DIR/Sparkle.framework" ]]; then
    echo "Built product missing: $BUILD_DIR/Sparkle.framework" >&2
    exit 1
fi
echo "Products: $BUILD_DIR"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$CONTENTS/Resources" "$HELPERS"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp "$BUILD_DIR/ConduitHelper" "$HELPERS/$BUNDLE_ID.Helper"
cp "$BUILD_DIR/pm-dns" "$MACOS/pm-dns"

# The updater (#111): Sparkle runs in this nested app, never in Conduit; see
# UpdaterContract.swift and Resources/ConduitUpdater.entitlements.
mkdir -p "$UPDATER_APP/Contents/MacOS" "$UPDATER_APP/Contents/Frameworks"
cp "$BUILD_DIR/ConduitUpdater" "$UPDATER_APP/Contents/MacOS/$UPDATER_NAME"
ditto "$BUILD_DIR/Sparkle.framework" "$UPDATER_APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are for sandboxed hosts; the updater is not sandboxed.
rm -rf "$UPDATER_APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
    "$UPDATER_APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cat > "$UPDATER_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$UPDATER_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$UPDATER_ID</string>
    <key>CFBundleName</key>
    <string>$UPDATER_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Without the public update key (scripts/create-release-identity.sh) the app
# reports updates as unavailable rather than trusting an unsigned feed.
SPARKLE_KEYS=""
if [ -f "$SCRIPT_DIR/Resources/sparkle-public-ed-key" ]; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SCRIPT_DIR/Resources/sparkle-public-ed-key")"
    SPARKLE_KEYS="    <key>SUFeedURL</key>
    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>"
fi
cp "$SCRIPT_DIR/install-helper.sh" "$CONTENTS/Resources/install-helper.sh"
chmod 755 "$CONTENTS/Resources/install-helper.sh"
# The published release certificate, next to install-helper.sh, which adds
# it to the helper's pin so a GitHub release update stays admitted.
if [ -f "$SCRIPT_DIR/Resources/release-signing.pem" ]; then
    cp "$SCRIPT_DIR/Resources/release-signing.pem" "$CONTENTS/Resources/release-signing.pem"
fi
echo -n "APPL????" > "$CONTENTS/PkgInfo"

if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# SwiftPM's generated Bundle.module accessor looks in the app's Resources.
# Ship dependency resources too (including NIO's privacy manifest), so the
# installed app never depends on a checkout or build directory.
for resource_bundle in "$BUILD_DIR"/*.bundle(N); do
    cp -R "$resource_bundle" "$CONTENTS/Resources/"
done

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
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
$SPARKLE_KEYS
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>SUAllowsAutomaticUpdates</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
</dict>
</plist>
PLIST

# The privileged helper admits only callers signed by the certificate
# install-helper.sh pinned (#46), so the app is signed with the local identity
# scripts/create-signing-identity.sh makes, and with the hardened runtime:
# without it, anyone running as you could start this signed app with
# DYLD_INSERT_LIBRARIES and speak to the helper through its signature.
# Ad-hoc remains the fallback so a fresh checkout still builds; such an app
# is refused by a helper that enforces the pin.
SIGNING_NAME="Conduit Local Signing"
SIGNING_HASH="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$SIGNING_NAME\"" 'index($0, name) { print $2; exit }' || true)"
RELEASE_IDENTITY="${CONDUIT_RELEASE_SIGNING_IDENTITY:-}"

# Inside out, never --deep: --deep would give every nested binary the app's
# options and drop the updater's entitlement. Identifiers are explicit, since
# left to itself codesign names "$BUNDLE_ID.Helper" "$BUNDLE_ID" (it drops
# what looks like an extension), and the caller pin admits that identifier.
sign_bundle() { # <identity> <hardened runtime: yes|no>
    local identity="$1" runtime="$2"
    local options=(--force --timestamp=none --sign "$identity")
    [ "$runtime" = yes ] && options+=(--options runtime)
    local sparkle="$UPDATER_APP/Contents/Frameworks/Sparkle.framework"
    # One codesign run per distinct option set: with the local identity each
    # run is one more keychain "Allow" prompt. Paths are signed in order.
    codesign "${options[@]}" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"
    codesign "${options[@]}" --identifier "$UPDATER_ID" \
        --entitlements "$SCRIPT_DIR/Resources/ConduitUpdater.entitlements" "$UPDATER_APP"
    codesign "${options[@]}" --identifier "$BUNDLE_ID.Helper" "$HELPERS/$BUNDLE_ID.Helper"
    codesign "${options[@]}" --identifier "$BUNDLE_ID.pm-dns" "$MACOS/pm-dns"
    codesign "${options[@]}" "$APP_DIR"
    codesign --verify --strict --deep "$APP_DIR"
}

if $SHARE && [ -n "$RELEASE_IDENTITY" ]; then
    # Release CI (scripts/import-release-identity.sh): every published build
    # carries the one certificate helpers pin, with the hardened runtime the
    # helper requires.
    echo "Signing with \"Conduit Release Signing\" ($RELEASE_IDENTITY), hardened runtime..."
    sign_bundle "$RELEASE_IDENTITY" yes
elif $SHARE && [ -n "${CONDUIT_REQUIRE_RELEASE_SIGNING:-}" ]; then
    echo "CONDUIT_REQUIRE_RELEASE_SIGNING is set but CONDUIT_RELEASE_SIGNING_IDENTITY is not; refusing to publish an ad-hoc release." >&2
    exit 1
elif $SHARE; then
    # A local self-signed certificate is for helper identity pinning on the
    # builder's Mac. Shared test builds must not depend on that Mac's trust.
    echo "Signing shared test build ad-hoc..."
    sign_bundle - no
elif [ -n "$SIGNING_HASH" ]; then
    echo "Signing with \"$SIGNING_NAME\" ($SIGNING_HASH), hardened runtime..."
    sign_bundle "$SIGNING_HASH" yes
else
    echo "Signing ad-hoc..."
    sign_bundle - no
    echo "" >&2
    echo "WARNING: \"$SIGNING_NAME\" is not in your keychain, so this app is signed ad-hoc." >&2
    echo "WARNING: A helper installed with caller identity enforced will REFUSE it." >&2
    echo "WARNING: Run scripts/create-signing-identity.sh once, then rerun this script." >&2
    echo "" >&2
fi

echo ""
echo "Built: $APP_DIR"

if $SHARE; then
    SHARE_ZIP="$SCRIPT_DIR/.build/share/Conduit-$APP_VERSION-macOS26-$ARCH.zip"
    rm -f "$SHARE_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$SHARE_ZIP"
    echo "Shared test build: $SHARE_ZIP"
    echo "Requires macOS 26 or later, architecture $ARCH. Not notarized."
    if [ -z "$RELEASE_IDENTITY" ]; then
        echo "Signed ad-hoc: a helper that enforces a caller pin refuses it."
    fi
    exit 0
fi

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
