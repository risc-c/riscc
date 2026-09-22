// riscc_irq_ctrl.v : shared two-source interrupt mask and aggregator.

`timescale 10ns/10ns
`default_nettype none

// Two-source level interrupt mask. Source state belongs to its peripheral:
// UART RX is consumed by a read and the one-shot timer is rearmed by a write.
module riscc_irq_ctrl #(
    parameter integer REGISTER_IRQ = 0,
    parameter integer DATA_WIDTH = 16,
    parameter integer PIPELINE_WRITES = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_we,
    // Word index: 2-byte spacing on RC16, 4-byte spacing on RC32 boards.
    input  wire [3:0]  cpu_addr,
    input  wire [DATA_WIDTH-1:0] cpu_wdata,
    output wire [DATA_WIDTH-1:0] cpu_rdata,
    input  wire [1:0]  sources,
    output wire        irq
);
    // Direction disambiguates the source state from its enable mask.
    localparam [3:0] IRQ_STATE_W = 4'hb; // slot 11: pending/enables

    reg [1:0] enable_q;
    wire enable_write;
    wire [1:0] write_data;
    generate
        if (PIPELINE_WRITES != 0) begin : g_pipeline_writes
            reg write_q;
            reg [1:0] write_data_q;
            always @(posedge clk) begin
                write_q <= !rst && cpu_we && (cpu_addr == IRQ_STATE_W);
                write_data_q <= cpu_wdata[1:0];
            end
            assign enable_write = write_q;
            assign write_data = write_data_q;
        end else begin : g_direct_writes
            assign enable_write = cpu_we && (cpu_addr == IRQ_STATE_W);
            assign write_data = cpu_wdata[1:0];
        end
    endgenerate
    wire irq_next = |(sources & enable_q);

    assign cpu_rdata =
        (cpu_addr == IRQ_STATE_W) ? {{(DATA_WIDTH-2){1'b0}}, sources} :
        {DATA_WIDTH{1'b0}};

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
