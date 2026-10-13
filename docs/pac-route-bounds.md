# PAC route admission

`pacUsableRouteLimit` is a file-only integer in the existing flat Conduit JSON
configuration. It defaults to **32**, including when absent from an older file,
and validation accepts **1–128**. Invalid values reject configuration at the
normal validation boundary. A change takes effect on the next request without
replacing listeners, closing established streams, dropping cached answers or
refetching the PAC.

```json
{
  "pacUsableRouteLimit": 32
}
```

The engine retains the first N usable directives in their original order. Both
PROXY and DIRECT consume one slot. Unsupported and invalid directives do not
consume slots; their existing rejection accounting remains bounded separately.
Excess usable routes are counted but never attempted. PACChain itself enforces
the 128-route ceiling even for alternative adapters and direct constructors, and
the cache keeps chains at that ceiling: each answer is trimmed to N when it is
handed out, so raising N uses routes already cached. The 512-key cache therefore
retains at most 512 × 128 usable routes.

| DIRECT position | Policy |
| --- | --- |
| Explicit first directive | Existing explicit DIRECT precedence is preserved. |
| First usable directive after rejected entries | Existing promoted-DIRECT/strict-mode rules are preserved. |
| Within the retained prefix after proxies | Existing permitted DIRECT fallback is preserved. |
| Beyond the usable-route limit | Dropped with the other excess routes; never moved into the prefix. |

A PAC relying on a later proxy or DIRECT beyond N will no longer try it. Raise
the configured limit within the validated range if the deployment requires more
fallback entries. Truncation never adds a reachability shortcut or relaxes strict
mode. Empty/all-rejected answers retain the configured-upstreams-only policy.

`pac.routes_truncated` reports `retained`, `dropped`, `limit` and `suppressed`
counts without raw PAC text, endpoints or URLs. One global slot per engine emits
at most once per minute; the next report counts suppressed evaluations. Cache
hits do not generate additional truncation occurrences. See `docs/events.md`.

`pm-sim pac-route-bounds` uses a native oversized PAC and real loopback CONNECT
attempts: a two-route cap excludes a healthy third proxy and a trailing DIRECT;
a three-route cap admits that proxy in its original position.
