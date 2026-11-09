// ============================================================================
// freq_meter_gclk_top.sv —— UVM 验证顶层
// ----------------------------------------------------------------------------
// 实例化真实 DUT（freq_meter_gclk，COUNT_WIDTH=24）+ 验证接口，启动 run_test。
// 50MHz 系统时钟、全局复位由顶层产生；被测信号 clk_sig 由接口按配置周期生成。
// ============================================================================
`timescale 1ns/1ps

module freq_meter_gclk_top;
    import uvm_pkg::*;
    import freq_meter_gclk_pkg::*;

    reg clk_sys;
    reg rst_n;
    freq_meter_gclk_if vif (clk_sys, rst_n);

    // 50MHz 系统时钟（周期 20ns）
    initial clk_sys = 1'b0;
    always #10.0 clk_sys = ~clk_sys;

    // 复位：开局拉低 100ns 后释放
    initial begin
        rst_n = 1'b0;
        #100 rst_n = 1'b1;
    end
    assign vif.rst_sig_n = rst_n;   // 被测域复位跟随全局复位

    // ---- DUT：默认例化原版 freq_meter_gclk（存在 CDC 漏采缺陷）----
    //   加 +define+FIXED_DUT 编译可切换为修复版 freq_meter_gclk_fixed
    //   （toggle 握手，消除单周期脉冲漏采）。用法：
    //     make sim FIXED=1            （仅编译开关，VCS 加 +define+FIXED_DUT）
    //     make sim FIXED=1 TEST=freq_random_test  → 应 EXPECTED=GOT，MISSING=0
`ifdef FIXED_DUT
    freq_meter_gclk_fixed #(.COUNT_WIDTH(24)) dut (
`else
    freq_meter_gclk #(.COUNT_WIDTH(24)) dut (
`endif
        .clk_sig     (vif.clk_sig),
        .rst_sig_n   (vif.rst_sig_n),
        .gate_en     (vif.gate_en),
        .clk_sys     (vif.clk_sys),
        .rst_sys_n   (vif.rst_sys_n),
        .count_valid (vif.count_valid),
        .count       (vif.count)
    );

    initial begin
        uvm_config_db #(virtual freq_meter_gclk_if)::set(null, "*", "vif", vif);
        // 加 +DUMP 仿真时导出 VPD 波形（需用 -debug_access+all 编译，见 Makefile）。
        // 0 表示从顶层开始 dump 全部信号；想只看 DUT 可改成 $vcdpluson(0, dut)。
        if ($test$plusargs("DUMP")) $vcdpluson(0, freq_meter_gclk_top);
`ifdef FSDB
        // Verdi 波形：make sim VERDI_HOME=<verdi安装路径> WAVE=+FSDB
        // 之后 verdi -ssf sim/simv_uvm.fsdb &
        if ($test$plusargs("FSDB")) begin
            $fsdbDumpfile("sim/simv_uvm.fsdb");
            $fsdbDumpvars(0, freq_meter_gclk_top);
        end
`endif
        run_test();
    end

endmodule
