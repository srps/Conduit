Download the disk image matching your Mac: **arm64** for Apple Silicon (M1 or
later), **x86_64** for Intel. Requires macOS 26 or later on supported hardware.

Open the `.dmg`, drag **Conduit.app** into **Applications**, and launch it from
Applications. The `.zip` contains the same app if you prefer an archive.
No Xcode, Swift installation, or local bundling is required.

These packages are ad-hoc signed and are not notarized. If macOS blocks the
first launch, go to **System Settings → Privacy & Security → Open Anyway**.
The privileged helper is not installed by dragging the app. Helper v5 is required
for **Manage macOS proxy settings** and **Manage system DNS**. Install or reinstall
it from Conduit's Settings before using those integrations. Other functionality
can run without the helper.

The helper installer is also included in the downloaded app. If an old helper
refuses the app because its caller-signing pin does not accept this build, use
this explicit administrator installation after copying the app to Applications:

```sh
sudo /Applications/Conduit.app/Contents/Resources/install-helper.sh --source installed
```

Locally certificate-signed builds retain caller-identity enforcement when the
same certificate signs the new app. These shared ad-hoc packages have no signing
certificate to pin: their installer reports caller identity as unenforced and
keeps the console-user admission rule. Installing them over a locally pinned
build changes that policy; review the installer's summary. To retain your local
pin, build the release from source using the same local signing identity.

After installing the helper, Conduit retries failed managed proxy application
when it detects helper availability or receives a VPN/path report. The macOS PAC
URL should point at Conduit's **Currently serving** local PAC URL when adaptive
local PAC is enabled.

For rollback, stop Conduit and allow proxy/DNS restoration to complete before
installing an older app. Keep the recovery journal when troubleshooting; older
clients do not understand location-scoped records.

SHA-256 checksum files are included for both the ZIP and disk image.
