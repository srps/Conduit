#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
./bundle-app.sh --share

version="$(cat VERSION)"
architecture="$(uname -m)"
asset_name="Conduit-$version-macOS26-$architecture"
output_dir="$ROOT_DIR/.build/share"
stage_dir="$(mktemp -d /tmp/conduit-dmg-XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT

ditto "$output_dir/Conduit.app" "$stage_dir/Conduit.app"
ln -s /Applications "$stage_dir/Applications"
if [ -n "${CONDUIT_RELEASE_SIGNING_IDENTITY:-}" ]; then
    signing_note="This app is signed with the self-signed \"Conduit Release Signing\"
certificate (see docs/release-signing.md) and is not notarized. If macOS
blocks opening it, open System Settings > Privacy & Security and choose
Open Anyway."
    pin_note="To enforce caller identity, install the helper with the command above: it
pins the release certificate, so later releases keep working with it without
reinstalling the helper. Install Helper in Settings writes no pin."
else
    signing_note="This app is ad-hoc signed and is not notarized. If macOS blocks opening it,
open System Settings > Privacy & Security and choose Open Anyway."
    pin_note="This ad-hoc build cannot retain a certificate pin from a locally signed app.
The installer reports caller identity as unenforced and retains the console-user
admission rule. Review its summary before choosing this installation policy."
fi
cat > "$stage_dir/Read Me.txt" <<EOF
Conduit $version — macOS 26 or later, $architecture

Drag Conduit.app into Applications, then open it from Applications.

$signing_note

No Swift or Xcode is needed. Managed macOS proxy and system DNS settings
require the privileged helper v5. Install it in Conduit > General > Privileged
Helper. If an older helper refuses this build, run the bundled installer:

  sudo /Applications/Conduit.app/Contents/Resources/install-helper.sh --source installed

$pin_note
EOF

codesign --verify --strict --deep "$stage_dir/Conduit.app"
hdiutil create -volname "Conduit $version" -srcfolder "$stage_dir" \
    -format UDZO -ov "$output_dir/$asset_name.dmg"
hdiutil verify "$output_dir/$asset_name.dmg"
(
    cd "$output_dir"
    shasum -a 256 "$asset_name.zip" "$asset_name.dmg" > "$asset_name.sha256"
)
echo "Release packages: $output_dir/$asset_name.{dmg,zip,sha256}"
