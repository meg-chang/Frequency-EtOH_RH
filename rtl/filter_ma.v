// ============================================================================
// filter_ma.v —— 按 tag 分流的 N 点移动平均滤波器
// ----------------------------------------------------------------------------
// 链路位置：FIFO 读出口（25MHz 域），freq_restore 之前
//
// 为什么需要：
//   测频结果在窗口边界有 ±1~2 count 的抖动（同步器延迟 + 门控沿量化），
//   直接输出会在 UART 上看成跳字。移动平均用时间换平滑，是传感器链路
//   最常用的低通手段（也是面试高频题：滑动平均 vs FIFO 平均）。
//
// 实现要点：
//   - 三个通道各自独立的历史寄存器组，按 din_tag 索引，互不串扰
//   - sum = 本拍新值 + 前 TAPS-1 个历史值，右移 SHIFT 位 = 除以 TAPS
//   - 1 周期寄存输出，构成流水线的一级
//   - 输出位宽回到 DATA_WIDTH：TAPS 个不超过 2^DATA_WIDTH 的数求和后
//     右移 SHIFT，结果必然不超过原值域，不会溢出
//
// 参数：
//   TAPS       —— 抽头数（本项目 4，需为 2 的幂，右移代替除法）
//   SHIFT      —— log2(TAPS)
//   DATA_WIDTH —— 输入/输出数据位宽（计数位宽，本项目 20）
// ============================================================================
module filter_ma #(
    parameter TAPS       = 4,
    parameter SHIFT      = 2,
    parameter DATA_WIDTH = 20
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   din_valid,
    input  wire [1:0]             din_tag,
    input  wire [DATA_WIDTH-1:0] din_data,
    output reg                    dout_valid,
    output reg  [1:0]             dout_tag,
    output reg  [DATA_WIDTH-1:0] dout_data
);

localparam SUM_W = DATA_WIDTH + SHIFT;   // 求和位宽，防中间溢出
localparam NHIST = TAPS - 1;             // 历史深度 = 抽头数 - 1

// ---- 三通道历史寄存器组：[通道][新→旧] --------------------------------------
// 上电/复位后全 0，因此前 TAPS-1 笔输出是"部分和"，属于正常的滤波器建立过程
reg [DATA_WIDTH-1:0] hist [0:2][0:NHIST-1];

integer i, j;

// ---- 组合求和（按 tag 选通道） ----------------------------------------------
reg [SUM_W-1:0] sum_c;
always @(*) begin
    sum_c = {1'b0, din_data};
    for (i = 0; i < NHIST; i = i + 1)
        sum_c = sum_c + hist[din_tag[1:0]][i];
end

// ---- 时序逻辑：寄存输出 + 移位更新 ------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dout_valid <= 1'b0;
        dout_tag   <= 2'd0;
        dout_data  <= {DATA_WIDTH{1'b0}};
        for (i = 0; i < 3; i = i + 1)
            for (j = 0; j < NHIST; j = j + 1)
                hist[i][j] <= {DATA_WIDTH{1'b0}};
    end else begin
        // 1 周期延迟输出，与输入 valid/data 对齐
        dout_valid <= din_valid;
        dout_tag   <= din_tag;
        // sum_c[SUM_W-1:SHIFT] 即 (sum >> SHIFT)，宽度恰为 DATA_WIDTH
        dout_data  <= sum_c[SUM_W-1:SHIFT];

        if (din_valid) begin
            hist[din_tag[1:0]][0] <= din_data;                 // 最新值入队
            for (j = 1; j < NHIST; j = j + 1)                  // 旧的往后挪
                hist[din_tag[1:0]][j] <= hist[din_tag[1:0]][j-1];
        end
    end
end

endmodule
