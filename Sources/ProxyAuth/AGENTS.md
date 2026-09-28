# ProxyAuth

NTLM and Kerberos/Negotiate authenticators, and `credentialBasedAuthenticatorProvider`, the factory every host uses.

- An authenticator keeps per-handshake state across challenge rounds; the kernel reuses one instance per handshake (see `Sources/ProxyKernel/AGENTS.md`). Keep that state in the instance, never in shared or static storage.
- Keep `NegotiateAuthenticator`'s NTLM fallback lazy: constructing an authenticator never reads credentials. The Keychain is read when Kerberos has failed, or once at proxy start when a password is saved (`CredentialManager.warmCache`, #98), so a user who never saved one is never prompted. `CredentialManager` caches the read; don't add a second cache here.
- Every auth outcome emits a `RuntimeEvent` through the factory's `outcomeHandler` or `eventSink`. An event that would fire on every failing request is rate-limited per host and reason, as `RuntimeEventRepeatGate` does, so it cannot flood the bounded `RuntimeEventLog`. Don't re-arm such a gate on an initial-leg success: the continuation leg can still fail on every request.
