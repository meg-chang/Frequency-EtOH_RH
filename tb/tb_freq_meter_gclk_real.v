// ============================================================================
// tb_freq_meter_gclk_real.v
// ----------------------------------------------------------------------------
// 本地验证台（iverilog -g2005 可跑）：在真实 freq_meter_gclk + gate_timer 上，
// 扫描多个被测信号频率，独立统计「窗口内 clk_sig 上升沿数」作为参考，
// 比对 DUT 输出的 count / count_valid。
//
// 目的：在搭建 UVM 环境之前，先确认真实 DUT 行为正确、参考模型成立。
// 这里用解析式期望（窗口时长 / 被测周期，取整）±3 容差，与真实工程
// tb_freq_meter_gclk 的方法一致（其 37ns 用例期望 1072、容差 ±2）。
//
// 关键采样约定：count_valid 是 1 周期脉冲，必须在拉高当拍读 count。
// ============================================================================
`timescale 1ns/1ps

module tb_freq_meter_gclk_real;

    // ---- 参数（仿真加速：门控窗口远小于生产的 100ms）----
    localparam COUNT_WIDTH = 24;
    localparam GATE_CYCLES = 2000;        // 50MHz 下 2000 拍
    localparam IDLE_CYCLES = 16;
    localparam SYS_HALF_NS = 10.0;        // 50MHz
    // 实际门控窗口 = (GATE_CYCLES - IDLE_CYCLES) 个系统拍 = 1984 × 20ns = 39680ns
    localparam real WINDOW_NS = 39680.0;

    reg  clk_50;
    reg  rst_n;
    reg  clk_sig;
    real sig_half_ns;                     // 被测信号半周期，运行时可变

    wire gate_en, gate_tick, gate_start;
    wire                   count_valid;
    wire [COUNT_WIDTH-1:0] count;

    // 饱和度实例（6bit）：窗口内沿数 >> 63，应封顶不回绕
    wire        sat_valid;
    wire [5:0]  sat_count;

    integer err_cnt;
    integer i, k;
    integer edges_in_gate;                 // 参考：gate_en 高期间的 clk_sig 上升沿数

    // ---- 门控（真实模块，50MHz 域）----
    gate_timer #(.GATE_CYCLES(GATE_CYCLES), .IDLE_CYCLES(IDLE_CYCLES)) u_gate (
        .clk(clk_50), .rst_n(rst_n),
        .gate_en(gate_en), .gate_tick(gate_tick), .gate_start(gate_start)
    );

    // ---- 被测 DUT（真实模块）----
    freq_meter_gclk #(.COUNT_WIDTH(COUNT_WIDTH)) dut (
        .clk_sig(clk_sig), .rst_sig_n(rst_n),
        .gate_en(gate_en),
        .clk_sys(clk_50),  .rst_sys_n(rst_n),
        .count_valid(count_valid), .count(count)
    );

    freq_meter_gclk #(.COUNT_WIDTH(6)) dut_sat (
        .clk_sig(clk_sig), .rst_sig_n(rst_n),
        .gate_en(gate_en),
        .clk_sys(clk_50),  .rst_sys_n(rst_n),
        .count_valid(sat_valid), .count(sat_count)
    );

    initial clk_50 = 1'b0;
    always #(SYS_HALF_NS) clk_50 = ~clk_50;

    initial begin
        sig_half_ns = 18.5;                // 默认 37ns ≈ 27MHz
        clk_sig     = 1'b0;
    end
    always #(sig_half_ns) clk_sig = ~clk_sig;

    // ---- 参考模型：gate_en 高期间 clk_sig 上升沿计数 ----
    always @(posedge clk_sig) begin
        if (gate_en) edges_in_gate = edges_in_gate + 1;
    end

    // ---- 结果收集：count_valid 握手 ----
    reg        valid_seen;
    integer    valid_pulses;
    reg [COUNT_WIDTH-1:0] latched;

    initial begin
        valid_seen   = 1'b0;
        valid_pulses = 0;
    end

    always @(posedge clk_50) begin
        if (count_valid) begin
            latched      <= count;
            valid_seen   <= 1'b1;
            valid_pulses <= valid_pulses + 1;
        end
    end

    // ---- 等一个窗口结果 ----
    task get_result;
        output integer c;
        begin
            valid_seen = 1'b0;
            k = 0;
            while (!valid_seen && k < 400000) begin
                @(posedge clk_50); k = k + 1;
            end
            if (!valid_seen) begin
                $display("  [FAIL] 等待 count_valid 超时");
                err_cnt = err_cnt + 1; c = -1;
            end else
                c = latched;
        end
    endtask

    // ---- 检查一个窗口 ----
    task check_window;
        input integer expect;
        input integer tol;
        integer c, d;
        begin
            edges_in_gate = 0;
            get_result(c);
            if (c >= 0) begin
                d = c - expect; if (d < 0) d = -d;
                if (d > tol) begin
                    $display("  [FAIL] count=%0d 期望 %0d±%0d (gate内沿数=%0d)",
                             c, expect, tol, edges_in_gate);
                    err_cnt = err_cnt + 1;
                end else
                    $display("  [ OK ] count=%0d 期望 %0d±%0d (gate内沿数=%0d)",
                             c, expect, tol, edges_in_gate);
            end
        end
    endtask

    // ---- 跑 N 个窗口（频率已通过 sig_half_ns 设定）----
    task run_windows;
        input integer n;
        input integer expect;
        input integer tol;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1)
                check_window(expect, tol);
        end
    endtask

    // ---- 计算期望（窗口时长 / 被测周期，向下取整）----
    function integer expect_of;
        input real period_ns;
        expect_of = $rtoi(WINDOW_NS / period_ns);
    endfunction

    initial begin
        err_cnt = 0;
        rst_n   = 1'b0;
        $display("====================================================");
        $display(" tb_freq_meter_gclk_real : 验证真实 DUT");
        $display(" 窗口时长 = %0.1f ns (GATE=%0d, IDLE=%0d, SYS=%0.1fns)",
                 WINDOW_NS, GATE_CYCLES, IDLE_CYCLES, SYS_HALF_NS);
        $display("====================================================");

        repeat (5) @(posedge clk_50);
        repeat (5) @(posedge clk_sig);
        @(negedge clk_50) rst_n = 1'b1;

        // ---- 用例 1：基准频率 37ns (≈27MHz) ----
        sig_half_ns = 18.5;
        $display("-- 用例1: 被测周期 37ns, 期望 %0d", expect_of(37.0));
        run_windows(5, expect_of(37.0), 3);

        // ---- 用例 2：50ns (20MHz) ----
        sig_half_ns = 25.0;
        $display("-- 用例2: 被测周期 50ns, 期望 %0d", expect_of(50.0));
        run_windows(4, expect_of(50.0), 3);

        // ---- 用例 3：101ns (≈9.9MHz)，慢信号 ----
        sig_half_ns = 50.5;
        $display("-- 用例3: 被测周期 101ns, 期望 %0d", expect_of(101.0));
        run_windows(4, expect_of(101.0), 3);

        // ---- 用例 4：18.5ns (≈54MHz)，快信号（异步非整数倍）----
        sig_half_ns = 9.25;
        $display("-- 用例4: 被测周期 18.5ns, 期望 %0d", expect_of(18.5));
        run_windows(4, expect_of(18.5), 3);

        // ---- 用例 5：count_valid 每窗口恰好 1 拍 ----
        if (valid_pulses !== (5+4+4+4)) begin
            $display("  [FAIL] count_valid 累计 %0d，期望 %0d", valid_pulses, 5+4+4+4);
            err_cnt = err_cnt + 1;
        end else
            $display("  [ OK ] count_valid 每窗口 1 拍 (共 %0d)", valid_pulses);

        // ---- 用例 6：复位期间无输出 ----
        @(negedge clk_50) rst_n = 1'b0;
        valid_pulses = 0;
        repeat (600) @(posedge clk_50);
        if (valid_pulses !== 0) begin
            $display("  [FAIL] 复位期间仍出 %0d 个结果", valid_pulses);
            err_cnt = err_cnt + 1;
        end else
            $display("  [ OK ] 复位期间输出清零、无 valid");
        @(negedge clk_50) rst_n = 1'b1;

        // ---- 用例 7：饱和度实例封顶 63 不回绕 ----
        sig_half_ns = 18.5;
        begin : sat_blk
            reg sat_seen; integer sk; reg [5:0] sat_lat;
            sat_seen = 0;
            sk = 0;
            while (!sat_seen && sk < 400000) begin
                @(posedge clk_50);
                if (sat_valid) begin sat_lat = sat_count; sat_seen = 1; end
                sk = sk + 1;
            end
            if (!sat_seen) begin
                $display("  [FAIL] 饱和度实例未出结果");
                err_cnt = err_cnt + 1;
            end else if (sat_lat !== 6'd63) begin
                $display("  [FAIL] 6bit 实例计数 %0d，期望封顶 63", sat_lat);
                err_cnt = err_cnt + 1;
            end else
                $display("  [ OK ] 6bit 实例封顶 63 不回绕");
        end

        $display("----------------------------------------------------");
        if (err_cnt == 0)
            $display(" tb_freq_meter_gclk_real : PASS (0 errors)");
        else
            $display(" tb_freq_meter_gclk_real : FAIL (%0d errors)", err_cnt);
        $display("====================================================");
        $finish;
    end

endmodule
