**Accepted.** The proof shows that the helper installed right now admits this candidate's code identity and speaks protocol v5. You can run the owner-coordinated local acceptance with the current pin; nothing needs re-pinning or reinstalling.

## Why exit 0 means the helper admitted the candidate

- The worker (`UpdatePreflight.swift:177-192`) returns 0 only when the helper status is `.notInstalled` or `.installed`.
- `.notInstalled` happens only when the helper binary is missing (`HelperPrivilegeClient.swift:294-297`). The manifest records `installed_helper_path_exists: true`, so this was a real ping.
- `.installed` requires all of the following:
  - no refusal from the helper, which decides caller identity before it reads the request;
  - a reply stamped protocol 5;
  - `success: true` (`:325-340`).
- A pin rejection would have exited 73, an older protocol 70, and a timeout 74.
- The worker runs as the same executable as the app (`executable_sha256 c6ebdd3f…`, commit `7d852139`). So the identity the helper admitted is the one the app will present.

## On helper changes

I agree: a change to a shared type alone doesn't require re-pinning or a helper reinstall. Testing against the installed 0.5.8 helper is exactly what an app-only upgrade looks like for users, so it's the right target. The `git diff` from my last message now only decides what the release notes must say. It doesn't gate this acceptance.

## Limits of this proof

- It proves admission and protocol, not each command's argument validation. The acceptance steps cover the commands you actually use.
- This is not a release artifact. The version is still 0.5.8, the build isn't release-signed and there's no tag. Checking the release-signed artifact remains a later packaging step, as you said.

## Things you'll meet during the local acceptance

1. **Never let 0.5.8 run at the same time on the real settings folder.**
   - 0.5.8 ignores the new lock, and both apps share the bundle ID and version, so launching or activating "Conduit" from Spotlight or Finder can open the wrong copy.
   - Quit 0.5.8 completely, let its restoration finish, and keep it closed until you quit the candidate.
2. **Expect Keychain access prompts.**
   - Your saved credentials' access lists name the release-signed app, and the candidate is signed with your local certificate.
   - Choosing **Allow** grants access for that run only. **Always Allow** permanently adds the local build to those items' access lists. It doesn't break 0.5.8, but it does change the Keychain.
3. **Don't toggle "Launch at login" in the candidate if it runs from the worktree.**
   - Toggling it calls `SMAppService.mainApp.register()` for the running bundle (`LoginItemManager.swift:16`). That would point your login item at the worktree copy.
   - The app never re-registers at launch (`AppState.swift:1056-1058`), so leaving the setting alone is safe.
4. **The version is unchanged.** No version-changed lifecycle event will appear, and Check for Updates will see 0.5.8 as current. Both are expected for this local artifact.

The rest of my previous message stands: the six normal-usage steps (plus login-item launch only if you use it), the optional cases, and the merge-versus-release distinction.
