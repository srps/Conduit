# ConduitShared

The app↔helper wire contract and the control contracts, plus neutral values with no kernel dependency: `SecretBytes` (decision 0018) and `DomainNameSyntax`, which the config boundary and the helper's input validation share.

- Ask before changing the helper XPC/IPC surface. It is a versioned contract with helpers installed in the field.
- Extend this protocol rather than adding ad-hoc IPC.
