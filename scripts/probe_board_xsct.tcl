# Read-only JTAG target probe.  This does not reset or program the board.
connect
set fpt_targets [targets]
puts "============================================================"
puts "FPT_JTAG_TARGETS_BEGIN"
puts $fpt_targets
puts "FPT_JTAG_TARGETS_END"
if {[string trim $fpt_targets] eq ""} {
    # Keep the expected "board absent" state on stdout.  PowerShell promotes
    # native stderr to a terminating error before it can parse the target block.
    puts "No JTAG targets detected"
    disconnect
    exit 2
}
puts {[PASS] At least one JTAG target is visible}
puts "============================================================"
disconnect
