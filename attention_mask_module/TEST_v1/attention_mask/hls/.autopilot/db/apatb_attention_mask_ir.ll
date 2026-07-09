; ModuleID = 'D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/TEST_v1/attention_mask/hls/.autopilot/db/a.g.ld.5.gdce.bc'
source_filename = "llvm-link"
target datalayout = "e-m:e-i64:64-i128:128-i256:256-i512:512-i1024:1024-i2048:2048-i4096:4096-n8:16:32:64-S128-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024"
target triple = "fpga64-xilinx-none"

%"struct.ap_uint<16>" = type { %"struct.ap_int_base<16, false>" }
%"struct.ap_int_base<16, false>" = type { %"struct.ssdm_int<16, false>" }
%"struct.ssdm_int<16, false>" = type { i16 }

; Function Attrs: noinline
define void @apatb_attention_mask_ir(%"struct.ap_uint<16>"* noalias nocapture nonnull readonly "fpga.decayed.dim.hint"="524288" "maxi" %raw_scores, %"struct.ap_uint<16>"* noalias nocapture nonnull "fpga.decayed.dim.hint"="524288" "maxi" %masked_scores, i32 %q_heads, i32 %seq_len, i1 zeroext %causal, %"struct.ap_uint<16>"* nocapture readonly %mask_value) local_unnamed_addr #0 {
entry:
  %0 = bitcast %"struct.ap_uint<16>"* %raw_scores to [524288 x %"struct.ap_uint<16>"]*
  %1 = call i8* @malloc(i64 1048576)
  %raw_scores_copy = bitcast i8* %1 to [524288 x i16]*
  %2 = bitcast %"struct.ap_uint<16>"* %masked_scores to [524288 x %"struct.ap_uint<16>"]*
  %3 = call i8* @malloc(i64 1048576)
  %masked_scores_copy = bitcast i8* %3 to [524288 x i16]*
  call fastcc void @copy_in([524288 x %"struct.ap_uint<16>"]* nonnull %0, [524288 x i16]* %raw_scores_copy, [524288 x %"struct.ap_uint<16>"]* nonnull %2, [524288 x i16]* %masked_scores_copy)
  call void @apatb_attention_mask_hw([524288 x i16]* %raw_scores_copy, [524288 x i16]* %masked_scores_copy, i32 %q_heads, i32 %seq_len, i1 %causal, %"struct.ap_uint<16>"* %mask_value)
  call void @copy_back([524288 x %"struct.ap_uint<16>"]* %0, [524288 x i16]* %raw_scores_copy, [524288 x %"struct.ap_uint<16>"]* %2, [524288 x i16]* %masked_scores_copy)
  call void @free(i8* %1)
  call void @free(i8* %3)
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_in([524288 x %"struct.ap_uint<16>"]* readonly "unpacked"="0", [524288 x i16]* "unpacked"="1", [524288 x %"struct.ap_uint<16>"]* readonly "unpacked"="2", [524288 x i16]* nocapture "unpacked"="3.0") unnamed_addr #1 {
entry:
  call fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.21"([524288 x i16]* %1, [524288 x %"struct.ap_uint<16>"]* %0)
  call fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.12"([524288 x i16]* %3, [524288 x %"struct.ap_uint<16>"]* %2)
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>"([524288 x %"struct.ap_uint<16>"]* %dst, [524288 x i16]* readonly %src) unnamed_addr #2 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %dst, null
  %1 = icmp eq [524288 x i16]* %src, null
  %2 = or i1 %0, %1
  br i1 %2, label %ret, label %copy

copy:                                             ; preds = %entry
  call void @"arraycpy_hls.p0a524288struct.ap_uint<16>"([524288 x %"struct.ap_uint<16>"]* nonnull %dst, [524288 x i16]* nonnull %src, i64 524288)
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define void @"arraycpy_hls.p0a524288struct.ap_uint<16>"([524288 x %"struct.ap_uint<16>"]* %dst, [524288 x i16]* readonly %src, i64 %num) local_unnamed_addr #3 {
entry:
  %0 = icmp eq [524288 x i16]* %src, null
  %1 = icmp eq [524288 x %"struct.ap_uint<16>"]* %dst, null
  %2 = or i1 %1, %0
  br i1 %2, label %ret, label %copy

