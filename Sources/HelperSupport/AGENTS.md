# HelperSupport

The helper's policy for decision 0049, without its SystemConfiguration session: `VPNDNSOverridePublisher`, its store protocol `VPNDNSStore`, the relay protocol `VPNDNSFailoverRelay` that `DNSFailoverRelay` conforms to here, and the start-up report of a legacy record, which writes nothing. `ConduitHelper` runs it over the real store; `FakeMachine` and pm-sim run it over `FakeVPNDNSStore`.

- Depends on `ConduitShared` (the IPC values it reports) and `ProxyKernel` (the relay). The kernel never imports it.
- No machine side effects here: the store and the relay come in through their protocols.
- Single-threaded by contract: the helper calls it from its one loop, `FakeMachine` from under a lock.
