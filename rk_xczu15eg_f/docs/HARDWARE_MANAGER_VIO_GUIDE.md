# RK-XCZU15EG-F PL self-test: Hardware Manager and VIO/ILA guide

This procedure is the physical validation step. Until a human executes it on
the target PCB, the repository result is **built and software-verified, not
hardware-validated**.

## Files that must stay paired

```text
rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.bit
rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.ltx
```

Use files from the same build/commit. The XPR is:

```text
rk_xczu15eg_f/vx/rk_pl_selftest.xpr
```

## Open the Vivado GUI

The installed Vivado executable is:

```text
D:\Vitis\2025.2\Vivado\bin\unwrapped\win64.o\vivado.exe
```

Do not invoke that `unwrapped` executable directly. It depends on environment
variables prepared by the supported launcher:

```text
D:\Vitis\2025.2\Vivado\bin\vivado.bat
```

The simplest entry is to double-click:

```text
rk_xczu15eg_f/scripts/open_stage1h_vivado_gui.cmd
```

The launcher resolves the XPR relative to the repository. If Vivado is
installed elsewhere, set the `VIVADO_BIN` environment variable to the full
`vivado.bat` path before running it.

## Board connection

1. Power off before changing cables or board switches.
2. Configure the board for normal JTAG programming according to the vendor
   board manual. No SD card or boot image is required for this PL-only test.
3. Connect the board's JTAG interface and board power.
4. Power on and confirm that Vivado can see the JTAG device.

## Program in Vivado GUI

1. Open the XPR in Vivado 2025.2.
2. Select **Flow Navigator -> Open Hardware Manager**.
3. Select **Open target -> Auto Connect**.
4. In the Hardware window, select the device whose part is
   `xczu15eg-ffvb1156-2-i`.
5. Select **Program Device**.
6. Set **Bitstream file** to the stable `.bit` above.
7. Set **Debug probes file** to the matching stable `.ltx` above.
8. Click **Program**.

If the debug cores do not appear, first verify the `.bit`/`.ltx` pair, then
right-click the device and select **Refresh Device**. Do not substitute a
KV260 bitstream or an `.ltx` from another implementation.

## VIO probe map and PASS condition

The test begins automatically after the 200 MHz input clock is stable and the
Clock Wizard locks.

| VIO probe | Width | Meaning |
|---|---:|---|
| `probe_in0` | 1 | `busy`: test is still running |
| `probe_in1` | 1 | `done`: terminal state reached |
| `probe_in2` | 1 | `pass`: all checks passed |
| `probe_in3` | 1 | `fail`: any golden/protocol check failed |
| `probe_in4` | 64 | cycles from production start to terminal result |
| `probe_in5` | 17 | golden mismatch count |
| `probe_in6` | 17 | first mismatch index; 131071 means no mismatch |
| `probe_out0` | 1 | restart level; rising edge starts a new run |

Wait until `done=1`. A valid board PASS is exactly:

```text
busy              = 0
done              = 1
pass              = 1
fail              = 0
error_count        = 0
first_error_index  = 131071 (0x1FFFF)
cycle_count        > 0
```

Record `cycle_count`. At 100 MHz, the measured production-run latency is:

```text
latency_seconds = cycle_count / 100000000
latency_ms      = cycle_count / 100000
```

This counter excludes initial V-cache loading and measures from the
production `start` state until the self-test terminal result. It is therefore
repeatable accelerator latency, not host-to-host end-to-end latency.

## Restart regression

1. In the VIO dashboard, set `probe_out0` from 0 to 1.
2. Commit the output value.
3. Set it back from 1 to 0 and commit again.
4. Confirm `done` clears and `busy` becomes 1.
5. Wait for `done=1` again.
6. Confirm the full PASS condition above and compare `cycle_count` with the
   first run. The two values should match.
7. Repeat the restart sequence until at least 100 consecutive complete runs
   have passed. Record any cycle-count variation or JTAG/clock anomaly.

## Optional ILA capture

The ILA has nine one-bit probes:

```text
probe0 restart_pulse
probe1 production start
probe2 busy
probe3 done
probe4 pass
probe5 fail
probe6 raw_req_valid
probe7 raw_req_ready
probe8 compare_valid
```

Useful captures:

- Trigger on rising `probe1` to confirm production start.
- Trigger on rising `probe3` to observe terminal PASS/FAIL.
- Trigger on rising `probe5` for a failed run.
- Observe `probe6 && probe7` for accepted Q/K requests.

The ILA depth is 1024 samples and is intended for control/protocol evidence,
not for capturing the complete attention calculation.

## Evidence to record

For the hardware validation record, save:

- board PCB revision and serial identifier
- Git commit hash
- Vivado version
- SHA-256 hashes of the `.bit` and `.ltx`
- first-run and restart-run VIO screenshots
- both cycle counts
- the 100-run total and failure count
- whether ILA start/done triggers were observed
- date/operator and any clock/JTAG anomalies

Use these repository locations:

```text
reports/13_rk_pl_selftest_hardware/status.json
reports/13_rk_pl_selftest_hardware/run_log.csv
reports/13_rk_pl_selftest_hardware/screenshots/
```

Create one CSV row for every initial run, restart run, reprogrammed run and
cold-boot run. Do not mark the phase `HARDWARE_PASS` until the CSV contains at
least 100 consecutive restart rows with `result=PASS` and zero failed rows.
