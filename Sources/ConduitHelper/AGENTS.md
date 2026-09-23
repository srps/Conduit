# ConduitHelper

The privileged LaunchDaemon. Only operations that need root belong here.

- Validate every port to 0–65535 before a `UInt16` cast.
- A change here needs `sudo ./install-helper.sh` before the app will use it. Say so in the PR.
