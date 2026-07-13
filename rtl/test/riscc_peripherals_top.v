`timescale 10ns/10ns
`default_nettype none

module riscc_peripherals_top #(
    parameter integer TICK_DIV = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_addr,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,
    input  wire        uart_irq,
    output wire        timer_irq,
    output wire        cpu_irq
);
    wire [15:0] timer_rdata;
    wire [15:0] irq_rdata;

    riscc_timer_mmio #(.TICK_DIV(TICK_DIV)) timer (
        .clk(clk), .rst(rst), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(timer_rdata), .irq(timer_irq)
    );

    riscc_irq_ctrl irq_ctrl (
        .clk(clk), .rst(rst), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(irq_rdata),
        .sources({timer_irq, uart_irq}), .irq(cpu_irq)
    );

    assign cpu_rdata = timer_rdata | irq_rdata;
endmodule

`default_nettype wire
