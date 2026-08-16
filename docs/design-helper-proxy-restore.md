# Design handoff: restoring the user's own proxy settings on a machine that needs admin

> **Status: not started.** This is a handoff brief for a design conversation, written
> 2026-08-16 while finishing PR #56. Everything below is verified against the tree at
> `9b9253f` on `fix/unify-platform-side-effect-ownership` unless marked otherwise.

## The problem in one paragraph

PR #56 teaches Conduit to record what the machine's proxy settings were before it
changed them, so teardown can put them back instead of blanket-disabling. The recording
works. The putting-back does not — on any machine where the user cannot write proxy
settings without admin rights, which includes the project's own primary target. There,
every teardown degrades to a blanket clear and the recorded values are kept but never
applied. The feature currently buys "nothing is lost permanently" rather than "your
settings come back".

## Evidence

Verified on the development machine (macOS 26, non-admin-for-networksetup user):

```
$ networksetup -setautoproxyurl "Thunderbolt Bridge" http://example.test/a.pac
** Error: Command requires admin privileges.

$ networksetup -getautoproxyurl "Wi-Fi"
URL: http://127.0.0.1:63145/proxy.pac
Enabled: Yes
```

Unprivileged writes are refused, yet Wi-Fi carries Conduit's PAC URL — so `apply`
only ever reached the machine through `SystemProxyManager.applyViaPrivilegeClient`, the
privileged-helper fallback. **The requires-admin path is the default here, not an edge
case.** Any reasoning that treats it as rare is wrong for this deployment.

Follow it through `clear()`: the restore script is unprivileged, it fails with
`requires admin`, and the code degrades to `PrivilegedOperation.clearSystemProxy` per
service, sets `restoreSucceeded = false`, and keeps the records. Nothing is restored,
ever.

### A related bug this uncovered, already fixed in #56

On `main`, every command in the teardown script ends in `2>/dev/null || true`. That forces
the script's exit code to 0 and discards the `requires admin` text — and the fallback
detection keys on both. So on this machine `clear()` silently cleared *nothing* while
logging "Cleared macOS proxy settings." That is the stale-PAC symptom that started this
whole line of work: proxy stopped, system PAC still enabled and pointing at a dead port.
Fixed in `9b9253f` by removing the suffixes; the fallback now fires. Mentioned here
because it means **teardown-via-helper is newly load-bearing** and any design here inherits
that path.

## The key discovery: most of a restore is already expressible

The helper contract (`Sources/ConduitShared/HelperContract.swift`) already has four
proxy-writing operations, implemented in `Sources/ConduitHelper/HelperTool.swift`:

| Operation | What the helper actually runs |
|---|---|
| `applySystemProxy(service, host, port)` | `-setwebproxy` + `-setsecurewebproxy` (same host/port), then `-setwebproxystate on` + `-setsecurewebproxystate on` |
| `clearSystemProxy(service)` | `-setwebproxystate off`, `-setsecurewebproxystate off`, `-setautoproxystate off` |
| `setAutoproxyURL(service, url)` | `-setautoproxyurl`, then `-setautoproxystate on` |
| `disableAutoproxy(service)` | `-setautoproxystate off` |
| `setProxyBypass(service, domains...)` | `-setproxybypassdomains` |

The prior state #56 records per service is
`{webEnabled, webHost, webPort, secureEnabled, secureHost, securePort, autoEnabled, autoURL, bypassDomains}`
(see `SystemProxyManager.capturePriorState`). Mapping it onto the above:

**Expressible today:**
- bypass domains → `setProxyBypass` (exact)
- autoproxy enabled, URL present → `setAutoproxyURL` (exact)
- autoproxy disabled, URL present → `setAutoproxyURL` then `disableAutoproxy`
- autoproxy disabled, no URL → `disableAutoproxy`
- web **and** secure both enabled on the **same** host/port → `applySystemProxy`

**Not expressible:**
1. Web and secure with *different* endpoints, or only one of the two enabled —
   `applySystemProxy` writes both to one host/port and turns both on.
2. Writing an endpoint *without* enabling it — needed because `networksetup` retains
   host/port on a disabled proxy, and leaving Conduit's address there hands it to the
   user the moment they re-enable. (#56 already restores this correctly on the
   unprivileged path; the privileged path cannot.)
3. Partial clears — `clearSystemProxy` is all-or-nothing and also kills autoproxy, so it
   cannot serve as a building block.

So the design question is **not** "how do we add a restore operation" but "how much of the
gap is worth closing, and at what cost to a versioned IPC surface".

### Verified `networksetup` behaviour worth knowing

`-setautoproxyurl` **enables autoproxy as a side effect** — writing a URL to a service
whose autoproxy is off leaves it reporting `Enabled: Yes`. Confirmed empirically
2026-08-16; documented in neither `man networksetup` nor the usage string. This is why
`setAutoproxyURL` must be followed by `disableAutoproxy` when restoring a
configured-but-disabled URL, and why the unprivileged restore script writes its state line
last. Any new operation must preserve that ordering.

