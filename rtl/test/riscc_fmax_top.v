// riscc_fmax_top.v : registered harness for routed core-only timing.
// Not a board top: device configuration reset belongs to the board design.

`default_nettype none

module riscc_fmax_top (
    input  wire clk,
    output wire keep
);
`ifdef RISCC_FMAX_CACHED32
`define RISCC_FMAX_CACHED_CORE
    localparam integer XLEN = 32;
`elsif RISCC_FMAX_CACHED
`define RISCC_FMAX_CACHED_CORE
    localparam integer XLEN = 16;
`endif
`ifdef RISCC_FMAX_CACHED_CORE
    reg [3:0] reset_q = 0;
    wire rst = !reset_q[3];
    reg irq_q = 0;
    wire [XLEN-3:0] addr;
    wire [31:0] wdata;
    wire [3:0] sel;
    wire we, cyc, stb;
    reg ack_q = 0;
    reg [31:0] rdata_q = 1;
    wire [31:0] address_mix = {{(34-XLEN){1'b0}}, addr};
    always @(posedge clk) begin
        reset_q <= {reset_q[2:0], 1'b1};
        irq_q <= irq_q ^ addr[0] ^ we;
        ack_q <= !rst && cyc && stb;
        if (cyc && stb)
            rdata_q <= {rdata_q[30:0], rdata_q[31] ^ rdata_q[21]} ^ address_mix;
    end
    riscc_cached #(.XLEN(XLEN)) cpu (
        .clk(clk), .rst(rst), .irq(irq_q),
        .mem_addr(addr), .mem_rdata(rdata_q), .mem_wdata(wdata),
        .mem_wmask(sel), .mem_we(we), .mem_cyc(cyc), .mem_stb(stb),
        .mem_stall(1'b0), .mem_ack(ack_q)
    );
    assign keep = ^{addr, wdata, sel, we, cyc, stb, rdata_q};
`undef RISCC_FMAX_CACHED_CORE
`else
    reg [3:0] reset_q = 4'h0;
    reg       irq_q = 1'b0;
    reg [15:0] mem_rdata_q = 16'h1;
    wire rst = ~reset_q[3];
`ifdef RISCC_FMAX_FAST32
    wire [31:0] mem_addr;
    wire [30:0] fast_mem_addr;
    assign mem_addr = {1'b0, fast_mem_addr};
`elsif RISCC_FMAX_WIDE
    wire [31:0] mem_addr;
    wire [`RISCC_FMAX_WIDE_XLEN-2:0] wide_mem_addr;
    assign mem_addr = {{(33-`RISCC_FMAX_WIDE_XLEN){1'b0}}, wide_mem_addr};
`elsif RISCC_FMAX_SERIAL
    // Keep the harness address bus at 32 bits.  The serial core exposes
    // XLEN-1 address bits, so the unused high bits are explicit zeroes.
    wire [31:0] mem_addr;
    wire [`RISCC_FMAX_SERIAL_XLEN-2:0] serial_mem_addr;
    assign mem_addr = {{(33-`RISCC_FMAX_SERIAL_XLEN){1'b0}},
                       serial_mem_addr};
`else
    wire [14:0] mem_addr;
`endif
    wire [15:0] mem_wdata;
    wire [1:0] mem_wmask;
    wire mem_we;
    wire mem_request;
`ifdef RISCC_FMAX_FAST32
`define RISCC_FMAX_FAST_BUS
`elsif RISCC_FMAX_FAST
`define RISCC_FMAX_FAST_BUS
`endif
`ifdef RISCC_FMAX_FAST_BUS
    wire mem_cyc;
    wire mem_stb;
    wire mem_stall = 1'b0;
    wire mem_ack;
    reg  mem_ack_q;
    wire mem_accept = mem_cyc && mem_stb && !rst;
`endif

    always @(posedge clk) begin
        reset_q <= {reset_q[2:0], 1'b1};
        irq_q <= irq_q ^ mem_addr[0] ^ mem_we;
`ifdef RISCC_FMAX_FAST_BUS
        if (rst)
            mem_ack_q <= 1'b0;
        else
            mem_ack_q <= mem_accept;
`endif
`ifdef RISCC_FMAX_FAST32
        if (mem_accept)
            mem_rdata_q <= {mem_rdata_q[14:0], mem_rdata_q[15] ^ mem_rdata_q[13]} ^
                       mem_addr[15:0] ^ mem_addr[31:16];
`elsif RISCC_FMAX_FAST
        if (mem_accept)
            mem_rdata_q <= {mem_rdata_q[14:0], mem_rdata_q[15] ^ mem_rdata_q[13]} ^
                       {1'b0, mem_addr};
`else
        mem_rdata_q <= {mem_rdata_q[14:0], mem_rdata_q[15] ^ mem_rdata_q[13]} ^
`ifdef RISCC_FMAX_WIDE
                       mem_addr[15:0] ^ mem_addr[31:16];
`elsif RISCC_FMAX_SERIAL
                       mem_addr[15:0] ^ mem_addr[31:16];
`else
                       {1'b0, mem_addr};
`endif
`endif
    end

`ifdef RISCC_FMAX_FAST32
    riscc_fast #(.XLEN(32)) cpu (
`elsif RISCC_FMAX_FAST
    riscc_fast cpu (
`elsif RISCC_FMAX_NANO
    riscc_nano cpu (
`elsif RISCC_FMAX_WIDE
    riscc_wide #(
        .XLEN(`RISCC_FMAX_WIDE_XLEN),
        .PROFILE(`RISCC_FMAX_WIDE_PROFILE),
        .MDU(`RISCC_FMAX_WIDE_MDU)
    ) cpu (
`elsif RISCC_FMAX_SERIAL
    riscc_serial #(
        .XLEN(`RISCC_FMAX_SERIAL_XLEN),
        .W(`RISCC_FMAX_SERIAL_W),
        .PROFILE(`RISCC_FMAX_SERIAL_PROFILE)
    ) cpu (
`else
    riscc_wide #(.XLEN(16), .PROFILE(1)) cpu (
`endif
        .clk(clk),
        .rst(rst),
        .irq(irq_q),
`ifdef RISCC_FMAX_FAST32
        .mem_addr(fast_mem_addr),
`elsif RISCC_FMAX_WIDE
        .mem_addr(wide_mem_addr),
`elsif RISCC_FMAX_SERIAL
        .mem_addr(serial_mem_addr),
`else
        .mem_addr(mem_addr),
`endif
        .mem_rdata(mem_rdata_q),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_we(mem_we),
`ifdef RISCC_FMAX_NANO
        .mem_oe_n(mem_request)
`elsif RISCC_FMAX_FAST32
        .mem_cyc(mem_cyc),
        .mem_stb(mem_stb),
        .mem_stall(mem_stall),
        .mem_ack(mem_ack)
`elsif RISCC_FMAX_FAST
        .mem_cyc(mem_cyc),
        .mem_stb(mem_stb),
        .mem_stall(mem_stall),
        .mem_ack(mem_ack)
`else
        .mem_valid(mem_request),
        .mem_ready(mem_rdata_q[0])
`endif
    );

`ifdef RISCC_FMAX_FAST_BUS
    assign mem_ack = mem_ack_q;
    assign mem_request = mem_cyc && mem_stb;
`undef RISCC_FMAX_FAST_BUS
`endif

    assign keep = ^{mem_addr, mem_wdata, mem_wmask, mem_we, mem_request,
                    mem_rdata_q};
`endif

endmodule

`default_nettype wire
