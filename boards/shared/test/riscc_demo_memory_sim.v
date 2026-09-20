// Fast backing RAM for demo smoke tests. Pin-level SDRAM is tested separately.
`timescale 1ns/1ps
`default_nettype none
module riscc_demo_memory_sim (
    input wire clk, rst,
    input wire [23:0] cpu_addr,
    input wire [31:0] cpu_wdata,
    input wire [3:0] cpu_wmask,
    input wire cpu_we, cpu_cyc, cpu_stb,
    output wire cpu_stall, cpu_ack, cpu_ready,
    output wire [31:0] cpu_rdata,
    input wire [23:0] video_addr,
    input wire video_cyc, video_stb,
    output wire video_stall, video_ack,
    output wire [31:0] video_rdata
);
    wire [23:0] addr;
    wire [31:0] wdata;
    wire [3:0] wmask;
    wire we, cyc, stb;
    reg ack;
    reg [31:0] rdata;
    // Enough for the complete framebuffer; reject out-of-range smoke accesses.
    reg [31:0] words [0:16383];
    integer i;
    initial for (i = 0; i < 16384; i = i+1) words[i] = 0;
    riscc_sdram_fabric fabric (
        .cpu_clk(clk), .cpu_rst(rst), .memory_clk(clk), .memory_rst(rst),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_wmask(cpu_wmask),
        .cpu_we(cpu_we), .cpu_cyc(cpu_cyc), .cpu_stb(cpu_stb),
        .cpu_stall(cpu_stall), .cpu_ack(cpu_ack), .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .video_addr(video_addr), .video_cyc(video_cyc), .video_stb(video_stb),
        .video_stall(video_stall), .video_ack(video_ack), .video_rdata(video_rdata),
        .memory_addr(addr), .memory_wdata(wdata), .memory_wmask(wmask),
        .memory_we(we), .memory_cyc(cyc), .memory_stb(stb),
        .memory_stall(1'b0), .memory_ack(ack), .memory_ready(!rst), .memory_rdata(rdata)
    );
    always @(posedge clk) begin
        ack <= !rst && cyc && stb;
        if (!rst && cyc && stb) begin
            if (addr >= 16384) $fatal(1, "demo backing RAM address out of range: %h", addr);
            rdata <= words[addr[13:0]];
            if (we) begin
                if (wmask[0]) words[addr[13:0]][7:0] <= wdata[7:0];
                if (wmask[1]) words[addr[13:0]][15:8] <= wdata[15:8];
                if (wmask[2]) words[addr[13:0]][23:16] <= wdata[23:16];
                if (wmask[3]) words[addr[13:0]][31:24] <= wdata[31:24];
            end
        end
    end
endmodule
`default_nettype wire
