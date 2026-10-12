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

Both ways of installing the helper enforce caller identity: the command above
and **Install Helper** in Settings, which runs the same bundled installer for
the app it is running from. Either pins the release certificate, so later
releases keep working without reinstalling the helper. A helper pinned to a
locally signed build refuses this app until it is reinstalled once; Settings
then offers **Reinstall Helper** and shows the new pin. Locally signed builds
stay admitted beside releases, because the pin includes the release
certificate too. The app does not have to be in Applications: the pin names
certificates and bundle identifiers, not a path.

From 0.5, Conduit updates itself: **Check for Updates…** in the Conduit menu
or the menu bar popover, or turn on **Check for updates automatically** in
General → Updates. Each update is verified against Conduit's update key before
it is unpacked, and nothing installs until you choose to. Installing quits
Conduit, which restores your proxy and DNS settings, then relaunches the new
version. macOS may ask you to approve the updated app once, as on first launch.
Releases before 0.5 cannot update themselves; install 0.5 by hand.

After installing the helper, Conduit retries failed managed proxy application
when it detects helper availability or receives a VPN/path report. The macOS PAC
URL should point at Conduit's **Currently serving** local PAC URL when adaptive
local PAC is enabled.

For rollback, stop Conduit and allow proxy/DNS restoration to complete before
installing an older app. Keep the recovery journal when troubleshooting; older
clients do not understand location-scoped records.

SHA-256 checksum files are included for both the ZIP and disk image.

## Update compatibility and limits (0.5.3 onward)

Choosing Install first downloads and authenticates a preflight copy of the
candidate. It verifies the actual bundle identifier/version, arm64 executable,
minimum macOS, code signature and writable app/destination directory. A
root-owned helper pin is evaluated against that candidate; then the candidate's
early read-only worker pings the installed helper to confirm its actual loaded
admission policy and protocol. The worker composes no app runtime and invokes no
privileged operation besides ping. A missing helper is supported; an outdated,
unresponsive or refusing helper blocks installation. Preflight never installs,
re-pins or weakens the helper. Read-only/root-owned destinations require a manual
administrator install rather than an automatic elevation fallback.

The updater serializes each host with its existing ownership lock. Preflight
and Sparkle's subsequent download each have a 120-second total deadline and
256 MiB progress/final-size ceiling. An authenticated preflight ZIP is limited
to 16,384 entries and 1 GiB uncompressed; its inspection/extraction/worker
commands have 30-second deadlines and 4 KiB output limits. There is one private
staging directory per user/host (under the user's temporary directory), removed
on success/failure and reset before the next attempt after a crash. No automatic
retry occurs inside an install choice; automatic checks remain daily. Progress
callbacks can exceed a byte ceiling by one callback's data before cancellation.
Sparkle independently downloads and authenticates the same signed archive;
Conduit uses public APIs and does not depend on Sparkle's private staging paths.

The updater in 0.5.2 cannot retroactively run this new preflight. The first
0.5.2→0.5.3 update therefore uses the existing Sparkle flow. A later update
started from 0.5.3 gains the checks; candidates without the early-worker
capability are refused rather than launched as an app during preflight.

After preflight passes, Sparkle owns replacement/relaunch. A late disk failure,
helper-policy change or new Gatekeeper block can still occur. Before retrying,
check the installed bundle version and `lifecycle.version_changed`; do not assume
a downloaded archive means the update installed. If relaunch/startup fails,
proxy/DNS termination cleanup should have restored previous settings. Preserve
the recovery journal and configuration, launch the verified installed bundle
manually, and review readiness before enabling integrations. If replacement
failed, manually reinstall the last known working signed archive. Durable-state
rollback across future migrations is not promised; 0.5.3 introduces no config or
journal migration. Actual power-loss/relaunch/Gatekeeper/managed-Mac outcomes and
macOS 26/27 coverage must be recorded during installed validation.
