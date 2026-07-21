`timescale 10ns/10ns
`default_nettype none

module atum_a3_nano_soc_sim #(
    parameter MEM_HEX = "build/atum_a3_nano/mem/demo.memh",
    parameter integer UART_CLK_DIV = 8,
    parameter integer TIMER_TICK_DIV = 225000
) (
    input wire clk,
    input wire rst,
    input wire uart_rx,
    output wire uart_tx,
    output wire [3:0] led,
    output wire dbg_fb_we,
    output wire [14:0] dbg_fb_addr,
    output wire [15:0] dbg_fb_wdata,
    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    wire [1:0] fb_wmask;

    atum_a3_nano_soc #(
        .MEM_HEX(MEM_HEX),
        .UART_CLK_DIV(UART_CLK_DIV),
        .TIMER_TICK_DIV(TIMER_TICK_DIV)
    ) soc (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .button(2'b11),
        .uart_tx(uart_tx), .led(led), .fb_we(dbg_fb_we),
        .fb_addr(dbg_fb_addr), .fb_wmask(fb_wmask), .fb_wdata(dbg_fb_wdata),
        .dbg_fb_writes(dbg_fb_writes), .dbg_uart_tx_count(dbg_uart_tx_count),
        .dbg_uart_rx_count(dbg_uart_rx_count)
    );
endmodule

`default_nettype wire
