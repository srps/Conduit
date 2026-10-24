#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# bundle-app.sh --dev (#23), run for real against a temporary copy of the
# repository's packaging files. Build/sign tools are stand-ins; installation
# and LaunchServices registration are confined to scratch before any case. swift,
# codesign, security, python3 and the install-only tools are stand-ins on PATH
# that record their calls, so a call that reaches the Keychain or /Applications
# shows up in the log, and the test never makes one. The copied installer's
# /Applications destination and its LaunchServices registration are rewritten
# into scratch before any case runs, so the test stays inside scratch even if
# the --dev guard regresses.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
real_python="$(command -v python3)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/conduit-dev-bundle.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

fixture="$scratch/repo"
stubs="$scratch/stubs"
products="$scratch/products"
calls="$scratch/calls.log"
mkdir -p "$fixture/Resources/ThirdPartyLicenses" "$stubs" "$scratch/applications" "$products/Sparkle.framework/Versions/B/Updater.app" "$products/Sparkle.framework/Versions/B/XPCServices"
cp "$repo/bundle-app.sh" "$repo/install-helper.sh" "$repo/VERSION" "$repo/LICENSE" "$repo/NOTICE" "$fixture/"
echo "notice" > "$fixture/Resources/ThirdPartyLicenses/NOTICE.txt"
# Present, so a production bundle gets its update feed and a dev bundle must not.
echo "dGVzdC1rZXktbm90LWEtcmVhbC1rZXk=" > "$fixture/Resources/sparkle-public-ed-key"
for product in Conduit ConduitHelper pm-dns ConduitUpdater; do
    printf '#!/bin/sh\nexit 0\n' > "$products/$product"
    chmod 755 "$products/$product"
done
echo "stand-in" > "$products/Sparkle.framework/Versions/B/Autoupdate"

export CALLS="$calls" PRODUCTS="$products" REAL_PYTHON3="$real_python"

write_stub() { # <name>; body on stdin
    { echo '#!/bin/bash'; cat; } > "$stubs/$1"
    chmod 755 "$stubs/$1"
}
write_stub swift <<'EOF'
echo "swift $*" >> "$CALLS"
case " $* " in *" --show-bin-path "*) echo "$PRODUCTS" ;; esac
EOF
write_stub codesign <<'EOF'
echo "codesign $*" >> "$CALLS"
EOF
write_stub security <<'EOF'
echo "security $*" >> "$CALLS"
EOF
for tool in osascript pgrep pkill; do
    write_stub "$tool" <<EOF
echo "$tool \$*" >> "\$CALLS"
exit 1
EOF
done
write_stub python3 <<'EOF'
case " $* " in
    *check-third-party-notices.py*) echo "python3 $*" >> "$CALLS"; exit 0 ;;
esac
exec "$REAL_PYTHON3" "$@"
EOF
write_stub lsregister <<'EOF'
echo "lsregister $*" >> "$CALLS"
EOF

# Rewrites one exact line of the copied installer. A line that is not there
# exactly once means the installer changed, so the test refuses to run at all
# rather than run against an unknown destination.
retarget() { # <file> <exact old line> <new line>
    local file="$1" old="$2" new="$3" tmp="$1.retarget" line count=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$old" ]; then
            line="$new"
            count=$((count + 1))
        fi
        printf '%s\n' "$line"
    done < "$file" > "$tmp"
    if [ "$count" -ne 1 ]; then
        echo "test-dev-bundle: expected exactly one '$old' in bundle-app.sh, found $count; refusing to run" >&2
        exit 1
    fi
    mv "$tmp" "$file"
}
# The installer's /Applications destination and LaunchServices registration are
# host-targeting, so both are confined to scratch before any case runs.
retarget "$fixture/bundle-app.sh" \
    'INSTALL_DIR="/Applications/$APP_NAME.app"' \
    "INSTALL_DIR=\"$scratch/applications/Conduit.app\""
