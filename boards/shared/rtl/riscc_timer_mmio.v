`timescale 10ns/10ns
`default_nettype none

// A free-running 16-bit low-rate tick counter plus a one-shot 16-bit timer.
// TICK_DIV system clocks make one timer tick, so a board chooses its timebase
// without adding an architecturally visible prescaler register.
module riscc_timer_mmio #(
    parameter integer TICK_DIV = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_addr,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,
    output wire        irq
);
    localparam [3:0] TIMER_COUNT_W = 4'h2; // byte 0xffe4
    localparam [3:0] TICKS_W       = 4'h3; // byte 0xffe6
    localparam integer DIV_BITS = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

    localparam [DIV_BITS-1:0] TICK_DIV_LAST =
        TICK_DIV[DIV_BITS-1:0] - {{(DIV_BITS-1){1'b0}}, 1'b1};

    reg [15:0] count_q;
    reg        pending_q;
    reg [DIV_BITS-1:0] div_q;
    reg [15:0] ticks_q;
    wire count_write = cpu_we && (cpu_addr == TIMER_COUNT_W);
    wire tick_pulse = (TICK_DIV <= 1) || (div_q == {DIV_BITS{1'b0}});

    assign cpu_rdata =
        (cpu_addr == TIMER_COUNT_W) ? count_q :
        (cpu_addr == TICKS_W) ? ticks_q :
        16'h0000;
    assign irq = pending_q;

    always @(posedge clk) begin
        if (rst) begin
            count_q <= 16'h0000;
            pending_q <= 1'b0;
            div_q <= TICK_DIV_LAST;
            ticks_q <= 16'd0;
        end else begin
            if (tick_pulse) begin
                div_q <= TICK_DIV_LAST;
                ticks_q <= ticks_q + 1'b1;
            end else begin
                div_q <= div_q - 1'b1;
            end

            if (count_write) begin
                count_q <= cpu_wdata;
                pending_q <= 1'b0;
            end else if (tick_pulse && (count_q != 16'h0000)) begin
                count_q <= count_q - 1'b1;
                if (count_q == 16'h0001)
                    pending_q <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
