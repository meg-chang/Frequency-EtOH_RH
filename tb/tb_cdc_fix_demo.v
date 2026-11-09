// ============================================================================
// tb_cdc_fix_demo.v —— 验证修复版 freq_meter_gclk_fixed 消除漏采
// ----------------------------------------------------------------------------
// 与 tb_cdc_miss_demo 同法，但例化 fixed DUT。预期：所有频率 0% 漏采。
// ============================================================================
`timescale 1ns/1ps

module tb_cdc_fix_demo;

    localparam COUNT_WIDTH = 24;
    localparam GATE_CYCLES = 2000;
    localparam IDLE_CYCLES = 16;
    localparam SYS_HALF    = 10.0;

    reg  clk_50;
    reg  rst_n;
    reg  clk_sig;
    real sig_half;

    wire gate_en;
    wire                   count_valid;
    wire [COUNT_WIDTH-1:0] count;

    gate_timer #(.GATE_CYCLES(GATE_CYCLES), .IDLE_CYCLES(IDLE_CYCLES)) u_gate (
        .clk(clk_50), .rst_n(rst_n),
        .gate_en(gate_en), .gate_tick(), .gate_start()
    );

    freq_meter_gclk_fixed #(.COUNT_WIDTH(COUNT_WIDTH)) dut (
        .clk_sig(clk_sig), .rst_sig_n(rst_n),
        .gate_en(gate_en),
        .clk_sys(clk_50),  .rst_sys_n(rst_n),
        .count_valid(count_valid), .count(count)
    );

    initial clk_50 = 1'b0;
    always  #(SYS_HALF) clk_50 = ~clk_50;
    initial clk_sig = 1'b0;
    always  #(sig_half) clk_sig = ~clk_sig;

    task run_freq;
        input real period_ns;
        input integer n_wins;
        integer j, k;
        reg     seen;
        integer caught, missed;
    begin
        sig_half = period_ns / 2.0;
        caught   = 0;
        missed   = 0;
        repeat (40) @(posedge clk_50);
        for (j = 0; j < n_wins; j = j + 1) begin
            seen = 1'b0;
            k    = 0;
            while (!seen && k < 40000) begin
                @(negedge clk_50);
                if (count_valid) seen = 1'b1;
                k = k + 1;
            end
            if (seen) caught = caught + 1;
            else      missed = missed + 1;
        end
        $display("  f=%6.2fMHz  T_sig=%6.3fns  窗口=%0d  捕获=%0d  漏采=%0d  漏采率=%5.1f%%",
                 1000.0/period_ns, period_ns, n_wins, caught, missed,
                 100.0 * missed / n_wins);
    end
    endtask

    initial begin
        rst_n   = 1'b0;
        sig_half = 4.63;
        $display("====================================================");
        $display(" 修复版验证 (freq_meter_gclk_fixed)");
        $display(" 预期：所有频率 0%% 漏采");
        $display("====================================================");
        repeat (5) @(posedge clk_50);
        repeat (5) @(posedge clk_sig);
        @(negedge clk_50) rst_n = 1'b1;

        run_freq(50.00, 100);   // 20MHz
        run_freq(20.00, 100);   // 50MHz 边界
        run_freq(10.00, 100);   // 100MHz (=2× f_sys, 原版 100% 丢失)
        run_freq( 9.26, 100);   // 108MHz 生产点
        run_freq( 8.33, 100);   // 120MHz

        $display("====================================================");
        $display(" 若全部 0%% 漏采，修复验证通过");
        $display("====================================================");
        $finish;
    end

endmodule
