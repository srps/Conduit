# Release signing

Conduit releases are signed by two keys that the project owner holds. Neither is
an Apple Developer ID, so releases are still not notarized.

| Key | What it signs | Public half | Private half |
| --- | --- | --- | --- |
| **Conduit Release Signing**, a self-signed RSA-3072 code-signing certificate valid for 20 years | The app, the helper and `pm-dns` in every published release, with the hardened runtime | `Resources/release-signing.pem`, also bundled at `Conduit.app/Contents/Resources/release-signing.pem` | GitHub environment `release`; the owner's offline backup |
| **Sparkle update key**, Ed25519 | Every update archive (#111) | `Resources/sparkle-public-ed-key`, embedded in the app as `SUPublicEDKey` | GitHub environment `release`; the owner's offline backup |

## Why a shared certificate

The privileged helper admits only callers that satisfy the code-signing
requirement `install-helper.sh` pins (#46). That pin names a leaf certificate.
Ad-hoc builds have no certificate, so a helper cannot pin them. Before 0.5,
installing a downloaded release over a locally signed one dropped the pin, and a
self-update could never keep it.

Every release is now signed with the same certificate. The bundled installer
(`Conduit.app/Contents/Resources/install-helper.sh`, run with `sudo`), run
against any certificate-signed app, pins the installed app's certificate and
the release certificate together:

```
(certificate leaf = H"<installed app>" or certificate leaf = H"<release>")
    and (identifier "io.github.srps.Conduit" or identifier "io.github.srps.Conduit.Daemon")
```

So a helper installed this way once keeps admitting later releases from
GitHub, and a developer's locally signed builds stay admitted beside them.
**Install Helper** in Conduit's Settings runs the same bundled installer with
`--app` set to the running app, so it writes the same pin, derived from that
app wherever it runs from (#121). The nested helper
and `pm-dns` are signed as `io.github.srps.Conduit.Helper` and
`io.github.srps.Conduit.pm-dns`, which the pin refuses.
`scripts/verify-release-signing.sh` checks all of this on every tagged build.

The certificate proves only that code was signed with the project's key. macOS
does not trust it, Gatekeeper still asks for approval on first launch, and it
gives no Team ID. Without a Team ID, a hardened-runtime process cannot load a
framework signed this way. That is why the self-updater (#111) runs Sparkle in
its own process rather than inside the app.

## Creating the keys (once)

Run this in your own Terminal, not through an agent's shell. The machine needs
`gh` signed in (`gh auth login`) and Swift for the update key: Xcode, or just
the Command Line Tools (`xcode-select --install`), which the script falls back
to when Xcode is not installed.

```sh
scripts/create-release-identity.sh --backup-dir /Volumes/<encrypted-drive>/conduit-release --upload
```

It asks for a backup passphrase of at least 16 characters. The script then:

- writes the two public files under `Resources/`; commit them;
- writes `conduit-release-signing.p12` and `sparkle-ed25519.key.enc` to the
  backup directory, both encrypted under the passphrase;
- with `--upload`, after all of that is written and read back, sets up
  everything that guards the secrets before setting any of them:
  - the GitHub environment `release`, which only `v*` tags may deploy from
    (any other deployment policy is removed), with you as its required
    reviewer, so every job that reads the secrets waits for your approval,
    including a rerun of a run that existed before this setup;
  - the tag ruleset "Release tags", so only repository admins can create, move
    or delete `v*` tags. The environment policy matches a tag but cannot say
    who made it. An existing ruleset of that name is checked for what it
    actually enforces, including who may bypass it (repository admins only);
    one that does not protect `v*` tags stops the upload;
  - then the secrets `CONDUIT_RELEASE_P12_BASE64`,
    `CONDUIT_RELEASE_P12_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY`.

Keep the passphrase and the backup files in different places, for example the
passphrase in a password manager and the files on an encrypted drive.

If the upload fails, or to upload again later (for example after deleting the
environment), upload from the backup. It checks that the backup opens with the
passphrase, that its certificate is the committed one and that its update key
matches the committed public key:

```sh
scripts/create-release-identity.sh --upload-from-backup /Volumes/<encrypted-drive>/conduit-release
```

## In CI

Only tag builds of `.github/workflows/release.yml` run in the `release`
environment, and each waits for your approval in the Actions run before it
starts. `scripts/import-release-identity.sh` imports the certificate into
a throwaway keychain. It refuses a secret whose certificate differs from the
committed `Resources/release-signing.pem`. `bundle-app.sh --share` then signs
with it, and `CONDUIT_REQUIRE_RELEASE_SIGNING` turns a missing identity into a
failed build instead of an ad-hoc release. The keychain is deleted at the end of
the job. Pull requests and manual runs package ad-hoc.

## The update feed

The app reads `https://github.com/srps/Conduit/releases/latest/download/appcast.xml`.
On a tag build, `scripts/make-appcast.sh` signs the release ZIP with
`SPARKLE_ED_PRIVATE_KEY`, which reaches Sparkle's `sign_update` on stdin. It
checks that signature against the committed public key, and writes a one-item
`appcast.xml` with this version's CHANGELOG section as the release notes. The
draft release carries it as an asset. GitHub's "latest" resolves only to
published releases, so publishing the draft is what offers the update. Each
release's feed lists only itself.

## Rotation and loss

Replacing the certificate means every user reinstalls the helper once. Their
pin names the old certificate, and an app signed with the new one is refused
until they reinstall. Replacing the update key means every installed app
refuses updates signed with the new key, so users install the next release by
hand. Neither is routine.

- **Suspected compromise:** delete the `release` environment's secrets, then
  create new keys. Remove the old public files first; the script refuses to
  replace them. Publish a release by hand that explains the helper reinstall.
  Sparkle can also rotate the update key by signing one release with both keys;
  see its documentation.
- **Lost secrets, backup intact:** `--upload-from-backup`, as above.
- **Lost backup and secrets:** treat it as rotation.
