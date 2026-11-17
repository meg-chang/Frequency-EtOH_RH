// ============================================================================
// tb_cdc_fix_demo.v —— 验证修复版 freq_meter_gclk_fixed 消除漏采
// ----------------------------------------------------------------------------
// 与 tb_cdc_miss_demo 同法、同一套逐窗对账度量，但例化 fixed DUT。
// 预期：所有频率丢失率 0%。
//
// 度量方式见 tb_cdc_miss_demo.v 头部说明：按窗口数 vs count_valid 数对账，
// 不"等到任意一个 count_valid 就算捕获"。
// ============================================================================
`timescale 1ns/1ps

module tb_cdc_fix_demo;

    localparam COUNT_WIDTH = 24;
    localparam GATE_CYCLES = 2000;
    localparam IDLE_CYCLES = 16;
    localparam SYS_HALF    = 10.0;
    localparam WIN_CLKS    = GATE_CYCLES + IDLE_CYCLES;

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

    // ---- 逐窗对账统计 ----
    reg     meas_en;
    reg     gate_d;
    integer win_cnt;
    integer cv_cnt;
    integer last_cnt;

    always @(negedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            gate_d <= 1'b0;
        end else begin
            gate_d <= gate_en;
            if (meas_en) begin
                if (gate_en && !gate_d)
                    win_cnt = win_cnt + 1;
                if (count_valid) begin
                    cv_cnt   = cv_cnt + 1;
                    last_cnt = count;
                end
            end
        end
    end

    task run_freq;
        input real    period_ns;
        input integer n_wins;
        integer i;
    begin
        sig_half = period_ns / 2.0;

        @(posedge clk_50);
        repeat (WIN_CLKS + 4) @(posedge clk_50);

        @(posedge gate_en);
        @(negedge clk_50);
        meas_en  = 1'b0;
        win_cnt  = 0;
        cv_cnt   = 0;
        last_cnt = 0;
        meas_en  = 1'b1;

        for (i = 0; i < n_wins * WIN_CLKS - 8; i = i + 1)
            @(posedge clk_50);

        @(negedge clk_50);
        meas_en = 1'b0;

        $display("  f=%7.2fMHz  T_sig=%6.3fns  应到=%3d  实收=%3d  丢失=%3d  丢失率=%5.1f%%  last_count=%0d",
                 1000.0/period_ns, period_ns, win_cnt, cv_cnt,
                 win_cnt - cv_cnt,
                 (win_cnt > 0) ? 100.0*(win_cnt-cv_cnt)/win_cnt : 0.0,
                 last_cnt);
    end
    endtask

    initial begin
        rst_n    = 1'b0;
        sig_half = 4.63;
        meas_en  = 1'b0;
        win_cnt  = 0;
        cv_cnt   = 0;
        last_cnt = 0;

        $display("================================================================");
        $display(" 修复版验证（freq_meter_gclk_fixed，toggle 握手）");
        $display(" 预期：所有频率丢失率 0%%");
        $display("================================================================");

        repeat (5) @(posedge clk_50);
        repeat (5) @(posedge clk_sig);
        @(negedge clk_50) rst_n = 1'b1;

        run_freq(50.00, 100);   // 20MHz
        run_freq(20.00, 100);   // 50MHz 边界
        run_freq(14.29, 100);   // 70MHz
        run_freq(11.11, 100);   // 90MHz
        run_freq(10.00, 100);   // 100MHz (=2×f_sys，原版 100% 丢失)
        run_freq( 9.26, 100);   // 108MHz 生产 ÷4 点
        run_freq( 9.07, 100);   // 110MHz
        run_freq( 8.33, 100);   // 120MHz

        $display("================================================================");
        $display(" 若全部 0%% 丢失，修复验证通过");
        $display("================================================================");
        $finish;
    end

endmodule
