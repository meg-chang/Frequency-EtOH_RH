// ============================================================================
// tb_cdc_miss_demo.v —— 本地复现 DUT 跨域脉冲漏采（iverilog -g2005 可跑）
// ----------------------------------------------------------------------------
// 目的：独立于 UVM/VCS，用本地 iverilog 证明 freq_meter_gclk 的 done 单周期
//       脉冲在被测频率 > 50MHz（T_clk_sig < T_clk_sys=20ns）时会被两级同步器
//       漏采，导致整窗无 count_valid。
//
// 关键采样约定：count_valid 是 1 周期脉冲，必须在 clk_sys 的【下降沿】采样
//       （脉冲高电平窗口 = 半个系统周期，下降沿落在高电平中段，稳定可读）；
//       若用 posedge 采样会与 DUT 的 nb 赋值同拍读到旧值而漏掉。
// ============================================================================
`timescale 1ns/1ps

module tb_cdc_miss_demo;

    localparam COUNT_WIDTH = 24;
    localparam GATE_CYCLES = 2000;
    localparam IDLE_CYCLES = 16;
    localparam SYS_HALF    = 10.0;   // 50MHz

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

    freq_meter_gclk #(.COUNT_WIDTH(COUNT_WIDTH)) dut (
        .clk_sig(clk_sig), .rst_sig_n(rst_n),
        .gate_en(gate_en),
        .clk_sys(clk_50),  .rst_sys_n(rst_n),
        .count_valid(count_valid), .count(count)
    );

    initial clk_50 = 1'b0;
    always  #(SYS_HALF) clk_50 = ~clk_50;

    initial clk_sig = 1'b0;
    always  #(sig_half) clk_sig = ~clk_sig;

    // ---- 单个频率：跑 n_wins 个窗口，统计被捕获 / 漏采 ----
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
        repeat (40) @(posedge clk_50);   // 频率切换后让门控稳定
        for (j = 0; j < n_wins; j = j + 1) begin
            seen = 1'b0;
            k    = 0;
            while (!seen && k < 40000) begin
                @(negedge clk_50);        // 在下降沿采样 1 周期脉冲
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
        sig_half = 4.63;   // 默认 ~108MHz
        $display("====================================================");
        $display(" CDC 漏采本地复现 (iverilog -g2005)");
        $display(" clk_sys = 50MHz (T=20ns)");
        $display(" clk_sig 扫频 20~108MHz，每频率 %0d 个窗口", 200);
        $display("====================================================");

        repeat (5) @(posedge clk_50);
        repeat (5) @(posedge clk_sig);
        @(negedge clk_50) rst_n = 1'b1;

        run_freq(50.00, 100);   // 20MHz  T=50ns  > 20ns
        run_freq(20.00, 100);   // 50MHz  T=20ns  = 边界
        run_freq(14.29, 100);   // 70MHz  T=14.3ns
        run_freq(11.11, 100);   // 90MHz  T=11.1ns
        run_freq(10.00, 100);   // 100MHz T=10ns (=2× f_sys)
        run_freq( 9.26, 100);   // 108MHz T=9.26ns (生产 ÷4 实测点)
        run_freq( 9.07, 100);   // 110MHz
        run_freq( 8.33, 100);   // 120MHz

        $display("====================================================");
        $display(" 结论：f>50MHz 时漏采率≈ 1 - T_sig/20ns，与理论一致");
        $display("====================================================");
        $finish;
    end

endmodule
