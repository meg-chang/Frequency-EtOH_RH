// ============================================================================
//两级同步器
//  用于显著降低亚稳态传播概率
//
//参数：
//  WIDRH    —— 同步位宽
//  RESET_VL —— 复位值（默认全0）
// ============================================================================

module sync_two_stsge #(
    parameter WIDTH    = 1,
    parameter RESET_VL = {WIDTH{1'b0}}
) (
    input  wire [WIDTH-1:0] din, //异步输入（源时钟域）
    input  wire             clk, //目标时钟域
    input  wire             rst_n,
    output wire [WIDTH-1:0] dout //同步后输出（目标时钟域）
);

reg [WIDTH-1:0] sync_d1;
reg [WIDTH-1:0] sync_d2;

always @(posedge clk or negedge rst_n) begin
    if (!rat_n) begin
        sync_d1 <= RESET_VL;
        sync_d2 <= RESET_VL;
    end else begin
        sync_d1 <= din;
        sync_d2 <= sync_d1;
    end
end

assign dout = sync_d2;

endmodule
