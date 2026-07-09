
set TopModule "attention_mask"
set ClockPeriod 10
set ClockList ap_clk
set AxiliteClockList {}
set HasVivadoClockPeriod 0
set CombLogicFlag 0
set PipelineFlag 0
set DataflowTaskPipelineFlag 1
set TrivialPipelineFlag 0
set noPortSwitchingFlag 0
set FloatingPointFlag 0
set FftOrFirFlag 0
set NbRWValue 0
set intNbAccess 0
set NewDSPMapping 1
set HasDSPModule 0
set ResetLevelFlag 0
set ResetStyle control
set ResetSyncFlag 1
set ResetRegisterFlag 0
set ResetVariableFlag 0
set ResetRegisterNum 0
set FsmEncStyle onehot
set MaxFanout 0
set RtlPrefix {}
set RtlSubPrefix attention_mask_
set ExtraCCFlags {}
set ExtraCLdFlags {}
set SynCheckOptions {}
set PresynOptions {}
set PreprocOptions {}
set RtlWriterOptions {}
set CbcGenFlag 0
set CasGenFlag 0
set CasMonitorFlag 0
set AutoSimOptions {}
set ExportMCPathFlag 0
set SCTraceFileName mytrace
set SCTraceFileFormat vcd
set SCTraceOption all
set TargetInfo xc7z015:-clg485:-2
set SourceFiles {sc {} c ../../../src/attention_mask.cpp}
set SourceFlags {sc {} c {{}}}
set DirectiveFile {}
set TBFiles {verilog {D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/mask_test_vectors D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/tb/tb_attention_mask_from_file.cpp} bc {D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/mask_test_vectors D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/tb/tb_attention_mask_from_file.cpp} sc {D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/mask_test_vectors D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/tb/tb_attention_mask_from_file.cpp} vhdl {D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/mask_test_vectors D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/tb/tb_attention_mask_from_file.cpp} c {} cas {D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/mask_test_vectors D:/00game/FPT/Attention_Mask/Attention_Mask_TEST/tb/tb_attention_mask_from_file.cpp}}
set SpecLanguage C
set TVInFiles {bc {} c {} sc {} cas {} vhdl {} verilog {}}
set TVOutFiles {bc {} c {} sc {} cas {} vhdl {} verilog {}}
set TBTops {verilog {} bc {} sc {} vhdl {} c {} cas {}}
set TBInstNames {verilog {} bc {} sc {} vhdl {} c {} cas {}}
set XDCFiles {}
set ExtraGlobalOptions {"area_timing" 1 "clock_gate" 1 "impl_flow" map "power_gate" 0}
set TBTVFileNotFound {}
set AppFile {}
set ApsFile hls.aps
set AvePath ../../.
set DefaultPlatform DefaultPlatform
set multiClockList {}
set SCPortClockMap {}
set intNbAccess 0
set PlatformFiles {{DefaultPlatform {xilinx/zynq/zynq}}}
set HPFPO 0
