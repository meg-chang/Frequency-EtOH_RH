// ============================================================================
// freq_env.sv —— 验证环境
// ============================================================================
class freq_env extends uvm_env;
    `uvm_component_utils(freq_env)

    freq_agent      agt;
    freq_scoreboard scb;
    freq_coverage   cov;
    virtual freq_meter_gclk_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = freq_agent::type_id::create("agt", this);
        scb = freq_scoreboard::type_id::create("scb", this);
        cov = freq_coverage::type_id::create("cov", this);
        if (!uvm_config_db #(virtual freq_meter_gclk_if)::get(this, "", "vif", vif))
            `uvm_fatal("ENV", "vif not found in config_db")
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agt.mon.ap.connect(scb.result_imp);   // DUT 结果 → 记分板比对
        agt.drv.ap.connect(scb.item_imp);     // 激励笔数 → 记分板对账（查漏检）
        agt.drv.ap.connect(cov.analysis_export);
    endfunction

endclass
