# 0012: Optional attribution trailers, no session URLs

- Date: 2026-10-07
- Decision: accepted (owner, 2026-10-07, #127)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

`AGENTS.md` made a `Co-Authored-By:` trailer mandatory on AI-assisted commits, and automated review kept blocking pull requests that lacked one. Accountability already rests with the human committer (#127, commit 07d12a4).

## Decision

- Attribution trailers such as `Co-Authored-By:` are optional. Reviews neither require nor check them.
- The human committer is the author and is accountable for every commit, whatever tool helped write it.
- A session, conversation or transcript URL never goes in a commit message, because it resolves only for the tool account's owner. It may go in a PR description.

## Alternatives

Keep the trailer mandatory: it added review noise and no accountability the committer did not already carry.

## Consequences

Commit history does not reliably show which commits had tool help.

## Invariants and verification

No commit message contains a session URL. Review checks this; nothing automated does.

## Implementation evidence

[`AGENTS.md`](../../AGENTS.md), "Commits and pull requests", changed in #127.

Does not prove: that history is free of session URLs. Nothing scans commit messages.

## Open questions

None.
