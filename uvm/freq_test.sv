// ============================================================================
// freq_test.sv —— 测试用例
// ============================================================================
class freq_random_test extends uvm_test;
    `uvm_component_utils(freq_random_test)
    freq_env env;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = freq_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
        freq_random_seq seq;
        phase.raise_objection(this);
        seq = freq_random_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        // 最后一个 item 的 gate 落下后，DUT 还要 2~3 个被测周期 + 2~3 个系统拍
        // 才吐出 count_valid；立即 drop_objection 会把这最后一笔结果丢掉。
        // 等 1µs（最慢 10MHz 时约 10 个被测周期，足够）再退出。
        #1us;
        phase.drop_objection(this);
    endtask
endclass

class freq_directed_test extends uvm_test;
    `uvm_component_utils(freq_directed_test)
    freq_env env;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = freq_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
        freq_directed_seq seq;
        phase.raise_objection(this);
        seq = freq_directed_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        #1us;                                  // 等最后一笔 count_valid 回来
        phase.drop_objection(this);
    endtask
endclass
