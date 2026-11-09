// ============================================================================
// uart_tx.v —— UART 发送器（8N1，可配置波特率）
// ----------------------------------------------------------------------------
// 链路位置：流水线末端（25MHz 域），tx_packer 之后
//
// 帧格式：1 起始位(0) + 8 数据位(LSB first) + 1 停止位(1)
// 空闲位：高电平（mark）
//
// 设计要点：
//   - 波特率时钟由分频计数器产生，DIV = CLK_FREQ / BAUD_RATE 取整
//     本项目 25MHz / 115200 = 217（实际波特率 115,226，误差 0.02%，可接受）
//   - tx 用组合逻辑驱动 state：保证每个位宽精确等于 DIV 个时钟
//     （若用寄存输出，状态切换会多出 1 拍偏差，帧内累计 10 拍误差）
//   - tx_busy 组合输出：仅 IDLE 时为低，供 tx_packer 判断能否发下一字节
//   - tx_start 是 1 周期脉冲，上升沿锁存数据；busy 期间忽略新的 tx_start
//     （本项目帧间隔 100ms，不存在连续发送，无需 FIFO 缓冲）
// ============================================================================
module uart_tx #(
    parameter CLK_FREQ  = 25000000,
    parameter BAUD_RATE = 115200
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tx_start,     // 发送请求脉冲（1 周期）
    input  wire [7:0]  tx_data,      // 待发字节
    output wire        tx_busy,      // 高 = 正在发帧
    output wire        tx            // UART 串行输出
);

localparam [31:0] DIV   = CLK_FREQ / BAUD_RATE;   // 每比特时钟数 = 217
localparam [31:0] DIV_W = 8;                       // 0..216 需 8bit

localparam [1:0] S_IDLE  = 2'd0,
                 S_START = 2'd1,
                 S_DATA  = 2'd2,
                 S_STOP  = 2'd3;

reg [1:0]        state;
reg [DIV_W-1:0]  baud_cnt;
reg [2:0]        bit_idx;
reg [7:0]        shreg;

assign tx_busy = (state != S_IDLE);

// 组合驱动串行线：每位宽度严格 DIV 个时钟
assign tx = (state == S_START) ? 1'b0          :
            (state == S_DATA)  ? shreg[bit_idx] :
                                 1'b1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        baud_cnt  <= {DIV_W{1'b0}};
        bit_idx   <= 3'd0;
        shreg     <= 8'd0;
    end else begin
        case (state)
            // ---- 空闲：等启动脉冲 ----
            S_IDLE: begin
                baud_cnt <= {DIV_W{1'b0}};
                if (tx_start) begin
                    shreg <= tx_data;      // 锁存，防止发送中途数据变化
                    state <= S_START;
                end
            end

            // ---- 起始位：低电平 DIV 拍 ----
            S_START: begin
                if (baud_cnt == DIV-1) begin
                    baud_cnt <= {DIV_W{1'b0}};
                    bit_idx  <= 3'd0;
                    state    <= S_DATA;
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end

            // ---- 数据位：LSB first，每位 DIV 拍 ----
            S_DATA: begin
                if (baud_cnt == DIV-1) begin
                    baud_cnt <= {DIV_W{1'b0}};
                    if (bit_idx == 3'd7)
                        state <= S_STOP;
                    else
                        bit_idx <= bit_idx + 1'b1;
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end

            // ---- 停止位：高电平 DIV 拍，回空闲 ----
            S_STOP: begin
                if (baud_cnt == DIV-1) begin
                    baud_cnt <= {DIV_W{1'b0}};
                    state    <= S_IDLE;
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
