#!/bin/bash
# Writes the Sparkle feed for one release next to its archive:
# .build/share/appcast.xml, one item for this version, its archive signed
# with the update key, and this version's CHANGELOG section as the notes.
# Each published release attaches its own appcast.xml, and the app reads
# https://github.com/srps/Conduit/releases/latest/download/appcast.xml,
# so publishing a draft is what offers it.
#
# The private key comes from SPARKLE_ED_PRIVATE_KEY and reaches sign_update
# on stdin. The signature is checked against the public key before anything
# is written: Resources/sparkle-public-ed-key, or --public-key for a run
# with a throwaway key (pull requests, which have no release secrets).
#
#   SPARKLE_ED_PRIVATE_KEY=… scripts/make-appcast.sh [--public-key BASE64]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PUBLIC_KEY=""
if [ "${1:-}" = "--public-key" ]; then
    PUBLIC_KEY="${2:?--public-key needs a base64 key}"
elif [ -f Resources/sparkle-public-ed-key ]; then
    PUBLIC_KEY="$(tr -d '[:space:]' < Resources/sparkle-public-ed-key)"
else
    echo "Resources/sparkle-public-ed-key is missing: run scripts/create-release-identity.sh and commit it." >&2
    exit 1
fi
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is not set}"

version="$(cat VERSION)"
architecture="$(uname -m)"
archive=".build/share/Conduit-$version-macOS26-$architecture.zip"
[ -f "$archive" ] || { echo "$archive is missing: run scripts/package-release.sh first." >&2; exit 1; }
sign_update="$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f | head -1)"
[ -x "$sign_update" ] || { echo "sign_update not found under .build/artifacts (resolve the Sparkle package first)." >&2; exit 1; }

signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$archive")"
if ! xcrun swift scripts/ed25519-verify.swift "$PUBLIC_KEY" "$signature" "$archive"; then
    echo "The update signature does not verify with the public key the app ships; refusing to write a feed." >&2
    exit 1
fi
length="$(stat -f %z "$archive")"
url="https://github.com/srps/Conduit/releases/download/v$version/$(basename "$archive")"

python3 - "$version" "$url" "$length" "$signature" > .build/share/appcast.xml <<'PY'
import email.utils, html, re, sys
version, url, length, signature = sys.argv[1:5]

# This version's CHANGELOG section, as plain HTML: paragraphs, bullet lists
# and inline code; everything else is escaped text.
text = open("CHANGELOG.md", encoding="utf-8").read()
match = re.search(rf"^## {re.escape(version)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
section = match.group(1).strip() if match else f"Conduit {version}."
def inline(s):
    s = html.escape(s)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
blocks, items, para = [], [], []
def flush():
    if para: blocks.append("<p>" + inline(" ".join(para)) + "</p>"); para.clear()
    if items: blocks.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>"); items.clear()
for line in section.splitlines():
    if line.startswith("### "):
        flush(); blocks.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.startswith("- "):
        if para: flush()
        items.append(line[2:].strip())
    elif line.startswith("  ") and items:
        items[-1] += " " + line.strip()
    elif not line.strip():
        flush()
    else:
        if items: flush()
        para.append(line.strip())
flush()
notes = "\n".join(blocks).replace("]]>", "]]&gt;")

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Conduit</title>
    <link>https://github.com/srps/Conduit/releases</link>
    <item>
      <title>Conduit {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/srps/Conduit/releases/tag/v{html.escape(version)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(url, quote=True)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{html.escape(signature, quote=True)}"/>
    </item>
  </channel>
</rss>""")
PY
xmllint --noout .build/share/appcast.xml
echo "Update feed: .build/share/appcast.xml ($version, $length bytes, signature verified)"
