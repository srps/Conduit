# Store source guard mutations (2026-10-26)

The [manifest](manifest.json) records five executed source mutations, their required failing XCTest,
exact before/mutant/restored hashes, and the corresponding replayable patches. Every patch was
reconstructed from the committed preimage and matches the hash recorded during execution.
These are deliberately broken variants, not proposed product changes.

The source proof compares every changed production source file at immutable review head 0090a6b,
full-workflow head 3f6b80f, and the restored working tree. All hashes match and the source diff is clean.

To replay, use an owned scratch checkout of the full manifest head. Apply one patch, run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter with that record's
testFilter, then restore only its named file from the manifest head before the next patch. The required
witness must fail by an XCTest assertion rather than a compile error or crash. With all patches
restored, run ConfigurationStoreSourceTests and both named sequential reference models.

Executed logs remain with the local verification archive; these patches and hashes preserve the
specific sensitivity checks without checking in large logs. See the
[verification checkpoint](../../verification-configuration-source-2026-10-26.md) for bounds and exclusions.
