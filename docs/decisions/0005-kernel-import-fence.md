# 0005: Kernel import fence, Linux paused

- Date: 2026-09-23
- Decision: accepted (owner, 2026-09-23, #77)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Nothing enforced the kernel import fence. An `import Security` in `Sources/ProxyKernel` compiled, because SwiftPM cannot hide system frameworks, and the documents disagreed on what the kernel may import (#77, #84).

## Decision

Enforce an import allowlist in CI and keep `ProxyKernel` free of Apple platform frameworks. The allowlist is Foundation, Dispatch, the named `NIO*` modules, Darwin, Glibc and the grammar module (`ConduitShared` today). The kernel never constructs `Process`. Linux portability is not a goal for now.

## Alternatives

Keep the rule as prose in `AGENTS.md` and rely on review, which is what had already failed.

## Consequences

- A platform import in the kernel fails CI instead of review.
- Darwin stays allowed, so the kernel is not kept portable. Reviving Linux needs a new record.

## Invariants and verification

- `check-kernel-imports.py` takes each file's imports from the Swift compiler under the debug and release conditions, so no `#if` or comment hides one.
- An unqualified `Process` is a compile error, and the built kernel object must not reference `NSTask`.
- `test-kernel-imports.py` runs the fence against fixtures it must reject.

## Implementation evidence

- [`scripts/check-kernel-imports.py`](../../scripts/check-kernel-imports.py) and [`scripts/test-kernel-imports.py`](../../scripts/test-kernel-imports.py), run by [`swift.yml`](../../.github/workflows/swift.yml) after the build; landed in #141, which closed #77.
- [`ProcessUnavailable.swift`](../../Sources/ProxyKernel/Support/ProcessUnavailable.swift) makes `Process` unavailable in the kernel.
- [`Sources/ProxyKernel/AGENTS.md`](../../Sources/ProxyKernel/AGENTS.md) states the rule.

Does not prove: anything about dependencies the kernel reaches through allowed modules, such as what `ConduitShared` imports.

## Open questions

None.
