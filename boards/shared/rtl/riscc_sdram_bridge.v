// CPU-to-SDRAM clock crossing. Cached reads transfer a whole line per handshake.
// The CPU is the only writer; every store invalidates the retained read line.
// Assert both resets together and release each synchronously in its domain.
`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_bridge #(
    parameter integer ADDR_BITS = 23,
    parameter integer READ_WORD_BITS = 0
) (
    input wire host_clk, host_rst, memory_clk, memory_rst,
    input wire [ADDR_BITS-1:0] host_addr,
    input wire [31:0] host_wdata,
    input wire [3:0] host_wmask,
    input wire host_we, host_cyc, host_stb,
    output wire host_stall, host_ready,
    output reg host_ack,
    output reg [31:0] host_rdata,
    output wire [ADDR_BITS-1:0] memory_addr,
    output wire [31:0] memory_wdata,
    output wire [3:0] memory_wmask,
    output wire memory_we, memory_cyc, memory_stb,
    input wire memory_stall, memory_ack, memory_ready,
    input wire [31:0] memory_rdata
);
    localparam integer WORDS = 1 << READ_WORD_BITS;
    localparam integer BEAT_BITS = READ_WORD_BITS == 0 ? 1 : READ_WORD_BITS;
    localparam [ADDR_BITS-1:0] LINE_MASK = {{(ADDR_BITS-READ_WORD_BITS){1'b0}}, {READ_WORD_BITS{1'b1}}};
    // Four RAM entries, with one kept free, hold three outstanding commands.
    // Gray pointers are also RAM addresses: 00 -> 01 -> 11 -> 10 -> 00.
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [ADDR_BITS-1:0] address [0:3];
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [35:0] payload [0:3];
    reg [3:0] writing;
    (* preserve *) reg [1:0] producer_gray_q, consumer_gray_q;
    (* async_reg = "true" *) reg [1:0] producer_meta_q, producer_sync_q;
    (* async_reg = "true" *) reg [1:0] consumer_meta_q, consumer_sync_q;
    (* async_reg = "true" *) reg [1:0] ready_sync_q;
    wire host_empty = producer_gray_q == consumer_sync_q;
    reg empty_q;
    wire [1:0] next_producer_gray = {producer_gray_q[0], ~producer_gray_q[1]};
    wire [1:0] next_consumer_gray = {consumer_gray_q[0], ~consumer_gray_q[1]};
    reg read_wait_q, line_valid_q;
    wire busy_q = !host_empty || read_wait_q;
    reg [31:0] line_data [0:WORDS-1];
    // Only the last read's address is needed to identify the retained line.
    // Store it once instead of giving every queued address a second RAM port.
    reg [ADDR_BITS-1:0] line_address;
    wire [ADDR_BITS-1:0] head_address = address[consumer_gray_q];
    wire [BEAT_BITS-1:0] host_word = host_addr[BEAT_BITS-1:0] & LINE_MASK[BEAT_BITS-1:0];
    wire [BEAT_BITS-1:0] reply_word = line_address[BEAT_BITS-1:0] & LINE_MASK[BEAT_BITS-1:0];
    wire line_hit = READ_WORD_BITS != 0 && line_valid_q && !host_we &&
        (host_addr >> READ_WORD_BITS) == (line_address >> READ_WORD_BITS);
    assign host_ready = ready_sync_q[1] && !host_rst;
    assign host_stall = !host_ready || read_wait_q ||
                        next_producer_gray == consumer_sync_q ||
                        (!host_we && !host_empty);
    always @(posedge host_clk) begin
        consumer_meta_q <= consumer_gray_q;
        consumer_sync_q <= consumer_meta_q;
        ready_sync_q <= {ready_sync_q[0], memory_ready};
        host_rdata <= line_data[read_wait_q ? reply_word : host_word];
        host_ack <= 0;
        // The unused entry is always free, even when all three credits are
        // occupied. Sampling it needs no request decode or write enable.
        address[producer_gray_q] <= host_addr;
        payload[producer_gray_q] <= {host_wmask, host_wdata};
        writing[producer_gray_q] <= host_we;
        if (host_cyc && host_stb && !host_stall) begin
            if (line_hit)
                host_ack <= 1;
            else begin
                producer_gray_q <= next_producer_gray;
                host_ack <= host_we;
                line_valid_q <= 0;
                if (!host_we) begin
                    line_address <= host_addr;
                    read_wait_q <= 1;
                end
            end
        end
        if (read_wait_q && host_empty) begin
            host_ack <= 1;
            read_wait_q <= 0;
            line_valid_q <= 1;
        end
        if (host_rst) begin
            producer_gray_q <= 0;
            consumer_meta_q <= 0;
            consumer_sync_q <= 0;
            ready_sync_q <= 0;
            read_wait_q <= 0;
            line_valid_q <= 0;
            host_ack <= 0;
        end
    end

    localparam integer PENULTIMATE = WORDS > 1 ? WORDS - 2 : 0;
    reg issued_last_q, request_valid_q, reply_last_q;
    reg [BEAT_BITS-1:0] issued_q, returned_q;
    reg head_write;
    wire last_issue = head_write || READ_WORD_BITS == 0 || (&issued_q);
    wire last_reply = head_write || READ_WORD_BITS == 0 || reply_last_q;
    wire issue_last = memory_stb && !memory_stall && last_issue;
    wire complete = !empty_q && memory_ack && last_reply;
    assign memory_addr = head_write ? head_address :
        (head_address & ~LINE_MASK) | {{(ADDR_BITS-BEAT_BITS){1'b0}}, issued_q};
    wire [3:0] head_mask;
    assign {head_mask, memory_wdata} = payload[consumer_gray_q];
    assign memory_wmask = head_write ? head_mask : 4'hf;
    assign memory_we = head_write;
    assign memory_cyc = !empty_q;
    assign memory_stb = request_valid_q;
    wire current_write = writing[consumer_gray_q];
    wire next_write = writing[next_consumer_gray];
    always @(posedge memory_clk) begin
        // Select the current head, or the next head after completion.
        head_write <= complete ? next_write : current_write;
        producer_meta_q <= producer_gray_q;
        producer_sync_q <= producer_meta_q;
        empty_q <= (consumer_gray_q == producer_sync_q) ||
                   (complete && next_consumer_gray == producer_sync_q);
        // Keep issuing while the current command or a replacement is active.
        request_valid_q <= memory_ready &&
            ((complete && next_consumer_gray != producer_sync_q) ||
             (!issue_last && !issued_last_q &&
              consumer_gray_q != producer_sync_q));
        if (memory_stb && !memory_stall) begin
            issued_q <= issued_q + 1'b1;
            if (last_issue) begin
                issued_last_q <= 1;
            end
        end
        if (!empty_q && !head_write)
            line_data[returned_q] <= memory_rdata;
        if (!empty_q && memory_ack) begin
            returned_q <= returned_q + 1'b1;
            reply_last_q <= returned_q == PENULTIMATE[BEAT_BITS-1:0];
            if (last_reply) begin
                consumer_gray_q <= next_consumer_gray;
                issued_last_q <= 0;
                issued_q <= 0;
                returned_q <= 0;
                reply_last_q <= 0;
            end
        end
        if (memory_rst) begin
            producer_meta_q <= 0;
            producer_sync_q <= 0;
            empty_q <= 1;
            consumer_gray_q <= 0;
            head_write <= 0;
            issued_last_q <= 0;
            request_valid_q <= 0;
            issued_q <= 0;
            returned_q <= 0;
            reply_last_q <= 0;
        end
    end
endmodule
`default_nettype wire
