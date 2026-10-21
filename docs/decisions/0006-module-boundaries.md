# 0006: Module boundaries for the helper, shared contracts, Keychain codec, spool and paths

- Date: 2026-09-23
- Decision: accepted (owner, 2026-09-23, #76, #78, #80, #81, #82)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Several pieces sit in the wrong module:

- The root helper links all of `ProxyKernel` and SwiftNIO for two relays that import only Foundation (#76).
- `ConduitShared` mixes grammar, helper IPC, daemon control types and helper implementation (#78).
- The Keychain payload codec lives in the kernel (#80).
- The request-body spool uses a process-wide pool and an ambient temporary directory (#81).
- `RuntimeEnvironment.userDefault()` chooses application-support paths inside the kernel (#82).

## Decision

- **Helper off the kernel (#76):** move `TCPRelay` and `UDPRelay` into the helper's own library, and drop `ProxyKernel` from `ConduitHelper`.
- **Split `ConduitShared` (#78), in stages:** helper policy and subprocess code go to a `HelperCore`; the domain-name and IP grammar goes to a dependency-free `ConduitSyntax`; helper and control wire types separate where that helps; tool-only code moves to its tool. Encoded payloads and protocol versions stay compatible.
- **Keychain codec to PlatformMac (#80):** storage representation moves beside `KeychainStore`. `SecretBytes`, `ProxyCredentials` and neutral credential-failure classification stay where `ProxyAuth` and headless tools can use them. Users do not re-enter credentials.
- **Runtime-owned spool (#81):** each runtime gets a private spool directory and an injected service, with blocking file work off NIO loops and aggregate budgets.
- **Path defaults at the entry points (#82):** installed-user path policy moves out of the kernel into executable composition, without relocating existing user files.

Each lands on its own, passing the full `swift.yml` checks.

## Alternatives

- A broad target and access-level reshuffle first. #78 rules it out as a prerequisite for the first daemon/client slice.
- Moving all of `CredentialManagerError` unchanged (#80): `ProxyAuth` needs its platform-neutral part.

## Consequences

- The root helper gets smaller and stops carrying NIO.
- Headless tools keep their dependency fence ([0005](0005-kernel-import-fence.md)).
- Behavioural IPC changes need their own compatibility plan, separate from these moves.

## Invariants and verification

- `nm` shows no NIO symbols in the release helper (#76).
- Existing helper/control payloads and Keychain payloads decode unchanged, with fixtures (#78, #80).
- Two runtimes with separate state directories never delete each other's spool files (#81).
- Kernel path construction reads no ambient home or application-support location (#82).

## Implementation evidence

- #81, in part: #129 added structured spool failure events (`request.body_spool_failed`, `request.body_spool_cleanup_failed`) in [`HTTPProxyHandler`](../../Sources/ProxyKernel/Proxy/HTTPProxyHandler.swift), moved spool setup off NIO loops, and fixed plain-HTTP body truncation; the [`request-body-spool`](../../Sources/pm-sim/RequestBodySpoolScenarios.swift) scenario covers it.
- #76, #78, #80 and #82 have not started. [`Package.swift`](../../Package.swift) still gives `ConduitHelper` a `ProxyKernel` dependency and has no `ConduitSyntax` target.

Does not prove: spool isolation between runtimes, aggregate spool budgets or replay backpressure, which #81 still lists.

## Open questions

None recorded.
