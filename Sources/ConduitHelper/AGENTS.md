# ConduitHelper

The privileged LaunchDaemon. Only operations that need root belong here.

- Validate every port to 0–65535 before a `UInt16` cast.
- A change here needs `sudo ./install-helper.sh` before the app will use it. Say so in the PR.
- Every connection is admitted on two rules: the console-user uid (`HelperAdmission`) and, when `install-helper.sh` has pinned one, the caller's code signature (`HelperCallerPolicy`, #46). Read identity from the socket (`LOCAL_PEERTOKEN`), never from anything the peer sends, and decide it before the request is read.
- Every admitted or refused connection leaves one audit line: identity, command, outcome. Never a request value that could carry a secret.
- The helper's callers are the app and `ConduitDaemon`. A new caller needs its signing identifier added to the pin in `install-helper.sh`; `pm-proxy` and `pmctl` must never become one.
