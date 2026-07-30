# Corrected A+B+C+Real-PV Integration v2

## Important correction

Do **not** directly replace the already-PASS `attention_system_top.sv` with the
earlier v1 real-PV top.

The exact uploaded B+C v5 source contains:

```systemverilog
if (PV_TILE != 2)
    $error("qk_softmax_pv_pipeline_top: this delivery is fixed to PV_TILE=2");
```

The uploaded real PV core is TILE=4. Therefore simple parameter replacement to
PV_TILE=4 is not valid.

This corrected package:

- keeps B+C at its verified TILE2 contract;
- keeps the real PV core at TILE4;
- adds a one-Group TILE2 capture/TILE4 replay adapter;
- waits for real Context completion before advancing the GQA Group;
- does not edit B/C RTL;
- does not edit PV RTL.

The new top is:

```text
rtl/top/attention_system_with_pv_top.sv
```

Use it in a **new copied Vivado project**. Keep the old PASS project unchanged.
