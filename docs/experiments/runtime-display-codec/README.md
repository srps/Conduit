# Bounded display codec: allocation and lifetime evidence, 2026-10-25

These are isolated synthetic processes using the actual release `ControlDisplayText`,
`RuntimeSnapshotControlProjection` and `ControlRuntimeCodec`. No app, helper, user
configuration, machine settings or network is involved. The serving Conduit was unchanged.
This is experiment code, not a product target, CI RSS threshold or a second implementation
of the policy. The source fixture is derived from `DisplayBoundsFixture` in the projection
tests, with unused collection construction removed so its existing kernel destination
sanitizer cannot be mistaken for the display path.

Each process owns one update at a time. It constructs fourteen populated display fields,
projects and encodes a complete snapshot frame, drops sender forms, decodes it, releases
the decoded form, then repeats. The fields share one synthetic input String through value
semantics; they are not fourteen independently allocated raw inputs. These fixtures use
small metadata and no collection rows. They are allocation/lifetime samples, not the wider
baseline-size fixture or a universal memory maximum. Byte-size maximum exploration lives
in `RuntimeDisplayBoundsProjectionTests`.

`ResourceProbe.swift` is the exact final executed 101-update source. There is **no explicit
caller autorelease pool**. The first result is checked and sampled, then 100 more updates
are checked without retaining results. `after-results.json` preserves every numeric line
and process exit. Each of seven fresh processes exits 0. Short text and a4,096-byte Bearer
token exercise the unchanged and redacted-without-cut return paths; all cut cases check
14 notices, and omitted cases check the fixed marker. The short cases check zero notices.

| Fixture | Complete snapshot frame, B | Live malloc after first release, B | After101 releases, B | Whole-process peak RSS after 101, B |
| --- | ---: | ---: | ---: | ---: |
| plain-short | 2156 | 302288 | 302304 | 10141696 |
| redacted-short | 1946 | 434080 | 434096 | 10321920 |
| plain-cap-over | 10094 | 320400 | 320416 | 10190848 |
| nul-cap-over | 48494 | 320400 | 320416 | 10485760 |
| sanitizer-input-limit | 10094 | 320464 | 320480 | 10485760 |
| omitted-input | 2512 | 137632 | 137648 | 9453568 |
| double-input-limit | 2512 | 137696 | 137712 | 9568256 |

The +16B difference over100 additional updates is the observed curve, not a tolerance or
contract. In particular, the 16KiB-input case is320,464→320,480B. Resident/high-water bytes
need not fall when an allocation is freed. Library mappings, allocator reservations,
Foundation caches and initialisation contribute. `malloc_zone_statistics` is current live
allocator use at the sample, not a peak allocator counter; the sender sample is taken
after the display helper's inner scope has drained, so it does not measure the helper's
instantaneous transient peak. `getrusage.ru_maxrss` is a whole-process high-water value
(bytes on this macOS); `TASK_VM_INFO` reports current resident/physical-footprint values.
None is steady running-Conduit RAM or a bound for concurrent peers/rows/traffic.

## Defect and correction witnessed

`BeforeResourceProbe.swift`, `BeforePolicy.swift.txt` and `before-results.json` preserve the earlier no-caller-pool,
11-update witness, before the synchronous autorelease scope was added. At the 16KiB input
limit, live malloc was89,056B baseline,2,816,080B after the first release and27,799,712B
after 11 updates. Plain/NUL cap-over cases also grew. Inputs above the raw gate stayed flat.
A controlled caller-pool comparison stayed flat, identifying an autorelease-lifetime risk
for callers without a draining run loop; this does **not** establish a leak in the installed app.

The correction is one synchronous autorelease scope around the shared sanitize-then-cut
path, after the raw gate. Platforms without Objective-C use the same path directly. The
bounded Swift result stays owned through ARC; no speculative native-string copy, global
cache, new caller cleanup or alternate projection was introduced. The final11-update
comparison also passed, followed by the101-update witness above. Source was rebuilt in
release mode each time; old and new source use the same codec and fixture pipeline.

An initial scratch compile failed because an unused XCTest-only fixture method used an
internal memberwise initializer. Removing that unused method from the standalone harness
fixed compilation; product access was not widened. An earlier full-kernel fixture also
constructed rows unused by the scalar measurement. Those observations were excluded from
this scalar-only table, rather than attributing their preprocessing cost to this policy.

## URL-dense work (independent review follow-up)

`URLDenseProbe.swift` runs two fresh cases, three updates each, without caller pools:
1,820 short URLs or 1,260 URLs with userinfo,16,380 input bytes per displayed field. The actual
bridge and codec run on all 14 fields. Both exit 0 with capped text and14 notices. Live malloc
is 321,024→321,040B across the additional two updates. Whole-process peak RSS is10,829,824B
and 11,124,736B. The first complete update took about 39ms/42ms; subsequent two together
about45ms/78ms. These are single local observations, not percentiles or deadline guarantees.
The inherited URL sanitizer can do work per match, so a byte cap alone is not a linear-time
claim. Actual collection work is also bounded by its row/byte budget. Per-turn CPU scheduling,
actual-host Stop/status latency and the shipping service profile remain adoption gates.

## Reproduction and scope

Observed on local arm64 macOS with the Xcode toolchain, release product objects and an
`-O` standalone probe. Build `ProxyControlBridge` in release mode with the required
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, then use `run.py` with an
output directory. It links existing product/dependency objects with `-package-name conduit`,
so it changes no product access or dependencies. It runs only the final and URL-dense
sources: the before-fix source must be linked with the corresponding pre-fix product objects
if reproducing that historical witness. A fresh-cache reproduction initially exposed missing
generated NIO C module maps; the runner now supplies the generated map inventory
explicitly, rather than relying on the original probe cache. Results are platform/process samples and should be
interpreted with the stage and lifetime distinctions above.
