// ============================================================================
// freq_coverage.sv —— 覆盖率收集
// ----------------------------------------------------------------------------
// 订阅 driver 广播的 freq_item，对（被测频率 × 门控宽度）做交叉覆盖，
// 保证验证空间被充分遍历。频率与门控用整型便于 coverpoint 分箱。
// ============================================================================
class freq_coverage extends uvm_subscriber #(freq_item);
    `uvm_component_utils(freq_coverage)

    int cov_sig_freq_mhz;
    int cov_gate_ticks;

    covergroup cg_freq;
        cp_freq: coverpoint cov_sig_freq_mhz {
            bins f_low  = {[10:40]};
            bins f_mid  = {[41:80]};
            bins f_high = {[81:110]};
        }
        // 注意：small / medium / large 是 Verilog 保留字（charge strength），
        // 不能直接作 bins 名，故统一加 g_ 前缀。
        cp_gate: coverpoint cov_gate_ticks {
            bins g_small  = {[200:1000]};
            bins g_medium = {[1001:3000]};
            bins g_large  = {[3001:5000]};
        }
        x_freq_gate: cross cp_freq, cp_gate;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_freq = new();
    endfunction

    function void write(freq_item t);
        cov_sig_freq_mhz = t.sig_freq_mhz;
        cov_gate_ticks   = t.gate_ticks;
        cg_freq.sample();
    endfunction

endclass