copy:                                             ; preds = %entry
  %for.loop.cond7 = icmp sgt i64 %num, 0
  br i1 %for.loop.cond7, label %for.loop.lr.ph, label %copy.split

for.loop.lr.ph:                                   ; preds = %copy
  br label %for.loop

for.loop:                                         ; preds = %for.loop, %for.loop.lr.ph
  %for.loop.idx8 = phi i64 [ 0, %for.loop.lr.ph ], [ %for.loop.idx.next, %for.loop ]
  %3 = getelementptr [524288 x i16], [524288 x i16]* %src, i64 0, i64 %for.loop.idx8
  %dst.addr.0.0.06 = getelementptr [524288 x %"struct.ap_uint<16>"], [524288 x %"struct.ap_uint<16>"]* %dst, i64 0, i64 %for.loop.idx8, i32 0, i32 0, i32 0
  %4 = load i16, i16* %3, align 2
  store i16 %4, i16* %dst.addr.0.0.06, align 2
  %for.loop.idx.next = add nuw nsw i64 %for.loop.idx8, 1
  %exitcond = icmp ne i64 %for.loop.idx.next, %num
  br i1 %exitcond, label %for.loop, label %copy.split

copy.split:                                       ; preds = %for.loop, %copy
  br label %ret

ret:                                              ; preds = %copy.split, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_out([524288 x %"struct.ap_uint<16>"]* "unpacked"="0", [524288 x i16]* readonly "unpacked"="1", [524288 x %"struct.ap_uint<16>"]* "unpacked"="2", [524288 x i16]* nocapture readonly "unpacked"="3.0") unnamed_addr #4 {
entry:
  call fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>"([524288 x %"struct.ap_uint<16>"]* %0, [524288 x i16]* %1)
  call fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.5"([524288 x %"struct.ap_uint<16>"]* %2, [524288 x i16]* %3)
  ret void
}

declare i8* @malloc(i64) local_unnamed_addr

declare void @free(i8*) local_unnamed_addr

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.5"([524288 x %"struct.ap_uint<16>"]* "unpacked"="0" %dst, [524288 x i16]* nocapture readonly "unpacked"="1.0" %src) unnamed_addr #2 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %dst, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  call void @"arraycpy_hls.p0a524288struct.ap_uint<16>.8"([524288 x %"struct.ap_uint<16>"]* nonnull %dst, [524288 x i16]* %src, i64 524288)
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define void @"arraycpy_hls.p0a524288struct.ap_uint<16>.8"([524288 x %"struct.ap_uint<16>"]* "unpacked"="0" %dst, [524288 x i16]* nocapture readonly "unpacked"="1.0" %src, i64 "unpacked"="2" %num) local_unnamed_addr #3 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %dst, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  %for.loop.cond1 = icmp sgt i64 %num, 0
  br i1 %for.loop.cond1, label %for.loop.lr.ph, label %copy.split

for.loop.lr.ph:                                   ; preds = %copy
  br label %for.loop

for.loop:                                         ; preds = %for.loop, %for.loop.lr.ph
  %for.loop.idx2 = phi i64 [ 0, %for.loop.lr.ph ], [ %for.loop.idx.next, %for.loop ]
  %src.addr.0.0.05 = getelementptr [524288 x i16], [524288 x i16]* %src, i64 0, i64 %for.loop.idx2
  %dst.addr.0.0.06 = getelementptr [524288 x %"struct.ap_uint<16>"], [524288 x %"struct.ap_uint<16>"]* %dst, i64 0, i64 %for.loop.idx2, i32 0, i32 0, i32 0
  %1 = load i16, i16* %src.addr.0.0.05, align 2
  store i16 %1, i16* %dst.addr.0.0.06, align 2
  %for.loop.idx.next = add nuw nsw i64 %for.loop.idx2, 1
  %exitcond = icmp ne i64 %for.loop.idx.next, %num
  br i1 %exitcond, label %for.loop, label %copy.split

