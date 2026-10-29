# Kernel copy-on-write observation

Three fresh optimized Swift 6 processes link the f3 Release objects folder (per-object hashes were not recorded). This external program observes the real kernel value type at 1,000 and 10,000 rows; it is neither an XCTest nor a product mode. At 10,000 rows the activity update allocates 1,212,416 B in 153–168 µs; a remove allocates 409,536 B for the index; ending the second holder frees 1,622,144 B. Allocator deltas and timings describe this shape on this machine. Shared string storage is retained, not duplicated.

This does not drive the host flight or real connection churn, bound app RAM, or measure an unselected larger collection retained by a whole snapshot. See [results](results.json) and [the corrected custody assessment](../capture-object-custody.md).
