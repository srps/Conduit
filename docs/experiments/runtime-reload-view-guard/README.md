# Accepted-view freshness source guard

Executed on `011f589` after 30 focused tests passed. [Results](results.json) pin the
source/test trees and exact commands. The mutation accepts any later view instead
of requiring the reload's captured accepted view. It therefore restores the old
bug while leaving Start/Stop admission and the held-reload case unchanged.

The eligible-overlap witness fails its intended assertions: the old reload claims
currentAtEnd and records a flag action after a newer eligible view replaced it.
The held-overlap witness still distinguishes an ineligible observation from a new
accepted view. Baseline and exactly restored runs pass both tests. No compiler
error, crash or process timeout counts as detection; exact restoration and clean
product/test/script state are checked.

```sh
python3 docs/experiments/runtime-reload-view-guard/replay.py --repo "$PWD" --out /tmp/conduit-reload-view-guard-UNIQUE
```

Use a clean matching product/test checkpoint and a new output directory. This
experiment temporarily edits RuntimeHost.swift; no other writer or build may use
the checkout. It runs fake-machine tests with scratch state and never changes the
installed app/helper. This is one currentness witness, not complete schedule or
real-machine proof.
