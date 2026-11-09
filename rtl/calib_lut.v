// ============================================================================
// calib_lut.v —— 三通道标定查找表（线性增益 + 零漂 + 饱和）
// ----------------------------------------------------------------------------
// 链路位置：freq_restore 之后、tx_packer 之前（25MHz 域）
//
// 功能：把"还原后的频率值"换算成工程量。
//   每个通道一套系数（查表式，非存储器实现，3 组系数综合成组合 mux）：
//
//        out = sat( ((in - BASE) × MULT) >>> SHIFT  +  OFFSET )
//
//   BASE   —— 基准频率（移位【前】减去，有符号）。★ 分辨率的关键
//   MULT   —— 增益（量程换算）
//   SHIFT  —— 右移位（等效除以 2^SHIFT，避免引入除法器）
//   OFFSET —— 零漂/输出偏置（移位后加，有符号）
//   sat    —— 输出限幅到 [0, 2^OUT_WIDTH-1]，防标定系数配错时回绕
//
// 为什么必须有 BASE（设计演进，面试可讲）：
//   433.92MHz 直接 >>14 得到 2647 这种"绝对量"看似合理，但 LSB 代表
//   16384Hz —— 而 ÷4 方案的测量分辨率是 40Hz，被右移直接抹掉，
//   前端辛苦提升的 64 倍分辨率在最后一整级全部丢失。
//   正确做法是【先减基准再右移】：只把"相对基准的偏移量"放大到 16bit，
//   于是 LSB 可以做到几 Hz，测量分辨率才真正落到输出上。
//
//   ÷4 方案典型配置（生产值）：
//     in    = 10,848,000 × 4 = 43,392,000（433.92MHz）
//     BASE  = 43,000,000（433.0MHz 基准）
//     SHIFT = 3  →  (43,392,000 - 43,000,000) >> 3 = 49,000
//     LSB   = 8Hz，量程 = ±524kHz（2^16 × 8Hz），远大于 SAW 典型频偏
//   若某通道频偏超量程 → 饱和到 0/65535，此时应调大 SHIFT 而非报错。
//
// 演示系数（默认值）——三通道刻意取不同增益，便于：
//   · 仿真波形里一眼确认 tag 分流正确
//   · 端到端 tb 抓通道串扰（任一通道值被写错都会越出容差）
//   · 上板时替换为实测回归系数即可，接口不变
//   注：BASE 默认 0 —— 保持与旧版完全等价，已有 tb 无需改动
//
// 参数：
//   IN_WIDTH  —— 输入位宽（还原后频率，÷4 方案 26）
//   OUT_WIDTH —— 输出位宽（UART 帧携带 2 字节，本项目 16）
// ============================================================================
module calib_lut #(
    parameter IN_WIDTH  = 28,
    parameter OUT_WIDTH = 16,

    // CH0 酒精通道
    parameter [31:0]  CH0_BASE   = 32'd0,
    parameter [15:0]  CH0_MULT   = 16'd1,
    parameter integer CH0_SHIFT  = 14,
    parameter integer CH0_OFFSET = 0,

    // CH1 参考通道：零漂 +1000（基准偏置标定）
    parameter [31:0]  CH1_BASE   = 32'd0,
    parameter [15:0]  CH1_MULT   = 16'd1,
    parameter integer CH1_SHIFT  = 14,
    parameter integer CH1_OFFSET = 1000,

    // CH2 湿度通道
    parameter [31:0]  CH2_BASE   = 32'd0,
    parameter [15:0]  CH2_MULT   = 16'd1,
    parameter integer CH2_SHIFT  = 13,
    parameter integer CH2_OFFSET = 0
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   din_valid,
    input  wire [1:0]             din_tag,
    input  wire [IN_WIDTH-1:0]   din_data,
    output reg                    dout_valid,
    output reg  [1:0]             dout_tag,
    output reg  [OUT_WIDTH-1:0]  dout_data
);

localparam PROD_W = IN_WIDTH + 16;   // 乘法结果位宽 28+16 = 44

// ---- 按 tag 选系数（组合查表） ----------------------------------------------
wire signed [31:0] sel_base = (din_tag == 2'd0) ? $signed(CH0_BASE) :
                              (din_tag == 2'd1) ? $signed(CH1_BASE) :
                                                  $signed(CH2_BASE);

wire [15:0] sel_mult = (din_tag == 2'd0) ? CH0_MULT :
                       (din_tag == 2'd1) ? CH1_MULT : CH2_MULT;

wire [4:0]  sel_shift = (din_tag == 2'd0) ? CH0_SHIFT[4:0] :
                        (din_tag == 2'd1) ? CH1_SHIFT[4:0] : CH2_SHIFT[4:0];

wire signed [31:0] sel_offset = (din_tag == 2'd0) ? $signed(CH0_OFFSET) :
                                (din_tag == 2'd1) ? $signed(CH1_OFFSET) :
                                                    $signed(CH2_OFFSET);

// ---- 线性标定（有符号运算 + 饱和） ------------------------------------------
reg signed [PROD_W-1:0] dev;    // in - BASE（相对基准的偏移量，可负）
reg signed [PROD_W-1:0] prod;   // dev × MULT
reg signed [PROD_W-1:0] cal;    // (prod >>> SHIFT) + OFFSET

always @(*) begin
    dev  = $signed({1'b0, din_data}) - sel_base;   // 先减基准，保住分辨率
    prod = dev * $signed({1'b0, sel_mult});
    cal  = (prod >>> sel_shift) + sel_offset;
end

// 饱和边界（有符号常量，保证比较按有符号进行）
localparam signed [PROD_W-1:0] CAL_MAX = {{(PROD_W-OUT_WIDTH){1'b0}}, {OUT_WIDTH{1'b1}}};
localparam signed [PROD_W-1:0] CAL_MIN = {PROD_W{1'b0}};

wire [OUT_WIDTH-1:0] cal_sat = (cal < CAL_MIN) ? {OUT_WIDTH{1'b0}} :
                               (cal > CAL_MAX) ? {OUT_WIDTH{1'b1}} :
                                                 cal[OUT_WIDTH-1:0];

// ---- 1 周期寄存输出 ---------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dout_valid <= 1'b0;
        dout_tag   <= 2'd0;
        dout_data  <= {OUT_WIDTH{1'b0}};
    end else begin
        dout_valid <= din_valid;
        dout_tag   <= din_tag;
        dout_data  <= cal_sat;
    end
end

endmodule
