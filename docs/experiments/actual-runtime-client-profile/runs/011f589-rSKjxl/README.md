# Excluded premature resource run

The parent sent GO while the final simulator steps of the all-41 workflow still ran.
This partial Release build was stopped with SIGTERM; no probe results were produced.
It supplies no memory, latency or profile acceptance evidence. The workflow's perf
step completed before the overlap, and all final workflow steps passed.
A fresh isolated attempt is preserved in ../011f589-bwveLh.
