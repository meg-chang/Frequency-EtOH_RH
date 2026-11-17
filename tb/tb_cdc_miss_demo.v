// ============================================================================
// tb_cdc_miss_demo.v —— 本地复现 DUT 跨域脉冲漏采（iverilog -g2005 可跑）
// ----------------------------------------------------------------------------
// 目的：独立于 UVM/VCS，用本地 iverilog 证明 freq_meter_gclk 的 done 单周期
//       脉冲在被测频率 > 50MHz（T_clk_sig < T_clk_sys=20ns）时会被两级同步器
//       漏采，导致整窗无 count_valid。
//
// 【度量方法 · 重要】漏采率必须按「窗口」逐笔对账，不能「等到任意一个
//   count_valid 就算这一窗捕获」。后者会让本窗丢失被下一窗的脉冲顶替，
//   除 100% 全丢外一律误报 0%（本文件旧版本即踩此坑）。
//
//   正确做法：
//     1. 在 gate_en 上升沿（窗口起点）对齐，开启统计窗口；
//     2. 统计窗口内 gate_en 上升沿个数 = 应到笔数；
//     3. 同窗口内 count_valid 个数 = 实收笔数；
//     4. 丢失率 = (应到 − 实收) / 应到。
//   统计块挂在 clk_sys 下降沿：count_valid 是寄存器输出，上升沿采样会读到旧值。
// ============================================================================
`timescale 1ns/1ps

module tb_cdc_miss_demo;

    localparam COUNT_WIDTH = 24;
    localparam GATE_CYCLES = 2000;
    localparam IDLE_CYCLES = 16;
    localparam SYS_HALF    = 10.0;   // 50MHz
    localparam WIN_CLKS    = GATE_CYCLES + IDLE_CYCLES;  // 一个完整门控周期

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

    // ------------------------------------------------------------------
    // 逐窗对账统计（下降沿采样，避开寄存器更新同拍）
    // ------------------------------------------------------------------
    reg     meas_en;
    reg     gate_d;
    integer win_cnt;    // 应到笔数（统计窗口内 gate_en 上升沿数）
    integer cv_cnt;     // 实收笔数（统计窗口内 count_valid 数）
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

    // ---- 单个频率：跑 n_wins 个窗口，逐窗对账 ----
    task run_freq;
        input real    period_ns;
        input integer n_wins;
        integer i;
        real    expect_rate;
    begin
        sig_half = period_ns / 2.0;

        // 切频后先等一个完整门控周期，避免半路换频污染统计
        @(posedge clk_50);
        repeat (WIN_CLKS + 4) @(posedge clk_50);

        // 对齐到窗口起点再开表。win_cnt 从 0 起：开表后第一个下降沿就会把
        // 当前这个窗口的起点算进来，不能预设成 1（否则末尾会多算一窗）。
        @(posedge gate_en);
        @(negedge clk_50);
        meas_en  = 1'b0;
        win_cnt  = 0;
        cv_cnt   = 0;
        last_cnt = 0;
        meas_en  = 1'b1;

        // 跑 n_wins 个完整门控周期，末尾留 8 拍让最后一窗的 count_valid 落地。
        // 少跑这 8 拍会让最后一窗被判成"丢失"（本文件旧版本的另一处假象）。
        for (i = 0; i < n_wins * WIN_CLKS - 8; i = i + 1)
            @(posedge clk_50);

        @(negedge clk_50);
        meas_en = 1'b0;

        // 相位均匀随机假设下的期望值（实际仿真相位确定，会有偏离）
        expect_rate = (period_ns < 2.0*SYS_HALF)
                    ? 100.0 * (1.0 - period_ns/(2.0*SYS_HALF)) : 0.0;

        $display("  f=%7.2fMHz  T_sig=%6.3fns  应到=%3d  实收=%3d  丢失=%3d  丢失率=%5.1f%%  (随机相位期望 %5.1f%%)  last_count=%0d",
                 1000.0/period_ns, period_ns, win_cnt, cv_cnt,
                 win_cnt - cv_cnt,
                 (win_cnt > 0) ? 100.0*(win_cnt-cv_cnt)/win_cnt : 0.0,
                 expect_rate, last_cnt);
    end
    endtask

    initial begin
        rst_n    = 1'b0;
        sig_half = 4.63;   // 默认 ~108MHz
        meas_en  = 1'b0;
        win_cnt  = 0;
        cv_cnt   = 0;
        last_cnt = 0;

        $display("================================================================");
        $display(" CDC 漏采本地复现（iverilog -g2005）");
        $display(" clk_sys = 50MHz (T_sys=20ns)，门控 %0d 拍 = %0.2f us",
                 GATE_CYCLES, GATE_CYCLES*20.0/1000.0);
        $display(" 每频率 100 个窗口，逐窗对账（应到 vs 实收）");
        $display("================================================================");

        repeat (5) @(posedge clk_50);
        repeat (5) @(posedge clk_sig);
        @(negedge clk_50) rst_n = 1'b1;

        run_freq(50.00, 100);   // 20MHz  T=50ns  >  T_sys，脉宽够宽
        run_freq(20.00, 100);   // 50MHz  T=20ns  =  T_sys，边界
        run_freq(14.29, 100);   // 70MHz  T=14.3ns
        run_freq(11.11, 100);   // 90MHz  T=11.1ns
        run_freq(10.00, 100);   // 100MHz T=10ns  = 2×f_sys，确定性雷区
        run_freq( 9.26, 100);   // 108MHz T=9.26ns（生产 ÷4 点）
        run_freq( 9.07, 100);   // 110MHz
        run_freq( 8.33, 100);   // 120MHz

        $display("================================================================");
        $display(" 判读：T_sig >= T_sys 应 0%%；T_sig < T_sys 丢失率随频率上升，");
        $display("       f = 2×f_sys(100MHz) 处最坏（脉宽恰半个系统周期，可整段漏）");
        $display("================================================================");
        $finish;
    end

endmodule
