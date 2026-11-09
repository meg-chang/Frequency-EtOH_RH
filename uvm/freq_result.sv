// ============================================================================
// freq_result.sv —— 结果事务（monitor → scoreboard）
// ============================================================================
class freq_result extends uvm_sequence_item;
    `uvm_object_utils(freq_result)
    bit [23:0] count;
    function new(string name = "freq_result");
        super.new(name);
    endfunction
endclass
