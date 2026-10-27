# Native-client causal prior guard

One actual-source mutation checks the new saved-Start authority model on source
`00a4b304c368107b353460e33f5a8dee1fbe2d17`. [Results](results.json)
record the exact target hashes, source/test trees and intended assertion.

The baseline executes all 125 depth-three histories successfully. Removing the
prior from a saved Start's receipt causes the model's intended `XCTUnwrap`
assertion, with no compiler error, crash or timeout. Exact original bytes are
restored in `finally`, and the restored model passes all histories again.
The mutation leaves the receipt structurally valid, so this checks authority
facts rather than decoder rejection.

Scope: one omission of the causal prior. This is not proof of every field,
lifecycle schedule, helper, wake or OS behavior. Existing deterministic tests and
separate models retain their narrower claims.

To replay on the recorded source basis, with Xcode available:

```sh
python3 docs/experiments/native-client-guards/replay.py /private/tmp/new-native-prior-proof
```

The output directory must not exist. The replay checks the recorded source/test
trees and refuses dirty or mismatching source. It runs one baseline, one mutant
and one restored test under Xcode's developer directory, and restores only its
own exact mutated bytes. Stop all other edits and builds during it.
The executed experiment used the temporary driver with the same mutation and
test commands; this portable wrapper adds source-basis preflight and passed
syntax checking. It has not been rerun merely to repeat the same evidence.
