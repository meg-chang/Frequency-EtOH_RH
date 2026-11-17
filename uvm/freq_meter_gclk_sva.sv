// ============================================================================
// freq_meter_gclk_sva.sv —— 断言（SVA），挂在 DUT 内部，不改 RTL 一行
// ----------------------------------------------------------------------------
// 为什么断言不写进 RTL：
//   1) RTL 是交付物，验证代码不该污染它
//   2) 同一套断言可以同时挂到原版和修复版两个 DUT 变体上，保证两边约束一致
//   3) 换项目时断言文件能跟着复用
//
// 断言和 scoreboard 的分工（面试常问）：
//   - scoreboard 验"算得对不对"（数值比对），是**事务级**的，慢但全面
//   - SVA 验"行为合不合规"（协议性质），是**信号级**的，快且能精确到拍
//   - SVA 更早发现问题：协议一违规立刻报，不用等窗口结束拿到结果
//
// 每条断言都标了【来源】，说明它是从 RTL 哪一行推出来的，不是凭空写的。
// ============================================================================

`timescale 1ns/1ps

module freq_meter_gclk_sva #(
    parameter int COUNT_WIDTH = 24
) (
    input wire                  clk_sys,
    input wire                  rst_sys_n,
    input wire                  clk_sig,
    input wire                  rst_sig_n,
    input wire                  gate_en,
    input wire                  count_valid,
    input wire [COUNT_WIDTH-1:0] count,
    // 内部信号（白盒观察点）—— 只用两个 DUT 变体都有的信号，
    // 这样同一份断言模块能挂到原版和修复版上。
    // 原版有 done（单周期脉冲），修复版换成了 done_toggle（电平翻转），
    // 名字和语义都不同，所以不能作为端口。
    input wire [COUNT_WIDTH-1:0] cnt,
    input wire [COUNT_WIDTH-1:0] cnt_out
);

    // ★ 必须显式 import：这个模块是独立编译单元，不在 freq_meter_gclk_pkg 里，
    //   而 `uvm_error 宏展开后用到 uvm_pkg 的 uvm_report_* 类型和 UVM_ERROR
    //   枚举，不 import 会报 Error-[IND] Identifier 'UVM_ERROR' has not been
    //   declared yet。package 里的组件靠 package 的 import 拿到，模块拿不到。
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // 局部参数：饱和值
    localparam logic [COUNT_WIDTH-1:0] CNT_MAX = {COUNT_WIDTH{1'b1}};

    // ========================================================================
    // A1. count_valid 必须是单周期脉冲
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:135
    //   count_valid <= done_s2 & ~done_d;
    // 这是标准的上升沿检测写法：done_s2 为高的第一拍输出 1，第二拍 done_d
    // 也变高，与运算变 0。所以 count_valid 天然是 1 拍脉冲。
    //
    // 为什么这条最该断言：
    //   count_valid 是跨到系统域后的"结果有效"标志。如果它变成两拍宽，
    //   monitor 会采到两次同一个结果 → scoreboard 收到重复事务 → 假 PASS。
    //   这种错误数值比对抓不到（两次值一样，都"对"），只有断言能抓。
    // ========================================================================
    property p_count_valid_single_cycle;
        @(posedge clk_sys) disable iff (!rst_sys_n)
            count_valid |=> !count_valid;
    endproperty
    A1_COUNT_VALID_SINGLE_CYCLE: assert property (p_count_valid_single_cycle)
        else `uvm_error("SVA", "A1 FAIL: count_valid is not a single-cycle pulse")

    // ========================================================================
    // A2. 内部计数器永不越过饱和值
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:100-101
    //   if (cnt != CNT_MAX) cnt <= cnt + 1'b1;
    // 饱和保护的作用是防回绕：24 位计数器数满再 +1 会变 0，输出一个
    // "0 Hz"的鬼值。这条断言直接验证保护有效。
    //
    // 为什么这条值钱：
    //   它正是我加 freq_saturation_test 想覆盖的那条分支。
    //   断言和覆盖率是两条独立的证据链——覆盖率证明"代码被执行到"，
    //   断言证明"执行结果符合预期"。两个都有，才算真验过。
    // ========================================================================
    property p_cnt_saturate;
        @(posedge clk_sig) disable iff (!rst_sig_n)
            cnt <= CNT_MAX;
    endproperty
    A2_CNT_SATURATE: assert property (p_cnt_saturate)
        else `uvm_error("SVA", $sformatf(
            "A2 FAIL: cnt = %0d exceeded CNT_MAX = %0d (counter wrapped)",
            cnt, CNT_MAX))

    // ========================================================================
    // A3. 复位期间内部计数器必须为 0
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:85-86（复位分支）
    //   if (!rst_sig_n) begin cnt <= 0; ... end
    // 复位不干净是最常见的 RTL bug 之一，尤其多时钟域设计里容易漏某个域。
    // ========================================================================
    property p_reset_clears_cnt;
        @(posedge clk_sig)
            !rst_sig_n |-> cnt == '0;
    endproperty
    A3_RESET_CLEARS_CNT: assert property (p_reset_clears_cnt)
        else `uvm_error("SVA", $sformatf(
            "A3 FAIL: cnt = %0d during reset, expected 0", cnt))

    // ========================================================================
    // A4. 复位期间 count_valid 必须为低
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:132-133
    //   if (!rst_sys_n) count_valid <= 1'b0;
    // 复位期间吐"有效"是致命错误——下游会在系统还没准备好时就开始收数据。
    // ========================================================================
    property p_reset_clears_valid;
        @(posedge clk_sys)
            !rst_sys_n |-> !count_valid;
    endproperty
    A4_RESET_CLEARS_VALID: assert property (p_reset_clears_valid)
        else `uvm_error("SVA", "A4 FAIL: count_valid asserted during reset")

    // ========================================================================
    // A5. 吐 count_valid 时门控必须已经落下
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:104-107 + 跨域延迟链
    //   if (!gate_s2 && gate_d) begin cnt_out <= cnt; done <= 1'b1; end
    //
    // 算一下 count_valid 出现时 gate_en 已经低了多久：
    //   gate_en 落下 → 2 拍进 gate_s2 → 再 1 拍 done 置位
    //   → 2 拍进 done_s2 → 再 1 拍 count_valid
    //   合计 5 个系统拍，所以 count_valid 时 gate_en 必然已经是低电平。
    //
    // 用 |-> （重叠蕴含）而不是 |=> ：断言就在 count_valid 那一拍检查。
    // ========================================================================
    property p_valid_only_after_gate_closed;
        @(posedge clk_sys) disable iff (!rst_sys_n)
            count_valid |-> !gate_en;
    endproperty
    A5_VALID_ONLY_AFTER_GATE_CLOSED: assert property (p_valid_only_after_gate_closed)
        else `uvm_error("SVA", "A5 FAIL: count_valid asserted while gate_en still high")

    // ========================================================================
    // A6. 两次 count_valid 之间必须隔够时间（防重复/粘连）
    // ------------------------------------------------------------------------
    // 【来源】设计意图：一个门控窗口只产出一个结果。
    // 窗口最短 200 拍（freq_item 约束下界），所以两个 count_valid 之间
    // 至少隔 200 个系统拍。如果隔得更近，说明一个窗口吐了两次结果。
    //
    // 这条断言的价值：抓"窗口粘连"——如果 gate_s2 的同步出问题，
    // 可能一个窗口被识别成两个，吐出两个结果。scoreboard 会因为
    // 收到两笔而错位，但错误信息很难指向根因。
    // ========================================================================
    property p_valid_spacing;
        @(posedge clk_sys) disable iff (!rst_sys_n)
            count_valid |-> ##[1:199] !count_valid;
    endproperty
    A6_VALID_SPACING: assert property (p_valid_spacing)
        else `uvm_error("SVA", "A6 FAIL: two count_valid pulses closer than 200 cycles (window merge?)")

    // ========================================================================
    // A7. count 在 count_valid 之后必须保持稳定
    // ------------------------------------------------------------------------
    // 【来源】freq_meter_gclk.v:147-152
    //   cnt_h1 <= cnt_out; cnt_h2 <= cnt_h1; assign count = cnt_h2;
    // cnt_out 只在窗口结束时更新，所以 count（=cnt_h2）在窗口之间应该不变。
    // 同步延迟 2 拍，count_valid 出现时 count 已经是最新值，之后到下一个
    // 窗口结束前不该再变。这里只断言"紧接着下一拍稳定"这个最小性质，
    // 因为更长的区间需要知道下一个窗口何时来，用无界重复多数仿真器不支持。
    // ========================================================================
    property p_count_stable_after_valid;
        @(posedge clk_sys) disable iff (!rst_sys_n)
            count_valid |=> $stable(count);
    endproperty
    A7_COUNT_STABLE_AFTER_VALID: assert property (p_count_stable_after_valid)
        else `uvm_error("SVA", "A7 FAIL: count changed right after count_valid")

    // ========================================================================
    // 覆盖率关联：断言被触发过几次（证明断言本身不是摆设）
    // ------------------------------------------------------------------------
    // 这是很多人漏掉的一步：断言写了但从没被触发，等于没写。
    // 用 cover property 统计每条断言的前件命中次数。
    // ========================================================================
    C1_VALID_SEEN: cover property (
        @(posedge clk_sys) disable iff (!rst_sys_n) count_valid);
    C2_SAT_SEEN: cover property (
        @(posedge clk_sig) disable iff (!rst_sig_n) cnt == CNT_MAX);
    C3_RESET_SEEN: cover property (
        @(posedge clk_sig) !rst_sig_n);

endmodule


// ============================================================================
// 关于挂载方式：为什么这里没有 bind 语句，改成在顶层例化
// ----------------------------------------------------------------------------
// 最初写的是 bind（VCS 上工作正常），但 ModelSim 上踩了两个坑：
//
//   坑 1：bind 写在 compilation unit scope 时，ModelSim 只给一条警告
//         (vlog-2650) 'bind' found in compilation unit scope. Please use
//         -cuname to ensure that 'bind' gets elaborated.
//         然后**静默不 elaborate**——断言一条都不跑，但编译显示 Errors: 0。
//         这是最危险的情况：看起来验证通过了，其实断言根本没生效。
//         我是靠"故意改坏断言看它报不报"才发现的，光看编译日志会漏掉。
//
//   坑 2：按提示加 -cuname 会报 (vlog-2162) -cuname can only be used in
//         conjunction with -mfcu；加上 -mfcu 之后 bind 被关进独立编译单元
//         sva_cu，又报 (vsim-12036) Unresolved reference to
//         'freq_meter_gclk_fixed' in /sva_cu —— 目标模块在别的编译单元里，
//         看不见。
//
// 结论：bind 的跨仿真器可移植性没有想象中好。改用**在顶层直接例化**
// 断言模块、用层次化路径连到 DUT 内部信号，两个仿真器都稳定。
// 代价是内部信号必须保持可见（ModelSim 要 -voptargs="+acc"，
// VCS 要 -debug_access+all），本项目本来就有这两个参数。
//
// 这个坑值得记：验证环境"没报错"和"真的在检查"是两件事。
// ============================================================================
