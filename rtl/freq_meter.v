// ============================================================================
// freq_meter.v —— 门控计数测频模块（单通道）
// ----------------------------------------------------------------------------
// 链路位置：sig_in(1.691MHz, 异步) → 两级同步 → 边沿检测 → 门控计数
//
// 工作流程（每个 100ms 门控窗口）：
//   1. gate_en 高电平期间，对同步后的信号上升沿计数
//   2. gate_tick 到来：cnt 锁存到 cnt_out，发出 1 周期 count_valid 脉冲，cnt 清零
//   3. 下一窗口立即开始计数（计数不被锁存/等待阻塞）
//
// 关键设计点（面试可讲）：
//   - sig_in 是异步信号，必须两级同步，绝不能直接采样
//   - 同步器引入 2 拍延迟，门控边沿的脉冲可能被少数 1~2 个，
//     相对 10Hz 分辨率（还原后 2560Hz）完全可忽略
//   - cnt 计到饱和即停（不回绕），配合 SVA 断言防溢出 bug
//   - count_valid 是脉冲而非电平：与 write_arbiter 同时钟域，
//     仲裁侧有保持寄存器，同域脉冲必然被捕获，无需背压握手
//
// 参数：
//   COUNT_WIDTH —— 计数值位宽。100ms 窗口最多约 169,140 counts
//                   （433MHz/256 场景），18bit 够用，设计取 20bit 留裕量
// ============================================================================

module freq_meter #(
    parameter COUNT_WIDTH = 20
) (
    input  wire clk,
    input  wire rst_n,
    inout  wire sig_in,                    // 异步输入（片外分频后约 1.691MHz）
    input  wire gate_en,                   // 门控窗口（来自 gate_timer）
    input  wire gate_tick,                 // 窗口结束脉冲（来自 gate_timer）
    output reg  count_valid,               // 数据有效脉冲（1 周期）
    output wire [COUNT_WIDTH-1:0] count    // 本窗口计数值
);

// ---- 输入信号两级同步 + 上升沿检测 --------------------------------------
reg sig_d1, sig_d2, sig_d3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sig_d1 <= 1'b0;
        sig_d2 <= 1'b0;
        sig_d3 <= 1'b0;
    end else begin
        sig_d1 <= sig_in;
        sig_d2 <= sig_d1;
        sig_d3 <= sig_d2;
    end
end

wire sig_rise = sig_d2 & ~sig_d3;  //同步后信号的上升沿
