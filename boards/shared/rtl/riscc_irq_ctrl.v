`timescale 10ns/10ns
`default_nettype none

// Two-source level interrupt mask.  Source state belongs to its peripheral:
// UART RX is consumed by a read and the one-shot timer is rearmed by a write.
module riscc_irq_ctrl #(
    parameter integer REGISTER_IRQ = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_addr,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,
    input  wire [1:0]  sources,
    output wire        irq
);
    localparam [3:0] IRQ_PENDING_W = 4'h0; // byte 0xffe0
    localparam [3:0] IRQ_ENABLE_W  = 4'h1; // byte 0xffe2

    reg [1:0] enable_q;
    wire enable_write = cpu_we && (cpu_addr == IRQ_ENABLE_W);
    wire irq_next = |(sources & enable_q);

    assign cpu_rdata =
        (cpu_addr == IRQ_PENDING_W) ? {14'h0000, sources} :
        (cpu_addr == IRQ_ENABLE_W) ? {14'h0000, enable_q} :
        16'h0000;

    always @(posedge clk) begin
        if (rst)
            enable_q <= 2'b00;
        else if (enable_write)
            enable_q <= cpu_wdata[1:0];
    end

    generate
        if (REGISTER_IRQ != 0) begin : g_registered_irq
            reg irq_q;
            always @(posedge clk) begin
                if (rst)
                    irq_q <= 1'b0;
                else
                    irq_q <= irq_next;
            end
            assign irq = irq_q;
        end else begin : g_combinational_irq
            assign irq = irq_next;
        end
    endgenerate
endmodule

`default_nettype wire
