// Minimal registered harness for routed core-only timing measurements.
`default_nettype none

module riscc_fmax_top (
    input  wire clk,
    output wire keep
);
    reg [3:0] reset_q = 4'h0;
    reg       irq_q = 1'b0;
    reg [15:0] mem_rdata_q = 16'h1;
    wire rst = ~reset_q[3];
    wire [14:0] mem_addr;
    wire [15:0] mem_wdata;
    wire [1:0] mem_wmask;
    wire mem_we;

    always @(posedge clk) begin
        reset_q <= {reset_q[2:0], 1'b1};
        irq_q <= irq_q ^ mem_addr[0] ^ mem_we;
        mem_rdata_q <= {mem_rdata_q[14:0], mem_rdata_q[15] ^ mem_rdata_q[13]} ^
                       {1'b0, mem_addr};
    end

`ifdef RISCC_FMAX_FASTER
    riscc_faster cpu (
`elsif RISCC_FMAX_FAST
    riscc_fast cpu (
`elsif RISCC_FMAX_NANO
    wire mem_valid;

    riscc_nano1 cpu (
        .mem_valid(mem_valid),
`elsif RISCC_FMAX_TINY
`ifdef RISCC_FMAX_MIN
    riscc_tiny_min #(
`else
    riscc_tiny #(
`endif
        .W(`RISCC_FMAX_WIDTH)
    ) cpu (
`else
    riscc_tiny16 cpu (
`endif
        .clk(clk),
        .rst(rst),
        .irq(irq_q),
        .mem_addr(mem_addr),
        .mem_rdata(mem_rdata_q),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_we(mem_we)
    );

    assign keep = ^{mem_addr, mem_wdata, mem_wmask, mem_we, mem_rdata_q
`ifndef RISCC_FMAX_FAST
`ifdef RISCC_FMAX_NANO
                    , mem_valid
`endif
`endif
                   };
endmodule

`default_nettype wire
