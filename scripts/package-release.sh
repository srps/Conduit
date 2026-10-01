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
cat > "$stage_dir/Read Me.txt" <<EOF
Conduit $version — macOS 26 or later, $architecture

Drag Conduit.app into Applications, then open it from Applications.

This app is ad-hoc signed and is not notarized. If macOS blocks opening it,
open System Settings > Privacy & Security and choose Open Anyway.

No Swift, Xcode, terminal commands, or build scripts are needed to install.
The optional privileged helper is not installed by this disk image; Conduit
uses macOS admin prompts when it is absent.
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