retarget "$fixture/bundle-app.sh" \
    '    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"' \
    "    LSREGISTER=\"$stubs/lsregister\""

failures=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; failures=$((failures + 1)); }

rc=0
out=""
run_bundle() { # <args...>; sets rc and out, and starts from an empty call log
    : > "$calls"
    rc=0
    out="$(cd "$fixture" && PATH="$stubs:$PATH" zsh "$fixture/bundle-app.sh" "$@" 2>&1)" || rc=$?
}
clean_products() {
    find "$fixture" -maxdepth 1 -name '*.app' -exec rm -rf {} +
    rm -rf "$fixture/.build"
}
plist() { # <bundle> <key>; empty when the key is absent
    local value
    if value="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null)"; then
        printf '%s' "$value"
    fi
}
expect() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

version="$(cat "$repo/VERSION")"

# Production default: unchanged, and it still goes through the identity lookup.
clean_products
run_bundle
prod="$fixture/Conduit.app"
if [ "$rc" -eq 0 ] && [ -d "$prod" ] && [ ! -e "$fixture/Conduit Dev.app" ]; then
    ok "production default builds Conduit.app and no dev bundle"
else
    bad "production default (exit $rc): $out"
fi
expect "production identifier" "io.github.srps.Conduit" "$(plist "$prod" CFBundleIdentifier)"
expect "production display name" "Conduit" "$(plist "$prod" CFBundleDisplayName)"
expect "production update feed kept" "https://github.com/srps/Conduit/releases/latest/download/appcast.xml" "$(plist "$prod" SUFeedURL)"
expect "production preflight key kept" "1" "$(plist "$prod" ConduitUpdatePreflightVersion)"
expect "production updater identifier" "io.github.srps.Conduit.Updater" "$(plist "$prod/Contents/Helpers/Conduit Updater.app" CFBundleIdentifier)"
if [ -x "$prod/Contents/Library/LaunchServices/io.github.srps.Conduit.Helper" ]; then
    ok "production helper keeps its name"
else
    bad "production helper missing"
fi
if grep -q '^security find-identity' "$calls"; then
    ok "production looks up the personal signing identity"
else
    bad "production skipped the identity lookup"
fi
if grep -E -q '^(osascript|pkill|pgrep) ' "$calls"; then
    bad "a production build without --install touched the running app"
else
    ok "production build without --install never quits or signals a process"
fi

# Dev bundle: its own identity, no feed, and the identity lookup never runs.
clean_products
run_bundle --dev
dev="$fixture/Conduit Dev.app"
if [ "$rc" -eq 0 ] && [ -d "$dev" ] && [ ! -e "$fixture/Conduit.app" ]; then
    ok "--dev builds Conduit Dev.app beside the production bundle name"
else
    bad "--dev build (exit $rc): $out"
fi
expect "dev identifier" "io.github.srps.Conduit.dev" "$(plist "$dev" CFBundleIdentifier)"
expect "dev display name" "Conduit Dev" "$(plist "$dev" CFBundleDisplayName)"
expect "dev bundle name" "Conduit Dev" "$(plist "$dev" CFBundleName)"
expect "dev executable keeps the product name" "Conduit" "$(plist "$dev" CFBundleExecutable)"
expect "dev version comes from VERSION, not bumped" "$version" "$(plist "$dev" CFBundleShortVersionString)"
expect "dev updater identifier" "io.github.srps.Conduit.dev.Updater" "$(plist "$dev/Contents/Helpers/Conduit Updater.app" CFBundleIdentifier)"
expect "dev has no update feed" "" "$(plist "$dev" SUFeedURL)"
expect "dev has no update key" "" "$(plist "$dev" SUPublicEDKey)"
expect "dev has no preflight key" "" "$(plist "$dev" ConduitUpdatePreflightVersion)"
expect "dev updater has no feed either" "" "$(plist "$dev/Contents/Helpers/Conduit Updater.app" SUFeedURL)"
if [ -x "$dev/Contents/Library/LaunchServices/io.github.srps.Conduit.dev.Helper" ] \
    && [ ! -e "$dev/Contents/Library/LaunchServices/io.github.srps.Conduit.Helper" ]; then
    ok "dev helper has the dev identifier and not the production one"
