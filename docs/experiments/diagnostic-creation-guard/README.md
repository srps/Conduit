# Diagnostic first-creation regression guard

Source `ef3e4df` adds one bounded fresh resolution when `realpath` reports a
missing name but `lstat` finds an entry. The resource failure recorded a latched
snapshot refusal near first journal creation; its precise syscall interleaving
is inferred. The deterministic test orders that plausible interleaving using
real metadata calls and a real atomic creation.

Executed on 2026-10-27:

| Source | Result | Whole command time |
| --- | --- | --- |
| Corrected baseline | one test passed | 11.535 s |
| Recheck removed | intended `XCTAssertNoThrow` refusal and read-count assertions failed | 8.804 s |
| Exact restored bytes | one test passed | 7.112 s |

The mutant compiled and ran; its failure was not a crash or timeout. Results
retain assertion text and source hashes. Other tests preserve newly appeared
protected symlink/hardlink refusal, dangling links, disappeared entries and
non-missing errors. The separate simulator's 64 concurrent-creation rounds are
an integration witness, not a deterministic race oracle.

To repeat in a clean, isolated checkout with no competing build or source edit:

```sh
python3 docs/experiments/diagnostic-creation-guard/replay.py \
  --root "$PWD" --output /tmp/conduit-diagnostic-guard-unique
```

The driver temporarily edits one source file and restores exact bytes in a
`finally` block. It refuses dirty Sources/Tests/scripts and an existing output
directory. It uses the Xcode developer directory required by the repository.
This is one regression-sensitivity witness, not proof against every external
filesystem race or real-machine release validation.
