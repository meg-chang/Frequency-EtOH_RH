// ============================================================================
//格雷码转二进制
//
//   1. 调试时把格雷码指针还原成二进制，直观看出 FIFO 内数据个数
//   2. 需要计算 used 计数的场景
//
// 算法（前缀异或，逐位向高位折叠）：
//   bin[MSB] = gray[MSB]
//   bin[i]   = bin[i+1] ^ gray[i]
// ============================================================================

module gray2bin #(
        parameter WIDTH = 5
    ) (
        input  wire [WIDTH-1:0] gray,
        output wire [WIDTH-1:0] bin
    );

    integer i;
    reg [WIDTH-1:0] bin_r;

    always @(*) begin
        bin_r[WIDTH-1] = gray[WIDTH-1];
        for (i = WIDTH-2; i >= 0; i = i - 1)
            bin_r[i] = bin_r[i + 1] ^ gray[i]; 
    end 

    assign bin = bin_r;

endmodule