# Saved-command input binding

The owner selected preparation-time capture on 2026-10-26 in
[0037](decisions/0037-saved-command-preparation-capture.md), recorded in
[#186](https://github.com/srps/Conduit/issues/186). Claude Code reviewed the
alternatives through the owner’s claude.ai subscription.

## Selected behavior

A saved command, such as menu Restart or daemon Start, carries no configuration
while waiting. When preparation obtains capacity, it captures the current
required runtime/platform pair once, before staging or writing. The sole store
verifies that pair; the command uses it for its effects. If a newer observation
replaces the captured input before affected effects, hold the remaining work and
report the result. Do not rebind or retry automatically.

Private editor requests retain their submitted frozen values and exact baselines
(0035). Both sources use the same store, workflow and runtime owner. Stop fences
immediately; completed persistence and effects remain reported facts.

## Alternatives and compatibility

A is saved when Start/Restart is accepted. Another client explicitly reloads valid
B while the command waits, without a lifecycle change.

| Binding rule | B arrives before preparation | B replaces the pair after preparation, before affected effects |
| --- | --- | --- |
| **Selected: capture once at preparation** | Capture and use B. | Hold remaining work; require an explicit retry. |
| Pin at admission | Hold; the accepted input was A. | Hold. |
| Follow newer input through startup | Use B. | May use B, requiring a later binding point and receipts that explain the change. |

Preparation-time capture gives a saved command the meaning “use the saved settings
when work begins”. It avoids retaining queued configurations and keeps one input
for the effects that follow. Admission-time capture unnecessarily holds commands
when a reload happens before work starts. Following input changes during startup
adds binding and receipt rules that private frozen requests must never inherit.

Legacy preparation already read current saved values but could follow a later
reload through startup. The selected rule deliberately changes the latter
behavior: a held command must report that outcome rather than apparent success.
It requires no file-schema change, parallel loader, registry or compatibility mode.

## Implementation and acceptance

The local saved-command checkpoint replaces the admission-pinned prototype.
Complete shared module ownership,
then activate AppState once and delete its replaced runtime/save paths (0031).
The implementation must exercise reloads before and after capture through the
actual workflow/host, capacity refusal, required sidecars/defaults, external-file
conflicts, Stop at suspensions and coherent proxy/DNS inputs. Extend the independent
bounded model and actual-host simulator, and verify meaningful guard mutations.

Actual service/client adoption, private-channel responsiveness and production
capacity/deadline measurements remain release gates. API names and ordinary
implementation choices do not require further owner decisions.
