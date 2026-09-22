// Two source-line buffers shared by SDRAM fetch and scaled video scanout.
`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_scanout (
    input wire memory_clk, memory_rst, memory_ready,
    output wire [23:0] memory_addr,
    output wire memory_cyc, memory_stb,
    input wire memory_stall, memory_ack,
    input wire [31:0] memory_rdata,
    input wire pix_clk, rst,
    input wire visible, line_start,
    input wire [8:0] source_x,
    input wire [7:0] source_y,
    output wire [7:0] pixel,
    output reg pixel_valid,
    output reg underrun
);
    // Each mailbox holds its row stable until the memory domain acknowledges.
    reg [1:0] request_q, requested_q;
    reg [7:0] row0_q, row1_q;
    reg started_q, line_valid_q;
    (* async_reg = "true" *) reg [1:0] done_meta_q, done_sync_q;
    reg [1:0] done_q;
    wire bank = source_y[0];
    wire available = requested_q[bank] &&
        (done_sync_q[bank] == request_q[bank]) &&
        ((bank ? row1_q : row0_q) == source_y);
    wire valid_now = line_start ? available : line_valid_q;
    wire [7:0] next_row = source_y == 8'd179 ? 8'd0 : source_y + 1'b1;
    wire next_bank = next_row[0];
    reg [31:0] read_word_q;
    reg [1:0] lane_q;
`ifdef RISCC_ECP5
    (* ram_style = "block" *)
`else
    (* ramstyle = "M20K, no_rw_check" *)
`endif
    reg [31:0] lines [0:255];

    always @(posedge pix_clk) begin
        read_word_q <= lines[{bank, source_x[8:2]}];
        lane_q <= source_x[1:0];
        if (rst) begin
            request_q <= 0;
            requested_q <= 0;
            row0_q <= 0;
            row1_q <= 0;
            started_q <= 0;
            line_valid_q <= 0;
            done_meta_q <= 0;
            done_sync_q <= 0;
            pixel_valid <= 0;
            underrun <= 0;
        end else begin
            done_meta_q <= done_q;
            done_sync_q <= done_meta_q;
            pixel_valid <= visible && valid_now;
            if (!started_q) begin
                request_q[0] <= 1'b1;
                requested_q[0] <= 1'b1;
                row0_q <= 0;
                started_q <= 1'b1;
            end
            if (line_start) begin
                line_valid_q <= available;
                if (!available)
                    underrun <= 1'b1;
                if (done_sync_q[next_bank] == request_q[next_bank]) begin
                    request_q[next_bank] <= ~request_q[next_bank];
                    requested_q[next_bank] <= 1'b1;
                    if (next_bank)
                        row1_q <= next_row;
                    else
                        row0_q <= next_row;
                end
            end
        end
    end
    assign pixel = pixel_valid ? read_word_q[{lane_q, 3'b000} +: 8] : 8'h0;

    (* async_reg = "true" *) reg [1:0] request_meta_q, request_sync_q;
    reg busy_q, issuing_q, fetch_bank_q, setup_q;
    reg [7:0] fetch_row_q;
    reg [6:0] word_q;
    reg [2:0] block_q;
    reg [13:0] address_q;
    wire [7:0] fetch_row = (request_sync_q[0] != done_q[0]) ? row0_q : row1_q;
    assign memory_addr = {10'd0, address_q};
    assign memory_cyc = busy_q && !setup_q;
    assign memory_stb = issuing_q;
    always @(posedge memory_clk) begin
        if (memory_rst) begin
            request_meta_q <= 0;
            request_sync_q <= 0;
            done_q <= 0;
            busy_q <= 0;
            issuing_q <= 0;
            block_q <= 0;
            fetch_bank_q <= 0;
            setup_q <= 0;
            fetch_row_q <= 0;
            word_q <= 0;
            address_q <= 0;
        end else begin
            request_meta_q <= request_q;
            request_sync_q <= request_meta_q;
            if (!busy_q && memory_ready && request_sync_q != done_q) begin
                fetch_bank_q <= (request_sync_q[0] == done_q[0]);
                fetch_row_q <= fetch_row;
                setup_q <= 1;
                word_q <= 0;
                block_q <= 0;
                busy_q <= 1;
            end
            // Begin the fetch after selecting the requested mailbox row.
            if (setup_q) begin
                address_q <= ({6'd0, fetch_row_q} << 6) + ({6'd0, fetch_row_q} << 4);
                setup_q <= 0;
                issuing_q <= 1;
            end
            if (memory_stb && !memory_stall) begin
                // The address already counts words within each 16-word block.
                if (&address_q[3:0]) begin
                    block_q <= block_q + 1'b1;
                    if (block_q == 3'd4)
                        issuing_q <= 0;
                end
                address_q <= address_q + 1'b1;
            end
            if (busy_q && memory_ack) begin
                lines[{fetch_bank_q, word_q}] <= memory_rdata;
                if (word_q == 7'd79) begin
                    done_q[fetch_bank_q] <= request_sync_q[fetch_bank_q];
                    busy_q <= 0;
                end else begin
                    word_q <= word_q + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
