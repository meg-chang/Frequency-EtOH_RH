// ============================================================================
// freq_agent.sv —— 验证代理（driver + monitor + sequencer）
// ============================================================================
class freq_agent extends uvm_agent;
    `uvm_component_utils(freq_agent)

    freq_driver    drv;
    freq_monitor   mon;
    uvm_sequencer #(freq_item) sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon = freq_monitor::type_id::create("mon", this);
        drv = freq_driver::type_id::create("drv", this);
        sqr = uvm_sequencer #(freq_item)::type_id::create("sqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass
