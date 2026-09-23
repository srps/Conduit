# ProxyAuth

NTLM and Kerberos/Negotiate authenticators, and `credentialBasedAuthenticatorProvider`, the factory every host uses.

- An authenticator keeps per-handshake state across challenge rounds; the kernel reuses one instance per handshake (see `Sources/ProxyKernel/AGENTS.md`). Keep that state in the instance, never in shared or static storage.
- Keep `NegotiateAuthenticator`'s NTLM fallback lazy. The Keychain is read only when Kerberos has failed; loading it eagerly prompts users who never needed NTLM.
- Every auth outcome emits a `RuntimeEvent` through the factory's `outcomeHandler` or `eventSink`. An event that would fire on every failing request is rate-limited per host and reason, as `KerberosFailureEventGate` does, so it cannot flood the bounded `RuntimeEventLog`. Don't re-arm such a gate on an initial-leg success: the continuation leg can still fail on every request.
