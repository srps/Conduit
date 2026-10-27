# Native-client complete workflow checkpoint

All41 checks passed at source `ef3e4dfcdc712e29b46a78953a01ab00caa4b852`.
The source fingerprint is unchanged at the start and end. The Swift suite ran
3,685 tests with four skips and zero failures; pm-sim emitted103 scenario records.
`results.json` preserves each exact command, exit code and elapsed time.
Commands implement every local step of `.github/workflows/swift.yml`, plus the
DNS ephemeral-port regression. The repository workflow remains the authority;
this directory adds no parallel workflow implementation.

The fingerprint hashes sorted unique tracked/nonignored files under Sources,
Tests, scripts, .github and Resources, plus Package.swift, Package.resolved,
bundle-app.sh and VERSION, including path bytes and file bytes. It differs from
the resource probe's product-source fingerprint by design. Documentation-only
changes after this checkpoint received decision and diff checks; hosted CI
checks the final PR head separately.

This is local build/test evidence, not installed-machine or release acceptance.
