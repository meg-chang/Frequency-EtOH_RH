// ============================================================================
// freq_monitor.sv —— 结果监测器
// ----------------------------------------------------------------------------
// 在 50MHz 域采样 count_valid 上升沿，捕获 count，打包成 freq_result 送出。
// ============================================================================
class freq_monitor extends uvm_monitor;
    `uvm_component_utils(freq_monitor)

    virtual freq_meter_gclk_if vif;
    uvm_analysis_port #(freq_result) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual freq_meter_gclk_if)::get(this, "", "vif", vif))
            `uvm_fatal("MON", "vif not found in config_db")
        ap = new("ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        freq_result r;
        forever begin
            // 走 clocking block 采样（mon_cb 默认 input #1ns），
            // 避免在 posedge 的 active 区读到 DUT 非阻塞赋值更新前的旧值
            @(vif.mon_cb);
            if (vif.mon_cb.count_valid) begin
                r = freq_result::type_id::create("r");
                r.count = vif.mon_cb.count;
                ap.write(r);
            end
        end
    endtask

endclass
