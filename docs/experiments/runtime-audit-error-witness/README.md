# Audit evidence-read failure witness

At `bfe8922`, the actual-host simulator includes connection-audit coverage and
explicit failure assertions in eight outer unexpected-error catches. Expected
Start-refusal catches keep their own assertions. Cleanup and root retention
remain independent of whether the behavioral assertions passed.

A controlled source variant changes only the owned audit-file read to read a
child of that regular file. It cannot succeed. The executed scenario exits 1
with exactly `the audit exercise completed without error` false, while its
error-path cleanup and flush still confirm (21.726 s). Exact restored bytes then
pass all 132 scenario assertions and exit 0 (18.051 s). Source/Tests/scripts are
clean after restoration. No compile error, crash or timeout counts as evidence.

The focused wrapper already passed the normal path before this witness. The
witness tests one error boundary; static review covers the other seven catches.
It does not prove every exception schedule or machine behavior.

Repeat only in a clean, isolated checkout with no competing source edit/build:

```sh
python3 docs/experiments/runtime-audit-error-witness/replay.py \
  --root "$PWD" --output /tmp/conduit-audit-witness-unique
```

The driver temporarily edits one simulator source file, restores exact bytes in
a finally block and keeps per-attempt logs. It requires an unused output path.
