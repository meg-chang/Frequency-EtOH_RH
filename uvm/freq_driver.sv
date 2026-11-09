// ============================================================================
// freq_driver.sv —— 激励驱动器
// ----------------------------------------------------------------------------
// 收到 freq_item 后：设置被测信号周期 → 在 50MHz 域驱动一个 gate_en 高电平
// 窗口（gate_ticks 拍）→ 广播激励给 coverage。
// 不依赖真实 gate_timer，从而可随机化门控宽度做覆盖率收集。
// ============================================================================
class freq_driver extends uvm_driver #(freq_item);
    `uvm_component_utils(freq_driver)

    virtual freq_meter_gclk_if vif;
    uvm_analysis_port #(freq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual freq_meter_gclk_if)::get(this, "", "vif", vif))
            `uvm_fatal("DRV", "vif not found in config_db")
        ap = new("ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        freq_item req;
        int unsigned idle_cyc;
        vif.drv_cb.gate_en <= 1'b0;
        forever begin
            seq_item_port.get_next_item(req);
            vif.set_sig_period(req.sig_period_ps);

            // ★ DUT 硬约束：门控低电平必须 > 2 个被测周期
            //   （IDLE_CYCLES × T_sys > 2 × T_sig_max），否则被测域两级同步器
            //   可能采不到"门已关"，计数跨窗口累加 → 直接误判 FAIL。
            //   低频 10MHz 时被测周期 100ns = 5 个 clk_sys 拍，固定 5 拍刚好
            //   踩线，故按 sig_period_ps 动态计算并留 4 倍余量。
            idle_cyc = int'((4.0 * req.sig_period_ps) / 20000.0) + 4;
            repeat (idle_cyc) @(vif.drv_cb);      // 等频率稳定 + 满足低电平时长

            // ---- 调试辅助：把高频率窗口起始时刻打到日志 ----
            // f>50MHz 时 T_sig<20ns，done 单周期脉冲可能被两级同步器漏采。
            // 这里记下每个高频率窗口的起始时间（ps），方便在 Verdi 里用
            // "Goto time" 直接跳到 9~10ns 周期（f≈100~110MHz）那段看漏采实证。
            if (req.sig_freq_mhz > 50) begin
                real t_ns  = real'($time) / 1000.0;
                real t_per = real'(req.sig_period_ps) / 1000.0;
                `uvm_info("DRV_HF", $sformatf("[%0.1f ns] f=%0dMHz T=%.2fns idle_cyc=%0d gate=%0d%s",
                    t_ns, req.sig_freq_mhz, t_per, idle_cyc, req.gate_ticks,
                    (req.sig_freq_mhz >= 90) ? "  <<< 9-10ns band" : ""), UVM_NONE)
            end

            vif.drv_cb.gate_en <= 1'b1;
            repeat (req.gate_ticks) @(vif.drv_cb);
            vif.drv_cb.gate_en <= 1'b0;
            ap.write(req);                        // 广播激励 → coverage
            seq_item_port.item_done();
        end
    endtask

endclass
