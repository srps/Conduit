# Kernel sanitizer lifetime: direct Release probe

Run on 2026-10-25, on one Mac. `Probe.swift` calls the actual kernel sanitizer
source directly, compiled with `-O`, Swift 6. The baseline is commit
`21a6f96c7ead18e4028ec04d57171630e9675b2d`; the after source is the working-tree
sanitizer with its synchronous inner autorelease scope. Exact source hashes and
compiler version are in `metadata.json`.

There is no caller autorelease pool. Each batch calls `sanitize` 256 times on one
short synthetic input. Four cases cover unchanged text, URL suffix, URL userinfo
and a header. Every result must equal that process's expected sanitized value;
matching before/after output byte counts and checksums provide additional output
comparison evidence. Each batch has the same checksum; XORing 11 or 101 batches
(both odd) leaves that single-batch checksum. This is not exhaustive semantic
equivalence proof. Samples
use `malloc_zone_statistics(nil, ...)`, which sums all zones per the Xcode SDK
`malloc.h` contract. Returned strings are released between calls; no array of
results is retained.

| Input shape | Before, first→11th batch growth | After, first→101st batch growth |
| --- | ---: | ---: |
| normal endpoint | 1,662,976 B | 0 B |
| URL suffix | 2,293,760 B | 0 B |
| URL userinfo | 2,908,160 B | 0 B |
| header | 2,195,456 B | 0 B |

The probe extends from 11 to 101 batches only if first-to-eleventh growth is below
64 KiB. This is an experiment expansion gate, not a product limit. All before
cases stop at 11; all after cases reach 101. Raw outputs are in
`before-results.txt` and `after-results.txt`. These runs support a function-level
Foundation temporary-lifetime diagnosis and the scoped correction. They do not
prove a universal allocation bound, steady-state app RAM, RSS, latency deadline
or performance speedup: batch counts differ and elapsed times are single samples.
Existing redaction/parity tests and the complete repository workflow separately
check behavior and performance.

Reproduce from the repository root:

```sh
python3 docs/experiments/runtime-service-profile/kernel-sanitizer-release/run.py
```

The script reads the pinned baseline and current checkout, compiles in a fresh
temporary directory with a private module cache, and never edits product source.
Use `--output /absolute/new/directory` to retain a chosen artifact location.
The initial local compiler attempt lacked that private cache and was denied
writing the user's cache; it produced no probe result. Its log is preserved in
the task scratch directory. All recorded results used the private-cache retry.
