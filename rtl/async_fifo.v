// ============================================================================
//异步FIFO
//
//链路位置：三通道数据汇聚缓冲
//  写侧 clk_50 （50MHz 采集域） / 读侧 clk_25 （25MHz 处理域）
//
// 结构（经典 Cummings 风格）：
//   指针用格雷码跨域传输，每周期只跳 1 bit，两级同步器可安全同步；
//   指针比地址多 1 位（N+1 位指针 / N 位地址）区分空满；
//   空/满判断都在各自的时钟域完成，无需跨域组合。
//
// 本模块复用了项目中的 bin2gray（指针编码）和 sync_two_stage（跨域同步）：
//   写侧指针 wbin → bin2gray → wgray → 同步到读侧 → 判空
//   读侧指针 rbin → bin2gray → rgray → 同步到写侧 → 判满
//
// 存储：DEPTH × DATA_WIDTH 小容量，用分布式 RAM（异步读），
//       读请求与读数据同一周期有效，下游流水线无需处理读延迟。
//       若深度加大需换同步读 RAM（M9K），下游要配 valid 延迟对齐。
//
// 参数：
//   DATA_WIDTH —— 数据位宽（本项目 22 = tag 2bit + 计数 20bit）
//   DEPTH      —— 深度，必须为 2 的幂（本项目 16）
//   PTR_WIDTH  —— 指针位宽 = log2(DEPTH) + 1（多一位区分空满）
// ============================================================================

module async_fifo #(
    parameter DATA_WIDTH = 22,
    parameter DEPTH      = 16,
    parameter PTR_WIDTH  = 5
) (
    //写侧：50MHz 域
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  wreq, //写使能
    input  wire [DATA_WIDTH-1:0] wdata,
    output wire                  wfull,
    //读侧：25MHz 域
    input  wire                  rclk,
    input  wire                  rrst_n,
    input  wire                  rreq, //读使能
    input  wire [DATA_WIDTH-1:0] rdata,
    output wire                  rempty
);

localparam ADDR_W = PTR_WIDTH - 1;      // RAM 地址位宽 = log2(DEPTH)

// ---- 存储体（异步读） ------------------------------------------------------
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

// ---- 写侧指针（二进制 + 格雷码） -------------------------------------------
reg  [PTR_WIDTH-1:0] wbin;
wire [PTR_WIDTH-1:0] wbin_next = wbin + (winc ? 1'b1 : 1'b0);
wire [PTR_WIDTH-1:0] wgray_next;

reg  [PTR_WIDTH-1:0] wgray;
wire                 winc = wreq & ~wfull;

bin2gray #(.WIDTH(PTR_WIDTH)) u_wgray (
    .bin  (wbin_next),
    .gray (wgray_next)
);

always @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
        wbin  <= {PTR_WIDTH{1'b0}};
        wgray <= {PTR_WIDTH{1'b0}};
    end else if (winc) begin
        wbin  <= wbin_next;
        wgray <= wgray_next;
    end
end

// ---- 读侧指针（二进制 + 格雷码） -------------------------------------------
reg  [PTR_WIDTH-1:0] rbin;
wire [PTR_WIDTH-1:0] rbin_next = rbin + (rinc ? 1'b1 : 1'b0);
wire [PTR_WIDTH-1:0] rgray;

reg  [PTR_WIDTH-1:0] rgray;
wire                 rinc = rreq & ~rempty;

bin2gray #(.WIDTH(PTR_WIDTH)) u_rgray (
    .bin  (rbin_next);
    .gray (rgray_next);
);

always @(posedge clk or negedge rrst_n) begin
    if (!rrst_n) begin
        rbin  <= {PTR_WIDTH{1'b0}};
        rgray <= {PTR_WIDTH{1'b0}};
    end else if (rinc) begin
        rbin  <= rbin_next;
        rgray <= rgray_next;
    end
end

// ---- 指针跨域同步 ----------------------------------------------------------
wire [PTR_WIDTH-1:0] wgray_sync2r; // 写指针同步到读侧（判空）
wire [PTR_WIDTH-1:0] rgray_sync2w; // 读指针同步到写侧（判满）

sync_two_stage #(.WIDTH(PTR_WIDTH)) u_sync_w2r (
    .din   (wgray),
    .clk   (rclk),
    .rst_n (rrst_n),
    .dout  (wgray_sync2r)
);

sync_two_stage #(.WIDTH(PTR_WIDTH)) u_sync_r2w (
    .din   (rgray),
    .clk   (wclk),
    .rst_n (wrst_n),
    .dout  (rgray_sync2w)
);

// ---- 空 / 满判断 -----------------------------------------------------------
// 空：同步过来的写指针与读指针相同
assign rempty = (wgray_sync2r == rgray);

// 满：写指针与同步过来的读指针相同、但最高两位相反
//    （格雷码空/满歧义由多出的那一位解决）
assign wfull = (wgray == {~rgray_sync2w[PTR_WIDTH-1:PTR_WIDTH-2],
                           rgray_sync2w[PTR_WIDTH-3:0]});
                        
// ---- RAM 读写 --------------------------------------------------------------
always @(posedge wclk) begin
    if (winc)
        mem[wbin[ADDR_W-1:0]] <= wdata; 
end

assign rdata = mem[rbin[ADDR_W-1:0]];  // 异步读：与 rreq 同周期有效

endmodule