copy.split:                                       ; preds = %for.loop, %copy
  br label %ret

ret:                                              ; preds = %copy.split, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.12"([524288 x i16]* nocapture "unpacked"="0.0" %dst, [524288 x %"struct.ap_uint<16>"]* readonly "unpacked"="1" %src) unnamed_addr #2 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %src, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  call void @"arraycpy_hls.p0a524288struct.ap_uint<16>.15"([524288 x i16]* %dst, [524288 x %"struct.ap_uint<16>"]* nonnull %src, i64 524288)
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define void @"arraycpy_hls.p0a524288struct.ap_uint<16>.15"([524288 x i16]* nocapture "unpacked"="0.0" %dst, [524288 x %"struct.ap_uint<16>"]* readonly "unpacked"="1" %src, i64 "unpacked"="2" %num) local_unnamed_addr #3 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %src, null
  br i1 %0, label %ret, label %copy

copy:                                             ; preds = %entry
  %for.loop.cond1 = icmp sgt i64 %num, 0
  br i1 %for.loop.cond1, label %for.loop.lr.ph, label %copy.split

for.loop.lr.ph:                                   ; preds = %copy
  br label %for.loop

for.loop:                                         ; preds = %for.loop, %for.loop.lr.ph
  %for.loop.idx2 = phi i64 [ 0, %for.loop.lr.ph ], [ %for.loop.idx.next, %for.loop ]
  %src.addr.0.0.05 = getelementptr [524288 x %"struct.ap_uint<16>"], [524288 x %"struct.ap_uint<16>"]* %src, i64 0, i64 %for.loop.idx2, i32 0, i32 0, i32 0
  %dst.addr.0.0.06 = getelementptr [524288 x i16], [524288 x i16]* %dst, i64 0, i64 %for.loop.idx2
  %1 = load i16, i16* %src.addr.0.0.05, align 2
  store i16 %1, i16* %dst.addr.0.0.06, align 2
  %for.loop.idx.next = add nuw nsw i64 %for.loop.idx2, 1
  %exitcond = icmp ne i64 %for.loop.idx.next, %num
  br i1 %exitcond, label %for.loop, label %copy.split

copy.split:                                       ; preds = %for.loop, %copy
  br label %ret

ret:                                              ; preds = %copy.split, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.21"([524288 x i16]* %dst, [524288 x %"struct.ap_uint<16>"]* readonly %src) unnamed_addr #2 {
entry:
  %0 = icmp eq [524288 x i16]* %dst, null
  %1 = icmp eq [524288 x %"struct.ap_uint<16>"]* %src, null
  %2 = or i1 %0, %1
  br i1 %2, label %ret, label %copy

copy:                                             ; preds = %entry
  call void @"arraycpy_hls.p0a524288struct.ap_uint<16>.24"([524288 x i16]* nonnull %dst, [524288 x %"struct.ap_uint<16>"]* nonnull %src, i64 524288)
  br label %ret

ret:                                              ; preds = %copy, %entry
  ret void
}

; Function Attrs: argmemonly noinline norecurse willreturn
define void @"arraycpy_hls.p0a524288struct.ap_uint<16>.24"([524288 x i16]* %dst, [524288 x %"struct.ap_uint<16>"]* readonly %src, i64 %num) local_unnamed_addr #3 {
entry:
  %0 = icmp eq [524288 x %"struct.ap_uint<16>"]* %src, null
  %1 = icmp eq [524288 x i16]* %dst, null
  %2 = or i1 %1, %0
  br i1 %2, label %ret, label %copy

copy:                                             ; preds = %entry
  %for.loop.cond7 = icmp sgt i64 %num, 0
  br i1 %for.loop.cond7, label %for.loop.lr.ph, label %copy.split

for.loop.lr.ph:                                   ; preds = %copy
  br label %for.loop

