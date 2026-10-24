# ConduitShared

The app↔helper wire contract and the control contracts, plus neutral values with no kernel dependency: `SecretBytes` (decision 0018) and `DomainNameSyntax`, which the config boundary and the helper's input validation share. `DomainResourceLimits` holds the approved configuration resource ceilings and `DomainResourceField` names each place (decision 0021). `ConfigurationResourceSource` is the resource-only view of a configuration, and `DomainResourceCheck.configuration(_:)` is the one typed traversal over it: the kernel and private adapters only map storage. The private scanner is a separate byte-order traversal that reuses `DomainResourceField` and the shared counters.

- Ask before changing the helper XPC/IPC surface. It is a versioned contract with helpers installed in the field.
- Extend this protocol rather than adding ad-hoc IPC.
