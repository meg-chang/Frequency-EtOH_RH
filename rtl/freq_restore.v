// ============================================================================
// freq_restore.v —— 频率域还原（分频比补偿）
// ----------------------------------------------------------------------------
// 链路位置：filter_ma 之后、calib_lut 之前（25MHz 域）
//
// 背景：
//   传感器输出 433MHz 级频率，片外硬件做了 256 分频后才进 FPGA
//   （低频晶振方案，见项目计划 1.2 节）。FIFO 里流传的是分频后的
//   计数值，量纲是"分频域频率"。
//   本模块左移 8 位 = 乘 256，把数据还原回 433MHz 域的频率值，
//   使后续标定系数的物理量纲与传感器手册一致。
//
//   例：100ms 门控计到 169,500 → 分频域 1.695 MHz
//       还原后 169,500 × 256 = 43,392,000 = 433.92 MHz
//
// 参数：
//   IN_WIDTH      —— 输入位宽（滤波后的计数，本项目 20）
//   RESTORE_SHIFT —— 左移位宽 = 片外分频比的对数（256 → 8）
//   OUT_WIDTH     —— 输出位宽 = IN_WIDTH + RESTORE_SHIFT（28）
//   TAG_WIDTH     —— 通道 tag 位宽（与数据同步流经本模块）
//
// 为什么带 tag 直通（联调整测修复，面试可讲）：
//   初版只有 data 通道，顶层把 tag 从 filter_ma 输出直接旁路到
//   calib_lut —— tag 比 data 少走一级流水线，错位一拍：
//   每个样本的数据配上了"下一个样本"的标定系数（CH0 数据套 CH1
//   系数 +1000、CH1 数据套 CH2 系数 >>13……），且每窗口第 3 个样本
//   因下游无新数据，tag 变成乱值。
//   → 教训：流水线里 metadata（tag/valid 附属的通道号）必须与 data
//     走同一组寄存器，不能在模块边界旁路。端到端 tb 首次运行即暴露。
// ============================================================================
module freq_restore #(
    parameter IN_WIDTH       = 20,
    parameter RESTORE_SHIFT = 8,
    parameter OUT_WIDTH     = 28,  // 必须等于 IN_WIDTH + RESTORE_SHIFT
    parameter TAG_WIDTH     = 2
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   din_valid,
    input  wire [TAG_WIDTH-1:0]  din_tag,
    input  wire [IN_WIDTH-1:0]   din_data,
    output reg                    dout_valid,
    output reg  [TAG_WIDTH-1:0]  dout_tag,
    output reg  [OUT_WIDTH-1:0]  dout_data
);

// 1 周期寄存，构成流水线的一级；tag 与 data/valid 同拍输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dout_valid <= 1'b0;
        dout_tag   <= {TAG_WIDTH{1'b0}};
        dout_data  <= {OUT_WIDTH{1'b0}};
    end else begin
        dout_valid <= din_valid;
        dout_tag   <= din_tag;
        dout_data  <= din_data << RESTORE_SHIFT;
    end
end

endmodule
