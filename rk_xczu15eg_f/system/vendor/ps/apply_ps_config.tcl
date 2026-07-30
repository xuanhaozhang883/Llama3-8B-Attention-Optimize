# RK-XCZU15EG-F V1.0 PS adapter.
#
# The board-vendor preset is extracted into the ignored generated/vendor_cache
# directory by system/scripts/prepare_vendor_assets.ps1. It is intentionally
# not copied into Git until redistribution permission is known.

set adapter_dir [file normalize [file dirname [info script]]]
set system_root [file normalize [file join $adapter_dir .. ..]]
set preset_tcl [file join \
    $system_root generated vendor_cache ps XCZU15EG_Base_Config.tcl]
if {[info exists ::env(RK_PS_PRESET_TCL)] &&
    $::env(RK_PS_PRESET_TCL) ne ""} {
    set preset_tcl [file normalize $::env(RK_PS_PRESET_TCL)]
}

if {![file isfile $preset_tcl]} {
    error "Run system/scripts/prepare_vendor_assets.ps1 or set RK_PS_PRESET_TCL. Missing: $preset_tcl"
}
source $preset_tcl
if {[llength [info procs apply_preset]] != 1} {
    error "Vendor PS preset must define: proc apply_preset {IPINST}"
}

proc rk_apply_ps_config {ps_cell} {
    set vendor_config [apply_preset $ps_cell]
    if {[catch {dict size $vendor_config}]} {
        error "Vendor apply_preset did not return a property dictionary"
    }

    # Additional PL interfaces required by this accelerator system.
    dict set vendor_config CONFIG.PSU__USE__M_AXI_GP0 1
    # The vendor reference enables M_AXI_HPM0_LPD for its own peripherals.
    # This project does not use that path; disabling it avoids an unconnected
    # PL clock and an incomplete address path in the generated block design.
    dict set vendor_config CONFIG.PSU__USE__M_AXI_GP2 0
    dict set vendor_config CONFIG.PSU__USE__S_AXI_GP0 1
    dict set vendor_config CONFIG.PSU__SAXIGP0__DATA_WIDTH 128
    dict set vendor_config CONFIG.PSU__FPGA_PL0_ENABLE 1
    # Preserve the exact PL0 clock produced by the vendor PLL/divider preset.
    # Vivado reports 96.968727 MHz for this configuration.
    dict set vendor_config \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 96.968727

    set_property -dict $vendor_config $ps_cell
}
