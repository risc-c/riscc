// Focused cycle-level checks for riscc_fast.
//
// This is deliberately self contained so it can be run without an image
// builder.  The memory model accepts at most one request.  The default mode
// presents a registered response during the following cycle; +WAIT adds a
// deterministic delay, +STALL applies B4 request backpressure, +ZERO returns
// an accepted read on the acceptance edge, and +MIX alternates early and
// delayed responses while also stalling requests.

`default_nettype none

module riscc_fast_pipeline_tb #(
    parameter integer XLEN = 16
);
    localparam integer MEM_WORDS = 65536;
    localparam integer DATA_BYTE = 16'h0080;
    localparam integer RESULT_BYTE = 16'h00a0;
    localparam integer DONE_BYTE = 16'h00c0;
    localparam integer DATA_HALF = DATA_BYTE >> 1;
    localparam integer RESULT_HALF = RESULT_BYTE >> 1;
    localparam integer DONE_HALF = DONE_BYTE >> 1;
    localparam [15:0] DONE_VALUE = 16'h005a;
    localparam integer CALL_TARGET = XLEN == 32 ? 32'h10040 : 32'h0040;

    reg clk;
    reg rst;
    reg irq;
    wire [XLEN-2:0] mem_addr;
    wire [15:0] mem_rdata;
    wire [15:0] mem_wdata;
    wire [1:0] mem_wmask;
    wire mem_we;
    wire mem_cyc;
    wire mem_stb;
    wire mem_stall;
    wire mem_ack;

    reg [15:0] mem [0:MEM_WORDS-1];
    integer expected_gap [0:MEM_WORDS-1];
    reg response_pending_q;
    reg [XLEN-2:0] response_addr_q;
    reg [15:0] response_data_q;
    reg [2:0] response_wait_q;
    reg [31:0] cycle_q;
    reg wait_mode;
    reg stall_mode;
    reg zero_mode;
    reg mix_mode;
    reg ack_high_mode;
    reg mix_early_q;
    reg [31:0] test_case;

    reg done_seen_q;
    reg [3:0] done_age_q;
    reg failed_q;

    integer i;
    integer accepted_count;
    integer response_count;
    integer write_count;
    integer expected_writes;
    integer commit_count;
    integer commit_run;
    integer max_commit_run;
    integer last_commit_cycle;
    integer have_last_commit;
    integer last_commit_pc;
    integer memory_gap_errors;
    integer simple_gap_errors;
    integer literal_reads;
    integer call_commits;
    integer loop_taken;
    integer loop_exits;
    integer negative_not_taken;
    integer negative_taken;
    integer wanted_gap;
    integer early_ack_count;
    integer ack_stall_count;
    integer stalled_count;
    integer stable_stall_count;
    integer response_drop_count;
    integer ack_idle_count;
    wire strict_timing = !wait_mode && !stall_mode && !zero_mode &&
                         !mix_mode && !ack_high_mode;
    integer irq_beat;
    integer data_beat_count;
    integer irq_take_count;
    integer irq_epc_errors;
    integer reti_count;
    integer main_data_accepts;
    integer irq_shift_entry_errors;
    integer alias_data_accepts;
    integer alias_addr_errors;
    integer alias_irq_entry_errors;
    reg irq_raised_q;
    reg irq_withdrawn_q;
    localparam integer IRQ_MAIN_LOAD_PC = 11;
    localparam integer IRQ_MAIN_RETURN_PC = 12;
    localparam integer IRQ_SHIFT_RETURN_PC = 15;
    localparam integer IRQ_ALIAS_RETURN_PC = 16;
    reg stall_seen_q;
    reg [XLEN-2:0] stall_addr_q;
    reg [15:0] stall_wdata_q;
    reg [1:0] stall_wmask_q;
    reg stall_we_q;
    reg stall_cyc_q;
    reg stall_stb_q;
    reg response_drop_q;
    reg [15:0] last_response_data_q;

    riscc_fast #(.XLEN(XLEN), .RESET_PC(0)) dut (
        .clk(clk), .rst(rst), .irq(irq),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb),
        .mem_stall(mem_stall),
        .mem_ack(mem_ack)
    );

    // ISA encoders used by the programs below (see doc/RISC-C-ISA.md).
    function automatic [15:0] enc_i(
        input [2:0] rd, input [2:0] op, input [7:0] imm);
        enc_i = {2'b10, rd, op, imm};
    endfunction

    function automatic [15:0] enc_mem(
        input store, input [2:0] rs, input [2:0] ra, input [7:0] disp);
        enc_mem = {2'b01, rs, ra, disp[7:1], store};
    endfunction

    function automatic [15:0] enc_r(
        input [2:0] rd, input [2:0] ra, input [4:0] func, input [2:0] rb);
        enc_r = {2'b11, rd, ra, func, rb};
    endfunction

    function automatic [15:0] enc_branch(
        input [2:0] cc, input signed [7:0] relative);
        reg [7:0] rotated;
        begin
            rotated = {relative[7:1], relative[0]};
            // The ISA stores rel8 bit 7 in instruction bit 0 and rel8 bits
            // 6:0 in bits 7:1.
            rotated = {relative[6:0], relative[7]};
            enc_branch = enc_i(cc, 3'b111, rotated);
        end
    endfunction

    task automatic put_i(
        input integer address, input [2:0] rd, input [2:0] op,
        input [7:0] imm);
        begin mem[address] = enc_i(rd, op, imm); end
    endtask

    task automatic put_mem(
        input integer address, input store, input [2:0] rs,
        input [2:0] ra, input integer disp);
        begin
            mem[address] = enc_mem(store, rs, ra, disp[7:0]);
            expected_gap[address] = XLEN == 32 ? 3 : 2;
            if (store) expected_writes = expected_writes + (XLEN == 32 ? 2 : 1);
        end
    endtask

    task automatic put_r(
        input integer address, input [2:0] rd, input [2:0] ra,
        input [4:0] func, input [2:0] rb);
        begin
            mem[address] = enc_r(rd, ra, func, rb);
            if (func == 5'h0b) expected_writes = expected_writes + 1;
            if (func == 5'h08) expected_gap[address] = XLEN == 32 ? 3 : 2;
            else if (func == 5'h0a || func == 5'h0b || func == 5'h0e)
                expected_gap[address] = 2;
        end
    endtask

    task automatic fail(input [8*96-1:0] message);
        begin
            if (!failed_q) begin
                failed_q = 1'b1;
                $display("FAIL CASE %0d XLEN=%0d: %0s", test_case, XLEN,
                         message);
                $fatal(1, "CASE %0d XLEN=%0d: %0s", test_case, XLEN,
                       message);
            end
        end
    endtask

    // Programs use r7 as a base.  They deliberately finish with a store to
    // DONE_BYTE so the test can stop without depending on a non-ISA halt.
    task automatic init_program;
        integer pc;
        begin
            // Native values are little endian halfwords.  These initial
            // values exercise both byte lanes and RC32's high native beat.
            mem[DATA_HALF] = 16'h80a5;
            mem[DATA_HALF + 1] = 16'h1234;
            mem[DATA_HALF + 2] = 16'h0203;
            mem[DATA_HALF + 3] = 16'h0000;
            pc = 0;
            if (test_case == 0) begin
                // Independent operations: after fill, commits must remain
                // adjacent until the first data transaction.
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1; // LDI
                put_i(pc, 3'd1, 3'd0, 8'h11); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'h22); pc = pc + 1;
                repeat (4) begin
                put_r(pc, 3'd3, 3'd1, 5'h00, 3'd2); pc = pc + 1; // ADD
                put_r(pc, 3'd4, 3'd1, 5'h06, 3'd2); pc = pc + 1; // XOR
                put_r(pc, 3'd5, 3'd1, 5'h04, 3'd2); pc = pc + 1; // AND
                put_r(pc, 3'd6, 3'd1, 5'h05, 3'd2); pc = pc + 1; // OR
                end
                put_mem(pc, 1'b1, 3'd3, 3'd7, RESULT_BYTE-DATA_BYTE);
                pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 1) begin
                // Every ADDI consumes the preceding result.  Write-first RF
                // forwarding is required for this to produce 34.
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd1, 3'd0, 8'd1); pc = pc + 1;
                repeat (16) begin
                    put_i(pc, 3'd1, 3'd2, 8'd1); pc = pc + 1;
                end
                put_r(pc, 3'd1, 3'd1, 5'h00, 3'd1); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 3) begin
                // A load holds the next JALL in Decode. Its sequential
                // literal must be captured once, even with delayed ACK.
                // RC32 also exercises target bit 16.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_mem(1, 1'b0, 3'd3, 3'd7, 0);
                mem[2] = 16'h0034 | (5 << 11) |
                         ((CALL_TARGET >> 16) << 6); // JALL S5
                mem[3] = CALL_TARGET[15:0];
                put_r(4, 3'd1, 3'd5, 5'h18, 3'd2); // MOV r1, S5
                put_mem(5, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(6, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(7, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
                put_r(CALL_TARGET >> 1, 3'd0, 3'd5, 5'h18, 3'd0); // RET S5
                // If the return's younger fetch escapes its flush, this
                // uncounted write makes the exactly-once assertion fail.
                mem[(CALL_TARGET >> 1) + 1] =
                    enc_mem(1'b1, 3'd3, 3'd7, RESULT_BYTE-DATA_BYTE);
            end else if (test_case == 4) begin
                // Two backward BNEZ branches and one fall-through exercise
                // the zero flag after r0 writes. BLTZ must fall through for
                // zero, then take after r0 becomes negative.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd0, 3'd0, 8'd3);
                put_i(2, 3'd0, 3'd2, 8'hff); // ADDI r0, -1
                mem[3] = enc_branch(3'd1, -8'sd2); // BNEZ -> 2
                mem[4] = enc_branch(3'd4, 8'sd2); // JMP -> 7
                mem[5] = enc_mem(1'b1, 3'd0, 3'd7, RESULT_BYTE-DATA_BYTE);
                mem[6] = mem[5];
                put_i(7, 3'd0, 3'd0, 8'd0); // LDI r0, 0; clear N
                mem[8] = enc_branch(3'd2, 8'sd1); // BLTZ -> 10, not taken
                put_i(9, 3'd0, 3'd2, 8'hff); // ADDI r0, -1; set N
                mem[10] = enc_branch(3'd2, 8'sd1); // BLTZ -> 12
                mem[11] = enc_mem(1'b1, 3'd0, 3'd7,
                                  RESULT_BYTE-DATA_BYTE);
                put_r(12, 3'd1, 3'd0, 5'h00, 3'd0);
                put_mem(13, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(14, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(15, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 5) begin
                // IRQ vector at halfword 2.  The vector jump leaves room for
                // the handler and starts mainline at halfword 8.  The
                // handler saves the interrupted r0, records one entry,
                // restores r0, and returns through S0.  The mainline native
                // RC32 load is the operation whose first or second beat can
                // be surrounded by the injected IRQ.
                mem[0] = enc_branch(3'd4, 8'sd7); // JMP8 -> 8
                mem[2] = enc_r(3'd1, 3'd0, 5'h1f, 3'd3); // MTS S1, r0
                put_i(3, 3'd0, 3'd0, 8'd1);             // LDI r0, 1
                put_mem(4, 1'b1, 3'd0, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4);       // entry flag
                mem[5] = enc_r(3'd0, 3'd1, 5'h1f, 3'd2); // MFS r0, S1
                mem[6] = enc_r(3'd5, 3'd0, 5'h1f, 3'd0); // RETI S0
                pc = 8;
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                mem[pc] = enc_r(3'd2, 3'd0, 5'h1f, 3'd0); // CLI
                pc = pc + 1;
                mem[pc] = enc_r(3'd7, 3'd0, 5'h1f, 3'd0); // STI
                pc = pc + 1;
                put_r(pc, 3'd1, 3'd7, 5'h08, 3'd0); // RC32 native LDX
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd1, 3'd7,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7,
                        DONE_BYTE-DATA_BYTE);
            end else if (test_case == 6) begin
                // Exercise the side-state datapath under a continuously
                // asserted ACK: a variable shift and a multiply must still
                // hold Execute until completion while ordinary requests use
                // the same one-outstanding bus protocol.
                pc = 0;
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd1, 3'd0, 8'h40); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'd1); pc = pc + 1;
                put_r(pc, 3'd4, 3'd1, 5'h0c, 3'd2); pc = pc + 1; // SRL
                put_mem(pc, 1'b1, 3'd4, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4); pc = pc + 1;
                put_r(pc, 3'd3, 3'd1, 5'h07, 3'd2); pc = pc + 1; // MUL
                put_mem(pc, 1'b1, 3'd3, 3'd7,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7,
                        DONE_BYTE-DATA_BYTE);
            end else if (test_case == 7 || test_case == 9) begin
                // Exercise both forms of destination feedback.  The first
                // shift reads r1 and writes r3; the second reads and writes
                // r3.  An IRQ is raised while the second shift is iterating,
                // so the handler must observe its completed value and RETI
                // must resume at the dependent ADD.
                mem[0] = enc_branch(3'd4, 8'sd7); // JMP8 -> 8
                put_mem(2, 1'b1, 3'd3, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4);       // handler observes r3
                mem[3] = enc_r(3'd5, 3'd0, 5'h1f, 3'd0); // RETI S0
                pc = 8;
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd1, 3'd0, 8'h40); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'd1); pc = pc + 1;
                mem[pc] = enc_r(3'd2, 3'd0, 5'h1f, 3'd0); pc = pc + 1; // CLI
                mem[pc] = enc_r(3'd7, 3'd0, 5'h1f, 3'd0); pc = pc + 1; // STI
                put_r(pc, 3'd3, 3'd1, 5'h0c, 3'd2); pc = pc + 1;
                put_r(pc, 3'd3, 3'd3, 5'h0c, 3'd2); pc = pc + 1;
                put_r(pc, 3'd4, 3'd3, 5'h00, 3'd2); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd4, 3'd7,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7,
                        DONE_BYTE-DATA_BYTE);
            end else if (test_case == 8) begin
                // RC32 native loads must retain their original address
                // operands while the two halfword beats complete. The first
                // load aliases its destination with its base (LD r7,[r7]);
                // the indexed load aliases its destination with rb
                // (LDX r6,[r5+r6]). An IRQ raised on the first beat is held
                // until the first load finishes, then enters before the
                // second aliased load, saving its full 32-bit EPC.
                mem[0] = enc_branch(3'd4, 8'sd7); // JMP8 -> 8
                mem[2] = enc_r(3'd1, 3'd0, 5'h1f, 3'd3); // MTS S1, r0
                put_i(3, 3'd0, 3'd0, 8'd1);             // LDI r0, 1
                put_mem(4, 1'b1, 3'd0, 3'd5,
                        RESULT_BYTE-DATA_BYTE+4);       // entry flag
                mem[5] = enc_r(3'd0, 3'd1, 5'h1f, 3'd2); // MFS r0, S1
                mem[6] = enc_r(3'd5, 3'd0, 5'h1f, 3'd0); // RETI S0
                pc = 8;
                // Poison every EPC bit so a partial-width IRQ write fails.
                put_i(pc, 3'd0, 3'd0, 8'd0); pc = pc + 1;
                put_i(pc, 3'd0, 3'd2, 8'hff); pc = pc + 1; // ADDI r0,-1
                put_r(pc, 3'd0, 3'd0, 5'h1f, 3'd3); pc = pc + 1; // MTS S0,r0
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd5, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, 8'd4); pc = pc + 1;
                mem[pc] = enc_r(3'd7, 3'd0, 5'h1f, 3'd0); pc = pc + 1; // STI
                put_mem(pc, 1'b0, 3'd7, 3'd7, 0); pc = pc + 1; // LD r7,[r7]
                put_r(pc, 3'd6, 3'd5, 5'h08, 3'd6); pc = pc + 1; // LDX r6,[r5+r6]
                put_r(pc, 3'd1, 3'd7, 5'h00, 3'd6); pc = pc + 1; // ADD r1,r7,r6
                put_mem(pc, 1'b1, 3'd1, 3'd5,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd0, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd0, 3'd5,
                        DONE_BYTE-DATA_BYTE);
            end else begin
                // Typed accesses are one beat at either width.  Native and
                // indexed accesses are one beat on RC16 and two on RC32.
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DATA_BYTE + 1); pc = pc + 1;
                put_i(pc, 3'd0, 3'd0, 8'd0); pc = pc + 1; // LDX rb
                put_r(pc, 3'd1, 3'd7, 5'h0a, 3'd0); pc = pc + 1; // LDB
                put_mem(pc, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                pc = pc + 1;
                put_r(pc, 3'd2, 3'd7, 5'h0e, 3'd0); pc = pc + 1; // LDBS
                put_mem(pc, 1'b1, 3'd2, 3'd7, RESULT_BYTE-DATA_BYTE+4);
                pc = pc + 1;
                put_r(pc, 3'd3, 3'd6, 5'h0a, 3'd0); pc = pc + 1; // odd LDB
                put_mem(pc, 1'b1, 3'd3, 3'd7, RESULT_BYTE-DATA_BYTE+8);
                pc = pc + 1;
                put_r(pc, 3'd4, 3'd6, 5'h0e, 3'd0); pc = pc + 1; // odd LDBS
                put_mem(pc, 1'b1, 3'd4, 3'd7, RESULT_BYTE-DATA_BYTE+12);
                pc = pc + 1;
                put_r(pc, 3'd1, 3'd6, 5'h0b, 3'd0); pc = pc + 1; // STB odd
                put_mem(pc, 1'b0, 3'd5, 3'd7, 0); pc = pc + 1; // LD
                put_r(pc, 3'd5, 3'd7, 5'h08, 3'd0); pc = pc + 1; // LDX
                put_mem(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+16);
                pc = pc + 1;
                if (XLEN == 32) begin
                    put_r(pc, 3'd5, 3'd7, 5'h0a, 3'd2); pc = pc + 1; // LDH
                    put_mem(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+24);
                    pc = pc + 1; // native check of LDH
                    put_r(pc, 3'd5, 3'd7, 5'h0e, 3'd2); pc = pc + 1; // LDHS
                    put_mem(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+28);
                    pc = pc + 1;
                    // RC32 direct typed halfwords use bbb=010.  This
                    // writes the original data halfword once more.
                    put_r(pc, 3'd5, 3'd7, 5'h0b, 3'd2); pc = pc + 1; // STH
                end
                // The marker is after all checks and is always native-width.
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end
        end
    endtask

    // STALL is independent of ACK.  In particular, the old response may be
    // acknowledged while a replacement command is being held.  The response
    // has priority on the read-data bus; an early response reads the array
    // directly, and an idle bus deliberately drives an invalid value so a
    // core cannot accidentally consume stale SRAM data.
    wire stall_pattern = (cycle_q[2:0] == 3'd2) ||
                         (cycle_q[2:0] == 3'd3);
    assign mem_stall = (stall_mode && mem_cyc && mem_stb) &&
                       ((response_pending_q &&
                         (response_wait_q == 2'd1)) || stall_pattern);
    wire mem_accept = mem_cyc && mem_stb && !mem_stall;
    wire early_response = !response_pending_q && mem_accept &&
                          (zero_mode || ack_high_mode ||
                           (mix_mode && mix_early_q));
    wire live_read = !response_pending_q && mem_accept &&
                     (zero_mode || ack_high_mode ||
                      (mix_mode && mix_early_q));
    assign mem_ack = ack_high_mode ||
                     (response_pending_q && (response_wait_q == 2'd1)) ||
                     early_response;
    assign mem_rdata = response_pending_q ? response_data_q :
                       live_read ? mem[mem_addr] : 16'hdead;

    // A response is sampled by the CPU at the edge following acceptance.
    // Updating response_data_q at acceptance leaves it stable throughout the
    // response cycle, and accepting on an ACK edge supports replacement.
    always @(posedge clk) begin
        if (rst) begin
            response_pending_q <= 1'b0;
            response_addr_q <= 0;
            response_data_q <= 0;
            response_wait_q <= 0;
            cycle_q <= 0;
            mix_early_q <= 1'b1;
            accepted_count <= 0;
            response_count <= 0;
            write_count <= 0;
            literal_reads <= 0;
            done_seen_q <= 1'b0;
            done_age_q <= 0;
            early_ack_count <= 0;
            ack_stall_count <= 0;
            stalled_count <= 0;
            stable_stall_count <= 0;
            response_drop_count <= 0;
            ack_idle_count <= 0;
            stall_seen_q <= 1'b0;
            response_drop_q <= 1'b0;
            last_response_data_q <= 16'hdead;
            data_beat_count <= 0;
            irq_take_count <= 0;
            irq_epc_errors <= 0;
            reti_count <= 0;
            main_data_accepts <= 0;
            irq_shift_entry_errors <= 0;
            alias_data_accepts <= 0;
            alias_addr_errors <= 0;
            alias_irq_entry_errors <= 0;
            irq_raised_q <= 1'b0;
            irq_withdrawn_q <= 1'b0;
        end else begin
            cycle_q <= cycle_q + 1'b1;
            // The compact frontend has one holding halfword.  A delayed
            // fetch response reserves that same slot, while data responses
            // may coexist with its younger, held instruction.
            if ((int'(dut.d_valid_q) + int'(dut.fetch_pending)) > 1)
                fail("fetch response and held instruction exceed the Decode slot");

            if ((test_case == 7 || test_case == 9) && dut.in_shift && dut.x_pc_q == 14 &&
                !irq_raised_q) begin
                irq_raised_q <= 1'b1;
                irq <= 1'b1;
            end

            // Once IRQ entry has been selected, withdraw the pin while an
            // older fetch still delays the vector request. Entry must finish.
            if (test_case == 9 && dut.take_irq && dut.fetch_pending &&
                !mem_ack && !irq_withdrawn_q) begin
                irq <= 1'b0;
                irq_withdrawn_q <= 1'b1;
            end

            // The first two accepted data beats belong to LD r7,[r7], and
            // the next two belong to LDX r6,[r5+r6]. Check both address
            // halves at acceptance, then raise IRQ after the first beat so
            // the request is pending before the first aliased load finishes.
            if (test_case == 8 && mem_accept && dut.data_request && !mem_we) begin
                case (alias_data_accepts)
                    0: if (mem_addr != DATA_HALF)
                           alias_addr_errors <= alias_addr_errors + 1;
                    1: if (mem_addr != DATA_HALF + 1)
                           alias_addr_errors <= alias_addr_errors + 1;
                    2: if (mem_addr != DATA_HALF + 2)
                           alias_addr_errors <= alias_addr_errors + 1;
                    3: if (mem_addr != DATA_HALF + 3)
                           alias_addr_errors <= alias_addr_errors + 1;
                    default: alias_addr_errors <= alias_addr_errors + 1;
                endcase
                alias_data_accepts <= alias_data_accepts + 1;
                if (alias_data_accepts == 0 && !irq_raised_q) begin
                    irq_raised_q <= 1'b1;
                    irq <= 1'b1;
                end
            end

            // Raise IRQ only after the selected native-load beat has been
            // accepted.  The core must defer entry until the complete RC32
            // instruction, including its second beat, has retired.
            if (test_case == 5 && mem_accept && !mem_we &&
                (mem_addr == DATA_HALF || mem_addr == DATA_HALF + 1)) begin
                data_beat_count <= data_beat_count + 1;
                main_data_accepts <= main_data_accepts + 1;
                if (data_beat_count + 1 == irq_beat)
                    irq <= 1'b1;
            end
            if ((test_case == 5 || test_case == 7 || test_case == 8 || test_case == 9) && dut.take_irq &&
                dut.frontend_flush) begin
                irq_take_count <= irq_take_count + 1;
                irq <= 1'b0;
                if ((test_case == 7 || test_case == 9) && dut.in_shift)
                    irq_shift_entry_errors <= irq_shift_entry_errors + 1;
                if (test_case == 8 && (!dut.x_native_word_q || dut.data_pending))
                    alias_irq_entry_errors <= alias_irq_entry_errors + 1;
                // An IRQ raised after an immediate final ACK is sampled
                // after the following store has started. Finish both store
                // beats, then resume at the instruction after that store.
                if (test_case == 5 &&
                    last_commit_pc != IRQ_MAIN_LOAD_PC &&
                    !(irq_beat == 2 && last_commit_pc == IRQ_MAIN_RETURN_PC))
                    fail("IRQ entered outside the completed load/store boundary");
                if (!dut.rf_we || dut.rf_waddr !== 4'h8 ||
                    dut.rf_wdata !== ((test_case == 5 ?
                                         (last_commit_pc + 1) :
                                         (test_case == 7 || test_case == 9) ? IRQ_SHIFT_RETURN_PC :
                                         IRQ_ALIAS_RETURN_PC) << 1)) begin
                    irq_epc_errors <= irq_epc_errors + 1;
                end
            end

            if ((response_pending_q && mem_ack) || early_response)
                response_count <= response_count + 1;

            if (ack_high_mode && mem_ack && (!mem_cyc || !mem_stb))
                ack_idle_count <= ack_idle_count + 1;

            if (early_response)
                early_ack_count <= early_ack_count + 1;
            if (response_pending_q && mem_ack && mem_stall &&
                mem_cyc && mem_stb)
                ack_stall_count <= ack_stall_count + 1;
            if (mem_stall && mem_cyc && mem_stb)
                stalled_count <= stalled_count + 1;

            // A response must belong either to the one accepted command or
            // to the command accepted on this edge.  ACK does not imply that
            // STALL is low: a slave may complete the old command while
            // withholding the replacement.
            if (!ack_high_mode && mem_ack && !response_pending_q &&
                !early_response)
                fail("ACK without an accepted request");
            if (!ack_high_mode && mem_ack && !response_pending_q &&
                !mem_accept)
                fail("early ACK without request acceptance");

            // Capture and compare every command held under STALL.  Include
            // all externally visible command fields, since a Wishbone slave
            // is allowed to sample any of them on acceptance.
            if (stall_seen_q &&
                (stall_addr_q != mem_addr ||
                 stall_wdata_q != mem_wdata ||
                 stall_wmask_q != mem_wmask ||
                 stall_we_q != mem_we ||
                 stall_cyc_q != mem_cyc ||
                 stall_stb_q != mem_stb))
                fail("stalled command changed before acceptance");
            if (mem_stall && mem_cyc && mem_stb) begin
                if (stall_seen_q)
                    stable_stall_count <= stable_stall_count + 1;
                stall_addr_q <= mem_addr;
                stall_wdata_q <= mem_wdata;
                stall_wmask_q <= mem_wmask;
                stall_we_q <= mem_we;
                stall_cyc_q <= mem_cyc;
                stall_stb_q <= mem_stb;
                stall_seen_q <= 1'b1;
            end else begin
                stall_seen_q <= 1'b0;
            end

            // Invalidate an acknowledged response without a replacement,
            // catching accidental reuse of its data on later edges.
            if (response_drop_q && !response_pending_q && !mem_ack &&
                mem_rdata == last_response_data_q) begin
                fail("read response remained valid after ACK");
            end
            response_drop_q <= 1'b0;

            if (response_pending_q && !mem_cyc)
                fail("CYC dropped before the response");

            // At most one request can be in flight.  The only legal overlap
            // is a replacement on the cycle that presents the old ACK.
            if (mem_accept && response_pending_q && !mem_ack)
                fail("accepted a second request before the response");

            if (mem_accept) begin
                if (test_case == 3 && !mem_we && mem_addr == 3)
                    literal_reads <= literal_reads + 1;
                accepted_count <= accepted_count + 1;
                response_pending_q <= 1'b1;
                response_addr_q <= mem_addr;
                response_data_q <= mem[mem_addr];
                if (!response_pending_q && early_response) begin
                    // Same-cycle ACK has already completed this request.
                    response_pending_q <= 1'b0;
                    response_wait_q <= 0;
                end else begin
                    // A replacement accepted with an old ACK cannot itself
                    // complete on this edge: the response bus belongs to the
                    // old request.  It therefore gets the next registered
                    // response slot.
                    response_wait_q <= (test_case == 9 && !mem_we &&
                                        mem_addr < DATA_HALF) ? 3'd5 :
                                       wait_mode ? 3'd2 : 3'd1;
                end
                if (mix_mode && !response_pending_q)
                    mix_early_q <= ~mix_early_q;
                if (mem_we) begin
                    write_count <= write_count + 1;
                    if (mem_wmask[0]) mem[mem_addr][7:0] <= mem_wdata[7:0];
                    if (mem_wmask[1]) mem[mem_addr][15:8] <= mem_wdata[15:8];
                    if (mem_addr == DONE_HALF &&
                        mem_wdata[7:0] == DONE_VALUE[7:0]) begin
                        done_seen_q <= 1'b1;
                        done_age_q <= 0;
                    end
                end
            end else if (response_pending_q && mem_ack) begin
                last_response_data_q <= response_data_q;
                response_drop_q <= 1'b1;
                response_drop_count <= response_drop_count + 1;
                response_pending_q <= 1'b0;
                response_wait_q <= 0;
            end else if (response_pending_q && response_wait_q > 1) begin
                response_wait_q <= response_wait_q - 1'b1;
            end

            if (done_seen_q && done_age_q != 4'hf)
                done_age_q <= done_age_q + 1'b1;
        end
    end

    // Commit counters use the internal X stage metadata, which avoids adding
    // test-only ports to the production core.  A run of adjacent commits is
    // the direct observable for one IPC on this in-order machine.
    always @(posedge clk) begin
        if (!rst) begin
            if (dut.commit_valid && !dut.run_commit &&
                test_case != 6 && test_case != 7 && test_case != 9)
                fail("non-multicycle test committed without run_commit");
            if (dut.commit_valid) begin
                if (!have_last_commit && strict_timing &&
                    (test_case == 0 || test_case == 1) && cycle_q != 2)
                    fail("compact fetch startup did not take three edges");
                if (test_case == 3) begin
                    if (dut.x_pc_q == 3)
                        fail("JALL literal issued as an instruction");
                    if (dut.x_pc_q == 2) call_commits <= call_commits + 1;
                    if (have_last_commit && strict_timing) begin
                        if (last_commit_pc == 2 &&
                            (dut.x_pc_q != (CALL_TARGET >> 1) ||
                             cycle_q - last_commit_cycle != 2))
                            fail("JALL target did not commit after one bubble");
                        if (last_commit_pc == (CALL_TARGET >> 1) &&
                            (dut.x_pc_q != 4 || cycle_q - last_commit_cycle != 2))
                            fail("RET target did not commit after one bubble");
                    end
                end
                if (test_case == 5 && dut.x_pc_q == 6)
                    reti_count <= reti_count + 1;
                if ((test_case == 7 || test_case == 9) && dut.x_pc_q == 3)
                    reti_count <= reti_count + 1;
                if (test_case == 8 && dut.x_pc_q == 6)
                    reti_count <= reti_count + 1;
                if (test_case == 4 && have_last_commit && last_commit_pc == 3) begin
                    if (dut.x_pc_q == 2) loop_taken <= loop_taken + 1;
                    else if (dut.x_pc_q == 4) loop_exits <= loop_exits + 1;
                    else fail("conditional branch committed an unexpected PC");
                end
                if (test_case == 4 && have_last_commit && last_commit_pc == 8) begin
                    if (dut.x_pc_q == 9)
                        negative_not_taken <= negative_not_taken + 1;
                    else
                        fail("BLTZ did not fall through for nonnegative r0");
                end
                if (test_case == 4 && have_last_commit && last_commit_pc == 10) begin
                    if (dut.x_pc_q == 12)
                        negative_taken <= negative_taken + 1;
                    else
                        fail("BLTZ did not take after the preceding r0 write");
                end
                commit_count <= commit_count + 1;
                if (have_last_commit && cycle_q == last_commit_cycle + 1)
                    commit_run <= commit_run + 1;
                else
                    commit_run <= 1;
                if (have_last_commit && cycle_q == last_commit_cycle + 1 &&
                    commit_run + 1 > max_commit_run)
                    max_commit_run <= commit_run + 1;
                if (have_last_commit && strict_timing &&
                    test_case != 3 && test_case != 5 && test_case != 6 &&
                    test_case != 7 && test_case != 8 && test_case != 9) begin
                    wanted_gap = expected_gap[dut.x_pc_q];
                    if (test_case == 4 &&
                        ((last_commit_pc == 3 && dut.x_pc_q == 2) ||
                         (last_commit_pc == 4 && dut.x_pc_q == 7) ||
                         (last_commit_pc == 10 && dut.x_pc_q == 12)))
                        wanted_gap = 2;
                    if (cycle_q - last_commit_cycle != wanted_gap) begin
                        $display("GAP pc=%0d expected=%0d actual=%0d", dut.x_pc_q,
                                 wanted_gap, cycle_q-last_commit_cycle);
                        if (test_case == 2) memory_gap_errors <= memory_gap_errors + 1;
                        else simple_gap_errors <= simple_gap_errors + 1;
                    end
                end
                have_last_commit <= 1;
                last_commit_cycle <= cycle_q;
                last_commit_pc <= dut.x_pc_q;
            end
        end
    end

    task automatic check_results;
        begin
            if (!done_seen_q)
                fail("program did not reach completion marker");
            if (response_count > accepted_count ||
                accepted_count - response_count > 1)
                fail("memory response was lost or duplicated");
            if (write_count != expected_writes)
                fail("store side effects did not occur exactly once per beat");
            if (mem[DONE_HALF][7:0] != DONE_VALUE[7:0])
                fail("completion marker write is incorrect");
            if (test_case == 0) begin
                if (mem[RESULT_HALF] !== 16'h0033)
                    fail("independent ALU result mismatch");
                if (simple_gap_errors != 0)
                    fail("independent ALU stream did not sustain one IPC");
                if (zero_mode && max_commit_run < 4)
                    fail("same-cycle ACK did not sustain simple-op IPC");
            end else if (test_case == 1) begin
                if (mem[RESULT_HALF] !== 16'h0022)
                    fail("dependent ALU forwarding result mismatch");
                if (simple_gap_errors != 0)
                    fail("dependent ALU stream did not sustain one IPC");
                if (zero_mode && max_commit_run < 4)
                    fail("same-cycle ACK did not sustain dependent-op IPC");
            end else if (test_case == 3) begin
                if (mem[RESULT_HALF] !== 16'h0008 ||
                    (XLEN == 32 && mem[RESULT_HALF + 1] !== 16'h0000))
                    fail("JALL link/return PC mismatch");
                if (literal_reads != 1 || call_commits != 1)
                    fail("JALL header or literal processed more than once");
            end else if (test_case == 4) begin
                if (mem[RESULT_HALF] !== 16'hfffe ||
                    (XLEN == 32 && mem[RESULT_HALF + 1] !== 16'hffff))
                    fail("conditional branch loop result mismatch");
                if (loop_taken != 2 || loop_exits != 1)
                    fail("conditional branch loop took the wrong path");
                if (negative_not_taken != 1)
                    fail("negative branch did not fall through for nonnegative r0");
                if (negative_taken != 1)
                    fail("negative branch did not take the dependent path");
                if (simple_gap_errors != 0)
                    fail("taken/fall-through branch latency mismatch");
            end else if (test_case == 5) begin
                if (XLEN != 32)
                    fail("IRQ memory-beat case requires RC32");
                if (mem[RESULT_HALF] !== 16'h80a5 ||
                    mem[RESULT_HALF + 1] !== 16'h1234)
                    fail("IRQ interrupted RC32 load result mismatch");
                if (mem[RESULT_HALF + 2][7:0] !== 8'h01)
                    fail("IRQ handler did not record exactly one entry");
                if (data_beat_count != 2 || main_data_accepts != 2)
                    fail("RC32 load beat was replayed or lost around IRQ");
                if (irq_take_count != 1 || irq_epc_errors != 0)
                    fail("IRQ did not save the next instruction EPC");
                if (reti_count != 1)
                    fail("IRQ handler did not return through RETI");
            end else if (test_case == 6) begin
                if (mem[RESULT_HALF] !== 16'h0040 ||
                    mem[RESULT_HALF + 2] !== 16'h0008)
                    fail("shift or multiply result mismatch");
                if (test_case == 6 && ack_high_mode && !ack_idle_count)
                    fail("ACK_HIGH did not remain asserted while idle");
            end else if (test_case == 7 || test_case == 9) begin
                if (mem[RESULT_HALF] !== 16'h0002 ||
                    mem[RESULT_HALF + 2] !== 16'h0001)
                    fail("shift feedback or dependent result mismatch");
                if (irq_take_count != 1 || irq_epc_errors != 0 ||
                    irq_shift_entry_errors != 0)
                    fail("IRQ was not deferred until shift completion");
                if (reti_count != 1)
                    fail("shift IRQ handler did not return through RETI");
                if (test_case == 9 && !irq_withdrawn_q)
                    fail("IRQ was not withdrawn during a pending redirect");
            end else if (test_case == 8) begin
                if (XLEN != 32)
                    fail("aliased native-load case requires RC32");
                if (mem[RESULT_HALF] !== 16'h82a8 ||
                    mem[RESULT_HALF + 1] !== 16'h1234)
                    fail("aliased load or dependent result mismatch");
                if (mem[RESULT_HALF + 2][7:0] !== 8'h01)
                    fail("aliased-load IRQ handler did not record one entry");
                if (alias_data_accepts != 4 || alias_addr_errors != 0)
                    fail("aliased native-load beat addresses were replayed or lost");
                if (irq_take_count != 1 || irq_epc_errors != 0 ||
                    alias_irq_entry_errors != 0)
                    fail("aliased-load IRQ did not save the second load EPC");
                if (reti_count != 1)
                    fail("aliased-load IRQ handler did not return through RETI");
            end else begin
                if (mem[RESULT_HALF] !== 16'h00a5)
                    fail("LDB result mismatch");
                if (mem[RESULT_HALF + 2] !== 16'hffa5)
                    fail("LDBS result mismatch");
                if (mem[RESULT_HALF + 4] !== 16'h0080)
                    fail("odd-byte LDB result mismatch");
                if (mem[RESULT_HALF + 6] !== 16'hff80)
                    fail("odd-byte LDBS result mismatch");
                if (XLEN == 16 && mem[RESULT_HALF + 8] !== 16'ha5a5)
                    fail("RC16 native/indexed load mismatch");
                if (XLEN == 32 &&
                    (mem[RESULT_HALF + 8] !== 16'ha5a5 ||
                     mem[RESULT_HALF + 9] !== 16'h1234))
                    fail("RC32 native/indexed load mismatch");
                if (XLEN == 32 &&
                    (mem[RESULT_HALF + 12] !== 16'ha5a5 ||
                     mem[RESULT_HALF + 13] !== 16'h0000))
                    fail("RC32 halfword load mismatch");
                if (XLEN == 32 &&
                    (mem[RESULT_HALF + 14] !== 16'ha5a5 ||
                     mem[RESULT_HALF + 15] !== 16'hffff))
                    fail("RC32 signed halfword load mismatch");
                if (XLEN == 32 && mem[DATA_HALF] !== 16'ha5a5)
                    fail("RC32 halfword store mismatch");
                if (memory_gap_errors != 0)
                    fail("memory transaction latency did not match the contract");
            end
            $display("PASS CASE %0d XLEN=%0d cycles=%0d commits=%0d max_ipc_run=%0d accepts=%0d responses=%0d early_acks=%0d ack_stalls=%0d stalls=%0d stable_stalls=%0d response_drops=%0d ack_idle=%0d",
                     test_case, XLEN, cycle_q, commit_count, max_commit_run,
                     accepted_count, response_count, early_ack_count,
                     ack_stall_count, stalled_count, stable_stall_count,
                     response_drop_count, ack_idle_count);
            $finish(0);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        irq = 1'b0;
        wait_mode = $test$plusargs("WAIT");
        mix_mode = $test$plusargs("MIX");
        ack_high_mode = $test$plusargs("ACK_HIGH");
        stall_mode = $test$plusargs("STALL") || mix_mode;
        zero_mode = $test$plusargs("ZERO");
        if (!$value$plusargs("CASE=%d", test_case))
            test_case = 0;
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            mem[i] = 16'h8000; // LDI r0, 0: defined filler
            expected_gap[i] = 1;
        end
        expected_writes = 0;
        loop_taken = 0;
        loop_exits = 0;
        negative_not_taken = 0;
        negative_taken = 0;
        wanted_gap = 0;
        init_program();
        accepted_count = 0;
        response_count = 0;
        commit_count = 0;
        commit_run = 0;
        max_commit_run = 0;
        last_commit_cycle = 0;
        have_last_commit = 0;
        last_commit_pc = 0;
        memory_gap_errors = 0;
        simple_gap_errors = 0;
        call_commits = 0;
        failed_q = 1'b0;
        if (!$value$plusargs("IRQ_BEAT=%d", irq_beat))
            irq_beat = 1;
        if (irq_beat < 1 || irq_beat > 2)
            fail("IRQ_BEAT must be 1 or 2");
        stall_seen_q = 1'b0;
        response_drop_q = 1'b0;
        early_ack_count = 0;
        ack_stall_count = 0;
        stalled_count = 0;
        stable_stall_count = 0;
        response_drop_count = 0;
        ack_idle_count = 0;
        mix_early_q = 1'b1;
        last_response_data_q = 16'hdead;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        forever begin
            @(posedge clk);
            if (done_seen_q && done_age_q >= 4)
                check_results();
            if (cycle_q > 10000)
                fail("watchdog expired");
        end
    end

    always #1 clk = ~clk;
endmodule

`default_nettype wire
