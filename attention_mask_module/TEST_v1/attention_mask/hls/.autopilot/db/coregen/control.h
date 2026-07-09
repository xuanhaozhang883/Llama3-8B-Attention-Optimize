// 0x00 : Control signals
//        bit 0  - ap_start (Read/Write/COH)
//        bit 1  - ap_done (Read/COR)
//        bit 2  - ap_idle (Read)
//        bit 3  - ap_ready (Read/COR)
//        bit 7  - auto_restart (Read/Write)
//        bit 9  - interrupt (Read)
//        others - reserved
// 0x04 : Global Interrupt Enable Register
//        bit 0  - Global Interrupt Enable (Read/Write)
//        others - reserved
// 0x08 : IP Interrupt Enable Register (Read/Write)
//        bit 0 - enable ap_done interrupt (Read/Write)
//        bit 1 - enable ap_ready interrupt (Read/Write)
//        others - reserved
// 0x0c : IP Interrupt Status Register (Read/TOW)
//        bit 0 - ap_done (Read/TOW)
//        bit 1 - ap_ready (Read/TOW)
//        others - reserved
// 0x10 : Data signal of raw_scores
//        bit 31~0 - raw_scores[31:0] (Read/Write)
// 0x14 : Data signal of raw_scores
//        bit 31~0 - raw_scores[63:32] (Read/Write)
// 0x18 : reserved
// 0x1c : Data signal of masked_scores
//        bit 31~0 - masked_scores[31:0] (Read/Write)
// 0x20 : Data signal of masked_scores
//        bit 31~0 - masked_scores[63:32] (Read/Write)
// 0x24 : reserved
// 0x28 : Data signal of q_heads
//        bit 31~0 - q_heads[31:0] (Read/Write)
// 0x2c : reserved
// 0x30 : Data signal of seq_len
//        bit 31~0 - seq_len[31:0] (Read/Write)
// 0x34 : reserved
// 0x38 : Data signal of causal
//        bit 0  - causal[0] (Read/Write)
//        others - reserved
// 0x3c : reserved
// 0x40 : Data signal of mask_value
//        bit 15~0 - mask_value[15:0] (Read/Write)
//        others   - reserved
// 0x44 : reserved
// (SC = Self Clear, COR = Clear on Read, TOW = Toggle on Write, COH = Clear on Handshake)

#define CONTROL_ADDR_AP_CTRL            0x00
#define CONTROL_ADDR_GIE                0x04
#define CONTROL_ADDR_IER                0x08
#define CONTROL_ADDR_ISR                0x0c
#define CONTROL_ADDR_RAW_SCORES_DATA    0x10
#define CONTROL_BITS_RAW_SCORES_DATA    64
#define CONTROL_ADDR_MASKED_SCORES_DATA 0x1c
#define CONTROL_BITS_MASKED_SCORES_DATA 64
#define CONTROL_ADDR_Q_HEADS_DATA       0x28
#define CONTROL_BITS_Q_HEADS_DATA       32
#define CONTROL_ADDR_SEQ_LEN_DATA       0x30
#define CONTROL_BITS_SEQ_LEN_DATA       32
#define CONTROL_ADDR_CAUSAL_DATA        0x38
#define CONTROL_BITS_CAUSAL_DATA        1
#define CONTROL_ADDR_MASK_VALUE_DATA    0x40
#define CONTROL_BITS_MASK_VALUE_DATA    16
