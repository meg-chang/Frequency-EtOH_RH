// ============================================================================
// freq_meter_gclk_fixed.v —— 修复版：用 toggle 握手替代单周期脉冲回传 done
// ----------------------------------------------------------------------------
// 原始缺陷（见验证报告）：freq_meter_gclk 的 done 是被测域【单周期脉冲】，
//   经 2-FF 同步 + 边沿检测（done_s2 & ~done_d）回传系统域。当 T_clk_sig <
//   T_clk_sys（f>50MHz）时，该脉冲可能整段落在两个 clk_sys 边沿之间，被同步
//   器完全漏采 → 整窗无 count_valid，且 UVM 不报 error（静默漏检）。
//   最坏情况：f_sig = 2× f_sys（本工程 100MHz）时确定性 100% 丢失。
//
// 修复方法：脉冲 → 电平翻转（toggle）握手。被测域每次窗口结束翻转一个
//   done_toggle 寄存器；该电平在两次窗口之间保持（≥ 一个完整门控周期，远大于
//   2 个系统周期），故 2-FF 同步器必然采到；系统域对同步后的翻转做边沿检测
//   （done_t2 ^ done_t3）重新得到 1 周期 count_valid。翻转是"电平"而非"脉冲"，
//   与脉宽无关，彻底消除漏采。
//
// 其余逻辑（gate_en 同步、cnt_out 准静态同步、计数/饱和）与原版完全一致。
// 接口与原版 pin-to-pin 兼容，可直接替换验证。
// ============================================================================
module freq_meter_gclk_fixed #(
    parameter COUNT_WIDTH = 24
) (
    input  wire                   clk_sig,
    input  wire                   rst_sig_n,
    input  wire                   gate_en,
    input  wire                   clk_sys,
    input  wire                   rst_sys_n,
    output reg                    count_valid,
    output wire [COUNT_WIDTH-1:0] count
);

// ============================================================================
// 被测时钟域
// ============================================================================
localparam [COUNT_WIDTH-1:0] CNT_MAX = {COUNT_WIDTH{1'b1}};

reg gate_s1, gate_s2;
reg gate_d;
reg [COUNT_WIDTH-1:0] cnt;
reg [COUNT_WIDTH-1:0] cnt_out;
reg done_toggle;          // 修复点：窗口结束翻转，电平保持到下一窗口

always @(posedge clk_sig or negedge rst_sig_n) begin
    if (!rst_sig_n) begin
        gate_s1  <= 1'b0;
        gate_s2  <= 1'b0;
        gate_d   <= 1'b0;
        cnt      <= {COUNT_WIDTH{1'b0}};
        cnt_out  <= {COUNT_WIDTH{1'b0}};
        done_toggle <= 1'b0;
    end else begin
        gate_s1 <= gate_en;
        gate_s2 <= gate_s1;
        gate_d  <= gate_s2;

        if (gate_s2 && !gate_d) begin
            cnt <= {COUNT_WIDTH{1'b0}};
        end else if (gate_s2) begin
            if (cnt != CNT_MAX)
                cnt <= cnt + 1'b1;
        end

        if (!gate_s2 && gate_d) begin
            cnt_out    <= cnt;
            done_toggle <= ~done_toggle;   // 翻转握手（替代单周期脉冲）
            cnt        <= {COUNT_WIDTH{1'b0}};
        end
    end
end

// ============================================================================
// 系统时钟域：toggle → 2-FF 同步 → 边沿检测
// ============================================================================
reg done_t1, done_t2, done_t3;

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
        done_t1 <= 1'b0;
        done_t2 <= 1'b0;
        done_t3 <= 1'b0;
    end else begin
        done_t1 <= done_toggle;
        done_t2 <= done_t1;
        done_t3 <= done_t2;
    end
end

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n)
        count_valid <= 1'b0;
    else
        count_valid <= done_t2 ^ done_t3;   // 每个窗口恰好 1 拍
end

// ---- cnt_out 准静态跨域：两级寄存器（同原版）----
reg [COUNT_WIDTH-1:0] cnt_h1, cnt_h2;

always @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
        cnt_h1 <= {COUNT_WIDTH{1'b0}};
        cnt_h2 <= {COUNT_WIDTH{1'b0}};
    end else begin
        cnt_h1 <= cnt_out;
        cnt_h2 <= cnt_h1;
    end
end

assign count = cnt_h2;

endmodule
