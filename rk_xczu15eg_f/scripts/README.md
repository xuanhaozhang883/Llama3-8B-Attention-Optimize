# Script entry points

`run_stage1.ps1` is the user entry point. It accepts:

- `project`: derive golden memory images and create the persistent XPR/IP
- `sim`: run the two-pass behavioral golden regression
- `bitstream`: run synthesis, implementation, checks, and bitstream generation
- `all`: execute those three stages in order

All Tcl source paths are derived from the script location. Generated data and
the XPR are disposable; they can be regenerated from checked-in source.
Vivado/Tcl errors return a non-zero process status.

Example:

```powershell
$env:VIVADO_BIN = "D:\Vitis\2025.2\Vivado\bin\vivado.bat"
.\rk_xczu15eg_f\scripts\run_stage1.ps1 -Mode all
```

The Tcl files can also be sourced from Vivado's Tcl Console, using a path
relative to the repository root:

```tcl
set argv {project}
set argc 1
source rk_xczu15eg_f/build_rk_xczu15eg_pl_selftest.tcl
```

Use `sim`, `bitstream`, or `all` in place of `project` for the other actions.
The PowerShell entry point is preferable for unattended rebuilds because it
also writes each stage's `build.log`.
