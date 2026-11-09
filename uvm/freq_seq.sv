// ============================================================================
// freq_seq.sv —— 测试序列
// ----------------------------------------------------------------------------
// freq_random_seq   : 50 笔随机（频率 10~110MHz × 门控 200~5000 拍）
// freq_directed_seq : 4 频率 × 3 门控 定向扫描
// ============================================================================
class freq_random_seq extends uvm_sequence #(freq_item);
    `uvm_object_utils(freq_random_seq)
    function new(string name = "freq_random_seq");
        super.new(name);
    endfunction
    task body();
        freq_item req;
        repeat (50) begin
            req = freq_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_error("SEQ", "randomize failed")
            finish_item(req);
        end
    endtask
endclass

class freq_directed_seq extends uvm_sequence #(freq_item);
    `uvm_object_utils(freq_directed_seq)
    function new(string name = "freq_directed_seq");
        super.new(name);
    endfunction
    task body();
        freq_item req;
        int unsigned freqs[] = '{20, 50, 80, 108};
        int unsigned gates[] = '{500, 1000, 3000};
        foreach (freqs[i]) begin
            foreach (gates[j]) begin
                req = freq_item::type_id::create("req");
                start_item(req);
                assert(req.randomize() with {
                    sig_freq_mhz == freqs[i];
                    gate_ticks   == gates[j];
                }) else `uvm_error("SEQ", "randomize failed")
                finish_item(req);
            end
        end
    endtask
endclass
