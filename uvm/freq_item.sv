// ============================================================================
// freq_item.sv —— 激励事务
// ----------------------------------------------------------------------------
// 两个随机变量：被测频率 sig_freq_mhz、门控窗口宽度 gate_ticks（clk_sys 拍）。
// sig_period_ps 由 post_randomize 派生（period_ps = 1e6 / f_MHz）。
// ============================================================================
class freq_item extends uvm_sequence_item;
    `uvm_object_utils(freq_item)

    rand int unsigned sig_freq_mhz;     // 被测信号频率 (MHz)，对应真实 ÷4 后 108.48MHz 量级
    rand int unsigned gate_ticks;       // 门控窗口宽度（clk_sys = 50MHz 的拍数）
    real             sig_period_ps;     // 派生：被测信号周期 (ps)

    constraint c_freq { sig_freq_mhz inside {[10:110]}; }
    constraint c_gate { gate_ticks   inside {[200:5000]}; }

    function new(string name = "freq_item");
        super.new(name);
    endfunction

    function void post_randomize();
        sig_period_ps = 1.0e6 / real'(sig_freq_mhz);   // period(ps) = 1e12/Hz = 1e6/f_MHz
    endfunction

    function string convert2string();
        return $sformatf("sig_freq=%0dMHz gate_ticks=%0d period_ps=%0.1f",
                         sig_freq_mhz, gate_ticks, sig_period_ps);
    endfunction

endclass
