set SynModuleInfo {
  {SRCNAME attention_mask_Pipeline_QH_LOOP_QT_LOOP_KT_LOOP MODELNAME attention_mask_Pipeline_QH_LOOP_QT_LOOP_KT_LOOP RTLNAME attention_mask_attention_mask_Pipeline_QH_LOOP_QT_LOOP_KT_LOOP
    SUBMODULES {
      {MODELNAME attention_mask_flow_control_loop_pipe_sequential_init RTLNAME attention_mask_flow_control_loop_pipe_sequential_init BINDTYPE interface TYPE internal_upc_flow_control INSTNAME attention_mask_flow_control_loop_pipe_sequential_init_U}
    }
  }
  {SRCNAME attention_mask MODELNAME attention_mask RTLNAME attention_mask IS_TOP 1
    SUBMODULES {
      {MODELNAME attention_mask_mul_8ns_8ns_16_1_1 RTLNAME attention_mask_mul_8ns_8ns_16_1_1 BINDTYPE op TYPE mul IMPL auto LATENCY 0 ALLOW_PRAGMA 1}
      {MODELNAME attention_mask_mul_8ns_8ns_15_1_1 RTLNAME attention_mask_mul_8ns_8ns_15_1_1 BINDTYPE op TYPE mul IMPL auto LATENCY 0 ALLOW_PRAGMA 1}
      {MODELNAME attention_mask_mul_6ns_16ns_20_1_1 RTLNAME attention_mask_mul_6ns_16ns_20_1_1 BINDTYPE op TYPE mul IMPL auto LATENCY 0 ALLOW_PRAGMA 1}
      {MODELNAME attention_mask_gmem0_m_axi RTLNAME attention_mask_gmem0_m_axi BINDTYPE interface TYPE adapter IMPL m_axi}
      {MODELNAME attention_mask_gmem1_m_axi RTLNAME attention_mask_gmem1_m_axi BINDTYPE interface TYPE adapter IMPL m_axi}
      {MODELNAME attention_mask_control_s_axi RTLNAME attention_mask_control_s_axi BINDTYPE interface TYPE interface_s_axilite}
    }
  }
}
