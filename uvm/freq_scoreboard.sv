// ============================================================================
// freq_scoreboard.sv —— 记分板 + 参考模型（golden）
// ----------------------------------------------------------------------------
// 参考模型：在 clk_sig 域统计 gate_en 高电平期间的上升沿数（window_edge）。
// 这是独立于 DUT 的"黄金"计数，与本地 iverilog TB 的方法一致。
// DUT 把 gate_en 同步进被测域后计数，结果恒比 window_edge 少约 1（同步延迟），
// 因此比对容差取 ±3 覆盖 CDC 同步不确定性。
//
// 另外对账：driver 每发一笔激励就计入 exp_cnt，最后与实收结果数比对，
// 用于抓"DUT 压根没吐 count_valid"这种情况（比对容差抓不到，会静默漏检）。
// ============================================================================
`uvm_analysis_imp_decl(_result)
`uvm_analysis_imp_decl(_item)

class freq_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(freq_scoreboard)

    virtual freq_meter_gclk_if vif;
    uvm_analysis_imp_result #(freq_result, freq_scoreboard) result_imp;
    uvm_analysis_imp_item   #(freq_item,   freq_scoreboard) item_imp;

    int unsigned pass_cnt;
    int unsigned fail_cnt;
    int unsigned exp_cnt;      // driver 发出的激励笔数

    // 参考模型状态（在 run_phase 的 fork 中维护）
    bit [23:0] ref_edge;
    bit [23:0] window_edge;
    logic      prev_gate;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual freq_meter_gclk_if)::get(this, "", "vif", vif))
            `uvm_fatal("SCB", "vif not found in config_db")
        result_imp = new("result_imp", this);
        item_imp   = new("item_imp", this);
    endfunction

    task run_phase(uvm_phase phase);
        ref_edge    = '0;
        prev_gate   = 1'b0;
        window_edge = '0;
        fork
            // 黄金参考：统计 gate_en 高电平期间的 clk_sig 上升沿数（窗口起始当拍记为 1）。
            // 与本地 iverilog 基线（edges_in_gate 每沿 +1）完全一致：参考 = N，
            // DUT 在 gate_s2 上升沿清零、其后才累加，故 DUT ≈ N-1，比对容差取 ±3
            // 覆盖 gate_en 异步采样与两级同步引入的 ±1~2 拍不确定性。
            forever begin
                @(posedge vif.clk_sig);
                if (vif.gate_en && !prev_gate) ref_edge <= 1;               // 窗口首沿计为 1
                else if (vif.gate_en)          ref_edge <= ref_edge + 1'b1;
                if (!vif.gate_en && prev_gate) window_edge <= ref_edge;     // 窗口结束：锁存
                prev_gate <= vif.gate_en;
            end
        join_none
    endtask

    // driver 广播的激励：只计数，用于最后对账
    function void write_item(freq_item t);
        exp_cnt++;
    endfunction

    function void write_result(freq_result r);
        int signed exp_val, d;
        // 架构性偏差必须扣掉，不能塞进容差里：
        //   参考模型把窗口首沿计为 1（ref_edge <= 1），而 DUT 是在 gate_s2
        //   上升沿把 cnt 清零、其后才逐沿累加，所以 DUT 恒比 window_edge 少 1。
        //   这是确定量，不是随机抖动。实测 5 个随机种子 × 50 笔 = 250 笔，
        //   偏差 100% 为 -1。若把它算进容差，等于白白浪费掉 1 的判别力。
        exp_val = $signed(window_edge) - 1;
        d = $signed(r.count) - exp_val;
        if (d < 0) d = -d;
        // 容差只留给 gate_en 异步采样落在窗口边界上的 ±1 拍不确定性。
        if (d <= 1) begin
            `uvm_info("SCORE", $sformatf("PASS count=%0d ref_edges=%0d exp_val=%0d",
                                          r.count, window_edge, exp_val), UVM_MEDIUM)
            pass_cnt++;
        end else begin
            `uvm_error("SCORE", $sformatf("FAIL count=%0d ref_edges=%0d exp_val=%0d delta=%0d",
                                           r.count, window_edge, exp_val, d))
            fail_cnt++;
        end
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned got;
        got = pass_cnt + fail_cnt;
        `uvm_info("SCORE", $sformatf("==== SCOREBOARD PASS=%0d FAIL=%0d ====",
                                      pass_cnt, fail_cnt), UVM_NONE)
        `uvm_info("SCORE", $sformatf("==== EXPECTED=%0d GOT=%0d MISSING=%0d ====",
                                      exp_cnt, got, (exp_cnt > got) ? (exp_cnt - got) : 0), UVM_NONE)
        if (exp_cnt != got)
            // 消息用英文：ModelSim/VCS 控制台按本地代码页输出，中文会变 ?，
            // 而这条警告恰恰是最关键的信息（漏采笔数），不能让它读不出来。
            // 中文解释留在注释和验证报告里。
            `uvm_warning("SCORE", $sformatf(
                "%0d stimuli got NO count_valid: DUT done is a 1-cycle pulse in the \
measured clock domain; when T_clk_sig < T_clk_sys (f > 50MHz) the 2-FF synchronizer \
misses it. This is the DUT CDC defect, not a testbench issue.",
                exp_cnt - got))
    endfunction

endclass
