// ============================================================================
// freq_meter_gclk.v —— 门控计数测频（被测信号直驱 GCLK，高性能架构）
// ----------------------------------------------------------------------------
// 与旧版 freq_meter.v 的根本区别：
//
//   旧版（采样法）：系统时钟 50MHz 去采样被测信号 → 边沿检测 → 计数
//       要求 系统时钟 ≥ 2.5 × 被测频率，因此被测频率必须被压得很低
//       （旧方案片外 ÷256 → 1.691MHz），分辨率 = 10Hz × 256 = 2560Hz
//
//   新版（GCLK 直驱法）：被测信号本身接专用时钟引脚 → 全局时钟网络
//       → 直接作为计数器的时钟，门控窗口跨域送进来
//       被测频率只受 GCLK 上限约束（EP4CE10-C8：402MHz），不再受
//       "系统时钟 ≥ 2.5×被测" 的约束，因此分频比可以大幅降低：
//       ÷4 → 108.48MHz，分辨率 = 10Hz × 4 = 40Hz（提升 64 倍）
//
// 为什么 ÷4 而不是 ÷2：
//   ÷2 = 216.96MHz 虽仍在 GCLK 402MHz 上限内，但 24bit 进位链在
//   C8（最慢）等级上 Fmax 只剩很小余量，温度/电压漂移下有失败风险；
//   ÷4 = 108.48MHz 对 24bit 计数器有 >2× 余量，是性能与可靠性的最优点。
//
// 跨域信号（本模块的全部跨域点，面试要能画出来）：
//   1. gate_en：系统域(50MHz) → 被测域。电平信号，两级同步即可安全
//   2. done   ：被测域 → 系统域。脉冲，两级同步 + 边沿检测
//   3. cnt_out：被测域 → 系统域。多 bit 数据，用"准静态"论证见下
//
// 为什么 cnt_out 不用格雷码（重要，面试可讲）：
//   格雷码是为"连续变化的指针"准备的。cnt_out 是窗口结束时的锁存值，
//   更新周期 = 100ms（10Hz），在 50MHz 系统域看它几乎是静态的：
//   两次更新之间隔 5,000,000 个系统时钟周期，远大于同步器建立所需的
//   几拍。因此两级寄存器同步即可，不存在"采样到跳变中间态"的传播风险。
//   判断依据：数据更新率 << 采样时钟频率，且数据在读取期间不变化。
//   若后续把更新率提到 MHz 级，必须换成格雷码或握手。
//
// 门控误差：gate_en 同步到被测域引入 ±1 个被测周期的不确定性，
//   100ms 窗口下 = ±9.2ns / 100ms = ±0.09ppm，远小于 ±1 count 的
//   量化误差（±1/10,848,000 = ±0.09ppm 同量级），无需补偿。
//
// ★ 硬约束（联调整测实测踩坑，必须写进设计文档）：
//   门控【低电平】持续时间必须 > 2 个被测时钟周期，否则被测域的同步器
//   可能永远采不到"门已关"，窗口边界丢失 → 计数跨多个窗口累加。
//   即：IDLE_CYCLES × T_sys > 2 × T_sig_max
//   生产配置：IDLE=16 × 20ns = 320ns，被测 108.48MHz（T=9.22ns）
//             → 320 / 9.22 = 34.7 倍，安全
//   踩坑现场：端到端 tb 把被测信号放慢到 407/533/811ns 以加速仿真，
//             IDLE 仍是 16（320ns）→ 320 < 533/811，CH1/CH2 采不到关门，
//             计数值翻倍（实测 DUT=7503 vs 影子 3752）。
//             修复：tb 把 IDLE_CYCLES 提到 128（2.56µs = 3.2× 最慢周期）。
//   教训：跨域控制信号的"脉宽"必须按【接收方时钟】核算，不能只看发送方。
//
// 参数：
//   COUNT_WIDTH —— 100ms 窗口、108.48MHz → 10,848,000 counts
//                  2^23 = 8.39M 不够，2^24 = 16.78M 足够 → 取 24
// ============================================================================
module freq_meter_gclk #(
    parameter COUNT_WIDTH = 24
) (
    // ---- 被测时钟域（信号经专用时钟引脚 + GCLK 进来）----
    input  wire                   clk_sig,      // 被测信号（÷4 后 108.48MHz）
    input  wire                   rst_sig_n,
    input  wire                   gate_en,      // 门控窗口（来自系统域，异步）
    // ---- 系统时钟域（50MHz）----
    input  wire                   clk_sys,
    input  wire                   rst_sys_n,
    output reg                    count_valid,  // 1 周期脉冲（系统域）
    output wire [COUNT_WIDTH-1:0] count
);

// ============================================================================
// 被测时钟域
// ============================================================================
localparam [COUNT_WIDTH-1:0] CNT_MAX = {COUNT_WIDTH{1'b1}};

reg gate_s1, gate_s2;          // gate_en 两级同步（系统域 → 被测域）
reg gate_d;                    // gate_s2 延迟一拍，用于边沿检测
reg [COUNT_WIDTH-1:0] cnt;     // 工作计数器
reg [COUNT_WIDTH-1:0] cnt_out; // 锁存输出（窗口级静态）
reg done;                      // 被测域窗口结束脉冲（1 拍）

always @(posedge clk_sig or negedge rst_sig_n) begin
    if (!rst_sig_n) begin
        gate_s1  <= 1'b0;
        gate_s2  <= 1'b0;
        gate_d   <= 1'b0;
        cnt      <= {COUNT_WIDTH{1'b0}};
        cnt_out  <= {COUNT_WIDTH{1'b0}};
        done     <= 1'b0;
    end else begin
        // ---- 门控同步（电平信号，两级同步足够）----
        gate_s1 <= gate_en;
        gate_s2 <= gate_s1;
        gate_d  <= gate_s2;

        done <= 1'b0;   // 默认拉低，仅窗口结束当拍置 1

        if (gate_s2 && !gate_d) begin
            // 窗口刚开始：清零，准备本窗口计数
            cnt <= {COUNT_WIDTH{1'b0}};
        end else if (gate_s2) begin
            // 窗口期间：每个被测周期 +1；饱和即停（防回绕出鬼值）
            if (cnt != CNT_MAX)
                cnt <= cnt + 1'b1;
        end

        if (!gate_s2 && gate_d) begin
            // 窗口刚结束：锁存 + 发脉冲 + 清零待下一窗口
            cnt_out <= cnt;
            done    <= 1'b1;
            cnt     <= {COUNT_WIDTH{1'b0}};
        end
    end
end

// ============================================================================
// 系统时钟域
// ============================================================================
// ---- done 脉冲回传：两级同步 + 上升沿检测 ----
reg done_s1, done_s2, done_d;

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
        done_s1 <= 1'b0;
        done_s2 <= 1'b0;
        done_d  <= 1'b0;
    end else begin
        done_s1 <= done;
        done_s2 <= done_s1;
        done_d  <= done_s2;
    end
end

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n)
        count_valid <= 1'b0;
    else
        count_valid <= done_s2 & ~done_d;   // 1 周期脉冲
end

// ---- cnt_out 准静态跨域：两级寄存器 ----
// 更新周期 100ms >> 同步所需 2 拍（40ns），见文件头论证
reg [COUNT_WIDTH-1:0] cnt_h1, cnt_h2;

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
        cnt_h1 <= {COUNT_WIDTH{1'b0}};
        cnt_h2 <= {COUNT_WIDTH{1'b0}};
    end else begin
        cnt_h1 <= cnt_out;
        cnt_h2 <= cnt_h1;
    end
end

assign count = cnt_h2;

endmodule
