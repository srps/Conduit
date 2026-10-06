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

Every release is now signed with the same certificate. A helper installed from
any certificate-signed app pins the installed app's certificate and the release
certificate together:

```
(certificate leaf = H"<installed app>" or certificate leaf = H"<release>")
    and (identifier "io.github.srps.Conduit" or identifier "io.github.srps.Conduit.Daemon")
```

So a helper installed once keeps admitting later releases from GitHub, and a
developer's locally signed builds stay admitted beside them. The nested helper
and `pm-dns` are signed as `io.github.srps.Conduit.Helper` and
`io.github.srps.Conduit.pm-dns`, which the pin refuses.
`scripts/verify-release-signing.sh` checks all of this on every tagged build.

The certificate proves only that code was signed with the project's key. macOS
does not trust it, Gatekeeper still asks for approval on first launch, and it
gives no Team ID. Without a Team ID, a hardened-runtime process cannot load a
framework signed this way. That is why the self-updater (#111) runs Sparkle in
its own process rather than inside the app.

## Creating the keys (once)

Run this in your own Terminal, not through an agent's shell:

```sh
scripts/create-release-identity.sh --backup-dir /Volumes/<encrypted-drive>/conduit-release --upload
```

It asks for a backup passphrase of at least 16 characters. The script then:

- writes the two public files under `Resources/`; commit them;
- writes `conduit-release-signing.p12` and `sparkle-ed25519.key.enc` to the
  backup directory, both encrypted under the passphrase;
- with `--upload`, creates the GitHub environment `release`, which only `v*`
  tags may deploy from, and sets its secrets `CONDUIT_RELEASE_P12_BASE64`,
  `CONDUIT_RELEASE_P12_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY`.

Keep the passphrase and the backup files in different places, for example the
passphrase in a password manager and the files on an encrypted drive.

To upload again from the backup, for example after deleting the environment:

```sh
base64 -i conduit-release-signing.p12 | tr -d '\n' | gh secret set CONDUIT_RELEASE_P12_BASE64 --env release
gh secret set CONDUIT_RELEASE_P12_PASSWORD --env release   # prompts; type the passphrase
openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 600000 -a -in sparkle-ed25519.key.enc \
    | gh secret set SPARKLE_ED_PRIVATE_KEY --env release      # prompts for the passphrase
```

## In CI

Only tag builds of `.github/workflows/release.yml` run in the `release`
environment. `scripts/import-release-identity.sh` imports the certificate into
a throwaway keychain. It refuses a secret whose certificate differs from the
committed `Resources/release-signing.pem`. `bundle-app.sh --share` then signs
with it, and `CONDUIT_REQUIRE_RELEASE_SIGNING` turns a missing identity into a
failed build instead of an ad-hoc release. The keychain is deleted at the end of
the job. Pull requests and manual runs package ad-hoc.

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
- **Lost secrets, backup intact:** upload them again from the backup, as above.
- **Lost backup and secrets:** treat it as rotation.
