// Shared register file and immediate shifter for the pipelined cores.

`default_nettype none

// Two synchronous one-read/one-write copies provide the two architectural
// read ports. Folding the collision choice into each registered read avoids
// separate bypass-data and bypass-valid registers in the block-RF build.
module riscc_fast_rf #(parameter integer XLEN = 16) (
    input  wire        clk,
    input  wire        read_en_a,
    input  wire        read_en_b,
    input  wire [3:0]  raddr_a,
    output wire [XLEN-1:0] rdata_a,
    input  wire [3:0]  raddr_b,
    output wire [XLEN-1:0] rdata_b,
    input  wire [3:0]  waddr,
    input  wire [XLEN-1:0] wdata,
    input  wire        we
);
`ifdef RISCC_FAST_BLOCK_RF
    (* ram_style = "block" *) reg [XLEN-1:0] mem_a [0:15];
    (* ram_style = "block" *) reg [XLEN-1:0] mem_b [0:15];
    reg  [XLEN-1:0] ram_rdata_a_q;
    reg  [XLEN-1:0] ram_rdata_b_q;

    assign rdata_a = ram_rdata_a_q;
    assign rdata_b = ram_rdata_b_q;

    always @(posedge clk) begin
        if (read_en_a)
            ram_rdata_a_q <= (we && (waddr == raddr_a)) ?
                             wdata : mem_a[raddr_a];
        if (read_en_b)
            ram_rdata_b_q <= (we && (waddr == raddr_b)) ?
                             wdata : mem_b[raddr_b];
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`else
`ifdef RISCC_ECP5
    (* ram_style = "distributed" *) reg [XLEN-1:0] mem_a [0:15];
    (* ram_style = "distributed" *) reg [XLEN-1:0] mem_b [0:15];
`else
    (* ramstyle = "MLAB, no_rw_check" *) reg [XLEN-1:0] mem_a [0:15];
    (* ramstyle = "MLAB, no_rw_check" *) reg [XLEN-1:0] mem_b [0:15];
`endif
    reg [XLEN-1:0] rdata_a_q;
    reg [XLEN-1:0] rdata_b_q;

    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    always @(posedge clk) begin
        if (read_en_a)
            rdata_a_q <= (we && (waddr == raddr_a)) ? wdata : mem_a[raddr_a];
        if (read_en_b)
            rdata_b_q <= (we && (waddr == raddr_b)) ? wdata : mem_b[raddr_b];
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`endif
endmodule

// Shared 1..8-bit immediate shifter. Align either direction in one input
// window, then discard unused bits at each right-shift stage. Decode supplies
// offset = count-1 for right shifts, or 8-count for left shifts.
module riscc_fast_shift #(parameter integer XLEN = 16) (
    input wire [XLEN-1:0] value, other,
    input wire [2:0] offset,
    input wire left, arithmetic, funnel,
    output wire [XLEN-1:0] result
);
    wire right_fill = funnel ? other[0] : (arithmetic && value[XLEN-1]);
    wire left_fill = funnel && other[XLEN-1];
    wire [XLEN+6:0] window = left ?
        {value[XLEN-2:0], left_fill, 7'b0} :
        {{8{right_fill}}, value[XLEN-1:1]};
    // Coarse stages first keep the following mux banks narrow.
    wire [XLEN+2:0] s4 = offset[2] ? window[XLEN+6:4] : window[XLEN+2:0];
    wire [XLEN:0] s2 = offset[1] ? s4[XLEN+2:2] : s4[XLEN:0];
    wire [XLEN-1:0] s1 = offset[0] ? s2[XLEN:1] : s2[XLEN-1:0];
    assign result = s1;
endmodule

`default_nettype wire
