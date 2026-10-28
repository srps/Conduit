# Lifetime-corrected app composition: Release profile

Code commit `673e53ab58ddd131f951a65eb2985a193725de33` has clean product source.
The complete 41-step workflow exited 0 before measurement (3,700 tests, four skips,
103 simulator records). Release builds; all 31 fresh trials pass 481 checks, with
no failure/inconclusive/pinned result and every scratch root removed. Host,
observer, flush and lease release checks all pass. Source and linked objects
remain unchanged during the run. [Metadata](metadata.json) and
[build/run provenance](build-and-probe.json) retain the complete records.

The actual widest client Quit uses the selected 10,000 ms total and returns in
974.235 ms with verified final saves, closed listener and cleared system proxy.
This is fake-effect timing, separate from AppKit and real-helper timing.

The probe consumes RuntimeServiceProfile.inProcessApp and compares every term
against independent codec-derived limits. All measured terms equal the shipping
profile; none differ. Its retained legacy label saying other terms are proposed
is historical wording, not an unadopted configuration or a new owner decision.

Fingerprint scopes differ by construction:
- Full workflow/build/consumer: `01691fd16ac6d74d348bccb41c82f2dea51b882c70e4bcef81c811a088cdf402`
  hashes relevant Source, Tests, scripts, workflows, resources, manifest and build inputs.
- Probe product fingerprint:`4b07b1530977a513505d4f093f25c097c4080340b2481ff27161b7d6e24b86d8` uses Git index/diff plus untracked bytes
  for Sources/ and the package manifests; metadata confirms clean product source.
- Immutable lifetime review: `383c41a361a5c90bd471c1fba9f10e2310348382e39b3e873c98d47ea27748f5`
  hashes its 790 copied Source/Test/instruction/selected-document files. A later
  two-line test-only weak-var spelling retains Swift 6.2 compatibility; production
  Source is unchanged. The new workflow tests that final spelling.

Each scope ties to the same corrected production bytes at `673e53a`; these hashes
are not interchangeable. Their matching before/after values prove stability
within that scope, not a process-memory or installed-machine guarantee.

No other local build/test/probe ran during the measurements. Three additional
fresh Debug consumer trials also pass; [their raw data](../../../appstate-consumer-observation/lifetime-fix-results.json)
keeps the separate scope. Encoded custody is not app RAM; fixture/observation/
draft objects are intentionally retained by some modes. Native and hosted
acceptance for the new PR head remain separate; the Mac is still locked.
