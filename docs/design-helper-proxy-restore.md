# Design: restoring the user's own proxy settings on a machine that needs admin

> **Status: implemented.** Designed and built 2026-08-16 on
> `fix/unify-platform-side-effect-ownership`, on top of PR #56. The brief that
> opened this design conversation is preserved below under
> [The problem](#the-problem); everything from [Decisions](#decisions) onward
> records what was chosen and why.
>
> **Operational note: `sudo ./install-helper.sh` is required after this lands.**
> The helper protocol went 3 → 4. An un-reinstalled helper is reported
> `.outdated` in Settings and every privileged operation degrades to an admin
> prompt — which now works, and did not before (see [B2](#b2)).

## The problem

PR #56 teaches Conduit to record what the machine's proxy settings were
before it changed them, so teardown can put them back instead of blanket-
disabling. The recording worked. The putting-back did not — on any machine where
the user cannot write proxy settings without admin rights, which includes the
project's own primary target. There, every teardown degraded to a blanket clear
and the recorded values were kept but never applied. The feature bought
"nothing is lost permanently" rather than "your settings come back".

Verified on the development machine (macOS 26, non-admin-for-`networksetup`
user):

```
$ networksetup -setautoproxyurl "Thunderbolt Bridge" http://example.test/a.pac
** Error: Command requires admin privileges.

$ networksetup -getautoproxyurl "Wi-Fi"
URL: http://127.0.0.1:63145/proxy.pac
Enabled: Yes
```

Unprivileged writes are refused, yet Wi-Fi carries Conduit's PAC URL — so
`apply` only ever reached the machine through the privileged-helper fallback.
**The requires-admin path is the default here, not an edge case.**

### Verified `networksetup` behaviour worth knowing

**Writing an address enables the proxy, on every setter.** `-setautoproxyurl`
leaves a service reporting `Enabled: Yes` whatever it was before — and so does
`-setwebproxy`, including when clearing:

```
# web proxy was Enabled: No, Server: 10.1.2.3, Port: 1111
$ sudo networksetup -setwebproxy "Thunderbolt Bridge" "" 0
exit=0
$ networksetup -getwebproxy "Thunderbolt Bridge"
Enabled: Yes        # <- switched on by a command that only cleared an address
Server:
Port: 0
```

Confirmed empirically 2026-08-16 on macOS 26; documented in neither
`man networksetup` nor the usage string. Every path that writes an address must
therefore write the on/off state *after* it. This is enforced inside the
`setAutoproxy` and `setWebProxyEndpoint` operations rather than left to callers
to remember — the rule is the kind that gets forgotten once per call site, so
there is only one call site.

**An empty host with port `0` clears an address.** That is the form used to
blank a manual endpoint; see [B10](#b10) for why it is needed.

`sh -c` reports only the **last** command's exit status, which is what made the
old single-script teardown unable to detect a partial failure:

```
$ /bin/sh -c "networksetup -setwebproxystate 'Thunderbolt Bridge' off   # requires admin
              /usr/bin/true"
** Error: Command requires admin privileges.
script exit=0
```

`lsof` lives at `/usr/sbin/lsof` on macOS 26, not `/usr/bin/lsof`.

## Decisions

The options weighed were **A** (compose from the existing operations, accept the
gaps), **B** (one wide `restoreSystemProxy` taking the whole prior state), and
**C** (two narrow primitives). **C was chosen**, with four decisions around it.

### 1. Contract shape: two new operations

| Operation | Values | Helper runs |
|---|---|---|
| `setWebProxyEndpoint` | `service, kind (web\|secure), host, port, state` | `-set{web,securewebproxy}` if host non-empty, **then** `-set…state` |
| `setAutoproxy` | `service, url, state` | `-setautoproxyurl` if url non-empty, **then** `-setautoproxystate` |

Empty host/port and empty URL are legal and write only the state. That is the
case `applySystemProxy` could not express and restore needs most: `networksetup`
keeps host, port and URL on a *disabled* proxy, so putting a user's setting back
without switching it on is the common case, not an edge one. Asymmetric
configurations (web and secure at different addresses, or only one enabled) fall
out for free.

Ordering lives inside each operation, not in the caller. That is deliberate: the
`-setautoproxyurl` side effect above is the kind of rule that is got wrong once
per call site, so there is only one call site.

`applySystemProxy` / `setAutoproxyURL` / `disableAutoproxy` are **kept, not
deprecated** — an older helper's vocabulary should not shrink — but the restore
path no longer uses them.

### 2. Versioning: bump to 4, and make the fallback real

`HelperProtocolVersion.current` is now 4. The question the brief asked ("what
should a new client do when it meets an old helper?") turned out to have an
answer already baked in, and a bad one: see [B2](#b2). With that fixed, an old
or missing helper degrades to an AppleScript admin prompt and emits an
`auth.privilege_helper_degraded` event, instead of failing every privileged
operation outright.

Because the AppleScript fallback prompts **per invocation**, and a full restore
is four operations per service, `PrivilegeClient` gained
`execute(batch:)` — one elevation for a whole service. `AppleScriptPrivilegeClient`
renders the batch as a single script; the helper client loops over the socket
(where round-trips are free) and hands the *remainder* of the batch to the
fallback if the helper drops out mid-sequence. The protocol default
implementation loops, so existing conformers are unchanged.

### 3. Restore also runs at launch

`SystemProxyManager.restoreIfNeeded` mirrors `SystemDNSManager.restoreIfNeeded`,
called from `AppState` at startup: a run that was `SIGKILL`ed never tore down,
and launch is when the recorded prior is most likely still the truth. Same
7-day staleness rule. The "is this actually orphaned?" test is whether anything
is *serving* the loopback port the machine points at — see
[the port probe](#the-port-probe).

### 4. One description, two renderers

`ProxyServiceState` decodes the journal record; `writeSteps` turns it into an
ordered `[ProxyWriteStep]`; each step renders either to a shell command or to a
typed privileged operation. The two restore paths can no longer disagree,
because there is only one of them. This was the actual structural problem — two
implementations of one platform side effect is what the prior-state journal was
introduced to remove in the first place.

## Bugs found and fixed along the way

Ranked by what they cost the user.

**B1 — teardown trusted an exit code that could not report failure.** `clear()`
concatenated every service's commands into one `/bin/sh -c` and read
`result.exitCode` as "did the restore land"; `sh` reports only the last
command's status. A restore whose endpoint write failed but whose trailing
bypass write succeeded reported success, and `forgetAll` then destroyed the
records — the only copy of the user's real settings — for every service. Fixed
by making each service its own unit of work and prefixing the script with
`set -e`. Every write is an absolute set, so aborting early and re-running the
sequence through the privileged path is safe.

<a id="b2"></a>**B2 — `HelperToolPrivilegeClient` could not reach its own
documented fallback.** The class comment promised "falls back to AppleScript
when the helper is not installed or unreachable", but `sendRequest` throws
`helperNotInstalled` / `communicationFailed`, and `execute` had
`catch let error as PrivilegeClientError { throw error }` *ahead* of the
fallback. Only JSON coding errors ever reached it. So a machine with no helper
failed every privileged operation outright — meaning teardown cleared nothing at
all, silently, on exactly the machines this design targets. Now
`PrivilegeClientError.isHelperUnreachable` separates "could not reach or
understand the helper" (retry by another route) from "the helper ran it and it
failed" (a real error), and only the former degrades.

**B3 — bypass domains were the one unvalidated helper argument.** Both the
client and `HelperTool` validated the service name and passed the rest to
`networksetup` untouched, while every other operation validated everything. The
reason is visible in real data — `*.local` and `169.254/16` are both live on the
development machine and neither passes `validateDomain` — but the answer to
that is a bypass-specific rule, not an exemption from the trust boundary. Added
`validateProxyBypassEntry`, which also rejects a leading `-`: these reach
`networksetup` as argv, so an entry shaped like a flag is the one input that
changes what the command does.

This also settles the brief's open question 5. Zero domains is no longer
accepted; clearing takes the explicit `Empty` sentinel, mirroring how
`setDNSServers` already spells `empty`. A caller that lost its argument list is
now distinguishable from one that means "clear".

**B4 — `apply`'s PAC path still carried `2>/dev/null || true`.** The same
suppression `9b9253f` removed from teardown, under the same reasoning that was
found to be wrong. Removed.

**B5 — port `0` round-tripped into an invalid write.** `-getwebproxy` reports
`Port: 0` for a service that never had a manual proxy; carried through
literally that becomes `-setwebproxy host 0`, which the privileged path rejects
outright and the unprivileged one writes as an unusable endpoint.
`ProxyServiceState` normalises 0 to "no port", and `validateOptionalEndpoint`
requires host and port to travel together.

**B6 — the residue probe mis-fired on a user's own loopback proxy.** After a
successful restore the journal was forgotten, so `knowsSurfaceIsIdle` was true —
but `loopbackResidueExists()` still read a user's *own* loopback proxy (a local
mitmproxy, a second tool) as our residue, so the second teardown of a session
disabled what the first had just restored. That is the double-teardown erase
`4af8269` fixed, re-entering through the residue door.

The fix is the journal remembering that it let go. The applied marker now
carries an ownership payload — absent (legacy) or `applied` reads as applied,
`released` means teardown completed — written last-write-wins, unlike prior
values, because ownership describes the present and has to be able to change. A
released surface skips the residue probe entirely.

> An earlier sketch stored the *applied fingerprint* (our host/port/PAC URL) on
> the marker so residue could mean "matches what we wrote". That turns out not
> to be the lever: whenever a fingerprint exists the surface is marked applied,
> `knowsSurfaceIsIdle` is already false, and the residue probe is never
> consulted. The probe only runs when ownership is *unknown* — where by
> definition there is no fingerprint to compare against. Remembering the
> release is the whole fix.

**B7 — `PlatformSurface.systemProxy` did not document `bypassDomains`,** though
the enum's own docs promise each case lists its keys. Fixed, and pointed at
`ProxyServiceState` as the typed reader.

**B8 — `apply` records prior state and marks applied before attempting the
write,** so a fully failed apply leaves the surface permanently non-idle. Left
as-is: the consequence is a later teardown restoring values identical to what is
already there. Noted rather than fixed.

<a id="b10"></a>**B10 — teardown left Conduit's address in a service that
had none before it.** Found by driving the rebuilt helper against
`Thunderbolt Bridge`, not by reading the code. A service with no manual proxy
reports `Server: (empty), Port: 0`; apply overwrites that with
`127.0.0.1:<port>`; the recorded prior therefore says "no endpoint"; and both
renderers read an empty host as *write only the state*. So teardown switched the
proxy off and left our address in the `Server` field — to be handed to the user
the moment they re-enabled the proxy by hand. That is precisely the harm
restoring disabled endpoints exists to prevent, and it was inherited from #56's
`restoreScript`, which had the same skip.

The fix is that "the service had no address" and "do not touch the address" are
now different instructions. `ProxyEndpoint` has three cases — `.unchanged`,
`.cleared`, `.address` — and on the wire the host argument carries the
instruction, on the pattern `setProxyBypass` and `setDNSServers` already use:
empty leaves it alone, the `Empty` sentinel clears it. The blanket-clear path
still uses `.unchanged`, because an endpoint we never recorded is not ours to
erase.

**B9 — `SystemDNSManager.isPort53InUse()` had never returned `true` on macOS
26.** It shells out to `/usr/bin/lsof`, which does not exist on this OS version
(`lsof` moved to `/usr/sbin`), so the probe threw and answered "port free"
always — which made `restoreIfNeeded` treat a *running* relay's saved state as
orphaned and force a restore at launch. The path is now resolved from a list of
known absolute paths at first use. Absolute, not a `PATH` lookup: resolving tool
locations from the inherited environment is how a process that may elevate ends
up running someone else's binary.

<a id="the-port-probe"></a>
## The port probe

The proxy surface's "is this still being served?" test does **not** shell out.
`LoopbackPortProbe.isServed(port:)` does a non-blocking `connect` to
`127.0.0.1:port` and reads `SO_ERROR`. Three reasons:

1. It answers the question actually being asked. `lsof` reports which process
   holds a socket; a teardown decision needs to know whether the address the
   machine points at is being *served*.
2. No subprocess means no path to get wrong — which is exactly how B9 happened.
3. It is bounded: a loopback connect completes or is refused immediately, and
   the 250 ms timeout only covers a listener whose accept backlog is full.

A `bind` probe would avoid opening a connection, but it cannot serve the DNS
case (binding port 53 unprivileged fails with `EACCES` whether or not anything
holds it) and it misreports listeners using `SO_REUSEPORT`. So the DNS surface
keeps `lsof`, with its path resolved rather than assumed.

## Deferred: unify `apply`'s privileged path (separate issue)

In scope for this change was restore plus the structural fixes it depends on.
Deliberately **not** done, and worth its own issue:

- **`applyViaPrivilegeClient` still uses the old operations.** In `.pac` mode it
  runs `setAutoproxyURL → clearSystemProxy → setAutoproxyURL`, a three-operation
  re-arm dance with a window where the PAC is off, because `clearSystemProxy`
  also kills autoproxy. Expressed as `setWebProxyEndpoint(web, …, off)`,
  `setWebProxyEndpoint(secure, …, off)`, `setAutoproxy(url, on)` it becomes
  three independent writes with no window and no dance.
- **Privileged PAC apply has never set bypass domains.** The unprivileged PAC
  path does not either, so this is a pre-existing gap on both sides rather than
  a divergence — but the manual path does, and the asymmetry is not explained
  anywhere.
- **`apply` is still one concatenated script for all services,** so it carries
  B1's exit-code blindness. It is less dangerous there (apply throws on failure
  rather than dropping records) but it is the same bug.
- **Once `apply` moves over,** `applySystemProxy` / `setAutoproxyURL` /
  `disableAutoproxy` have no remaining callers and the deprecation question
  from the original brief becomes live.

## Constraints honoured

- **`AGENTS.md`: "Ask before changing the helper XPC/IPC surface".** Asked and
  agreed before implementing. Mitigating fact: the project is pre-0.1 with no
  tags and no releases, so the only installed daemon in the field is the
  developer's own.
- **Validation is mandatory.** Every new argument is validated on both sides of
  the boundary — `HelperToolPrivilegeClient.validate` before IPC and
  `HelperTool` before execution — and the whole batch is validated before any of
  it runs, so a step rejected halfway cannot leave a surface in a state no
  caller asked for.
- **No silent recovery.** The degrade to AppleScript emits
  `auth.privilege_helper_degraded`; `AuditingPrivilegeClient` audits every step
  of a batch.

## Where the code is

| Concern | File |
|---|---|
| Target state, write steps, both renderers | `Sources/PlatformMac/ProxyServiceState.swift` |
| Capture / restore / teardown / launch recovery | `Sources/PlatformMac/SystemProxyManager.swift` |
| Prior-state storage and surface ownership | `Sources/PlatformMac/PlatformStateJournal.swift` |
| Port probe | `Sources/PlatformMac/LoopbackPortProbe.swift` |
| Contract enum and validators | `Sources/ConduitShared/HelperContract.swift` |
| Operation enum, batch step, error classification | `Sources/ProxyKernel/Abstractions/PrivilegeClient.swift` |
| Client implementations and the fallback | `Sources/PlatformMac/HelperPrivilegeClient.swift` |
| Privileged implementation | `Sources/ConduitHelper/HelperTool.swift` |
| Tests | `SystemProxyManagerTests`, `HelperContractTests`, `PlatformStateJournalTests`, `LoopbackPortProbeTests`, `PrivilegeAuditTests` |

## How to verify by hand

The unprivileged path is fully driven from tests — `SystemProxyManager` takes an
injectable `commandRunner` and `portProbe`, and `FakeNetworksetupRunner` models
`networksetup` well enough to assert on generated scripts and privileged
batches. The privileged path needs the installed helper, rebuilt at protocol 4.

`Thunderbolt Bridge` on the development machine is a safe target — it has no IP
address, so `connectedNetworkServices` excludes it and Conduit never
manages it, but `networksetup` will still read and write its proxy settings.
Save and restore its state around any experiment:

```
networksetup -getautoproxyurl "Thunderbolt Bridge"       # save
networksetup -getproxybypassdomains "Thunderbolt Bridge"
... experiment ...
sudo networksetup -setautoproxystate "Thunderbolt Bridge" off   # restore
```

Do **not** experiment on Wi-Fi; it carries the live proxy configuration.

### What was verified against the live helper

Driven over the helper socket on 2026-08-16, against `Thunderbolt Bridge`, with
the machine's state saved and restored around it:

- **`Empty` clears the bypass list.** Read back as
  `There aren't any bypass domains set on Thunderbolt Bridge.`, which is the
  string `readBypassDomains` filters on. The brief's open question 5 is closed.
- **An asymmetric configuration round-trips exactly**: web enabled at one
  address, secure *disabled* at a different one, and a PAC URL written while
  staying `Enabled: No`. None of the three was expressible before.
- **Helper-side validation holds with the client's validation bypassed** — the
  threat model's actual case, since the helper must not trust its input. Ten
  malformed frames sent straight to the socket (bad kind, port `0`,
  half-specified endpoint, bad state, `file://` PAC URL, credentials in the PAC
  URL, `-setwebproxystate` as a bypass entry, zero-argument bypass,
  `Empty` alongside a domain, and `Wi-Fi; rm -rf /` as a service name) were all
  rejected, and the machine was unchanged afterwards.
- **The version gate holds both ways**: a protocol-3 frame to the protocol-4
  helper is refused, and the refusal carries `protocolVersion: 4` so a client
  can tell *outdated* from *broken*.
- **B10 was found this way**, which is the argument for doing this at all: it is
  invisible in the code and obvious the moment a real service with no manual
  proxy goes through a full apply-and-restore.
