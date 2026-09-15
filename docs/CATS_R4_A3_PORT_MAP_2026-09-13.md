# CATS-R4 A3 Port Map

## Accepted identities

- integration base: f9419e8d30d13f5aeba6cfeb6dd1403028f79d43
- B source head: 18cdd2335bfa60927b1fbb466020561681f725eb
- interface tagged commit: 4d386e0f8f39c9f3c6de5ffa2ced408f254146ee
- local accepted head: d2027924b698baad092873c98903533ca0f46d96

## Direct connections

| Producer | Consumer | Channels |
|---|---|---|
| q_slab_client | qk_32lane_engine | engine_start, engine_done |
| qk_32lane_engine | a3_row_frontend | raw score vector and context_tag 0..2 |
| a3_row_frontend | b4_softmax_pv_cluster | row, score |
| b4_softmax_pv_cluster | a3_row_frontend | final_release |
| b4_softmax_pv_cluster | C service | weight write/commit/read/release, pv_row, V, Context |
| A-side arbiter and B4 | a3_error_join | tokenized error streams |

## Frozen fields

```text
A→B row: row_valid,row_ready,row_epoch,row_group,row_global_q_head,
         row_index,row_slot_id,row_numeric_mode,row_max_bf16
A→B score: score_valid,score_ready,score_epoch,score_group,
           score_global_q_head,score_row,score_slot_id,
           score_numeric_mode,score_key,score_bf16,score_last
B→C weight write: weight_wr_valid,weight_wr_ready,weight_wr_epoch,
                  weight_wr_group,weight_wr_global_q_head,weight_wr_row,
                  weight_wr_slot_id,weight_wr_numeric_mode,weight_wr_key,
                  weight_wr_mask,weight_wr_data,weight_wr_last
B→C row commit: row_commit_valid,row_commit_ready,row_commit_epoch,
                row_commit_group,row_commit_global_q_head,row_commit_row,
                row_commit_slot_id,row_commit_numeric_mode,
                row_commit_sum_fp32,row_commit_inv_sum_fp32
C→B PV row: pv_row_valid,pv_row_ready,pv_row_epoch,pv_row_group,
            pv_row_global_q_head,pv_row_row,pv_row_slot_id,
            pv_row_numeric_mode,pv_row_sum_fp32,pv_row_inv_sum_fp32
B↔C weight read: weight_rd_req_valid,weight_rd_req_ready,
                 weight_rd_req_epoch,weight_rd_req_group,
                 weight_rd_req_global_q_head,weight_rd_req_row,
                 weight_rd_req_slot_id,weight_rd_req_numeric_mode,
                 weight_rd_req_key,weight_rd_rsp_valid,
                 weight_rd_rsp_epoch,weight_rd_rsp_group,
                 weight_rd_rsp_global_q_head,weight_rd_rsp_row,
                 weight_rd_rsp_slot_id,weight_rd_rsp_numeric_mode,
                 weight_rd_rsp_key,weight_rd_rsp_mask,weight_rd_rsp_data
V service: v_req_valid,v_req_ready,v_req_context_tag,v_req_key,
           v_req_feature_block,v_rsp_valid,v_rsp_context_tag,v_rsp_vec_bf16
Context: out_valid,out_ready,out_epoch,out_seq,out_global_q_head,out_row,
         out_feature_block,out_data_bf16,out_row_last,out_tensor_last
Release: weight_release_valid,weight_release_ready,weight_release_epoch,
         weight_release_group,weight_release_global_q_head,
         weight_release_row,weight_release_slot_id,
         weight_release_numeric_mode,final_release_valid,
         final_release_ready,final_release_epoch,final_release_group,
         final_release_global_q_head,final_release_row,
         final_release_slot_id,final_release_numeric_mode
Unified error: error_valid,error_ready,error_source,error_epoch,error_group,
               error_global_q_head,error_row,error_slot_id,
               error_numeric_mode,error_code,error_bad_key
```

## Latency and backpressure

- score memory response: one registered response, held until ready
- C weight response: fixed N+2, non-backpressured response as frozen by Interface V3
- V response: tagged response; request is backpressured, response is consumed by B4
- Context, row, score, final_release and unified error hold all payload fields while stalled

## Timing sign-off boundary

The A3 package-less OOC gate times every internal clock-to-clock path at 6.666 ns. Top-level contract inputs and outputs are false-pathed only because this wrapper has no package placement or board timing budget. Production C integration must remove that assumption, apply the actual cross-module/interface constraints, and close boundary timing; the OOC exception is not a production-top constraint.
