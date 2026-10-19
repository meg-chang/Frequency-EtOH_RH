// ============================================================================
//  门控定时器（三通道共用）
//  测频原理：在固定宽度的时间窗口（门控）内对输入信号上升沿计数，
//           频率 = 计数值 / 门控宽度。
//
// 本设计：50MHz 时钟，更新率 10Hz → 每 100ms 输出一笔数据
//   总周期    GATE_CYCLES = 50_000_000 × 0.1s = 5_000_000 个时钟
//   门控窗口  cnt ∈ [0, GATE_CYCLES-IDLE_CYCLES)，共 GATE_CYCLES-IDLE_CYCLES 拍
//   IDLE 窗口 末尾 IDLE_CYCLES 拍留给 freq_meter 锁存结果
//
// 输出：
//   gate_en   —— 门控窗口，高电平期间 freq_meter 计数
//   gate_tick —— 窗口结束脉冲（1 周期），freq_meter 锁存计数值
//   gate_start—— 新窗口起始脉冲（1 周期），调试/对齐用
//
// 仿真加速：tb 例化时覆盖 GATE_CYCLES 为小值（如 5000），逻辑完全一致。
// ============================================================================

module gate_timer #(
    parameter GATE_CYCLES = 5000000, //总周期：50MHz × 100ms
    parameter IDLE_CYCLES = 16       //末尾锁存窗口
) (
    input  wire clk,
    input  wire rst_n,
    output reg  gate_en,
    output reg  gate_tick,
    output reg  gate_start
);

localparam CNT_W = 32;  // 足以表示 GATE_CYCLES-1（5_000_000 < 2^23）

reg [CNT_W-1:0] cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt         <= 0;
        gate_en     <= 1'b0;
        gate_tick   <= 1'b0;
        gate_start  <= 1'b0; 
    end else begin
        gate_tick  <= 1'b0;
        gate_start <= 1'b0;

        if (cnt >= GATE_CYCLES -1) begin
            //周期结束：回零。开新窗口
            cnt         <= 0;
            gate_en     <= 1'b1;
            gate_start  <= 1'b1;
        end else begin
            cnt <= cnt + 1;
            if (cnt == GATE_CYCLES - IDLE_CYCLES - 1) begin
                //计数窗口结束，关门锁存通知
                gate_en   <= 1'b0;
                gate_tick <= 1'b1;
            end
        end
    end
end
endmodule