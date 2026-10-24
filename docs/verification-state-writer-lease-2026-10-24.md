# State writer lease and canonical root verification

Date: 2026-10-24. Implements the unadopted OS lease and layout primitives under decisions [0017](decisions/0017-exclusive-state-directory-writer.md) and [0020](decisions/0020-canonical-runtime-writer-root.md). No shipping host or persistence writer acquires this lease yet. No installed app, helper or user state was changed.

## Executed checks

Claude implemented and corrected this slice using the owner's claude.ai Max subscription. Codex reviewed the actual patch, wrote and ran independent regression witnesses, and executed the final focused wrapper after Claude's last correction could not invoke its allowed Bash command.

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` with `xcrun swift build` and `xcrun swift test --filter 'StateWriter|StateRoot|StateDirectoryLease|RuntimeEnvironment'`: **80 tests, zero failures**. Kernel import fence, event catalogue, decision checks with history, and `pm-sim state-writer-lease` passed (**17 assertions**). This is a focused checkpoint; full workflow-equivalent gates are still running and are recorded separately below when complete.

Independent failures reproduced before correction:

- Existing and missing ASCII case aliases were accepted as different roles; repeated uncertain release became `alreadyReleased` (three initial witnesses failed).
- Missing long-s aliases could become the writer lock or preferences file (two later witnesses failed). Owned APFS probes also established final-sigma and micro-sign aliases.
- A stale test expected `alreadyReleased` after an uncertain close. It now expects the same uncertainty; its scripted close would return success on a second call, so this also detects an unwanted retry.

The final run includes all these witnesses plus case-sensitive/insensitive/unknown-volume fakes, canonical normalization, hard/symbolic links, headless input-only layout, concurrent release outcomes, and owned subprocess tests. Actual-volume Unicode witnesses probe the relevant alias before asserting and may skip on another filesystem. They passed here.

## Implemented shape

- `StateWriterLeasing` returns acquired/busy/typed failure. `OSStateWriterLeasing` opens stable `state-writer.lock` with `O_NOFOLLOW | O_CLOEXEC` and mode0600, takes nonblocking `flock`, and compares descriptor/path identities. It never unlinks/replaces the lock, writes a PID, or explicitly unlocks a shared open-file description.
- An opaque lease closes exactly once. Uncertain close remains uncertain on every later call; close is never retried. Concurrent release waits for the first close's result. A destructor reports an unconfirmed fallback close once. Acquire/release are synchronous worker operations, never main-actor work.
- `StateRootLayout` checks the four writable roles for canonical containment, disjointness and reserved resources. Existing aliases use device/inode identity; missing names use parent identity plus canonical equivalence and conservative locale-fixed Unicode case folding, conditioned on volume case behavior. Nil/failed metadata refuses only a potentially folded collision. Case-sensitive volumes keep case-distinct names.
- `resolveReadOnlyInput` resolves only the root and input, accepting an outside config without resolving unused sidecars. No host uses it yet.
- New filesystem effects have a protocol and additive fakes in `PlatformMac`. The fake is not an independent model of APFS.

## Filesystem evidence

Owned local scratch probes established: atomic data saves replace data inodes; a lock on the old data inode does not exclude a new open after replacement; a fixed root lock survives replacement; atomic save through a symbolic-link leaf replaces the link. A later store must write the resolved logical path and keep authority until writes quiesce.

The subprocess tests run Swift's adapter in the test process with Python `flock` contenders. They demonstrate busy/acquire after release, release on holder process exit, and close-on-exec inheritance with a positive inheritable-descriptor control. They do not run two Swift hosts or prove deployed-host startup order. Child waits are bounded and joined before fixture deletion.

## Limits and adoption work

No async store, writer coverage, startup/migration/recovery integration, session Stop/Quit fence, caller deadline, legacy upgrade ordering, total shutdown budget or machine recovery is proved. A missing component parent is currently refused by layout preflight; a future store may create it under authority, then must re-resolve before writing. Lease acquisition requires root canonicalization first, while any migration/recovery writes must wait for acquired authority.

The Unicode fold is conservative and is not advertised as the filesystem's exact comparison table. Canonical-equivalent missing spellings are refused on every volume; this may refuse legitimate distinct names on a normalization-sensitive filesystem. Existing names use actual identities. Deployment storage, non-APFS/network filesystems, mount points, and arbitrary external directory/path replacement remain unverified. A reserved symlink is compared by its entry, not its target. Canonical parent containment can conservatively refuse alternate case spellings. These limits remain explicit before adoption; no new filesystem-wide ban is selected.

Root/component/global registry alternatives and revisit triggers are recorded in0020. A future extension needs versioned/quiescent handoff and mixed-version tests; it is not a transparent mechanism swap.
