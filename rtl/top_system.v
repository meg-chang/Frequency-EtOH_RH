// ============================================================================
// top_system.v —— 酒精/湿度检测系统数字链路顶层（仿真用，多时钟域）
// ----------------------------------------------------------------------------
// 完整数据通路（详见 README.md 架构图）：
//
//   SAW 433.92MHz ×3 ──片外 ÷4──▶ 108.48MHz（专用时钟引脚 → GCLK）
//        │
//        ▼  ┌──── 被测时钟域（信号直驱 GCLK，三通道各自一个域）────┐
//   freq_meter_gclk ×3 ← gate_en（50MHz 域产生，两级同步进来）
//        │ count_valid 脉冲 + 24bit 计数（准静态跨域回传）
//        ▼  ┌───────────── 50MHz 采集域 ────────────┐
//   write_arbiter   固定优先级 CH0>CH1>CH2 + 保持寄存器（FIFO 满不丢数据）
//        │ {tag[1:0], count[23:0]}  26bit
//        ▼
//   async_fifo      格雷码指针 CDC，写50M / 读25M，深度16
//        │
//        ▼  ┌───────────── 25MHz 处理域 ────────────┐
//   读侧限速 rd_tick（RD_INTERVAL 拍一次，避免无脑全速读）
//        ▼
//   filter_ma       按 tag 分流 4 点移动平均
//        ▼
//   freq_restore    <<2 还原到 433MHz 域（片外 ÷4 → ×4）
//        ▼
//   calib_lut       先减 BASE 再右移（保住分辨率）+ 零漂 + 饱和
//        ▼
//   tx_packer       组 4 字节帧 0xAA|tag|val_hi|val_lo
//        ▼
//   uart_tx         115200 8N1 输出
//
// 时钟域说明：
//   - clk_sig0/1/2：被测信号域（各 ~108.48MHz，经专用时钟引脚 + GCLK）
//     三通道频率略有差异且互不相关，是三个独立的异步时钟域
//   - clk_50：采集域（门控、写仲裁、FIFO 写侧）
//   - clk_25：处理域（FIFO 读侧、滤波、标定、组帧、UART）
//   - 域间数据通道：被测域→采集域用"准静态两级同步"（更新率仅 10Hz）；
//     采集域→处理域唯一通道是 async_fifo（格雷码指针）
//
// 分辨率核算（÷4 方案，这是选它的原因）：
//   100ms 门控 → 分频域分辨率 10Hz → 还原 ×4 → 433MHz 域分辨率 40Hz
//   对比旧 ÷256 方案：10Hz × 256 = 2560Hz，本方案提升 64 倍
//   为此标定必须"先减 BASE 再右移"，否则 40Hz 会被 >>14 抹掉
//
// 已知可改进点（面试可主动讲）：
//   - rst_n 直接进各时钟域。规范做法是每域一个复位同步器
//     （异步置位、同步释放），本系统复位只在开机时发生一次，风险低，
//     列为改进项而非缺陷。
//   - FIFO 深度 16 用分布式 RAM（异步读）；深度加大需换 M9K 同步读，
//     下游流水线要补 1 拍 valid 对齐。
//   - cnt_out 跨域用准静态两级同步（论证见 freq_meter_gclk.v 文件头）。
//     若更新率提到 MHz 级，必须换成格雷码或握手。
//
// 联调整测记录（端到端 tb 首次运行即暴露，已修复）：
//   - 初版 calib_lut 的 din_tag 旁路自 filter_ma 输出，比数据少走一级
//     freq_restore，导致每个样本配上下一个样本的标定系数。
//     修复：freq_restore 增加 tag 直通端口，tag 与 data 同拍流动。
//     教训：流水线 metadata 必须与数据走同一组寄存器。
// ============================================================================
module top_system #(
    // ---- 采集域参数 ----
    parameter GATE_CYCLES  = 5000000,   // 50MHz × 100ms = 5,000,000
    parameter IDLE_CYCLES  = 16,        // 门控末尾留给锁存的拍数
    parameter COUNT_WIDTH  = 24,        // 100ms@108.48MHz → 10,848,000（需 24bit）
    parameter RESTORE_SHIFT = 2,        // 片外 ÷4 → ×4 还原
    // ---- FIFO 参数 ----
    parameter FIFO_DEPTH   = 16,        // 必须 2 的幂
    parameter PTR_WIDTH    = 5,         // log2(DEPTH) + 1
    // ---- 处理域参数 ----
    parameter TAPS         = 4,         // 移动平均抽头数（2 的幂）
    parameter RD_INTERVAL  = 2000,      // 读侧限速：25MHz 下 80µs 读一次
    // ---- 标定系数（BASE 在右移前减，决定分辨率；见 calib_lut.v）----
    parameter [31:0] CAL0_BASE = 32'd43000000,   // 433.0MHz 基准
    parameter [15:0] CAL0_MULT = 16'd1,
    parameter integer CAL0_SHIFT = 3,            // LSB = 8Hz，量程 ±524kHz
    parameter integer CAL0_OFFSET = 0,
    parameter [31:0] CAL1_BASE = 32'd43000000,   // 参考通道同基准
    parameter [15:0] CAL1_MULT = 16'd1,
    parameter integer CAL1_SHIFT = 3,
    parameter integer CAL1_OFFSET = 1000,        // 零漂偏置
    parameter [31:0] CAL2_BASE = 32'd43000000,   // 湿度通道
    parameter [15:0] CAL2_MULT = 16'd1,
    parameter integer CAL2_SHIFT = 3,
    parameter integer CAL2_OFFSET = 0,
    // ---- UART 参数 ----
    parameter CLK_FREQ     = 25000000,
    parameter BAUD_RATE    = 115200
) (
    input  wire clk_50,
    input  wire clk_25,
    input  wire rst_n,
    // 三路传感器信号（片外 ÷4 后约 108.48MHz；上板时必须接专用时钟引脚）
    input  wire sig_ch0,
    input  wire sig_ch1,
    input  wire sig_ch2,
    // 串行输出
    output wire uart_tx,
    // 调试观测口（示波器/逻辑分析仪/上板 LED 用，不参与功能）
    output wire dbg_gate_en,
    output wire dbg_fifo_empty
);

