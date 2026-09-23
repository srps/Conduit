# ProxyAuth

NTLM and Kerberos/Negotiate authenticators, and `credentialBasedAuthenticatorProvider`, the factory every host uses.

- Reuse one `ProxyAuthenticator` instance across the challenge rounds of a handshake. Upstream proxy auth is stateful per connection, and a new instance breaks multi-leg SPNEGO and NTLM.
- Keep `NegotiateAuthenticator`'s NTLM fallback lazy. The Keychain is read only when Kerberos has failed; loading it eagerly prompts users who never needed NTLM.
- Every auth outcome emits a `RuntimeEvent` through the factory's `outcomeHandler` or `eventSink`. An event that fires on every failing request is gated per host to state changes, as `KerberosFailureEventGate` does, so it cannot flood the bounded `RuntimeEventLog`.