## Options to weigh

**A. Compose from existing operations, accept the gaps.** No contract change, ships
immediately, covers the common case (web and secure pointing at the same proxy, which is
what almost every corporate config and every GUI-configured proxy looks like). Falls back
to `clearSystemProxy` plus a loud log for asymmetric configs. Cost: silently lossy for a
minority, and case 2 above means a disabled endpoint keeps our address.

**B. One new operation that takes the whole prior state.** e.g.
`restoreSystemProxy(service, webEnabled, webHost, webPort, secureEnabled, secureHost,
securePort, autoEnabled, autoURL, bypass...)`. Exact, single round-trip, one new case to
validate. Cost: a wide argument list over a security boundary, and a versioned-contract
change — `AGENTS.md` says to ask first, and the field-compat argument is weak but the
review burden is real.

**C. Two narrow primitives.** `setWebProxy(service, kind, host, port, enabled)` and
`setAutoproxy(service, url, enabled)`, composing to cover everything. More round-trips,
smaller and more reviewable each, and they subsume the existing `applySystemProxy` /
`setAutoproxyURL` / `disableAutoproxy` — which raises whether to deprecate those.

My prior, weakly held: **C**, with A as the interim if the contract change needs to wait.
But this is exactly what the design conversation is for.

## Constraints and things not to break

- **`AGENTS.md`: "Ask before changing the helper XPC/IPC surface" in `ConduitShared`** —
  it is a versioned contract. Note the mitigating fact: the project is pre-0.1 with no tags
  and no releases, and `docs/RELEASE-PREP.md` ships 0.1 as a fresh repo, so there are no
  installed daemons in the field except the developer's own.
- **Validation is mandatory and already exists.** `HelperTool` calls `validateService`,
  `validateServiceHostPort`, `validateAutoproxyURL` before every `run`. Any new operation
  must validate every argument the same way; the threat model treats helper input as
  untrusted. See `docs/threat-model.md` and `Tests/ConduitTests/HelperContractTests.swift`.
- **The helper is versioned and rejects unversioned frames** (`HelperDaemon.swift`). Adding
  a case means deciding whether old helpers must be re-installed, and what a new client
  does when it meets an old helper — probably: detect the unknown-command error and fall
  back to option A's composition.
- **`SystemProxyManager.restoreScript` already builds the correct unprivileged sequence.**
  Whatever the privileged path does should produce the same end state; consider driving
  both from one description of the target state rather than writing the logic twice. The
  duplicate-implementation problem is what #56 was about in the first place.

## Where the code is

| Concern | File |
|---|---|
| Prior-state capture / restore / teardown | `Sources/PlatformMac/SystemProxyManager.swift` (`capturePriorState`, `restoreScript`, `clear`, `applyViaPrivilegeClient`) |
| Prior-state storage | `Sources/PlatformMac/PlatformStateJournal.swift` |
| Contract enum | `Sources/ConduitShared/HelperContract.swift` |
| Privileged implementation | `Sources/ConduitHelper/HelperTool.swift` |
| Frame handling / versioning | `Sources/ConduitHelper/HelperDaemon.swift` |
| Tests | `Tests/ConduitTests/SystemProxyManagerTests.swift`, `HelperContractTests.swift`, `PrivilegeAuditTests.swift` |

## How to verify any of this for real

The unprivileged path can be driven entirely from tests — `SystemProxyManager` takes an
injectable `commandRunner`, and `FakeNetworksetupRunner` in the test file models
`networksetup` well enough to assert on generated scripts. The privileged path cannot: it
needs the installed helper.

For manual verification, `Thunderbolt Bridge` on the development machine is a safe target —
it has no IP address, so `connectedNetworkServices` excludes it and Conduit never
manages it, but `networksetup` will still read and write its proxy settings. Save and
restore its state around any experiment:

```
networksetup -getautoproxyurl "Thunderbolt Bridge"   # save
... experiment ...
sudo networksetup -setautoproxystate "Thunderbolt Bridge" off   # restore
```

Do **not** experiment on Wi-Fi; it carries the live proxy configuration.

## Open questions for the design conversation

1. Which option — and if C, do `applySystemProxy` / `setAutoproxyURL` / `disableAutoproxy`
   get deprecated, or kept for compatibility with a helper that predates the change?
2. What should a new client do when it meets an old helper? Silent composition fallback, or
   a visible "re-install the helper to restore proxy settings" prompt?
3. Should restore be attempted at *launch* as well as teardown? See #57 — there is no
   crash-recovery pass for this surface, and launch is the moment when the recorded prior
   is most likely still the truth.
4. Is a lossy restore worse than no restore? An asymmetric web/secure config restored as
   symmetric is arguably worse than leaving it cleared, because it looks correct.
5. Does `setProxyBypass` with zero domains actually clear the list, or does it need the
   literal `Empty` that the unprivileged path uses? Unverified.
