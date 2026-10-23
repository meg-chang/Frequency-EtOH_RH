//门控计数测频（被测信号直驱 GCLK，高性能架构）
//
//GCLK直驱法：被测信号本身接专用时钟引脚 -> 全局时钟网络 -> 直接作为计数器的时钟，门控窗口跨域送进来
//
//参数：
//  COUNT_WIDTH —— 100ms 窗口、108.48MHz -> 10,848,000 counts
//                 2^23 = 8.39M 不够，2^24 = 16.78M 足够 -> 取 24

module freq_meter_gclk #(
        parameter COUNT_WIDTH = 24
) (
        //被测时钟域（信号经专用时钟引脚 + GCLK 进来）
        input  wire                   clk_sig,      //被测信号（除以 4 后 108.48MHz）
        input  wire                   rst_sig_n,
        input  wire                   gate_en,      //门控窗口（来自系统域，异步）
        //系统时钟域（50MHz）
        input  wire                   clk_sys,
        input  wire                   rst_sys_n,
        output reg                    count_valid,  //1 周期脉冲（系统域）
        output wire [COUNT_WIDTH-1:0] count
);

        //被测时钟域
        localparam [COUNT_WIDTH-1:0] CNT_MAX = {COUNT_WIDTH{1'b1}};

        reg gate_s1, gate_s2;           //gate_en 两级同步（系统域 -> 被测域）
        reg gate_d;                     //gate_s2 延迟一拍，用于边沿检测
        reg [COUNT_WIDTH-1:0] cnt;      //工作计数器
        reg [COUNT_WIDTH-1:0] cnt_out;  //锁存输出（窗口级静态）
        reg done;                       //被测域窗口结束脉冲（1 拍）

        always @(posedge clk_sig or negedge rst_sig_n) begin
                if (!rst_sig_n) begin
                        gate_s1 <= 1'b0;
                        gate_s2 <= 1'b0;
                        gate_d  <= 1'b0;
                        cnt     <= {COUNT_WIDTH{1'b0}};
                        cnt_out <= {COUNT_WIDTH{1'b0}};
                        done    <= 1'b0;
                end else begin
                        //门控同步（电平信号，两级同步足够）
                        gate_s1 <= gate_en;
                        gate_s2 <= gate_s1;
                        gate_d  <= gate_s2;

                        done <= 1'b0;   //默认拉低，仅窗口结束当拍置 1
