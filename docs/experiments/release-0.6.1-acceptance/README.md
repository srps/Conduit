# Signed 0.6.1 acceptance — 2026-10-29

Evidence for [release verification](../../verification-release-0.6.1-2026-10-29.md).
The release tag is `v0.6.1`, commit `f809bb965ccdad9f6879f3eab73ea5b6b1e0881b`.
Its tree matches verified PR head `f445952`. The official signed main executable
SHA-256 is `88381b5f3d97f6e32f31e573093e996211ef3b509d0800c8e8220693d5c6d740`.

- `completed-run.json` is a byte-identical copy of the redacted owner report:
  23 pass, four observations, no errors, one explicit product-duration skip.
- `run-history.json` preserves counts, errors and original hashes for the declined,
  interrupted and completed runs. The first two are not relabelled as passes.
- `signed-assets.json` records downloaded digests, feed signature and negative
  control, release-certificate checks, the matching ZIP/DMG main binary, image
  detach and the actual signed app's read-only helper preflight. Its unchanged
  app/process flags predate the owner's installation.
- `independent-review.md` accepts the scoped normal-path evidence and qualifications, without requesting another run.
- `post-run-live-check.json` is a separate sanitized read after completion. It
  confirms the expected installed signed binary and running/VPN/Kerberos state,
  plus unchanged configuration/platform/preferences bytes since before install.

Baseline event counts span the original 0.6.1 installation boundary and earlier
partial sessions. Use the isolated reopen counts (five Kerberos successes and 21
helper successes, no failures in a complete window) for the final relaunch claim.
Neither set attributes authentication causally to the HTTPS probe. An additional
shutdown between the interrupted attempt and the completed baseline was outside
the checker's measured phases; no timing or owner-action claim is made for it.

Journal release is not physical per-service restoration or global PAC absence.
The 5.92-second Quit figure includes owner reaction from the prompt; it is an
upper bound, not a product-only duration or an expiry/slow-helper test. Connections
rows are the owner's attestation. No credentials, configuration values, upstream
or service identities, raw machine logs or session URLs are archived.

The source review found that serving can have journal markers labelled released
while tracked records exist. Marker labels are not used to infer ownership or
cleanup here; the Stop/Quit checks use non-marker record counts. Manual Start is
inferred from the ordered no-listener/new-process/Start-prompt/serving sequence,
with user-source lifecycle events corroborated by the independent read; no UI
click was instrumented.

GitHub records [0.6.1](https://github.com/srps/Conduit/releases/tag/v0.6.1) as
published on 2026-10-29 at 22:40:28 UTC, observed during documentation closeout.
The draft-state fields in `signed-assets.json` and the publication wording in
`independent-review.md` describe their earlier checkpoints and remain unchanged.
