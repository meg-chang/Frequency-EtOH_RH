// ============================================================================
// freq_saturation_test.sv —— 计数器饱和保护用例（补不可达分支）
// ----------------------------------------------------------------------------
// 目标：覆盖 freq_meter_gclk.v:100 `if (cnt != CNT_MAX)` 的 **false 侧**
//       （即 cnt == CNT_MAX 时不再自增的饱和保护）。
//
// 为什么不能用常规激励跑出来：
//   CNT_MAX = 2^24-1 = 16777215。要让窗口内自然数满，按 108MHz 算需要
//   16777215 / 108e6 ≈ 155 ms 仿真时间。而现有 random 用例最长的窗口
//   才 5000 × 20ns = 100 µs，差三个数量级。硬跑不现实。
//
// 本用例的做法（白盒，业界常规手段）：
//   1. 先跑一笔常规激励，把 DUT 带出复位态；
//   2. 用 uvm_hdl_deposit 把 DUT 内部计数器 cnt 直接写到 CNT_MAX-2；
//   3. 再跑一笔激励，DUT 自己数 2 拍到 CNT_MAX，第 3 拍进
//      `if (cnt != CNT_MAX)` 的 false 侧 → 该分支被覆盖；
//   4. 校验：窗口结束后 count_out 必须锁存在 CNT_MAX，不能回绕成 0。
//      这一步才是真正验证「饱和保护有效」，光覆盖到分支不算验证完。
//
// 注意：
//   - 需要 -debug_access+all 编译（Makefile 的 VCS_OPTS 已带），否则
//     uvm_hdl_deposit 报 Error-[ACC-STR] Design debug db not found。
//   - 本用例关掉 scoreboard 的数值比对（config_db 置 disable_check=1），
//     因为参考模型从 0 起算的语义在这里不成立；比对由本用例自己完成。
// ============================================================================

// ---- 辅助序列：跑一笔固定参数的激励 ----
class freq_single_seq extends uvm_sequence #(freq_item);
    `uvm_object_utils(freq_single_seq)
    int unsigned f_mhz;
    int unsigned g_ticks;

    function new(string name = "freq_single_seq");
        super.new(name);
    endfunction

    task body();
        freq_item req;
        req = freq_item::type_id::create("req");
        start_item(req);
        if (!req.randomize() with {
                sig_freq_mhz == f_mhz;
                gate_ticks   == g_ticks;
            }) `uvm_error("SAT", "randomize failed")
        finish_item(req);
    endtask
endclass

class freq_saturation_test extends uvm_test;
    `uvm_component_utils(freq_saturation_test)

    freq_env env;

    // 与 RTL 保持一致的饱和值（COUNT_WIDTH=24）
    localparam int unsigned COUNT_WIDTH = 24;
    localparam logic [COUNT_WIDTH-1:0] CNT_MAX = {COUNT_WIDTH{1'b1}};

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // 参考模型语义不适用，关掉数值比对，只留覆盖率收集
        uvm_config_db #(bit)::set(this, "*", "disable_check", 1'b1);
        env = freq_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        freq_single_seq          seq;
        logic [COUNT_WIDTH-1:0]  captured;
        logic [COUNT_WIDTH-1:0]  readback;
        bit                      deposit_ok;

        phase.raise_objection(this);

        // ---- 1. 先跑一笔常规激励，把 DUT 带出复位态、进入正常工作 ----
        //    deposit 在复位期间会被复位值覆盖，所以必须先让 DUT 跑起来。
        seq = freq_single_seq::type_id::create("warmup");
        seq.f_mhz   = 100;             // 10ns 周期，计数快
        seq.g_ticks = 500;             // 10µs 窗口
        seq.start(env.agt.sqr);
        #1us;                          // 等这笔结果吐完

        // ---- 2. 开一个窗口，让 DUT 自己数到饱和 ----
        //    必须在窗口打开之后、计数已经跑起来时 deposit：
        //    窗口起始沿 DUT 会把 cnt 清零（gate_s2 && !gate_d 分支），
        //    写在窗口之前会被这一拍冲掉。
        fork
            begin
                seq = freq_single_seq::type_id::create("sat");
                seq.f_mhz   = 100;
                seq.g_ticks = 2000;    // 40µs 窗口，留足中途插入的时间
                seq.start(env.agt.sqr);
            end
            begin
                wait (env.agt.drv.vif.gate_en === 1'b1);
                repeat (200) @(posedge env.agt.drv.vif.clk_sig);
                // ★ 必须在时钟沿之后错开一点再 deposit，不能卡在沿上。
                //   实测踩坑：紧贴 posedge 做 deposit，会与同一时间步里
                //   `cnt <= cnt + 1'b1` 的 NBA 更新撞在一起——在 ModelSim 上
                //   NBA 赢，deposit 被覆盖，cnt 继续从 ~197 数到 3999，
                //   最后报"计数器回绕"其实是 deposit 根本没留住。
                //   VCS 上只是调度顺序碰巧让 deposit 赢了，看起来能过。
                //   错开 1ns（100MHz 下周期 10ns，1ns 处于周期中部，
                //   没有任何 pending NBA）两边行为才一致。
                #1;
                deposit_ok = uvm_hdl_deposit("freq_meter_gclk_top.dut.cnt", CNT_MAX - 2);
                if (!deposit_ok) `uvm_fatal("SAT", "mid-window deposit failed (path not found)")
                // ★ deposit 返回 1 只代表路径找得到，不代表值写进去了。
                //   ModelSim 上实测过：返回成功但 cnt 没变，最后 cnt_out 是
                //   正常数出来的值，看起来像"计数器回绕"其实是 deposit 无效。
                //   所以必须读回确认，否则报错信息会指向错误的方向。
                if (!uvm_hdl_read("freq_meter_gclk_top.dut.cnt", readback))
                    `uvm_fatal("SAT", "readback failed")
                if (readback !== (CNT_MAX - 2)) begin
                    `uvm_error("SAT", $sformatf(
                        "deposit did NOT take effect: readback cnt = %0d, expected %0d. \
On ModelSim add -voptargs=\"+acc\" to vsim so hierarchical paths are visible.",
                        readback, CNT_MAX - 2))
                end else begin
                    `uvm_info("SAT", $sformatf(
                        "mid-window deposit verified: cnt = %0d at %0t", readback, $time), UVM_NONE)
                end
            end
        join
        #2us;                          // 等窗口结束、结果吐出

        // ---- 4. 校验：饱和后必须锁存在 CNT_MAX，不能回绕 ----
        if (!uvm_hdl_read("freq_meter_gclk_top.dut.cnt_out", captured)) begin
            `uvm_fatal("SAT", "uvm_hdl_read on dut.cnt_out failed")
        end
        if (captured !== CNT_MAX) begin
            `uvm_error("SAT", $sformatf(
                "saturation FAILED: cnt_out = %0d, expected CNT_MAX = %0d. \
Counter wrapped or did not saturate.", captured, CNT_MAX))
        end else begin
            `uvm_info("SAT", $sformatf(
                "saturation PASS: cnt_out locked at CNT_MAX = %0d, no wrap-around",
                captured), UVM_NONE)
        end

        phase.drop_objection(this);
    endtask

endclass