for.loop:                                         ; preds = %for.loop, %for.loop.lr.ph
  %for.loop.idx8 = phi i64 [ 0, %for.loop.lr.ph ], [ %for.loop.idx.next, %for.loop ]
  %src.addr.0.0.05 = getelementptr [524288 x %"struct.ap_uint<16>"], [524288 x %"struct.ap_uint<16>"]* %src, i64 0, i64 %for.loop.idx8, i32 0, i32 0, i32 0
  %3 = getelementptr [524288 x i16], [524288 x i16]* %dst, i64 0, i64 %for.loop.idx8
  %4 = load i16, i16* %src.addr.0.0.05, align 2
  store i16 %4, i16* %3, align 2
  %for.loop.idx.next = add nuw nsw i64 %for.loop.idx8, 1
  %exitcond = icmp ne i64 %for.loop.idx.next, %num
  br i1 %exitcond, label %for.loop, label %copy.split

copy.split:                                       ; preds = %for.loop, %copy
  br label %ret

ret:                                              ; preds = %copy.split, %entry
  ret void
}

declare void @apatb_attention_mask_hw([524288 x i16]*, [524288 x i16]*, i32, i32, i1, %"struct.ap_uint<16>"*)

; Function Attrs: argmemonly noinline norecurse willreturn
define internal fastcc void @copy_back([524288 x %"struct.ap_uint<16>"]* "unpacked"="0", [524288 x i16]* readonly "unpacked"="1", [524288 x %"struct.ap_uint<16>"]* "unpacked"="2", [524288 x i16]* nocapture readonly "unpacked"="3.0") unnamed_addr #4 {
entry:
  call fastcc void @"onebyonecpy_hls.p0a524288struct.ap_uint<16>.5"([524288 x %"struct.ap_uint<16>"]* %2, [524288 x i16]* %3)
  ret void
}

declare void @attention_mask_hw_stub(%"struct.ap_uint<16>"* noalias nocapture nonnull readonly, %"struct.ap_uint<16>"* noalias nocapture nonnull, i32, i32, i1 zeroext, %"struct.ap_uint<16>"* nocapture readonly)

define void @attention_mask_hw_stub_wrapper([524288 x i16]*, [524288 x i16]*, i32, i32, i1, %"struct.ap_uint<16>"*) #5 {
entry:
  %6 = call i8* @malloc(i64 1048576)
  %7 = bitcast i8* %6 to [524288 x %"struct.ap_uint<16>"]*
  %8 = call i8* @malloc(i64 1048576)
  %9 = bitcast i8* %8 to [524288 x %"struct.ap_uint<16>"]*
  call void @copy_out([524288 x %"struct.ap_uint<16>"]* %7, [524288 x i16]* %0, [524288 x %"struct.ap_uint<16>"]* %9, [524288 x i16]* %1)
  %10 = bitcast [524288 x %"struct.ap_uint<16>"]* %7 to %"struct.ap_uint<16>"*
  %11 = bitcast [524288 x %"struct.ap_uint<16>"]* %9 to %"struct.ap_uint<16>"*
  call void @attention_mask_hw_stub(%"struct.ap_uint<16>"* %10, %"struct.ap_uint<16>"* %11, i32 %2, i32 %3, i1 %4, %"struct.ap_uint<16>"* %5)
  call void @copy_in([524288 x %"struct.ap_uint<16>"]* %7, [524288 x i16]* %0, [524288 x %"struct.ap_uint<16>"]* %9, [524288 x i16]* %1)
  call void @free(i8* %6)
  call void @free(i8* %8)
  ret void
}

attributes #0 = { noinline "fpga.wrapper.func"="wrapper" }
attributes #1 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="copyin" }
attributes #2 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="onebyonecpy_hls" }
attributes #3 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="arraycpy_hls" }
attributes #4 = { argmemonly noinline norecurse willreturn "fpga.wrapper.func"="copyout" }
attributes #5 = { "fpga.wrapper.func"="stub" }

!llvm.dbg.cu = !{}
!llvm.ident = !{!0, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1, !1}
!llvm.module.flags = !{!2, !3, !4}
!blackbox_cfg = !{!5}

!0 = !{!"AMD/Xilinx clang version 16.0.6"}
!1 = !{!"clang version 7.0.0 "}
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !{i32 1, !"wchar_size", i32 4}
!5 = !{}
