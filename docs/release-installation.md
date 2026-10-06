Download the **arm64** disk image. Conduit runs on Apple Silicon Macs (M1 or
later) with macOS 26 or later; Intel Macs are no longer supported.

Open the `.dmg`, drag **Conduit.app** into **Applications**, and launch it from
Applications. The `.zip` contains the same app if you prefer an archive.
No Xcode, Swift installation, or local bundling is required.

These packages are signed with Conduit's self-signed release certificate
([release signing](release-signing.md)) and are not notarized. If macOS blocks
the first launch, go to **System Settings → Privacy & Security → Open Anyway**.
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

A helper installed from this app pins the release certificate, so later
releases keep working with it without reinstalling the helper. A helper that was
installed from an ad-hoc release, or pinned to a locally signed build only,
refuses this app until it is reinstalled once; the installer's summary reports
the new pin. Locally signed builds stay admitted beside releases when the helper
is installed from them, because the pin includes the release certificate too.

After installing the helper, Conduit retries failed managed proxy application
when it detects helper availability or receives a VPN/path report. The macOS PAC
URL should point at Conduit's **Currently serving** local PAC URL when adaptive
local PAC is enabled.

For rollback, stop Conduit and allow proxy/DNS restoration to complete before
installing an older app. Keep the recovery journal when troubleshooting; older
clients do not understand location-scoped records.

SHA-256 checksum files are included for both the ZIP and disk image.