localparam DATA_W = 2 + COUNT_WIDTH;           // FIFO 数据位宽 26 = tag 2 + count 24

// ============================================================================
// 采集域（clk_50）：门控窗口
// ============================================================================
wire gate_en, gate_tick, gate_start;

gate_timer #(
    .GATE_CYCLES(GATE_CYCLES),
    .IDLE_CYCLES(IDLE_CYCLES)
) u_gate (
    .clk       (clk_50),
    .rst_n     (rst_n),
    .gate_en   (gate_en),
    .gate_tick (gate_tick),
    .gate_start(gate_start)
);

// ---- 三通道测频（被测信号直驱 GCLK）-----------------------------------------
// 门控 gate_en 由 50MHz 域产生，在模块内两级同步进各被测域；
// 结果以"准静态"两级同步回传 50MHz 域，出 1 周期 count_valid 脉冲。
wire                   fm_v0, fm_v1, fm_v2;
wire [COUNT_WIDTH-1:0] fm_c0, fm_c1, fm_c2;

freq_meter_gclk #(.COUNT_WIDTH(COUNT_WIDTH)) u_fm0 (
    .clk_sig(sig_ch0), .rst_sig_n(rst_n),
    .gate_en(gate_en),
    .clk_sys(clk_50),  .rst_sys_n(rst_n),
    .count_valid(fm_v0), .count(fm_c0)
);

freq_meter_gclk #(.COUNT_WIDTH(COUNT_WIDTH)) u_fm1 (
    .clk_sig(sig_ch1), .rst_sig_n(rst_n),
    .gate_en(gate_en),
    .clk_sys(clk_50),  .rst_sys_n(rst_n),
    .count_valid(fm_v1), .count(fm_c1)
);

freq_meter_gclk #(.COUNT_WIDTH(COUNT_WIDTH)) u_fm2 (
    .clk_sig(sig_ch2), .rst_sig_n(rst_n),
    .gate_en(gate_en),
    .clk_sys(clk_50),  .rst_sys_n(rst_n),
    .count_valid(fm_v2), .count(fm_c2)
);

// ---- 写仲裁 ----------------------------------------------------------------
wire                  fifo_wreq;
wire [DATA_W-1:0]     fifo_wdata;
wire                  fifo_full;

write_arbiter #(.COUNT_WIDTH(COUNT_WIDTH)) u_arb (
    .clk      (clk_50),
    .rst_n    (rst_n),
    .ch0_valid(fm_v0), .ch0_count(fm_c0),
    .ch1_valid(fm_v1), .ch1_count(fm_c1),
    .ch2_valid(fm_v2), .ch2_count(fm_c2),
    .fifo_full(fifo_full),
    .fifo_wreq(fifo_wreq),
    .fifo_wdata(fifo_wdata)
);

// ============================================================================
// 异步 FIFO（写 50MHz / 读 25MHz）
// ============================================================================
wire                  fifo_rreq;
wire [DATA_W-1:0]     fifo_rdata;
wire                  fifo_rempty;

async_fifo #(
    .DATA_WIDTH(DATA_W),
    .DEPTH     (FIFO_DEPTH),
    .PTR_WIDTH (PTR_WIDTH)
) u_fifo (
    .wclk  (clk_50),
    .wrst_n(rst_n),
    .wreq  (fifo_wreq),
    .wdata (fifo_wdata),
    .wfull (fifo_full),
    .rclk  (clk_25),
    .rrst_n(rst_n),
    .rreq  (fifo_rreq),
    .rdata (fifo_rdata),
    .rempty(fifo_rempty)
);

