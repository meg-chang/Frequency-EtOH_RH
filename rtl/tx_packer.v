// ============================================================================
// tx_packer.v —— UART 组帧器（4 字节定长帧 + 4 深度环形队列）
// ----------------------------------------------------------------------------
// 帧格式（4 字节）：
//   byte0 = 0xAA          帧头（固定，便于上位机/逻辑分析仪同步）
//   byte1 = tag[1:0]      通道号：0 酒精 / 1 参考 / 2 湿度
//   byte2 = val[15:8]     标定值高字节
//   byte3 = val[7:0]      标定值低字节
//
// 为什么需要握手：uart_tx 一次只能发一帧，组帧器必须等上一帧发完
//                 才能发下一字节，否则 tx_start 会被 busy 中的 uart_tx 丢弃。
//
// 为什么需要队列（设计演进，面试可讲）：
//   初版用 1 级保持寄存器。联调时发现会丢数据：
//     一帧时长 = 4 字节 × 10 bit × 217 拍 = 8680 拍 @25MHz ≈ 347µs
//     而三通道数据经 write_arbiter 后在 ~3 个读周期内突发进入流水线
//     （读侧限速 RD_INTERVAL=2000 拍 ≈ 80µs，3 笔共 ~240µs）
//     → 第 2、3 笔请求到达时第 1 帧还在发，1 级寄存器被覆盖 → 丢数
//   因此升级为 QD=4 的环形队列：覆盖 3 通道同窗口突发 + 1 级余量。
//   队列容量核算：最坏占用 3 笔，深度 4 永不溢出；若后续提高更新率
//   （如三通道改 100Hz），按 帧时长/请求间隔 重算深度即可。
//
// 状态机（5 态）：
//   P_IDLE    —— 等队列非空且 uart_tx 空闲（tx_start 绝不在 busy 期间发出）
//   P_START   —— 向 uart_tx 发 1 周期 tx_start（本拍带出当前字节）
//   P_WAIT_UP —— 等 uart_tx 拉忙（确认启动被受理）
//   P_WAIT_DN —— 等 uart_tx 发完本帧（tx_busy 拉低）
//   4 字节发完 → 队首指针后移 → P_IDLE
//
// 握手健壮性（联调实测修复，面试可讲）：
//   uart_tx 是单帧发送器，busy 期间到来的 tx_start 会被直接丢弃。
//   P_IDLE→P_START 必须以 !uart_busy 为前提，否则：
//     tx_start 在 busy 期间脉冲 → 被 uart_tx 丢弃；
//     P_WAIT_UP 却因 uart_busy=1 误判"已受理" → 进 P_WAIT_DN 等旧帧发完
//     → 本字节静默丢失（tb A/B 段切换时实测丢 0xAA，只收到 3/4 字节）。
//   修复后 P_IDLE 增加 !uart_busy 条件，从机制上保证脉冲必被受理。
// ============================================================================
module tx_packer (
    input  wire        clk,
    input  wire        rst_n,
    // 请求接口（来自 calib_lut，1 周期脉冲）
    input  wire        req_valid,
    input  wire [1:0]  req_tag,
    input  wire [15:0] req_val,
    // UART 状态
    input  wire        uart_busy,
    // UART 驱动接口
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    // 观测用：有数据待发（队列非空 或 正在发帧）
    output wire        pkt_busy
);

    localparam [1:0] P_IDLE    = 2'd0,
                     P_START   = 2'd1,
                     P_WAIT_UP = 2'd2,
                     P_WAIT_DN = 2'd3;

    localparam [2:0] FRAME_LEN = 3'd4;

    // ---- 环形队列 ----
    localparam integer QD  = 4;                 // 深度：3 通道突发 + 1 余量
    localparam integer QAW = 2;                 // 索引位宽
    localparam integer QPW = QAW + 1;           // 指针位宽（多 1 位区分空满）

    reg [15:0]    q_val [0:QD-1];
    reg [1:0]     q_tag [0:QD-1];
    reg [QPW-1:0] q_wr;                          // 写指针
    reg [QPW-1:0] q_rd;                          // 读指针

    wire             q_empty = (q_wr == q_rd);
    wire             q_full  = (q_wr[QPW-1] != q_rd[QPW-1]) &&
                               (q_wr[QAW-1:0] == q_rd[QAW-1:0]);
    wire [QAW-1:0]  q_idx   = q_rd[QAW-1:0];

    // ---- 发送状态机 ----
    reg [1:0] state;
    reg [2:0] idx;        // 当前字节下标 0..3

    // ---- 当前待发字节（读队首）----
    wire [7:0] frame_byte = (idx == 3'd0) ? 8'hAA              :
                            (idx == 3'd1) ? {6'b00, q_tag[q_idx]} :
                            (idx == 3'd2) ? q_val[q_idx][15:8]  :
                                           q_val[q_idx][7:0];

    // 整帧发完（用于推进队首指针）
    wire frame_done = (state == P_WAIT_DN) && !uart_busy &&
                      (idx == FRAME_LEN-1) && !q_empty;

    assign pkt_busy = ~q_empty | (state != P_IDLE);

    integer i;

    // ---- 队列读写 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wr <= {QPW{1'b0}};
            q_rd <= {QPW{1'b0}};
            for (i = 0; i < QD; i = i + 1) begin
                q_val[i] <= 16'd0;
                q_tag[i] <= 2'd0;
            end
        end else begin
            // 入队（队列深度按最坏突发核算，正常工况不会满；
            //       若满则丢弃并可通过 pkt_busy 观测到异常）
            if (req_valid && !q_full) begin
                q_val[q_wr[QAW-1:0]] <= req_val;
                q_tag[q_wr[QAW-1:0]] <= req_tag;
                q_wr <= q_wr + 1'b1;
            end
            // 出队（整帧发完）
            if (frame_done)
                q_rd <= q_rd + 1'b1;
        end
    end

    // ---- 发送状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= P_IDLE;
            idx      <= 3'd0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
        end else begin
            tx_start <= 1'b0;          // 默认拉低，仅 P_START 置 1 拍

            case (state)
                P_IDLE: begin
                    // 必须等 uart_tx 空闲才发启动脉冲：
                    // uart_tx 在 busy 期间会丢弃 tx_start（单帧发送器无缓冲），
                    // 若此时脉冲发出，P_WAIT_UP 仅凭 uart_busy=1 会误判"已受理"，
                    // 导致本字节被静默丢弃（联调实测：A 段余帧在飞时丢 0xAA）。
                    if (!q_empty && !uart_busy) begin
                        idx   <= 3'd0;
                        state <= P_START;
                    end
                end

                P_START: begin
                    tx_start <= 1'b1;             // 1 周期脉冲
                    tx_data  <= frame_byte;       // 与 start 同拍给出
                    state    <= P_WAIT_UP;
                end

                P_WAIT_UP: begin
                    // uart_tx 受理后 tx_busy 变高，确认不会丢
                    if (uart_busy)
                        state <= P_WAIT_DN;
                end

                P_WAIT_DN: begin
                    if (!uart_busy) begin          // 本帧发完
                        if (idx == FRAME_LEN-1)
                            state <= P_IDLE;       // 队首指针已在别处推进
                        else begin
                            idx   <= idx + 1'b1;
                            state <= P_START;
                        end
                    end
                end

                default: state <= P_IDLE;
            endcase
        end
    end

endmodule
