# ConduitShared

The app↔helper wire contract, plus `DomainNameSyntax`, which the config boundary and the helper's input validation share.

- Ask before changing the helper XPC/IPC surface. It is a versioned contract with helpers installed in the field.
- Extend this protocol rather than adding ad-hoc IPC.
