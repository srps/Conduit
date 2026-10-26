# Runtime intent guard mutations

Eight patches reproduce the actual executed source changes in the manifest, based on reviewed
fda80f7. Each mutated source hash was checked against the execution record. Each variant failed its
named XCTest assertion without a compile failure or crash. Exact source bytes were restored and the
focused restored tests passed. The manifest also fingerprints all eight changed production files.

Apply one patch at a time to that source checkpoint and run its named witness with Xcode selected:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter WITNESS`.
Restore before the next variant. These are evidence artifacts, not a permanent test runner or CI step.

This demonstrates sensitivity at the named guards, not every modified comparison. It does not cover
real Keychain account normalization, direct system-PAC repointing, hostname canonicalization, all
concurrent PAC cache stores or the host's verified-start view guard independently.
