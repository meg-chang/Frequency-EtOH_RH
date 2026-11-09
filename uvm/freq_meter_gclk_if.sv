// ============================================================================
// freq_meter_gclk_if.sv —— 验证接口
// ----------------------------------------------------------------------------
// 对齐真实 freq_meter_gclk 端口：
//   clk_sig   : 被测信号（DUT 计数时钟，由本接口按 sig_period_ps 生成）
//   gate_en   : 门控窗口（50MHz 域产生，driver 驱动；DUT 内部两级同步进被测域）
//   count_valid / count : 结果（DUT 输出，monitor 采样）
// rst_sig_n / rst_sys_n / clk_sys 由顶层直接驱动。
// ============================================================================
`timescale 1ns/1ps

interface freq_meter_gclk_if (input wire clk_sys, input wire rst_sys_n);
    logic        clk_sig;
    logic        rst_sig_n;
    logic        gate_en;
    logic        count_valid;
    logic [23:0] count;

    // ---- 被测信号 clk_sig：可配置周期（ps），默认 50MHz ----
    real sig_period_ps = 20000.0;
    initial clk_sig = 1'b0;
    always #(sig_period_ps / 2000.0) clk_sig = ~clk_sig;

    // driver 调用：设置被测信号周期
    task set_sig_period(input real ps);
        sig_period_ps = ps;
    endtask

    // ---- 驱动时钟域（50MHz）：driver 通过它驱动 gate_en ----
    clocking drv_cb @(posedge clk_sys);
        default input #1ns output #1ns;
        output gate_en;
    endclocking

    // ---- 监测时钟域：monitor 采样 count_valid / count ----
    clocking mon_cb @(posedge clk_sys);
        default input #1ns;
        input count_valid;
        input count;
        input gate_en;
    endclocking

endinterface
