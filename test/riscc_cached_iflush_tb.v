// Directed public-wrapper test for self-modifying JALL code and IFLUSH.
//
// The test deliberately puts the nested JALL header at the last halfword of
// an I-cache line.  Its literal therefore arrives from the next line.  The
// first two calls warm the old target. The CPU patches the literal and the
// instruction after IFLUSH, then checks the new target, link, and
// successor. The backing model delays both reads and writes; an ordered
// uncached read makes the patch visible before IFLUSH while an unrelated
// posted store overlaps invalidate.

`timescale 1ns/1ps
`default_nettype none
/* The fixture uses integer byte addresses and compact-width encoders. */
/* verilator lint_off WIDTH */

module riscc_cached_iflush_tb #(
    parameter integer XLEN = 32,
    parameter integer SRAM_ADDR_BITS = 0,
    parameter SRAM_HEX = ""
);
    // 0x3e ends a cache line at both widths and leaves room for main.
    localparam integer LONG_AT = 62;
    localparam integer IFLUSH_AT = 80;
    localparam integer SUCCESSOR_AT = IFLUSH_AT + 2;
    localparam integer LITERAL_AT = 224;
    localparam integer OLD_TARGET = 128;
    localparam integer NEW_TARGET = 144;
    localparam integer RESULT_AT = 192;
    localparam integer SUCCESSOR_RESULT_AT = 196;
    localparam integer LINK_RESULT_AT = 200;
    localparam integer DONE_AT = 204;
    localparam [XLEN-1:0] OLD_MARK = 16'h0011;
    localparam [XLEN-1:0] NEW_MARK = 16'h0022;
    localparam [XLEN-1:0] OLD_SUCCESSOR_MARK = 16'h0033;
    localparam [XLEN-1:0] NEW_SUCCESSOR_MARK = 16'h0055;
    localparam [XLEN-1:0] DONE_MARK = 16'h00d0;
    localparam integer SECOND_RETURN = IFLUSH_AT + 12;
    localparam integer MEM_WORDS = 65536;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg irq = 1'b0;
    always #5 clk = ~clk;

    wire [XLEN-3:0] mem_addr;
    wire [31:0] mem_rdata;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we, mem_cyc, mem_stb, mem_stall, mem_ack;

    riscc_cached #(
        .XLEN(XLEN), .SRAM_ADDR_BITS(SRAM_ADDR_BITS), .SRAM_HEX(SRAM_HEX), .RESET_PC(0),
        .DCACHE_UNCACHED_BIT(7)
    ) dut (
        .clk(clk), .rst(rst), .irq(irq), .mem_cacheable(),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb), .mem_stall(mem_stall),
        .mem_ack(mem_ack)
    );

    reg [31:0] backing [0:MEM_WORDS-1];
    reg pending_q;
    reg pending_we_q;
    reg [XLEN-3:0] pending_addr_q;
    reg [31:0] pending_wdata_q;
    reg [3:0] pending_mask_q;
    integer pending_wait_q;
    integer read_delay;
    integer write_delay;
    integer cycle_q;
    integer failed;
    integer iflush_req_seen;
    integer iflush_start_seen;
    integer iflush_ack_seen;
    integer clear_seen;
    integer btb_clear_seen;
    integer payload_write_seen;
    integer payload_pending;
    integer successor_write_seen;
    integer iflush_start_count;
    integer warm_btb_hit_seen;
    integer flush_write_overlap_seen;
    integer iflush_done_seen;
    integer i;

    wire backend_accept = mem_cyc && mem_stb && !mem_stall;
    wire [31:0] pending_word = backing[pending_addr_q];
    // Present the response on an unstalled cycle, as a normal registered
    // Wishbone completion.  This also lets the cache retire posted writes
    // before the wrapper starts the I-cache reset sweep.
    assign mem_stall = pending_q && (pending_wait_q != 0);
    assign mem_ack = pending_q && (pending_wait_q == 0);
    assign mem_rdata = pending_word;

    wire btb_clearing_monitor = dut.cpu.g_btb.clearing_q;
    wire iflush_start_monitor = dut.iflush_start;
    wire iflush_done_monitor = dut.cpu.iflush_done;

    function automatic [15:0] enc_i(
        input [2:0] rd, input [2:0] op, input [7:0] imm);
        enc_i = {2'b10, rd, op, imm};
    endfunction

    function automatic [15:0] enc_mem(
        input store, input [2:0] rs, input [2:0] ra,
        input [7:0] disp);
        enc_mem = XLEN == 32 ? {2'b01, rs, ra, disp[7:2], disp[7], store} :
                              {2'b01, rs, ra, disp[7:1], store};
    endfunction

    function automatic [15:0] enc_r(
        input [2:0] rd, input [2:0] ra, input [4:0] func,
        input [2:0] rb);
        enc_r = {2'b11, rd, ra, func, rb};
    endfunction

    function automatic [15:0] enc_branch(
        input [2:0] cc, input integer relative);
        reg signed [7:0] rel;
        begin
            rel = relative;
            enc_branch = {2'b10, cc, 3'b111,
                          {rel[6:0], rel[7]}};
        end
    endfunction

    function automatic [15:0] enc_jall(
        input [2:0] link, input integer target);
        begin
            enc_jall = 16'h0034 | (link << 11) |
                       (((target >> 16) & 31) << 6);
        end
    endfunction

    function automatic [15:0] enc_sth(
        input [2:0] rs, input [2:0] ra);
        enc_sth = XLEN == 32 ? enc_r(rs, ra, 5'b01011, 3'b010) :
                              enc_mem(1'b1, rs, ra, 8'd0);
    endfunction

    task automatic put16(input integer address, input [15:0] value);
        begin
            if (address[1]) backing[address >> 2][31:16] = value;
            else backing[address >> 2][15:0] = value;
        end
    endtask

    task automatic put32(input integer address, input [31:0] value);
        begin backing[address >> 2] = value; end
    endtask

    task automatic put_store(input integer address, input [2:0] rs,
                             input [2:0] ra);
        begin put16(address, enc_sth(rs, ra)); end
    endtask

    task automatic fail(input [8*120-1:0] message);
        begin
            if (!failed) begin
                failed = 1;
                $display("FAIL Cached IFLUSH XLEN=%0d BTB=1 SRAM=%0d: %0s",
                         XLEN, SRAM_ADDR_BITS, message);
                $fatal(1, "Cached IFLUSH directed check failed");
            end
        end
    endtask

    task automatic init_program;
        integer pc;
        begin
            for (i = 0; i < MEM_WORDS; i = i + 1) backing[i] = 32'b0;

            // Main entry and first-call continuation.
            put16(16'h00, enc_jall(3'd1, LONG_AT));
            put16(16'h02, LONG_AT[15:0]);
            // Repeat the call once so the BTB exercises its trusted,
            // warmed JALL path before its literal is modified.
            put16(16'h04, enc_jall(3'd1, LONG_AT));
            put16(16'h06, LONG_AT[15:0]);
            put16(16'h08, enc_r(3'd2, 3'd0, 5'h1f, 3'd0)); // CLI
            put16(16'h0a, enc_i(3'd7, 3'd0, (LONG_AT + 2) & 8'hff));
            put16(16'h0c, enc_i(3'd2, 3'd0, NEW_TARGET[7:0]));
            put_store(16'h0e, 3'd2, 3'd7);
            put16(16'h10, enc_i(3'd7, 3'd0, LITERAL_AT[7:0]));
            put16(16'h12, enc_mem(1'b0, 3'd2, 3'd7, 8'd0)); // LD opcode
            put16(16'h14, enc_i(3'd7, 3'd0, SUCCESSOR_AT[7:0]));
            put_store(16'h16, 3'd2, 3'd7);
            put16(16'h18, enc_r(3'd7, 3'd0, 5'h1f, 3'd0)); // STI
            put16(16'h1a, enc_branch(3'd4,
                                     (IFLUSH_AT - 6 - (16'h1a + 2)) >> 1));

            // An ordered uncached read drains the patch stores before the
            // unrelated posted store immediately before IFLUSH.
            put16(IFLUSH_AT - 6, enc_i(3'd7, 3'd0, 8'hf8)); // LDI r7,0xf8
            put16(IFLUSH_AT - 4, enc_mem(1'b0, 3'd2, 3'd7, 8'd0)); // LD r2,[r7]
            put_store(IFLUSH_AT - 2, 3'd2, 3'd7); // unrelated posted store

            // The nested call is deliberately split across an I-cache line.
            put16(LONG_AT, enc_jall(3'd2, OLD_TARGET));
            put16(LONG_AT + 2, OLD_TARGET[15:0]);
            put16(LONG_AT + 4, enc_r(3'd0, 3'd1, 5'h1f, 3'd0)); // RET S1

            // IFLUSH resumes at the immediately following, patched successor.
            put16(IFLUSH_AT, enc_r(3'd3, 3'd0, 5'h1f, 3'd0));
            put16(SUCCESSOR_AT,
                  enc_i(3'd3, 3'd0, OLD_SUCCESSOR_MARK[7:0]));
            put16(SUCCESSOR_AT + 2, enc_i(3'd7, 3'd0,
                                          SUCCESSOR_RESULT_AT[7:0]));
            put_store(SUCCESSOR_AT + 4, 3'd3, 3'd7);
            put16(SUCCESSOR_AT + 6, enc_jall(3'd1, LONG_AT));
            put16(SUCCESSOR_AT + 8, LONG_AT[15:0]);
            put16(SECOND_RETURN, enc_r(3'd3, 3'd1, 5'h1f, 3'd2)); // MFS r3,S1
            put16(SECOND_RETURN + 2, enc_i(3'd7, 3'd0,
                                           LINK_RESULT_AT[7:0]));
            put_store(SECOND_RETURN + 4, 3'd3, 3'd7);
            put16(SECOND_RETURN + 6, enc_i(3'd3, 3'd0, DONE_MARK[7:0]));
            put16(SECOND_RETURN + 8, enc_i(3'd7, 3'd0, DONE_AT[7:0]));
            put_store(SECOND_RETURN + 10, 3'd3, 3'd7);

            // Distinct old/new target bodies make a stale literal observable.
            put16(OLD_TARGET, enc_i(3'd3, 3'd0, OLD_MARK[7:0]));
            put16(OLD_TARGET + 2, enc_i(3'd7, 3'd0, RESULT_AT[7:0]));
            put_store(OLD_TARGET + 4, 3'd3, 3'd7);
            put16(OLD_TARGET + 6, enc_r(3'd0, 3'd2, 5'h1f, 3'd0)); // RET S2
            put16(NEW_TARGET, enc_i(3'd3, 3'd0, NEW_MARK[7:0]));
            put16(NEW_TARGET + 2, enc_i(3'd7, 3'd0, RESULT_AT[7:0]));
            put_store(NEW_TARGET + 4, 3'd3, 3'd7);
            put16(NEW_TARGET + 6, enc_r(3'd0, 3'd2, 5'h1f, 3'd0)); // RET S2
            put32(LITERAL_AT, 32'h00009855);
            put32(8'hf8, 32'h00000000);

            // Keep PC-indexed tooling from treating uninitialized locations as
            // successful exits, while leaving every tested halfword explicit.
            pc = SECOND_RETURN + 12;
            put16(pc, enc_branch(3'd4, -1));
        end
    endtask

    function automatic [31:0] merged_word(
        input [31:0] old_value, input [31:0] new_value, input [3:0] mask);
        integer lane;
        begin
            merged_word = old_value;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask[lane]) merged_word[lane*8 +: 8] = new_value[lane*8 +: 8];
        end
    endfunction

    function automatic [15:0] word_half(input integer address);
        begin
            word_half = address[1] ? backing[address >> 2][31:16] :
                                     backing[address >> 2][15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0;
            failed = 0;
            iflush_req_seen <= 0;
            iflush_start_seen <= 0;
            iflush_ack_seen <= 0;
            iflush_done_seen <= 0;
            clear_seen <= 0;
            btb_clear_seen <= 0;
            payload_write_seen <= 0;
            payload_pending <= 0;
            successor_write_seen <= 0;
            iflush_start_count <= 0;
            warm_btb_hit_seen <= 0;
            flush_write_overlap_seen <= 0;
            pending_q <= 0;
            pending_we_q <= 0;
            pending_addr_q <= 0;
            pending_wdata_q <= 0;
            pending_mask_q <= 0;
            pending_wait_q <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            if ($test$plusargs("TRACE") && dut.cpu.x_finish)
                $display("COMMIT c=%0d pc=%h instr=%h result=%h base=%h", cycle_q,
                         dut.cpu.x_pc_q, dut.cpu.x_instr_q, dut.cpu.x_result,
                         dut.cpu.x_pc_q);
            if ($test$plusargs("TRACE") && dut.cpu.rf_we && dut.cpu.w_dst_q[3])
                $display("SWRITE c=%0d s=%0d value=%h", cycle_q,
                         dut.cpu.w_dst_q[2:0], dut.cpu.rf_wdata);
            // Explicit sticky registers keep all observations in the clocked
            // process, including when using older Verilator timing models.
            iflush_req_seen <= iflush_req_seen || dut.iflush_req;
            iflush_start_seen <= iflush_start_seen || iflush_start_monitor;
            iflush_ack_seen <= iflush_ack_seen || dut.iflush_ack;
            iflush_done_seen <= iflush_done_seen || iflush_done_monitor;
            clear_seen <= clear_seen ||
                (dut.iflush_req && dut.icache.state_q == 3'd6);
            btb_clear_seen <= btb_clear_seen ||
                (dut.iflush_req && btb_clearing_monitor);
            warm_btb_hit_seen <= warm_btb_hit_seen ||
                (!iflush_req_seen && dut.cpu.d_issue &&
                 dut.cpu.d_jall && dut.cpu.f_pc_q == (LONG_AT >> 1) &&
                 dut.cpu.btb_taken);
            flush_write_overlap_seen <= flush_write_overlap_seen ||
                (iflush_start_monitor && pending_q && pending_we_q &&
                 pending_addr_q == (8'hf8 >> 2));

            if (iflush_start_monitor) begin
                if (iflush_start_count != 0)
                    fail("IFLUSH restarted before the patched successor executed");
                iflush_start_count <= iflush_start_count + 1;
                if (word_half(LONG_AT + 2) != NEW_TARGET[15:0])
                    fail("IFLUSH started before the patch was visible");
            end
            if (dut.iflush_ack) begin
                if (!iflush_start_seen || !clear_seen)
                    fail("IFLUSH ACK preceded I-cache clear sweep");
                if (!btb_clear_seen)
                    fail("IFLUSH ACK preceded BTB clear sweep");
                if (dut.cpu.interrupt_enable_q !== 1'b1)
                    fail("IFLUSH changed interrupt enable state");
            end

            if (backend_accept && mem_we) begin
                if (mem_addr == ((LONG_AT + 2) >> 2)) begin
                    payload_write_seen <= 1;
                    payload_pending <= 1;
                end
                if (mem_addr == (SUCCESSOR_AT >> 2)) successor_write_seen <= 1;
            end
            if (pending_q && pending_wait_q == 0) begin
                if (pending_we_q)
                    backing[pending_addr_q] <= merged_word(
                        backing[pending_addr_q], pending_wdata_q, pending_mask_q);
                if (pending_we_q && pending_addr_q == ((LONG_AT + 2) >> 2))
                    payload_pending <= 0;
            end
            // A completed beat can be replaced on the same clock.
            if (backend_accept) begin
                if (pending_q && pending_wait_q != 0)
                    fail("backing request accepted before the previous response");
                pending_q <= 1;
                pending_we_q <= mem_we;
                pending_addr_q <= mem_addr;
                pending_wdata_q <= mem_wdata;
                pending_mask_q <= mem_wmask;
                pending_wait_q <= mem_we ? write_delay : read_delay;
            end else if (pending_q && pending_wait_q == 0) begin
                pending_q <= 0;
            end else if (pending_q) begin
                pending_wait_q <= pending_wait_q - 1;
            end

            if (word_half(DONE_AT) == DONE_MARK[15:0]) begin
                if (!iflush_req_seen || !iflush_start_seen || !iflush_ack_seen ||
                    !iflush_done_seen)
                    fail("IFLUSH did not complete its synchronization handshake");
                if (!warm_btb_hit_seen)
                    fail("nested JALL did not hit the BTB before patching");
                if (!payload_write_seen || !successor_write_seen)
                    fail("instruction patch stores were not observed");
                if (!flush_write_overlap_seen)
                    fail("unrelated posted write did not overlap invalidate start");
                if (word_half(RESULT_AT) != NEW_MARK[15:0])
                    fail("post-IFLUSH JALL did not reach the new target");
                if (word_half(SUCCESSOR_RESULT_AT) != NEW_SUCCESSOR_MARK[15:0])
                    fail("patched successor did not execute");
                if (word_half(LINK_RESULT_AT) != SECOND_RETURN[15:0]) begin
                    $display("LINK expected=%h actual=%h", SECOND_RETURN[15:0],
                             word_half(LINK_RESULT_AT));
                    fail("JALL link value was not preserved");
                end
                $display("PASS Cached IFLUSH XLEN=%0d BTB=1 SRAM=%0d cycles=%0d",
                         XLEN, SRAM_ADDR_BITS, cycle_q);
                $finish;
            end
            if (cycle_q > 200000) fail("cycle limit exceeded");
        end
    end

    initial begin
        read_delay = 2;
        write_delay = 80;
        if ($value$plusargs("READ_DELAY=%d", read_delay));
        if ($value$plusargs("WRITE_DELAY=%d", write_delay));
        init_program();
        repeat (6) @(negedge clk);
        rst = 0;
    end
endmodule

/* verilator lint_on WIDTH */
