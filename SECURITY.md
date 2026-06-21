# Security Policy

## Supported Versions

Conduit is pre-1.0. Security fixes are applied to the latest commit on `main`.

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| < main  | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability, **please do not open a public issue.**

Instead, report it privately via one of:

1. **GitHub Security Advisories** - use the "Report a vulnerability" button on the [Security tab](../../security/advisories/new) of this repository.
2. **Email** - send details to sergio.pds@outlook.pt with subject line `[Conduit Security]`.

### What to include

- Description of the vulnerability
- Steps to reproduce or proof of concept
- Impact assessment (what an attacker could achieve)
- Affected component (e.g., helper daemon, PAC evaluator, DNS forwarder)

### Response timeline

- **Acknowledgment**: within 72 hours
- **Initial assessment**: within 7 days
- **Fix timeline**: depends on severity (critical: ASAP, high: 14 days, medium: 30 days)

### Scope

The following are in scope:

- Local privilege escalation via the helper daemon
- Credential leakage (Proxy-Authorization headers, Keychain data, NTLM hashes)
- Path traversal in helper commands
- Unauthenticated access to the proxy when `strictMode` is enabled
- DNS cache poisoning or response injection
- PAC evaluation sandbox escapes

Out of scope:

- Denial of service against the local proxy (it's a local-only tool by default)
- Attacks requiring physical access to an unlocked machine
- Issues in third-party dependency code (report upstream; notify us if exploitable via Conduit)

## Security Design

See [`docs/threat-model.md`](docs/threat-model.md) for the full threat model and [`docs/STYLE.md`](docs/STYLE.md) §8 (Security-first) for the engineering discipline around credentials and trust boundaries.