else
    bad "dev helper name"
fi
if grep -q '^security ' "$calls"; then
    bad "--dev reached the Keychain/identity lookup: $(grep '^security ' "$calls")"
else
    ok "--dev never runs security, so it cannot prompt for the Keychain"
fi
codesign_lines="$(grep '^codesign ' "$calls" | grep -v -e '--verify' || true)"
if [ -n "$codesign_lines" ] && [ -z "$(grep -v -e '--sign - ' <<<"$codesign_lines" || true)" ]; then
    ok "every dev signature is ad-hoc (--sign -)"
else
    bad "a dev signature is not ad-hoc: $codesign_lines"
fi
if grep -q -- '--options runtime' "$calls"; then
    bad "a dev signature asks for the hardened runtime"
else
    ok "dev signatures carry no hardened runtime"
fi
if [ -n "$(grep -- '--identifier ' <<<"$codesign_lines" | grep -v -e 'io.github.srps.Conduit.dev' || true)" ]; then
    bad "a dev signature names a production identifier"
else
    ok "dev signatures name only dev identifiers"
fi
if grep -q -- 'check-third-party-notices' "$calls"; then
    ok "dev bundles keep the third-party notice check"
else
    bad "dev build skipped the third-party notice check"
fi

# Build-time flags that conflict with --dev are refused before anything runs.
for combo in "--dev --install" "--install --dev" "--dev --share" "--share --dev" \
    "--dev --release" "--release --dev" "--dev --release --install"; do
    clean_products
    read -r -a flags <<<"$combo"
    run_bundle "${flags[@]}"
    if [ "$rc" -ne 0 ] && [[ "$out" == *"--dev builds"* ]] && [ ! -s "$calls" ] \
        && [ -z "$(find "$fixture" -maxdepth 1 -name '*.app' -print -quit)" ] && [ ! -e "$fixture/.build" ]; then
        ok "refused before any effect: $combo"
    else
        bad "$combo (exit $rc): $out; calls: $(cat "$calls")"
    fi
done

# Runtime flags are not build arguments, so they are refused, not passed on.
clean_products
run_bundle --dev --section dns
if [ "$rc" -ne 0 ] && [[ "$out" == *"Unknown argument: --section"* ]] && [ ! -s "$calls" ]; then
    ok "a runtime flag given to the build is refused before any effect"
else
    bad "runtime flag handling (exit $rc): $out"
fi

# Containment under a regressed guard: a copy with the --dev refusal removed
# runs --dev --install for real. The install must reach only scratch, and the
# LaunchServices step must hit the stand-in, never the host's lsregister.
clean_products
mutant="$scratch/mutant"
cp -R "$fixture" "$mutant"
retarget "$mutant/bundle-app.sh" 'if $DEV && ($INSTALL || $SHARE || $RELEASE); then' 'if false; then'
: > "$calls"
rc=0
out="$(cd "$mutant" && PATH="$stubs:$PATH" zsh "$mutant/bundle-app.sh" --dev --install 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ -d "$scratch/applications/Conduit.app" ] \
    && [[ "$out" == *"Installed to $scratch/applications/Conduit.app"* ]] \
    && [ "$(grep -c '^lsregister ' "$calls")" -eq 1 ]; then
    ok "a regressed guard still installs only into scratch and registers only the stand-in"
else
    bad "containment under a regressed guard (exit $rc): $out; calls: $(cat "$calls")"
fi

clean_products
if [ "$failures" -ne 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all dev bundle checks passed"
