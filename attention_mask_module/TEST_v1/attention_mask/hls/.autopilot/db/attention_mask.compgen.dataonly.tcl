# This script segment is generated automatically by AutoPilot

set axilite_register_dict [dict create]
set port_control {
raw_scores { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 16
	offset_end 27
}
masked_scores { 
	dir I
	width 64
	depth 1
	mode ap_none
	offset 28
	offset_end 39
}
q_heads { 
	dir I
	width 32
	depth 1
	mode ap_none
	offset 40
	offset_end 47
}
seq_len { 
	dir I
	width 32
	depth 1
	mode ap_none
	offset 48
	offset_end 55
}
causal { 
	dir I
	width 1
	depth 1
	mode ap_none
	offset 56
	offset_end 63
}
mask_value { 
	dir I
	width 16
	depth 1
	mode ap_none
	offset 64
	offset_end 71
}
ap_start { }
ap_done { }
ap_ready { }
ap_idle { }
interrupt {
}
}
dict set axilite_register_dict control $port_control


