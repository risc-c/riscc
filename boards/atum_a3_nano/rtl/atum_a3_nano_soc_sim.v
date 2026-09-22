// atum_a3_nano_soc_sim.v : simulation wrapper for the Atum demo SoC.

`timescale 10ns/10ns
`default_nettype none

module atum_a3_nano_soc_sim #(
    parameter MEM_HEX = "build/atum_a3_nano/mem/demo.memh",
    parameter integer UART_CLK_DIV = 8,
    parameter integer TIMER_TICK_DIV = 200000
) (
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,
    output wire uart_tx,
    output wire [3:0] led,
    output wire dbg_fb_we,
    output wire [13:0] dbg_fb_addr,
    output wire [31:0] dbg_fb_wdata,
    output wire [3:0] dbg_fb_wmask,
    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    wire [3:0] fb_wmask;

    wire [23:0] sdram_addr, video_addr;
    wire [31:0] sdram_wdata, sdram_rdata, video_rdata;
    wire [3:0] sdram_wmask;
    wire sdram_we, sdram_cyc, sdram_stb, sdram_stall, sdram_ack;
    wire video_cyc, video_stb, video_stall, video_ack;
    // One backing model serves both CPU and video memory ports.
    riscc_demo_memory_sim backing (
        .clk(clk),
        .rst(rst),
        .cpu_addr(sdram_addr),
        .cpu_wdata(sdram_wdata),
        .cpu_wmask(sdram_wmask),
        .cpu_we(sdram_we),
        .cpu_cyc(sdram_cyc),
        .cpu_stb(sdram_stb),
        .cpu_stall(sdram_stall),
        .cpu_ack(sdram_ack),
        .cpu_ready(),
        .cpu_rdata(sdram_rdata),
        .video_addr(video_addr),
        .video_cyc(video_cyc),
        .video_stb(video_stb),
        .video_stall(video_stall),
        .video_ack(video_ack),
        .video_rdata(video_rdata)
    );

    assign dbg_fb_wmask = fb_wmask;
    wire palette_we;
    wire [7:0] palette_addr;
    wire [23:0] palette_wdata;
    atum_a3_nano_soc #(
        .MEM_HEX(MEM_HEX),
        .UART_CLK_DIV(UART_CLK_DIV),
        .TIMER_TICK_DIV(TIMER_TICK_DIV)
    ) soc (
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .clk(clk),
        .rst(rst),
        .sdram_addr(sdram_addr),
        .sdram_wdata(sdram_wdata),
        .sdram_wmask(sdram_wmask),
        .sdram_we(sdram_we),
        .sdram_cyc(sdram_cyc),
        .sdram_stb(sdram_stb),
        .sdram_stall(sdram_stall),
        .sdram_ack(sdram_ack),
        .sdram_rdata(sdram_rdata),
        .uart_rx(uart_rx),
        .button(2'b11),
        .uart_tx(uart_tx),
        .led(led),
        .fb_we(dbg_fb_we),
        .fb_addr(dbg_fb_addr),
        .fb_wmask(fb_wmask),
        .fb_wdata(dbg_fb_wdata),
        .dbg_fb_writes(dbg_fb_writes),
        .dbg_uart_tx_count(dbg_uart_tx_count),
        .dbg_uart_rx_count(dbg_uart_rx_count)
    );
    atum_fb_hdmi video (
        .cpu_clk(clk),
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .memory_clk(clk),
        .memory_rst(rst),
        .memory_ready(!rst),
        .memory_addr(video_addr),
        .memory_cyc(video_cyc),
        .memory_stb(video_stb),
        .memory_stall(video_stall),
        .memory_ack(video_ack),
        .memory_rdata(video_rdata),
        .underrun(),
        .pix_clk(clk),
        .rst(rst),
        .pix_clk_out(),
        .hdmi_hs(),
        .hdmi_vs(),
        .hdmi_de(),
        .hdmi_rgb()
    );
endmodule

`default_nettype wire