// ============================================================================
// 处理域（clk_25）
// ============================================================================
// ---- 读侧限速 --------------------------------------------------------------
// 数据到达率仅 30 笔/秒，全速读没有意义；限速后平均每 80µs 尝试一次，
// 既保证 FIFO 被及时排空，又降低动态功耗（也是可讲的工程取舍）。
reg [31:0] rd_cnt;
reg        rd_tick;

always @(posedge clk_25 or negedge rst_n) begin
    if (!rst_n) begin
        rd_cnt  <= 32'd0;
        rd_tick <= 1'b0;
    end else if (rd_cnt >= RD_INTERVAL - 1) begin
        rd_cnt  <= 32'd0;
        rd_tick <= 1'b1;
    end else begin
        rd_cnt  <= rd_cnt + 1'b1;
        rd_tick <= 1'b0;
    end
end

wire rd_fire = rd_tick & ~fifo_rempty;
assign fifo_rreq = rd_fire;

// FIFO 异步读：rdata 与 rreq 同拍有效。这里寄存一拍，
// 使 valid/data 严格对齐后再进流水线（也隔离了 RAM 读端口）。
reg                  pl_v;
reg [DATA_W-1:0]     pl_d;

always @(posedge clk_25 or negedge rst_n) begin
    if (!rst_n) begin
        pl_v <= 1'b0;
        pl_d <= {DATA_W{1'b0}};
    end else begin
        pl_v <= rd_fire;
        pl_d <= fifo_rdata;
    end
end

// ---- 流水线：滤波 → 频率还原 → 标定 → 组帧 → UART ---------------------------
wire                 flt_v;
wire [1:0]           flt_tag;
wire [COUNT_WIDTH-1:0] flt_data;

filter_ma #(
    .TAPS      (TAPS),
    .SHIFT     ($clog2(TAPS)),
    .DATA_WIDTH(COUNT_WIDTH)
) u_flt (
    .clk      (clk_25),
    .rst_n    (rst_n),
    .din_valid(pl_v),
    .din_tag  (pl_d[DATA_W-1:DATA_W-2]),
    .din_data (pl_d[COUNT_WIDTH-1:0]),
    .dout_valid(flt_v),
    .dout_tag  (flt_tag),
    .dout_data (flt_data)
);

wire                 rst_v;
wire [1:0]           rst_tag;
wire [COUNT_WIDTH+RESTORE_SHIFT-1:0] rst_data;   // 24 + 2 = 26

freq_restore #(
    .IN_WIDTH      (COUNT_WIDTH),
    .RESTORE_SHIFT (RESTORE_SHIFT),
    .OUT_WIDTH     (COUNT_WIDTH + RESTORE_SHIFT)
) u_restore (
    .clk      (clk_25),
    .rst_n    (rst_n),
    .din_valid(flt_v),
    .din_tag  (flt_tag),     // tag 与 data 同拍流经本级（不得旁路！）
    .din_data (flt_data),
    .dout_valid(rst_v),
    .dout_tag  (rst_tag),
    .dout_data (rst_data)
);

wire                 cal_v;
wire [1:0]           cal_tag;
wire [15:0]          cal_data;

calib_lut #(
    .IN_WIDTH   (COUNT_WIDTH + RESTORE_SHIFT),
    .CH0_BASE   (CAL0_BASE),
    .CH0_MULT   (CAL0_MULT),
    .CH0_SHIFT  (CAL0_SHIFT),
    .CH0_OFFSET (CAL0_OFFSET),
    .CH1_BASE   (CAL1_BASE),
    .CH1_MULT   (CAL1_MULT),
    .CH1_SHIFT  (CAL1_SHIFT),
    .CH1_OFFSET (CAL1_OFFSET),
    .CH2_BASE   (CAL2_BASE),
    .CH2_MULT   (CAL2_MULT),
    .CH2_SHIFT  (CAL2_SHIFT),
    .CH2_OFFSET (CAL2_OFFSET)
) u_cal (
    .clk      (clk_25),
    .rst_n    (rst_n),
    .din_valid(rst_v),
    .din_tag  (rst_tag),     // 与 rst_data 同拍：经 restore 寄存后的 tag
    .din_data (rst_data),
    .dout_valid(cal_v),
    .dout_tag  (cal_tag),
    .dout_data (cal_data)
);

wire        pk_start;
wire [7:0]  pk_data;
wire        u_busy;

tx_packer u_pk (
    .clk      (clk_25),
    .rst_n    (rst_n),
    .req_valid(cal_v),
    .req_tag  (cal_tag),
    .req_val  (cal_data),
    .uart_busy(u_busy),
    .tx_start (pk_start),
    .tx_data  (pk_data),
    .pkt_busy (/* 观测用，未连接 */)
);

uart_tx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart (
    .clk     (clk_25),
    .rst_n   (rst_n),
    .tx_start(pk_start),
    .tx_data (pk_data),
    .tx_busy (u_busy),
    .tx      (uart_tx)
);

// 调试观测：门控窗口 + FIFO 空指示（顶层端口，便于示波器抓）
assign dbg_gate_en   = gate_en;
assign dbg_fifo_empty = fifo_rempty;

endmodule
