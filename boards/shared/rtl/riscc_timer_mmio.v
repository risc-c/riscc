`timescale 10ns/10ns
`default_nettype none

// A free-running 16-bit low-rate tick counter plus a one-shot 16-bit timer.
// TICK_DIV system clocks make one timer tick, so a board chooses its timebase
// without adding an architecturally visible prescaler register.
module riscc_timer_mmio #(
    parameter integer TICK_DIV = 1,
    parameter integer PIPELINE_WRITES = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_addr,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,
    output wire        irq
);
    // Direction disambiguates the one-shot command from the elapsed time:
    // write byte 0xfff4 to arm/rearm; read it to obtain free-running ticks.
    localparam [3:0] TIMER_W = 4'ha; // byte 0xfff4
    localparam integer DIV_BITS = (TICK_DIV <= 1) ? 1 : $clog2(TICK_DIV);

    localparam [DIV_BITS-1:0] TICK_DIV_LAST =
        TICK_DIV[DIV_BITS-1:0] - {{(DIV_BITS-1){1'b0}}, 1'b1};

    reg [15:0] count_q;
    reg        pending_q;
    reg [DIV_BITS-1:0] div_q;
    reg [15:0] ticks_q;
    wire timer_sel = cpu_addr == TIMER_W;
    wire write_fire;
    wire [3:0] write_addr;
    wire [15:0] write_data;
    generate
        if (PIPELINE_WRITES != 0) begin : g_pipeline_writes
            reg write_q;
            reg [3:0] write_addr_q;
            reg [15:0] write_data_q;
            always @(posedge clk) begin
                if (rst) begin
                    write_q <= 1'b0;
                    write_addr_q <= 4'h0;
                    write_data_q <= 16'h0000;
                end else begin
                    write_q <= cpu_we;
                    write_addr_q <= cpu_addr;
                    write_data_q <= cpu_wdata;
                end
            end
            assign write_fire = write_q;
            assign write_addr = write_addr_q;
            assign write_data = write_data_q;
        end else begin : g_direct_writes
            assign write_fire = cpu_we;
            assign write_addr = cpu_addr;
            assign write_data = cpu_wdata;
        end
    endgenerate
    wire count_write = write_fire && (write_addr == TIMER_W);
    wire tick_pulse = (TICK_DIV <= 1) || (div_q == {DIV_BITS{1'b0}});
    wire count_active = |count_q;
    wire count_last = count_q[0] && !(|count_q[15:1]);

    assign cpu_rdata = timer_sel ? ticks_q : 16'h0000;
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
                count_q <= write_data;
                pending_q <= 1'b0;
            end else if (tick_pulse && count_active) begin
                count_q <= count_q - 1'b1;
                if (count_last)
                    pending_q <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
