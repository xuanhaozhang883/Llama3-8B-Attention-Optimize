# Design decision

The verified A+B+C baseline must remain unchanged.

The corrected real-PV branch uses the exact B+C one-Group module with
`PV_TILE=2`, captures one complete Group, and then replays TILE4 vectors to the
real PV core. This is correctness-first and adds buffering, but it avoids
changing either verified core.

A direct TILE2 wire-to-TILE4 wire connection is impossible because B+C emits:

```text
head -> row_base(step2) -> feature_base(step2) -> reduce
```

while the real PV engine requests:

```text
head -> row_base(step4) -> col_base(step4) -> reduce
```

The matching quarter-vectors are not adjacent in the B+C stream, so a buffer is
required unless C's loader is redesigned and revalidated.
