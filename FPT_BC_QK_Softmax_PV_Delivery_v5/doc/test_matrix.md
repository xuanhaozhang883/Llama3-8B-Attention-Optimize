# v4 + B+C v3 Test Matrix

| Testbench | Configuration | Coverage |
|---|---|---|
| `tb_causal_mask_stream` | small | Mask, metadata, backpressure |
| `tb_score_rowtile_buffer` | SEQ=8,TILE=4 | Tile-to-row, first/last, backpressure |
| `tb_qk_softmax_adapter` | 2 heads,SEQ=8 | Mask + buffer integration |
| `tb_softmax_metadata` | MAX_LEN=4 | Softmax metadata and output backpressure |
| `tb_qk_softmax_adapter_file` | 4 heads,SEQ=128 | 65,536 Adapter outputs |
| `tb_qk_softmax_frontend_small` | 2 heads,SEQ=8 | Frontend control and row behavior |
| `tb_qk_softmax_reset_recovery` | 2 heads,SEQ=8 | Reset during fill/compute/output stall |
| `tb_qk_adapter_integration` | real QK,HD=8 | Real QK -> Adapter |
| `tb_qk_softmax_pipeline_small` | selected group,real QK,HD=8 | Numerical QK -> Softmax, group metadata, global Q/K addressing, B->C stall stability |
| `tb_qk_softmax_group_control` | two selected groups | Sequential launches, busy-start rejection, ID lock, global Q/K addressing |
| `tb_qk_softmax_frontend_golden` | 4 heads,SEQ=128 | 65,536 probabilities, row sums, masks |
| `tb_qk_adapter_integration_full_optional` | real QK,HD=128 | Long real QK -> Adapter |
| `tb_qk_softmax_pipeline_full_optional` | selected group,real QK,HD=128 | Long complete QK -> Mask -> Buffer -> Softmax, 65,536 scores/probabilities |
| `tb_qk_softmax_pv_pipeline_small` | Group 0 then 7,SEQ=8,HD=8,QK_TILE=4,PV_TILE=2 | Direct B->C stream, P replay, global V address/data, PV vectors, stalls and completion |
| `tb_qk_softmax_pv_pipeline_full_optional` | Group 6,SEQ=128,HD=128,QK_TILE=4,PV_TILE=2 | Long direct B+C run with 65,536 probabilities and 2,097,152 PV vectors |
| `tb_bc_invalid_group_id` | GQA_GROUPS=7,invalid ID=7 | Reject out-of-range launch without starting B/C |
| `tb_bc_reset_and_busy` | SEQ=8,HD=8 | Busy relaunch guard; reset during QK, C activity and stalled PV; final recovery Group |
| `tb_qk_softmax_pv_all_groups` | Groups 0..7,SEQ=8,HD=8 | Reference A controller, real V-cache load/read, all Group/head/address metadata and PV vectors |

The dedicated structural entry point is `run_synthesis_row_buffer.tcl`; at
the full `SEQ_LEN=128,TILE=4` configuration it requires the `512x17` payload
store to infer exactly one RAMB primitive.
