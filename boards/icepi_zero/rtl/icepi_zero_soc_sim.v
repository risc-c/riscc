`timescale 10ns/10ns
`default_nettype none

module icepi_zero_soc_sim #(
    parameter MEM_HEX = "build/icepi_zero/demo.memh",
    parameter integer UART_CLK_DIV = 8,
    parameter integer TIMER_TICK_DIV = 50000
) (
    input  wire       clk,
    input  wire       pix_clk,
    input  wire       shift_clk,
    input  wire       rst,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [4:0] led,
    output wire       dbg_fb_we,
    output wire [12:0] dbg_fb_addr,
    output wire [15:0] dbg_fb_wdata,
    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    wire        fb_we;
    wire [12:0] fb_addr;
    wire [1:0]  fb_wmask;
    wire [15:0] fb_wdata;
    wire [3:0]  tmds;

    assign dbg_fb_we = fb_we;
    assign dbg_fb_addr = fb_addr;
    assign dbg_fb_wdata = fb_wdata;

    icepi_zero_soc #(
        .MEM_HEX(MEM_HEX),
        .UART_CLK_DIV(UART_CLK_DIV),
        .TIMER_TICK_DIV(TIMER_TICK_DIV)
    ) soc (
        .clk(clk),
        .rst(rst),
        .uart_rx(uart_rx),
        .button(2'b11),
        .uart_tx(uart_tx),
        .led(led),
        .fb_we(fb_we),
        .fb_addr(fb_addr),
        .fb_wmask(fb_wmask),
        .fb_wdata(fb_wdata),
        .dbg_fb_writes(dbg_fb_writes),
        .dbg_uart_tx_count(dbg_uart_tx_count),
        .dbg_uart_rx_count(dbg_uart_rx_count)
    );

    icepi_fb_dvi video (
        .cpu_clk(clk),
        .cpu_we(fb_we),
        .cpu_addr(fb_addr),
        .cpu_wmask(fb_wmask),
        .cpu_wdata(fb_wdata),
        .pix_clk(pix_clk),
        .shift_clk(shift_clk),
        .rst(rst),
        .tmds(tmds)
    );
endmodule

`default_nettype wire
