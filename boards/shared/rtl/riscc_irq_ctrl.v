`timescale 10ns/10ns
`default_nettype none

// Two-source level interrupt mask.  Source state belongs to its peripheral:
// UART RX is consumed by a read and the one-shot timer is rearmed by a write.
module riscc_irq_ctrl #(
    parameter integer REGISTER_IRQ = 0,
    parameter integer PIPELINE_WRITES = 0
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
    // Direction disambiguates the source state from its enable mask.
    localparam [3:0] IRQ_STATE_W = 4'hb; // byte 0xfff6: read pending, write enables

    reg [1:0] enable_q;
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
    wire enable_write = write_fire && (write_addr == IRQ_STATE_W);
    wire irq_next = |(sources & enable_q);

    assign cpu_rdata =
        (cpu_addr == IRQ_STATE_W) ? {14'h0000, sources} :
        16'h0000;

    always @(posedge clk) begin
        if (rst)
            enable_q <= 2'b00;
        else if (enable_write)
            enable_q <= write_data[1:0];
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
