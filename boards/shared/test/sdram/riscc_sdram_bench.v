// Queued hardware traffic test. All addresses are 32-bit word addresses.
// Results remain stable until the reporting clock domain acknowledges them.
`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_bench #(
    parameter integer ADDR_BITS = 23,
    parameter integer FULL_BITS = ADDR_BITS,
    parameter integer RANDOM_BITS = 16
) (
    input wire clk, rst, ready,
    output wire [ADDR_BITS-1:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0] mem_wmask,
    output wire mem_we, mem_cyc, mem_stb,
    input wire mem_stall, mem_ack,
    input wire [31:0] mem_rdata,
    output reg result_toggle,
    input wire reply_toggle,
    output reg [3:0] phase,
    output wire [31:0] words,
    output reg [31:0] cycles,
    output wire [31:0] errors,
    output reg [31:0] address, expected, actual,
    output wire terminal,
    output reg done, failed
);
    localparam [3:0] WAIT_READY=0, PREP=1, RUN=2, DRAIN=3, NEXT=4, REPORT=5, FINISH=6, SETUP=7, BASE=8;
    reg [3:0] state;
    reg [ADDR_BITS-1:6] batch;
    reg [6:0] sent, received;
    reg mixed_read;
    reg sequential_mode, line_mode, short_mode, masked_write_mode, masked_read_mode, mixed_mode, write_mode;
    reg [1:0] subline;
    (* async_reg = "true" *) reg [1:0] reply_sync;
    reg [ADDR_BITS-1:0] request_addr;

    wire writing = write_mode || (mixed_mode && !mixed_read);
    // 64-word streams; phase 1 uses 16-word (64-byte) cache lines.
    reg strobe_q, timeout_q, timeout_failed_q;
    assign errors = timeout_failed_q ? 32'hffffffff : {31'b0,failed};
    wire last_sent = short_mode ? (&sent[3:0]) : (&sent[5:0]);
    wire last_received = short_mode ? (&received[3:0]) : (&received[5:0]);
    wire accept = mem_stb && !mem_stall;
    wire response = mem_cyc && mem_ack;
    wire [ADDR_BITS-1:0] base_index = {batch,6'b0};
    wire [ADDR_BITS-1:0] receive_index = {batch,received[5:0]};
    reg [5:0] next_slot;
    wire [ADDR_BITS-1:0] next_index = {batch,next_slot};
    localparam [ADDR_BITS-1:0] ADDRESS_MASK = {ADDR_BITS{1'b1}} >> (ADDR_BITS-FULL_BITS);
    reg [ADDR_BITS-1:0] random_base_q, line_base_q;
    always @(posedge clk) begin
        random_base_q <= permute(base_index);
        line_base_q <= permute(base_index >> 3);
    end
    // A bijective XOR/shift permutation scatters consecutive requests over
    // columns, banks and rows. Phase 2 preserves groups of eight words.
    function [ADDR_BITS-1:0] permute(input [ADDR_BITS-1:0] value);
        reg [ADDR_BITS-1:0] v;
        begin
            v = value ^ (value << 7);
            v = v ^ (v >> 9);
            v = v ^ (v << 8);
            permute = (v ^ {ADDR_BITS{1'b1}}) & ({ADDR_BITS{1'b1}} >> (ADDR_BITS-FULL_BITS));
        end
    endfunction
    function [ADDR_BITS-1:0] location(input [ADDR_BITS-1:0] index);
        reg [ADDR_BITS-1:0] v;
        begin
            v = line_base_q ^ permute({{(ADDR_BITS-3){1'b0}},index[5:3]}) ^ ADDRESS_MASK;
            location = sequential_mode ? (short_mode ? {index[ADDR_BITS-1:6],subline,index[3:0]} : index) : line_mode ?
                ({v[ADDR_BITS-4:0],index[2:0]} & ({ADDR_BITS{1'b1}} >> (ADDR_BITS-FULL_BITS))) : (random_base_q ^ permute({{(ADDR_BITS-6){1'b0}},index[5:0]}) ^ ADDRESS_MASK);
        end
    endfunction
    function [31:0] pattern(input [ADDR_BITS-1:0] addr);
        begin pattern = {{(32-ADDR_BITS){1'b0}},addr} ^ 32'h13579bdf; end
    endfunction
    function [31:0] wanted(input [ADDR_BITS-1:0] addr);
        reg [31:0] value;
        integer lane;
        begin
            value = pattern(addr);
            for (lane=0;lane<4;lane=lane+1)
                if (masked_read_mode && addr[lane]) value[lane*8 +: 8] = ~value[lane*8 +: 8];
            wanted = mixed_mode ? value ^ 32'ha5c39678 : value;
        end
    endfunction
    wire [ADDR_BITS-1:0] next_address = location(next_index);
    wire [ADDR_BITS-1:0] first_address = location(base_index);
    wire [ADDR_BITS-1:0] response_address = location(receive_index);
    assign mem_addr = request_addr;
    assign mem_wdata = masked_write_mode ? ~pattern(request_addr) :
                       mixed_mode ? pattern(request_addr) ^ 32'ha5c39678 : pattern(request_addr);
    assign mem_wmask = masked_write_mode ? request_addr[3:0] : 4'hf;
    assign mem_we = writing;
    assign mem_cyc = !rst && (state == RUN || state == DRAIN);
    assign mem_stb = !rst && state == RUN && strobe_q;
    assign words = sequential_mode ? (32'd1 << FULL_BITS) :
                   mixed_mode ? (32'd2 << RANDOM_BITS) : (32'd1 << RANDOM_BITS);
    assign terminal = failed || mixed_mode;
    wire last_batch = sequential_mode ? batch == ((1 << (FULL_BITS-6))-1) :
                                              batch == ((1 << (RANDOM_BITS-6))-1);
    reg finish_batch_q, advance_batch_q;
    always @(posedge clk) begin
        finish_batch_q <= failed || (last_batch && (!mixed_mode || mixed_read) && (!short_mode || subline == 3));
        advance_batch_q <= !(short_mode && subline != 3) && !(mixed_mode && !mixed_read);
        if (state == NEXT && advance_batch_q) batch <= batch + 1'b1;
        if (rst || state == SETUP) batch <= 0;
    end
    // Four lanes avoid a long carry chain on the 166 MHz measurement counter.
    wire counting = state == BASE || state == PREP || state == RUN || state == DRAIN || state == NEXT;
    reg response_valid, check_valid, compare_valid;
    reg [ADDR_BITS-1:0] response_address_q;
    reg [31:0] response_data_q;
    reg [31:0] check_expected, check_actual;
    reg [ADDR_BITS-1:0] check_address, compare_address;
    reg [31:0] compare_expected, compare_actual;
    reg [3:0] equal_bytes;
    reg mismatch_q;
    reg [ADDR_BITS-1:0] mismatch_address_q;
    reg [31:0] mismatch_expected_q, mismatch_actual_q;
    reg [2:0] drain_count;
    reg carry8_q, carry16_q, carry24_q;
    always @(posedge clk) begin
        carry8_q <= counting ? cycles[7:0] == 8'hfe : &cycles[7:0];
        carry16_q <= counting ? cycles[15:0] == 16'hfffe : &cycles[15:0];
        carry24_q <= counting ? cycles[23:0] == 24'hfffffe : &cycles[23:0];
        if (counting) begin
            cycles[7:0] <= cycles[7:0] + 1'b1;
            cycles[15:8] <= cycles[15:8] + {7'b0,carry8_q};
            cycles[23:16] <= cycles[23:16] + {7'b0,carry16_q};
            cycles[31:24] <= cycles[31:24] + {7'b0,carry24_q};
        end
        if (rst || state == SETUP) begin
            cycles <= 0;
            carry8_q <= 0; carry16_q <= 0; carry24_q <= 0;
        end
    end
    // Keep response checking away from request/backpressure control paths.
    always @(posedge clk) begin
        reply_sync <= {reply_sync[0],reply_toggle};
        timeout_q <= |cycles[31:28];
        response_valid <= response && !writing;
        response_address_q <= response_address;
        response_data_q <= mem_rdata;
        check_valid <= response_valid;
        compare_valid <= check_valid;
        mismatch_q <= compare_valid && !(&equal_bytes);
        mismatch_address_q <= compare_address;
        mismatch_expected_q <= compare_expected;
        mismatch_actual_q <= compare_actual;
        if (response_valid) begin
            check_expected <= wanted(response_address_q);
            check_actual <= response_data_q;
            check_address <= response_address_q;
        end
        equal_bytes[0] <= check_expected[7:0] == check_actual[7:0];
        equal_bytes[1] <= check_expected[15:8] == check_actual[15:8];
        equal_bytes[2] <= check_expected[23:16] == check_actual[23:16];
        equal_bytes[3] <= check_expected[31:24] == check_actual[31:24];
        compare_address <= check_address;
        compare_expected <= check_expected;
        compare_actual <= check_actual;
        case (state)
            WAIT_READY: if (ready) state <= SETUP;
            SETUP: begin
                sequential_mode <= phase < 2;
                line_mode <= phase == 2;
                short_mode <= phase == 1;
                masked_write_mode <= phase == 3;
                masked_read_mode <= phase == 4;
                mixed_mode <= phase == 5;
                write_mode <= phase == 0 || phase == 3;
                state <= BASE;
            end
            BASE: state <= PREP;
            PREP: begin
                request_addr <= first_address;
                sent <= 0; received <= 0; next_slot <= 1; strobe_q <= 1;
                state <= RUN;
            end
            RUN: begin
                if (accept) begin
                    sent <= sent + 1'b1;
                    next_slot <= next_slot + 1'b1;
                    if (last_sent) strobe_q <= 0;
                    request_addr <= next_address;
                end
                if (response) begin
                    received <= received + 1'b1;
                    if (last_received) begin state <= DRAIN; drain_count <= 0; end
                end
                // The watchdog is checked in the transaction state, keeping
                // its decode out of unrelated state transitions.
                if (timeout_q) begin
                    failed <= 1; timeout_failed_q <= 1;
                    result_toggle <= !result_toggle; state <= REPORT;
                end
            end
            DRAIN: begin
                drain_count <= drain_count + 1'b1;
                if (drain_count == 4) state <= NEXT;
            end
            NEXT: begin
                if (finish_batch_q) begin
                    result_toggle <= !result_toggle;
                    state <= REPORT;
                end else if (short_mode && subline != 3) begin
                    subline <= subline + 1'b1; state <= BASE;
                end else if (mixed_mode && !mixed_read) begin
                    mixed_read <= 1; state <= BASE;
                end else begin
                    mixed_read <= 0; subline <= 0; state <= BASE;
                end
            end
            REPORT: if (reply_sync[1] == result_toggle) begin
                if (terminal) begin done <= !failed; state <= FINISH; end
                else begin phase <= phase + 1'b1; state <= SETUP; end
            end
            default: ;
        endcase
        if (mismatch_q && !failed) begin
            failed <= 1;
            address <= {{(32-ADDR_BITS){1'b0}},mismatch_address_q} << 2;
            expected <= mismatch_expected_q; actual <= mismatch_actual_q;
        end
        if (rst) begin
            state <= WAIT_READY; phase <= 0; strobe_q <= 0; timeout_q <= 0;
            sent <= 0; received <= 0; next_slot <= 1; mixed_read <= 0; subline <= 0;
            timeout_failed_q <= 0; mismatch_q <= 0; address <= 0; expected <= 0; actual <= 0;
            result_toggle <= 0; reply_sync <= 0; done <= 0; failed <= 0;
            response_valid <= 0; check_valid <= 0; compare_valid <= 0; drain_count <= 0;
            sequential_mode <= 1; line_mode <= 0; short_mode <= 0;
            masked_write_mode <= 0; masked_read_mode <= 0; mixed_mode <= 0; write_mode <= 1;
        end
    end
    initial begin
        if (FULL_BITS < 7 || FULL_BITS > ADDR_BITS || RANDOM_BITS < 6 || RANDOM_BITS > FULL_BITS || ADDR_BITS > 30)
            $error("invalid SDRAM benchmark dimensions");
    end
endmodule
`default_nettype wire
