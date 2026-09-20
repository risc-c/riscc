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
    // Three command slots hold payloads until the memory domain consumes them.
    // Sequence counters track credits; slot indices wrap independently at three.
    (* ramstyle = "logic" *) reg [ADDR_BITS-1:0] address [0:2];
    (* ramstyle = "logic" *) reg [31:0] data [0:2];
    reg [3:0] mask [0:2];
    reg [2:0] writing;
    reg [1:0] put_q, get_q, read_slot_q;
    (* preserve *) reg [1:0] producer_gray_q, consumer_gray_q;
    (* async_reg = "true" *) reg [1:0] producer_meta_q, producer_sync_q;
    (* async_reg = "true" *) reg [1:0] consumer_meta_q, consumer_sync_q;
    (* async_reg = "true" *) reg [1:0] ready_sync_q;
    wire [1:0] consumed = {consumer_sync_q[1], ^consumer_sync_q};
    wire [1:0] produced = {producer_gray_q[1], ^producer_gray_q};
    wire [1:0] outstanding = produced - consumed;
    wire host_empty = outstanding == 0;
    reg empty_q;
    wire [1:0] next_producer_gray = {producer_gray_q[0], ~producer_gray_q[1]};
    wire [1:0] next_consumer_gray = {consumer_gray_q[0], ~consumer_gray_q[1]};
    reg read_wait_q, line_valid_q;
    wire busy_q = !host_empty || read_wait_q;
    reg [31:0] line_data [0:WORDS-1];
    wire [ADDR_BITS-1:0] line_address = address[read_slot_q];
    wire [BEAT_BITS-1:0] host_word = host_addr[BEAT_BITS-1:0] & LINE_MASK[BEAT_BITS-1:0];
    wire [BEAT_BITS-1:0] reply_word = line_address[BEAT_BITS-1:0] & LINE_MASK[BEAT_BITS-1:0];
    wire line_hit = READ_WORD_BITS != 0 && line_valid_q && !host_we &&
        (host_addr >> READ_WORD_BITS) == (line_address >> READ_WORD_BITS);
    assign host_ready = ready_sync_q[1] && !host_rst;
    assign host_stall = !host_ready || read_wait_q || outstanding == 3 ||
                        (!host_we && !host_empty);
    always @(posedge host_clk) begin
        consumer_meta_q <= consumer_gray_q;
        consumer_sync_q <= consumer_meta_q;
        ready_sync_q <= {ready_sync_q[0], memory_ready};
        host_rdata <= line_data[read_wait_q ? reply_word : host_word];
        host_ack <= 0;
        if (host_cyc && host_stb && !host_stall) begin
            if (line_hit) host_ack <= 1;
            else begin
                address[put_q] <= host_addr;
                data[put_q] <= host_wdata;
                mask[put_q] <= host_wmask;
                writing[put_q] <= host_we;
                put_q <= put_q == 2 ? 0 : put_q + 1'b1;
                producer_gray_q <= next_producer_gray;
                host_ack <= host_we;
                line_valid_q <= 0;
                if (!host_we) begin
                    read_slot_q <= put_q;
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
            put_q <= 0;
            read_slot_q <= 0;
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
    wire [1:0] next_get = get_q == 2 ? 0 : get_q + 1'b1;
    wire last_issue = head_write || READ_WORD_BITS == 0 || (&issued_q);
    wire last_reply = head_write || READ_WORD_BITS == 0 || reply_last_q;
    assign memory_addr = head_write ? address[get_q] :
        (address[get_q] & ~LINE_MASK) | {{(ADDR_BITS-BEAT_BITS){1'b0}}, issued_q};
    assign memory_wdata = data[get_q];
    assign memory_wmask = head_write ? mask[get_q] : 4'hf;
    assign memory_we = head_write;
    assign memory_cyc = !empty_q;
    assign memory_stb = request_valid_q;
    always @(posedge memory_clk) begin
        head_write <= writing[get_q];
        producer_meta_q <= producer_gray_q;
        producer_sync_q <= producer_meta_q;
        empty_q <= consumer_gray_q == producer_sync_q;
        request_valid_q <= consumer_gray_q != producer_sync_q && !issued_last_q && memory_ready;
        if (memory_stb && !memory_stall) begin
            issued_q <= issued_q + 1'b1;
            if (last_issue) begin
                issued_last_q <= 1;
                request_valid_q <= 0;
            end
        end
        // Sampling the current word speculatively removes ACK from the RAM
        // write-enable path. Only a valid reply advances its word index.
        if (!empty_q && !head_write) line_data[returned_q] <= memory_rdata;
        if (!empty_q && memory_ack) begin
            returned_q <= returned_q + 1'b1;
            reply_last_q <= returned_q == PENULTIMATE[BEAT_BITS-1:0];
            if (last_reply) begin
                head_write <= writing[next_get];
                get_q <= next_get;
                empty_q <= next_consumer_gray == producer_sync_q;
                request_valid_q <= next_consumer_gray != producer_sync_q && memory_ready;
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
            get_q <= 0;
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
