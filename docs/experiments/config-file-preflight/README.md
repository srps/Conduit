# Configuration-file preflight compatibility witnesses

These synthetic probes support decision0024. They read no installed configuration
and do not start or replace the serving app.

- `LegacyIgnoredGrammarWitness.swift` was temporarily installed in the real test
  target at pre-change commit `d86aae2518306e3d27fafea3f62fb0429a46b0e6`, run against
  the actual `ProxyConfigPersistence.decode`, and removed in a finally block.
  `legacy-ignored-result.txt` preserves the selected output: one passing test,
  with six accepted ignored-value cases. Five exercise malformed string content;
  `1e400` is valid JSON and is a separate numeric case.
- `FoundationIgnoredDepthProbe.swift` uses a minimal Decodable root, not
  `ProxyConfig`. It observed511 nested ignored arrays accepted and512 refused
  inside that root on the current Xcode Foundation. The real file boundary must
  still pin its own total nesting behavior. See `foundation-depth-result.txt`.

The witness establishes prior acceptance only. It is not the new strict parser,
a fuzz campaign, a memory bound or owner/real-machine validation. Source files
are retained as experiments; they are not additional production decoding paths.
