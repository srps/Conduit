# ConduitUpdater

The nested "Conduit Updater.app" (#111): the only process that links Sparkle. `bundle-app.sh` puts it at `Conduit.app/Contents/Helpers/` with Sparkle.framework in its own `Contents/Frameworks`.

- Sparkle never moves into the app. Self-signed builds have no Team ID, so loading Sparkle needs library validation off (`Resources/ConduitUpdater.entitlements`), and the app is the process the helper's caller pin admits. The pin refuses `io.github.srps.Conduit.Updater`.
- Talk to the app only through `UpdaterContract` (ConduitShared): reports carry the host path and use names derived from the host's bundle identifier, so a dev or test copy never acts on another copy's messages. Add a report there, then its event in `docs/events.md`; the app rejects names it does not know.
- Never install without the user's choice. `--test-auto-install` exists in debug builds only, for `scripts/test-updater-e2e.sh`.
- The app quits through Sparkle's normal quit event, which runs Conduit's termination cleanup. Do not kill it or bypass that path.
- Run `scripts/test-updater-e2e.sh` and `scripts/test-updater-e2e.sh --signed` after any change here or to the bundle layout.
