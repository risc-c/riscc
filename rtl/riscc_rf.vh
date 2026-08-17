`ifndef RISCC_RF_VH
`define RISCC_RF_VH

// Shared synchronous register file. WIDTH selects bits per cycle and
// ADDR_WIDTH selects the slice count: RC16 holds 256 bits, RC32 512, Nano 128.
module riscc_rf #(
    parameter integer WIDTH = 1,
    parameter integer ADDR_WIDTH = 8
) (
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output wire [WIDTH-1:0]      rdata,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [WIDTH-1:0]      wdata,
    input  wire                  we
);
    localparam integer DEPTH = 1 << ADDR_WIDTH;

`ifdef RISCC_ECP5
`ifdef RISCC_ECP5_BLOCK_RF
    // Select explicitly when the single 18-kbit sysMEM block is preferable to
    // distributed RAM.  This preserves the original ECP5 implementation and
    // makes the block-RAM/LUTRAM trade measurable from one RTL source.
    // A write-address collision can occur only while the corresponding read
    // result is dead.  Let the mapper use the block RAM's native collision
    // behavior instead of adding a read-first bypass network.
    (* ram_style = "block", no_rw_check *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] rdata_q;

    assign rdata = rdata_q;

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata_q <= mem[raddr];
    end
`else
    // ECP5's DPR16X4 LUTRAM stores 16 four-bit words.  A direct WIDTH x
    // DEPTH inference would use 16 LUTRAMs at /1 and eight at /2, because it
    // preserves the narrow, deep logical shape.  Pack only up to the
    // primitive's native four data bits instead: the 256-bit mainline RF uses
    // four DPR16X4s at /1, /2, /4, /8, and /16; Nano's 128-bit RF uses two.
    // This is also important for multiplier writeback, which must become
    // visible between serial passes.
    generate
        localparam integer RAM_WORD_WIDTH = 4;

        if (WIDTH < RAM_WORD_WIDTH) begin : g_ecp5_lutram_packed
            localparam integer SUBWORDS = RAM_WORD_WIDTH / WIDTH;
            localparam integer SUB_BITS = $clog2(SUBWORDS);
            localparam integer WORD_ADDR_WIDTH = ADDR_WIDTH - SUB_BITS;
            localparam integer WORD_DEPTH = 1 << WORD_ADDR_WIDTH;

            // A logical write sequence always visits the subwords from low
            // to high.  Byte-lane rotation alters WORD_ADDR, not that order.
            (* ram_style = "distributed" *)
            reg [RAM_WORD_WIDTH-1:0] mem [0:WORD_DEPTH-1];
            reg [RAM_WORD_WIDTH-1:0] read_word_q;
            reg [SUB_BITS-1:0] read_subword_q;
            reg [RAM_WORD_WIDTH-WIDTH-1:0] write_accum_q;
            wire [RAM_WORD_WIDTH-1:0] completed_write_word =
                {wdata, write_accum_q};

            assign rdata = read_word_q[read_subword_q * WIDTH +: WIDTH];

            always @(posedge clk) begin
                read_word_q <= mem[raddr[ADDR_WIDTH-1:SUB_BITS]];
                read_subword_q <= raddr[SUB_BITS-1:0];
                if (we) begin
                    write_accum_q <=
                        completed_write_word[RAM_WORD_WIDTH-1:WIDTH];
                    if (&waddr[SUB_BITS-1:0])
                        mem[waddr[ADDR_WIDTH-1:SUB_BITS]] <=
                            completed_write_word;
                end
            end
        end else begin : g_ecp5_lutram_native
            // /4, /8, and /16 use the LUTRAM's native write granularity.
            // The core either avoids a same-address collision or discards its
            // result before reissuing the read.
            (* ram_style = "distributed" *)
            reg [WIDTH-1:0] mem [0:DEPTH-1];
            reg [WIDTH-1:0] rdata_q;

            assign rdata = rdata_q;

            always @(posedge clk) begin
                if (we)
                    mem[waddr] <= wdata;
                rdata_q <= mem[raddr];
            end
        end
    endgenerate
`endif
`elsif RISCC_INFERRED_SYNC_RF
    generate
        localparam integer RF_BITS = WIDTH * DEPTH;
        if ((RF_BITS > 256) && (WIDTH < 16)) begin : g_word_packed
            // RC32 contains 512 bits. Pack it into the MLAB's 32x16 shape
            // instead of preserving a 64x8 shape that needs two blocks.
            localparam integer RAM_WORD_WIDTH = 16;
            localparam integer SUBWORDS = RAM_WORD_WIDTH / WIDTH;
            localparam integer SUB_BITS = $clog2(SUBWORDS);
            localparam integer WORD_ADDR_WIDTH = ADDR_WIDTH - SUB_BITS;
            localparam integer WORD_DEPTH = 1 << WORD_ADDR_WIDTH;
            localparam integer BYTE_SUB_BITS = $clog2(8 / WIDTH);
            localparam [ADDR_WIDTH-1:0] BYTE_LAST =
                {ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - BYTE_SUB_BITS);

            (* ramstyle = "MLAB, no_rw_check" *)
            reg [RAM_WORD_WIDTH-1:0] mem [0:WORD_DEPTH-1];
            reg [RAM_WORD_WIDTH-1:0] read_word_q;
            reg [SUB_BITS-1:0] read_subword_q;
            reg [7:0] write_accum_q;
            wire [7:0] extended_wdata = {{(8-WIDTH){1'b0}}, wdata};
            wire [7:0] completed_write_byte =
                (write_accum_q >> WIDTH) |
                (extended_wdata << (8-WIDTH));
            wire byte_complete = (waddr & BYTE_LAST) == BYTE_LAST;

            // Commit one byte at a time. This directly follows byte-load lane
            // rotation and avoids both a 16-bit accumulator and a byte swap.
            // Quartus maps the two fixed byte lanes into one 32x16 MLAB.

            assign rdata = read_word_q[read_subword_q * WIDTH +: WIDTH];

            always @(posedge clk) begin
                read_word_q <= mem[raddr[ADDR_WIDTH-1:SUB_BITS]];
                read_subword_q <= raddr[SUB_BITS-1:0];
                if (we) begin
                    write_accum_q <= completed_write_byte;
                    if (byte_complete) begin
                        if (waddr[SUB_BITS-1])
                            mem[waddr[ADDR_WIDTH-1:SUB_BITS]][15:8] <=
                                completed_write_byte;
                        else
                            mem[waddr[ADDR_WIDTH-1:SUB_BITS]][7:0] <=
                                completed_write_byte;
                    end
                end
            end
        end else if (WIDTH < 8) begin : g_byte_packed
            localparam integer SUBWORDS = 8 / WIDTH;
            localparam integer SUB_BITS = $clog2(SUBWORDS);
            localparam integer WORD_ADDR_WIDTH = ADDR_WIDTH - SUB_BITS;
            localparam integer WORD_DEPTH = 1 << WORD_ADDR_WIDTH;

            // RC16 and Nano fit one MLAB as 32x8 or smaller. Their byte-lane
            // rotation changes the word address, not the subword order.
            (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] mem [0:WORD_DEPTH-1];
            reg [7:0] read_word_q;
            reg [SUB_BITS-1:0] read_subword_q;
            reg [7-WIDTH:0] write_accum_q;
            wire [7:0] completed_write_word = {wdata, write_accum_q};

            assign rdata = read_word_q[read_subword_q * WIDTH +: WIDTH];

            always @(posedge clk) begin
                read_word_q <= mem[raddr[ADDR_WIDTH-1:SUB_BITS]];
                read_subword_q <= raddr[SUB_BITS-1:0];
                if (we) begin
                    write_accum_q <= completed_write_word[7:WIDTH];
                    if (&waddr[SUB_BITS-1:0])
                        mem[waddr[ADDR_WIDTH-1:SUB_BITS]] <= completed_write_word;
                end
            end
        end else begin : g_native_width
            // The core either avoids a same-address collision or discards its
            // result before reissuing the read.
            (* ramstyle = "MLAB, no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
            reg [WIDTH-1:0] rdata_q;

            assign rdata = rdata_q;

            always @(posedge clk) begin
                if (we)
                    mem[waddr] <= wdata;
                rdata_q <= mem[raddr];
            end
        end
    endgenerate
`elsif SYNTHESIS
    generate
        if (WIDTH == 1) begin : g_ice40_w1
            wire [15:0] ram_rdata;
            wire [10:0] raddr_phys = {{(11-ADDR_WIDTH){1'b0}}, raddr};
            wire [10:0] waddr_phys = {{(11-ADDR_WIDTH){1'b0}}, waddr};

            assign rdata[0] = ram_rdata[1];

            SB_RAM40_4K #(
                .READ_MODE(2),
                .WRITE_MODE(2)
            ) ram (
                .RDATA(ram_rdata),
                .RADDR(raddr_phys),
                .RCLK(clk),
                .RCLKE(1'b1),
                .RE(1'b1),
                .WADDR(waddr_phys),
                .WCLK(clk),
                .WCLKE(1'b1),
                .WE(we),
                .MASK(16'h0000),
                .WDATA({14'b0000_0000_0000_00, wdata[0], 1'b0})
            );
        end else if (WIDTH == 8) begin : g_ice40_w8
            wire [10:0] raddr_phys = {{(11-ADDR_WIDTH){1'b0}}, raddr};
            wire [10:0] waddr_phys = {{(11-ADDR_WIDTH){1'b0}}, waddr};
            wire [15:0] rdata16;

            assign rdata = {rdata16[14], rdata16[12], rdata16[10], rdata16[8],
                            rdata16[6],  rdata16[4],  rdata16[2],  rdata16[0]};

            SB_RAM40_4K #(
                .READ_MODE(1),
                .WRITE_MODE(1)
            ) ram (
                .RDATA(rdata16),
                .RADDR(raddr_phys),
                .RCLK(clk),
                .RCLKE(1'b1),
                .RE(1'b1),
                .WADDR(waddr_phys),
                .WCLK(clk),
                .WCLKE(1'b1),
                .WE(we),
                .MASK(16'h0000),
                .WDATA({1'b0, wdata[7], 1'b0, wdata[6], 1'b0, wdata[5], 1'b0,
                        wdata[4], 1'b0, wdata[3], 1'b0, wdata[2], 1'b0,
                        wdata[1], 1'b0, wdata[0]})
            );
        end else if (WIDTH == 16) begin : g_ice40_w16
            wire [10:0] raddr_phys = {{(11-ADDR_WIDTH){1'b0}}, raddr};
            wire [10:0] waddr_phys = {{(11-ADDR_WIDTH){1'b0}}, waddr};

            SB_RAM40_4K #(
                .READ_MODE(0),
                .WRITE_MODE(0)
            ) ram (
                .RDATA(rdata),
                .RADDR(raddr_phys),
                .RCLK(clk),
                .RCLKE(1'b1),
                .RE(1'b1),
                .WADDR(waddr_phys),
                .WCLK(clk),
                .WCLKE(1'b1),
                .WE(we),
                .MASK(16'h0000),
                .WDATA(wdata)
            );
        end else begin : g_ice40_inferred
            (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
            reg [WIDTH-1:0] rdata_q;

            assign rdata = rdata_q;

            always @(posedge clk) begin
                if (we)
                    mem[waddr] <= wdata;
                rdata_q <= mem[raddr];
            end
        end
    endgenerate
`else
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] rdata_q;

    assign rdata = rdata_q;

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata_q <= mem[raddr];
    end
`endif
endmodule

`endif
