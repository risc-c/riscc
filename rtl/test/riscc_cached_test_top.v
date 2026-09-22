// Test wrapper for the split instruction/data Fast cache hierarchy.
//
// The C++ Fast fixture predates the split ports and supplies a 16-bit,
// halfword-addressed Wishbone-like port.  riscc_cached uses one 32-bit
// backing port for both caches.  This wrapper serializes each backing word
// into the low and high halfword transactions expected by the fixture.  The
// wrapper owns one backing request at a time; a full-word read or write takes
// two halfword transfers, while a byte/halfword or high-half MMIO transfer
// only takes the enabled lane.

`default_nettype none

module riscc_cached_test_top #(
    parameter integer XLEN = 16,
    // The C++ fixture maps MMIO in byte addresses with bit 15 set on both
    // RC16 and RC32 configurations.
    parameter integer DCACHE_UNCACHED_BIT = 15
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             irq,

    output wire [XLEN-2:0]  mem_addr,
    input  wire [15:0]      mem_rdata,
    output wire [15:0]      mem_wdata,
    output wire [1:0]       mem_wmask,
    output wire             mem_we,
    output wire             mem_cyc,
    output wire             mem_stb,
    input  wire             mem_stall,
    input  wire             mem_ack
);
    wire [XLEN-3:0] back_addr;
    wire [31:0] back_wdata;
    wire [31:0] back_rdata;
    wire [3:0]  back_wmask;
    wire        back_we;
    wire        back_cyc;
    wire        back_stb;
    wire        back_stall;
    wire        back_ack;

    riscc_cached #(
        .XLEN(XLEN),
        .DCACHE_UNCACHED_BIT(DCACHE_UNCACHED_BIT)
    ) cached (
        .clk(clk),
        .rst(rst),
        .irq(irq),
        .mem_cacheable(), .mem_addr(back_addr),
        .mem_wdata(back_wdata),
        .mem_rdata(back_rdata),
        .mem_wmask(back_wmask),
        .mem_we(back_we),
        .mem_cyc(back_cyc),
        .mem_stb(back_stb),
        .mem_stall(back_stall),
        .mem_ack(back_ack)
    );

    reg active_q, half_pending_q, high_half_q, need_high_q;
    reg [XLEN-3:0] addr_q;
    reg [31:0] wdata_q, rdata_q;
    reg [3:0] wmask_q;
    reg we_q, ack_q;
    reg [15:0] low_rdata_q;
    wire accept = back_cyc && back_stb && !back_stall;
    wire half_accept = mem_stb && !mem_stall;
    wire half_response = mem_ack && (half_pending_q || half_accept);
    assign mem_addr = {addr_q, high_half_q};
    assign mem_wdata = high_half_q ? wdata_q[31:16] : wdata_q[15:0];
    assign mem_wmask = high_half_q ? wmask_q[3:2] : wmask_q[1:0];
    assign mem_we = we_q;
    assign mem_cyc = !rst && active_q;
    assign mem_stb = mem_cyc && !half_pending_q;
    assign back_stall = active_q || ack_q;
    assign back_ack = ack_q;
    assign back_rdata = rdata_q;

    // Register the adapter boundary so fixture response timing cannot feed
    // the cache's next command combinationally. This latency belongs to the
    // test adapter; native-width SRAM benchmarks do not instantiate it.
    always @(posedge clk) begin
        if (rst) begin
            active_q <= 0;
            half_pending_q <= 0;
            high_half_q <= 0;
            need_high_q <= 0;
            ack_q <= 0;
        end else begin
            ack_q <= 0;
            if (accept) begin
                active_q <= 1;
                addr_q <= back_addr;
                wdata_q <= back_wdata;
                wmask_q <= back_wmask;
                we_q <= back_we;
                high_half_q <= !(|back_wmask[1:0]);
                need_high_q <= |back_wmask[3:2];
            end
            if (half_accept) half_pending_q <= !mem_ack;
            if (half_response) begin
                half_pending_q <= 0;
                if (!high_half_q) low_rdata_q <= mem_rdata;
                if (!high_half_q && need_high_q) begin
                    high_half_q <= 1;
                end else begin
                    active_q <= 0;
                    ack_q <= 1;
                    rdata_q <= high_half_q ? {mem_rdata, low_rdata_q} : {16'b0, mem_rdata};
                end
            end
        end
    end

endmodule

`default_nettype wire
