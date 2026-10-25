# ConduitDaemon

The daemon entry point: argument and config loading, signals, `--print-status` output and the resident wait. The runtime policy it runs is `RuntimeHost` in `Sources/ConduitRuntime/`, with the twin rule in that target's `AGENTS.md`.

- Keep policy out of this target. A lifecycle, reconcile or observer rule belongs in `ConduitRuntime`. This target only composes the host.
- Inject process concerns here and nowhere else: pass `startedAt` and `terminalExit`, and pass production collaborators explicitly.
- `exit` is called from this file only.
- Take the state root first. `acquireStateRoot` runs before any load, migration, seed, journal restore or host construction, and a busy or refused root exits with its `config.state_root_*` event on stderr (decisions 0017 and 0028). The session is pinned for the process, and `RuntimeHost` takes it, never a raw environment.
