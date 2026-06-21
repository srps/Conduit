# Crash-Report Triage Runbook

How to root-cause a Conduit `.ips` crash report. Template derived from a
GSS/SPNEGO SIGSEGV investigation that went from report to a one-line fix using
exactly these steps.

## 0. Get the report

- Users: `pmctl diag` — the bundle includes the recent sanitized
  `Conduit*.ips` reports automatically.
- Locally: `ls ~/Library/Logs/DiagnosticReports/Conduit*`.

An `.ips` file is one JSON header line followed by a JSON body.

## 1. Read the exception block first

```bash
python3 - <<'EOF'
import json, sys
body = json.loads(open(sys.argv[1]).read().split('\n', 1)[1])
print(json.dumps(body.get('exception'), indent=2))
print(body.get('vmRegionInfo', '')[:200])
EOF
```

What to note:

- **`EXC_BAD_ACCESS` + a small fault address** (`0x0`, `0x8`, `0x10`…) is a
  NULL-pointer dereference through a struct field; the address *is* the
  field offset. In the GSS crash, `0x8` was `gss_buffer_desc.value` — the
  second field after a `size_t`.
- **`EXC_BREAKPOINT` / `SIGTRAP`** on arm64 is usually a Swift runtime trap:
  force-unwrap, precondition, array bounds, or a NIOAny type-mismatch
  fatal — the crashing frame's symbol will say which.
- `vmRegionInfo` saying "not in any region / bytes before following region"
  confirms a near-NULL deref rather than a wild pointer.

## 2. Extract the crashed thread's backtrace

```bash
python3 - <<'EOF'
import json, sys
body = json.loads(open(sys.argv[1]).read().split('\n', 1)[1])
imgs = body['usedImages']
for t in body['threads']:
    if not t.get('triggered'): continue
    for fr in t['frames']:
        img = imgs[fr['imageIndex']]
        print(f"  {img.get('name','?')}  {fr.get('symbol','?')} + {fr.get('symbolLocation','?')}")
EOF
```

## 3. Interrogate the backtrace's *shape*, not just its symbols

The decisive evidence is often which frames are **absent**:

- In the GSS crash, `SystemGSSTokenProvider.generateToken` has two branches
  — one wraps the input token in `Data.withUnsafeBytes`, one passes NULL.
  The backtrace showed `Array.withUnsafeMutableBufferPointer` (the OID
  wrapper, common to both) but **no** `Data.withUnsafeBytes` frame → the
  crash was provably in the nil-input branch. Combined with the `0x8`
  field offset, that pinned the exact call signature that crashed.
- Closure frames (`closure #1 in …`, `partial apply …`) tell you which
  callback path delivered the call — match them to the source's actual
  closures before theorizing.

## 4. Reconstruct the trigger from program state

Ask: what *state* must have been true for this branch to execute? Then ask
what real-world input produces that state. For the GSS crash: a live
`gssContext` (a prior handshake leg ran) **and** a nil input token (a bare
`Negotiate` re-challenge) — i.e., a proxy rejecting a token mid-handshake
or re-authenticating a kept-alive connection. Long-uptime daily-driver
processes (check `procLaunch` vs `captureTime` in the report — the GSS
crash had ~4.5 days of uptime) hit rare-state bugs that fresh processes
never see.

## 5. Fix at the invariant, not the symptom

Express the fix as the invariant that was violated, enforce it structurally,
and write it down at the call site:

- GSS crash: *"a nil/empty input token always means a fresh handshake"* →
  discard stale context before the call.
- NIOAny type-mismatch traps: *"no raw byte may reach a pipeline that still
  has an HTTP codec installed"* → fix splice ordering (see the upgrade-relay
  history in `HTTPProxyHandler.swift`).

## 6. Pin it

- Unit/regression test if the trigger is constructible (EmbeddedChannel
  reproduces most pipeline-state bugs synchronously).
- `pm-sim` scenario if it's runtime behavior — and run it under
  ASan/TSan (`swift run --sanitize=address pm-sim <scenario>`); the
  sanitizer soak exists because this class of bug hides in C-boundary and
  cross-event-loop timing windows that plain runs race past.
- If it cannot be tested without external infrastructure (live KDC, real
  corporate proxy), say so explicitly in the fix's comment and the audit
  note, so the gap is a documented decision rather than an accident.

## 7. Record it

Add an analysis note under `audit/` (local-only by convention) with the
backtrace, the branch-elimination reasoning, and the invariant, so the next
investigator inherits the reasoning rather than rediscovering it.
