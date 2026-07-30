# Waveform setup for tb_softmax_golden. This script is sourced after launch_simulation.
catch {remove_wave -quiet [get_waves *]}

catch {add_wave -divider "Clock / Reset"}
catch {add_wave /tb_softmax_golden/clk}
catch {add_wave /tb_softmax_golden/rst_n}

catch {add_wave -divider "Input Stream"}
catch {add_wave /tb_softmax_golden/in_valid}
catch {add_wave /tb_softmax_golden/in_ready}
catch {add_wave -radix hexadecimal /tb_softmax_golden/in_data}
catch {add_wave /tb_softmax_golden/in_mask}
catch {add_wave /tb_softmax_golden/in_last}

catch {add_wave -divider "Output Stream"}
catch {add_wave /tb_softmax_golden/out_valid}
catch {add_wave /tb_softmax_golden/out_ready}
catch {add_wave -radix hexadecimal /tb_softmax_golden/out_data}
catch {add_wave /tb_softmax_golden/out_last}
catch {add_wave /tb_softmax_golden/row_error}
catch {add_wave /tb_softmax_golden/busy}

catch {add_wave -divider "DUT State / Counters"}
catch {add_wave /tb_softmax_golden/dut/state}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/wr_count}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/row_len}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/proc_idx}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/out_idx}
catch {add_wave -radix signed /tb_softmax_golden/dut/max_score}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/sum_exp}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/recip_q30}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/exp_addr}
catch {add_wave -radix unsigned /tb_softmax_golden/dut/exp_current}

catch {add_wave -divider "Testbench Scoreboard"}
catch {add_wave -radix unsigned /tb_softmax_golden/out_count}
catch {add_wave -radix unsigned /tb_softmax_golden/pass_count}
catch {add_wave -radix unsigned /tb_softmax_golden/fail_count}
catch {add_wave /tb_softmax_golden/actual_real}
catch {add_wave /tb_softmax_golden/expected_real}
catch {add_wave /tb_softmax_golden/abs_err}
catch {add_wave /tb_softmax_golden/max_abs_err}

catch {wave zoom full}
