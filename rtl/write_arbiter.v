// ============================================================================
// write_arbiter.v —— 三通道 FIFO 写仲裁（固定优先级 + 保持寄存器）
// ----------------------------------------------------------------------------
// 问题背景：三个 freq_meter 的门控窗口同时结束，三笔数据几乎同时到达，
//           FIFO 只有一个写入口 → 需要仲裁。
//
// 方案：固定优先级 CH0 > CH1 > CH2（计划中的降级路径；
//       数据速率极低——每 100ms 才 3 笔，优先级不会造成饥饿，
//       如需严格公平可改 round-robin，只需替换 sel 逻辑）。
//
// 防丢数据机制：
//   - 每通道一个保持寄存器：freq_meter 的 valid 脉冲（同时钟域）必然被捕获
//   - FIFO 满时暂停写出，保持寄存器留住数据，不会丢
//   - 写仲裁 1 周期只能服务 1 笔；3 笔最多 3 周期服务完，
//     相对 100ms 窗口间隔有 6 个数量级余量
//
// 数据格式：{tag[1:0], count[COUNT_WIDTH-1:0]}，共 COUNT_WIDTH+2 bit
//   tag = 0 酒精通道 / 1 参考通道 / 2 湿度通道
//
// 参数：
//   COUNT_WIDTH —— 计数值位宽。旧 ÷256 方案为 20；÷4 方案为 24
//                  （100ms@108.48MHz = 10,848,000），故必须参数化，
//                  不能写死 20，否则高位被综合器悄悄截断。
// ============================================================================
module write_arbiter #(
    parameter COUNT_WIDTH = 24
) (
    input  wire        clk,
    input  wire        rst_n,
    // 三通道输入（50MHz 域，valid 为 1 周期脉冲）
    input  wire        ch0_valid,
    input  wire [COUNT_WIDTH-1:0] ch0_count,
    input  wire        ch1_valid,
    input  wire [COUNT_WIDTH-1:0] ch1_count,
    input  wire        ch2_valid,
    input  wire [COUNT_WIDTH-1:0] ch2_count,
    // 背压源
    input  wire        fifo_full,
    // FIFO 写接口（寄存 1 拍输出）
    output reg         fifo_wreq,
    output reg  [COUNT_WIDTH+1:0] fifo_wdata
);

localparam DATA_W = COUNT_WIDTH + 2;

// ---- 每通道保持寄存器 -----------------------------------------------------
reg        hold_v0, hold_v1, hold_v2;
reg [COUNT_WIDTH-1:0] hold_d0, hold_d1, hold_d2;

// ---- 优先级选择（组合） ---------------------------------------------------
wire sel0 = hold_v0;                                    // CH0 优先
wire sel1 = hold_v1 & ~hold_v0;
wire sel2 = hold_v2 & ~hold_v0 & ~hold_v1;

wire        wr_en  = ~fifo_full & (sel0 | sel1 | sel2);
wire [DATA_W-1:0] wr_data = sel0 ? {2'b00, hold_d0} :
                            sel1 ? {2'b01, hold_d1} :
                                   {2'b10, hold_d2};

// ---- 时序逻辑：捕获脉冲 + 写后清除 + 寄存输出 ------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hold_v0 <= 1'b0; hold_v1 <= 1'b0; hold_v2 <= 1'b0;
        hold_d0 <= {COUNT_WIDTH{1'b0}};
        hold_d1 <= {COUNT_WIDTH{1'b0}};
        hold_d2 <= {COUNT_WIDTH{1'b0}};
        fifo_wreq  <= 1'b0;
        fifo_wdata <= {DATA_W{1'b0}};
    end else begin
        // FIFO 写接口寄存输出（本拍选中，下一拍落在 FIFO 端口上）
        fifo_wreq  <= wr_en;
        fifo_wdata <= wr_data;

        // 保持寄存器：新脉冲优先捕获；被服务后清除
        // 注：同一通道上一笔未走时又来新脉冲会覆盖（正常工况不可能，
        //     100ms 间隔 >> 3 周期服务时间；如发生说明背压失效）
        if (ch0_valid) begin
            hold_d0 <= ch0_count;
            hold_v0 <= 1'b1;
        end else if (wr_en && sel0) begin
            hold_v0 <= 1'b0;
        end

        if (ch1_valid) begin
            hold_d1 <= ch1_count;
            hold_v1 <= 1'b1;
        end else if (wr_en && sel1) begin
            hold_v1 <= 1'b0;
        end

        if (ch2_valid) begin
            hold_d2 <= ch2_count;
            hold_v2 <= 1'b1;
        end else if (wr_en && sel2) begin
            hold_v2 <= 1'b0;
        end
    end
end

endmodule
