// Focused cycle-level checks for riscc_cached_pipe.
//
// This is deliberately self contained so it can be run without an image
// builder. Each memory port accepts one request per clock and returns a
// registered response at least one clock later. +WAIT delays replies; +STALL
// applies request backpressure; +MIX alternates one-cycle and two-cycle replies
// with stalls. A request may change while STALL is asserted, but the accepted
// request and its ordered response must remain associated.

`default_nettype none

module riscc_cached_pipeline_tb #(
    parameter integer XLEN = 16,
    parameter integer REGISTER_FETCH = 0
);
    localparam integer MEM_WORDS = 65536;
    localparam integer DATA_BYTE = 16'h0080;
    localparam integer RESULT_BYTE = 16'h00a0;
    localparam integer DONE_BYTE = 16'h00c0;
    localparam integer STREAM_BYTE = 16'h0040;
    localparam integer STREAM_WORD = STREAM_BYTE >> 2;
    localparam integer STREAM_OPS = 8;
    localparam integer DATA_HALF = DATA_BYTE >> 1;
    localparam integer RESULT_HALF = RESULT_BYTE >> 1;
    localparam integer DONE_HALF = DONE_BYTE >> 1;
    localparam [15:0] DONE_VALUE = 16'h005a;
    localparam integer CALL_TARGET = XLEN == 32 ? 32'h10040 : 32'h0040;
    localparam integer COMPACT_FETCH_STARTUP_GAP = 2;
    localparam integer REGISTERED_FETCH_STARTUP_GAP = 3;
    localparam integer COMPACT_FETCH_REDIRECT_GAP = 2;
    localparam integer REGISTERED_JALL_REDIRECT_GAP = 3;
    localparam integer REGISTERED_INDIRECT_REDIRECT_GAP = 3;

    reg clk;
    reg rst;
    reg irq;
    // The raw core has independent pipelined instruction and data ports.
    // Both models below allow one outstanding transaction, but they have
    // separate response queues so an instruction fetch never consumes a
    // data response (or vice versa).
    wire [XLEN-2:0] imem_addr;
    wire [15:0] imem_rdata;
    wire imem_cyc;
    wire imem_stb;
    wire imem_stall;
    wire imem_ack;
    wire [XLEN-3:0] dmem_addr;
    wire [31:0] dmem_rdata;
    wire [31:0] dmem_wdata;
    wire [3:0] dmem_wmask;
    wire dmem_we;
    wire dmem_cyc;
    wire dmem_stb;
    wire dmem_stall;
    wire dmem_ack;

    reg [15:0] mem [0:MEM_WORDS-1];
    integer expected_gap [0:MEM_WORDS-1];
    reg i_response_pending_q;
    reg [XLEN-2:0] i_response_addr_q;
    reg [15:0] i_response_data_q;
    reg [2:0] i_response_wait_q;
    reg d_response_pending_q;
    reg [XLEN-3:0] d_response_addr_q;
    reg [31:0] d_response_data_q;
    reg [2:0] d_response_wait_q;
    reg [31:0] cycle_q;
    reg wait_mode;
    reg stall_mode;
    reg mix_mode;
    reg i_mix_fast_q;
    reg [31:0] test_case;

    reg done_seen_q;
    reg [3:0] done_age_q;
    reg failed_q;

    integer i;
    integer i_accepted_count;
    integer i_response_count;
    integer d_accepted_count;
    integer d_response_count;
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
    integer fast_response_count;
    integer ack_stall_count;
    integer stalled_count;
    integer data_stalled_count;
    integer i_response_order_checks;
    integer d_response_order_checks;
    integer i_response_drop_count;
    integer d_response_drop_count;
    integer stream_data_accepts;
    integer stream_data_gap_errors;
    integer stream_last_accept_cycle;
    wire strict_timing = !wait_mode && !stall_mode && !mix_mode;
    integer irq_beat;
    integer data_beat_count;
    integer irq_take_count;
    integer irq_epc_errors;
    integer reti_count;
    integer main_data_accepts;
    integer irq_shift_entry_errors;
    integer irq_mul_entry_errors;
    integer alias_data_accepts;
    integer alias_addr_errors;
    integer alias_irq_entry_errors;
    integer target_pc_commits;
    reg early_jump_observed_q;
    reg irq_raised_q;
    reg irq_withdrawn_q;
    localparam integer IRQ_MAIN_LOAD_PC = 11;
    localparam integer IRQ_MAIN_RETURN_PC = 12;
    localparam integer IRQ_SHIFT_RETURN_PC = 15;
    localparam integer IRQ_ALIAS_RETURN_PC = 16;
    reg i_response_drop_q;
    reg [15:0] i_last_response_data_q;
    reg d_response_drop_q;
    reg [31:0] d_last_response_data_q;
    reg irq_epc_pending_q;
    reg [31:0] irq_epc_expected_q;

    riscc_cached_pipe #(.XLEN(XLEN), .RESET_PC(0),
                        // Zero-wait replies change as soon as STB is offered.
                        .FETCH_RESPONSE_HELD(0),
                        .REGISTER_FETCH(REGISTER_FETCH)) dut (
        .clk(clk), .rst(rst), .irq(irq),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .imem_cyc(imem_cyc), .imem_stb(imem_stb),
        .imem_stall(imem_stall), .imem_ack(imem_ack),
        .dmem_addr(dmem_addr), .dmem_rdata(dmem_rdata),
        .dmem_wdata(dmem_wdata), .dmem_wmask(dmem_wmask),
        .dmem_we(dmem_we), .dmem_cyc(dmem_cyc), .dmem_stb(dmem_stb),
        .dmem_stall(dmem_stall), .dmem_ack(dmem_ack)
    );

    // ISA encoders used by the programs below (see doc/RISC-C-ISA.md).
    function automatic [15:0] enc_i(
        input [2:0] rd, input [2:0] op, input [7:0] imm);
        enc_i = {2'b10, rd, op, imm};
    endfunction

    function automatic [15:0] enc_mem(
        input store, input [2:0] rs, input [2:0] ra, input [7:0] disp);
        enc_mem = XLEN == 32 ? {2'b01, rs, ra, disp[7:2], disp[7], store} :
                              {2'b01, rs, ra, disp[7:1], store};
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

    function automatic [15:0] enc_ldpc(
        input [2:0] rd, input [7:0] offset);
        enc_ldpc = enc_i(rd, 3'd1, offset);
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
            // X completion is the accepted request. The response reaches W
            // one edge later, so independent memory operations can commit on
            // adjacent cycles; load-use consumers are marked below.
            expected_gap[address] = 1;
            if (store) expected_writes = expected_writes + (XLEN == 32 ? 2 : 1);
        end
    endtask

    task automatic put_mem_after_load(
        input integer address, input store, input [2:0] rs,
        input [2:0] ra, input integer disp);
        begin
            put_mem(address, store, rs, ra, disp);
            // The following store consumes the preceding load's W value.
            expected_gap[address] = 2;
        end
    endtask

    task automatic put_r(
        input integer address, input [2:0] rd, input [2:0] ra,
        input [4:0] func, input [2:0] rb);
        begin
            mem[address] = enc_r(rd, ra, func, rb);
            if (func == 5'h0b) expected_writes = expected_writes + 1;
            if (func == 5'h07) begin
`ifdef RISCC_FAST_SOFT_MUL
                expected_gap[address] = XLEN / 2 + 1;
`else
                expected_gap[address] = 4;
`endif
            end else if (func == 5'h08) expected_gap[address] = 1;
            else if (func == 5'h0a || func == 5'h0b || func == 5'h0e)
                expected_gap[address] = 1;
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
            // values exercise both byte lanes and RC32's high native halfword.
            mem[DATA_HALF] = 16'h80a5;
            mem[DATA_HALF + 1] = 16'h1234;
            mem[DATA_HALF + 2] = 16'h0203;
            mem[DATA_HALF + 3] = 16'h0000;
            // Four independent source words feed the unrolled load/store
            // stream in CASE=0. Store destinations start with sentinels so
            // every final value is checked after all timing modes.
            mem[(STREAM_BYTE >> 1) + 0] = 16'h1111;
            mem[(STREAM_BYTE >> 1) + 1] = 16'h2222;
            mem[(STREAM_BYTE >> 1) + 2] = 16'h3333;
            mem[(STREAM_BYTE >> 1) + 3] = 16'h4444;
            mem[(STREAM_BYTE >> 1) + 16] = 16'hdead;
            mem[(STREAM_BYTE >> 1) + 17] = 16'h0000;
            mem[(STREAM_BYTE >> 1) + 18] = 16'hcafe;
            mem[(STREAM_BYTE >> 1) + 19] = 16'h0000;
            mem[(STREAM_BYTE >> 1) + 20] = 16'h0000;
            mem[(STREAM_BYTE >> 1) + 21] = 16'h0000;
            mem[(STREAM_BYTE >> 1) + 22] = 16'h0000;
            mem[(STREAM_BYTE >> 1) + 23] = 16'h0000;
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
                // Alternating independent loads and stores exercise one
                // accepted data request per clock. The loads write dead
                // destinations; stores use the already settled r3 value.
                put_mem(pc, 1'b0, 3'd1, 3'd7, STREAM_BYTE-DATA_BYTE+0);
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd3, 3'd7, STREAM_BYTE-DATA_BYTE+32);
                pc = pc + 1;
                put_mem(pc, 1'b0, 3'd2, 3'd7, STREAM_BYTE-DATA_BYTE+4);
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd3, 3'd7, STREAM_BYTE-DATA_BYTE+36);
                pc = pc + 1;
                put_mem(pc, 1'b0, 3'd4, 3'd7, STREAM_BYTE-DATA_BYTE+8);
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd3, 3'd7, STREAM_BYTE-DATA_BYTE+40);
                pc = pc + 1;
                put_mem(pc, 1'b0, 3'd5, 3'd7, STREAM_BYTE-DATA_BYTE+12);
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd3, 3'd7, STREAM_BYTE-DATA_BYTE+44);
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
                // RC32 load is the operation whose accepted native-word
                // request is surrounded by the injected IRQ.
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
                // operands while the one word request completes. The first
                // load aliases its destination with its base (LD r7,[r7]);
                // the indexed load aliases its destination with rb
                // (LDX r6,[r5+r6]). An IRQ raised on the first request is held
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
            end else if (test_case == 10) begin
                // MUL must retain the decoded operands while its side state
                // runs. Cover destination aliases with source A, source B,
                // and both sources, then a back-to-back dependent MUL and an
                // ALU/store consumer of its result.
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd1, 3'd0, 8'd3); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'd4); pc = pc + 1;
                put_r(pc, 3'd1, 3'd1, 5'h07, 3'd2); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'd5); pc = pc + 1;
                put_r(pc, 3'd2, 3'd1, 5'h07, 3'd2); pc = pc + 1;
                put_i(pc, 3'd3, 3'd0, 8'd7); pc = pc + 1;
                put_r(pc, 3'd3, 3'd3, 5'h07, 3'd3); pc = pc + 1;
                put_r(pc, 3'd4, 3'd1, 5'h07, 3'd2); pc = pc + 1;
                put_r(pc, 3'd4, 3'd4, 5'h07, 3'd3); pc = pc + 1;
                put_r(pc, 3'd5, 3'd4, 5'h00, 3'd1); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd1, 3'd7,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd2, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd3, 3'd7,
                        RESULT_BYTE-DATA_BYTE+8); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd4, 3'd7,
                        RESULT_BYTE-DATA_BYTE+12); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd5, 3'd7,
                        RESULT_BYTE-DATA_BYTE+16); pc = pc + 1;
                // A valid zero read must reach a dependent MUL unchanged.
                mem[DATA_HALF] = 16'h0000;
                mem[DATA_HALF + 1] = 16'h0000;
                put_mem(pc, 1'b0, 3'd5, 3'd7, 0); pc = pc + 1;
                put_r(pc, 3'd5, 3'd5, 5'h07, 3'd1);
                // The dependent MUL starts after the load-use bubble, then
                // retains the normal multiplier completion latency.
`ifdef RISCC_FAST_SOFT_MUL
                expected_gap[pc] = XLEN / 2 + 2;
`else
                expected_gap[pc] = 5;
`endif
                pc = pc + 1;
                put_mem(pc, 1'b1, 3'd5, 3'd7,
                        RESULT_BYTE-DATA_BYTE+20); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7,
                        DONE_BYTE-DATA_BYTE);
                if (REGISTER_FETCH) begin
                    // The raw fetch target needs a drain cycle when MUL
                    // releases its held reply; it reaches X two issues later.
                    expected_gap[12] = 2;
                    expected_gap[20] = 2;
                end
            end else if (test_case == 11) begin
                // Raise IRQ during a soft MUL. The handler records the
                // completed product, then RETI resumes at a dependent ALU
                // consumer so both deferred entry and writeback are checked.
                mem[0] = enc_branch(3'd4, 8'sd7); // JMP8 -> 8
                put_mem(2, 1'b1, 3'd3, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4);       // handler observes r3
                mem[3] = enc_r(3'd5, 3'd0, 5'h1f, 3'd0); // RETI S0
                pc = 8;
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd1, 3'd0, 8'd3); pc = pc + 1;
                put_i(pc, 3'd2, 3'd0, 8'd4); pc = pc + 1;
                mem[pc] = enc_r(3'd2, 3'd0, 5'h1f, 3'd0); pc = pc + 1; // CLI
                mem[pc] = enc_r(3'd7, 3'd0, 5'h1f, 3'd0); pc = pc + 1; // STI
                put_r(pc, 3'd3, 3'd1, 5'h07, 3'd2); pc = pc + 1; // MUL
                put_r(pc, 3'd4, 3'd3, 5'h00, 3'd2); pc = pc + 1; // ADD
                put_mem(pc, 1'b1, 3'd4, 3'd7,
                        RESULT_BYTE-DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7,
                        DONE_BYTE-DATA_BYTE);
            end else if (test_case == 12) begin
                // A delayed load response leaves JMP8 in Execute while the
                // registered fetch can already hold its early target. The
                // four stores on the sequential path must be flushed; only
                // the target store and completion marker may take effect.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd1, 3'd0, 8'd0);
                put_mem(2, 1'b0, 3'd3, 3'd7, 0);
                mem[3] = enc_branch(3'd4, 8'sd4); // JMP8 -> 8
                mem[4] = enc_mem(1'b1, 3'd1, 3'd7,
                                 RESULT_BYTE-DATA_BYTE);
                mem[5] = mem[4];
                mem[6] = mem[4];
                mem[7] = mem[4];
                put_i(8, 3'd1, 3'd0, 8'd42);
                put_mem(9, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(10, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(11, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 13) begin
                // CMPI writes r0. Both equality and sign branches consume
                // its saved flags in Execute. Stores between each branch
                // and target expose wrong-path execution; only the final
                // result and DONE stores count.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd1, 3'd0, 8'd3);
                put_i(2, 3'd1, 3'd3, 8'd3); // CMPI r1, 3: r0 = 0
                mem[3] = enc_branch(3'd0, 8'sd2); // BEQZ -> 6
                mem[4] = enc_mem(1'b1, 3'd1, 3'd7,
                                 RESULT_BYTE-DATA_BYTE);
                mem[5] = mem[4];
                put_i(6, 3'd1, 3'd2, 8'hff); // ADDI r1, -1
                put_i(7, 3'd1, 3'd3, 8'd3); // CMPI r1, 3: r0 = -1
                mem[8] = enc_branch(3'd2, 8'sd2); // BLTZ -> 11
                mem[9] = enc_mem(1'b1, 3'd1, 3'd7,
                                 RESULT_BYTE-DATA_BYTE);
                mem[10] = mem[9];
                mem[11] = enc_branch(3'd1, 8'sd2); // BNEZ -> 14
                mem[12] = enc_mem(1'b1, 3'd1, 3'd7,
                                  RESULT_BYTE-DATA_BYTE);
                mem[13] = mem[12];
                put_i(14, 3'd1, 3'd0, 8'd42);
                put_mem(15, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(16, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(17, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 14) begin
                // Load flags must replace stale r0 flags. A younger LDI
                // then overrides a zero load completing on the same edge.
                mem[DATA_HALF] = 0;
                mem[DATA_HALF+1] = 0;
                mem[DATA_HALF+2] = 16'hffff;
                mem[DATA_HALF+3] = 16'hffff;
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd0, 3'd0, 8'd1);
                put_mem(2, 1'b0, 3'd0, 3'd7, 0);
                mem[3] = enc_branch(3'd0, 8'sd2); // BEQZ -> 6
                mem[4] = enc_mem(1'b1, 3'd0, 3'd7, RESULT_BYTE-DATA_BYTE);
                mem[5] = mem[4];
                put_mem(6, 1'b0, 3'd0, 3'd7, 4);
                mem[7] = enc_branch(3'd2, 8'sd2); // BLTZ -> 10
                mem[8] = mem[4];
                mem[9] = mem[4];
                put_mem(10, 1'b0, 3'd0, 3'd7, 0);
                put_i(11, 3'd0, 3'd0, 8'd1);
                mem[12] = enc_branch(3'd1, 8'sd2); // BNEZ -> 15
                mem[13] = mem[4];
                mem[14] = mem[4];
                put_i(15, 3'd1, 3'd0, 8'd42);
                put_mem(16, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(17, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(18, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 15) begin
                // ALU producers exercise forwarding in both RF operand
                // positions before updating the saved flags. Slow r0
                // producers are followed immediately by both zero and sign
                // branches; their wrong-path stores must never execute.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd1, 3'd0, 8'd3);
                put_i(2, 3'd2, 3'd0, 8'd4);
                put_r(3, 3'd3, 3'd1, 5'h00, 3'd2); // ADD r3, r1, r2
                put_r(4, 3'd0, 3'd3, 5'h00, 3'd2); // ADD r0, r3, r2 (A)
                mem[5] = enc_branch(3'd1, 8'sd2); // BNEZ -> 8
                mem[6] = enc_mem(1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                mem[7] = mem[6];

                put_r(8, 3'd4, 3'd1, 5'h00, 3'd2); // ADD r4, r1, r2
                put_r(9, 3'd0, 3'd1, 5'h00, 3'd4); // ADD r0, r1, r4 (B)
                mem[10] = enc_branch(3'd1, 8'sd2); // BNEZ -> 13
                mem[11] = mem[6];
                mem[12] = mem[6];

                put_i(13, 3'd1, 3'd0, 8'd0);
                put_i(14, 3'd2, 3'd0, 8'd9);
                put_r(15, 3'd0, 3'd1, 5'h07, 3'd2); // MUL r0, 0, 9
                mem[16] = enc_branch(3'd0, 8'sd2); // BEQZ -> 19
                mem[17] = mem[6];
                mem[18] = mem[6];

                put_i(19, 3'd1, 3'd0, 8'd0);
                put_i(20, 3'd1, 3'd2, 8'hff); // r1 = -1
                put_i(21, 3'd2, 3'd0, 8'd1);
                put_r(22, 3'd0, 3'd1, 5'h07, 3'd2); // MUL r0, -1, 1
                mem[23] = enc_branch(3'd2, 8'sd2); // BLTZ -> 26
                mem[24] = mem[6];
                mem[25] = mem[6];

                put_i(26, 3'd1, 3'd0, 8'd1);
                // bbb=0 encodes the one-bit shift (the ISA count is bbb+1);
                // the result is zero and must set Z.
                put_r(27, 3'd0, 3'd1, 5'h0c, 3'd0); // SRLI r0, r1, 0
                mem[28] = enc_branch(3'd0, 8'sd2); // BEQZ -> 31
                mem[29] = mem[6];
                mem[30] = mem[6];

                put_i(31, 3'd1, 3'd0, 8'd0);
                put_i(32, 3'd1, 3'd2, 8'hff); // r1 = -1
                // bbb=2 encodes a three-bit iterative shift. Arithmetic right
                // shifting preserves the sign and must set N for BLTZ.
                put_r(33, 3'd0, 3'd1, 5'h0d, 3'd2); // SRAI r0, -1, 2
                mem[34] = enc_branch(3'd2, 8'sd2); // BLTZ -> 37
                mem[35] = mem[6];
                mem[36] = mem[6];

                put_i(37, 3'd1, 3'd0, 8'd42);
                put_mem(38, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(39, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(40, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 16) begin
                // JALR immediately follows an ALU update of its target
                // register. The destination aliases the ALU source, and the
                // sequential stores must be flushed before the target RET.
                // A second JALR consumes a loaded target to cover the slow
                // producer dependency without imposing a timing assertion.
                mem[DATA_HALF] = 16'h0060;
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd1, 3'd0, 8'h3c);
                put_i(2, 3'd1, 3'd2, 8'd4); // ADDI r1, r1, 4 -> 0x40
                put_r(3, 3'd5, 3'd1, 5'h1f, 3'd1); // JALR S5, r1
                mem[4] = enc_branch(3'd4, 8'sd3); // JMP8 -> 8 on return
                mem[5] = enc_mem(1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                mem[6] = mem[5];
                mem[7] = mem[5];

                put_mem(8, 1'b0, 3'd1, 3'd7, 0); // load second target
                put_r(9, 3'd6, 3'd1, 5'h1f, 3'd1); // JALR S6, r1
                mem[10] = enc_branch(3'd4, 8'sd3); // JMP8 -> 14 on return
                mem[11] = mem[5];
                mem[12] = mem[5];
                mem[13] = mem[5];

                put_i(14, 3'd1, 3'd0, 8'd42);
                put_mem(15, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(16, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(17, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);

                // First JALR target: save its byte link (8), then return.
                put_r(32, 3'd1, 3'd5, 5'h1f, 3'd2); // MFS r1, S5
                put_mem(33, 1'b1, 3'd1, 3'd7,
                        RESULT_BYTE-DATA_BYTE+4);
                mem[34] = enc_r(3'd0, 3'd5, 5'h1f, 3'd0); // RET S5
                mem[35] = mem[5]; // must be flushed by RET

                // Second JALR target: save its byte link (20), then return.
                put_r(48, 3'd2, 3'd6, 5'h1f, 3'd2); // MFS r2, S6
                put_mem(49, 1'b1, 3'd2, 3'd7,
                        RESULT_BYTE-DATA_BYTE+8);
                mem[50] = enc_r(3'd0, 3'd6, 5'h1f, 3'd0); // RET S6
                mem[51] = mem[5]; // must be flushed by RET
            end else if (test_case == 18) begin
                // Same useful instructions as the adjacent-CMPI fixture:
                // schedule the DONE and result immediates into branch gaps.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                put_i(1, 3'd1, 3'd0, 8'd3);
                put_i(2, 3'd1, 3'd3, 8'd3);
                put_i(3, 3'd6, 3'd0, DONE_VALUE[7:0]);
                mem[4] = enc_branch(3'd0, 8'sd2);
                mem[5] = enc_mem(1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                mem[6] = mem[5];
                put_i(7, 3'd1, 3'd2, 8'hff);
                put_i(8, 3'd1, 3'd3, 8'd3);
                put_i(9, 3'd1, 3'd0, 8'd42);
                mem[10] = enc_branch(3'd2, 8'sd2);
                mem[11] = mem[5];
                mem[12] = mem[5];
                mem[13] = enc_branch(3'd1, 8'sd2);
                mem[14] = mem[5];
                mem[15] = mem[5];
                put_mem(16, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_mem(17, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
            end else if (test_case == 17) begin
                // RC32 LDPC addresses a literal relative to the following
                // instruction. Its loaded value is consumed
                // immediately by ADD, exercising the load-use interlock and
                // write-first load bypass before the result is stored.
                put_i(0, 3'd7, 3'd0, DATA_BYTE);
                mem[1] = enc_ldpc(3'd1, 8'h24); // PC=2, literal at byte 40
                put_r(2, 3'd2, 3'd1, 5'h00, 3'd1); // ADD r2, r1, r1
                put_mem(3, 1'b1, 3'd2, 3'd7, RESULT_BYTE-DATA_BYTE);
                put_i(4, 3'd6, 3'd0, DONE_VALUE[7:0]);
                put_mem(5, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
                // PC-relative target: next PC byte address 4 + 0x24 = 40.
                mem[20] = 16'h5678;
                mem[21] = 16'h1234;
                expected_gap[2] = 2;
            end else begin
                // Typed accesses are one beat at either width. Native and
                // indexed accesses use one native data request.
                put_i(pc, 3'd7, 3'd0, DATA_BYTE); pc = pc + 1;
                put_i(pc, 3'd6, 3'd0, DATA_BYTE + 1); pc = pc + 1;
                put_i(pc, 3'd0, 3'd0, 8'd0); pc = pc + 1; // LDX rb
                put_r(pc, 3'd1, 3'd7, 5'h0a, 3'd0); pc = pc + 1; // LDB
                put_mem_after_load(pc, 1'b1, 3'd1, 3'd7, RESULT_BYTE-DATA_BYTE);
                pc = pc + 1;
                put_r(pc, 3'd2, 3'd7, 5'h0e, 3'd0); pc = pc + 1; // LDBS
                put_mem_after_load(pc, 1'b1, 3'd2, 3'd7, RESULT_BYTE-DATA_BYTE+4);
                pc = pc + 1;
                put_r(pc, 3'd3, 3'd6, 5'h0a, 3'd0); pc = pc + 1; // odd LDB
                put_mem_after_load(pc, 1'b1, 3'd3, 3'd7, RESULT_BYTE-DATA_BYTE+8);
                pc = pc + 1;
                put_r(pc, 3'd4, 3'd6, 5'h0e, 3'd0); pc = pc + 1; // odd LDBS
                put_mem_after_load(pc, 1'b1, 3'd4, 3'd7, RESULT_BYTE-DATA_BYTE+12);
                pc = pc + 1;
                put_r(pc, 3'd1, 3'd6, 5'h0b, 3'd0); pc = pc + 1; // STB odd
                put_mem(pc, 1'b0, 3'd5, 3'd7, 0); pc = pc + 1; // LD
                put_r(pc, 3'd5, 3'd7, 5'h08, 3'd0); pc = pc + 1; // LDX
                put_mem_after_load(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+16);
                pc = pc + 1;
                if (XLEN == 32) begin
                    put_r(pc, 3'd5, 3'd7, 5'h0a, 3'd2); pc = pc + 1; // LDH
                    put_mem_after_load(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+24);
                    pc = pc + 1; // native check of LDH
                    put_r(pc, 3'd5, 3'd7, 5'h0e, 3'd2); pc = pc + 1; // LDHS
                    put_mem_after_load(pc, 1'b1, 3'd5, 3'd7, RESULT_BYTE-DATA_BYTE+28);
                    pc = pc + 1;
                    // RC32 direct typed halfwords use bbb=010.  This
                    // writes the original data halfword once more.
                    put_r(pc, 3'd5, 3'd7, 5'h0b, 3'd2); pc = pc + 1; // STH
                end
                // The marker is after all checks and is always native-width.
                put_i(pc, 3'd6, 3'd0, DONE_VALUE[7:0]); pc = pc + 1;
                put_mem(pc, 1'b1, 3'd6, 3'd7, DONE_BYTE-DATA_BYTE);
                // This raw memory cannot replace a held fetch response in
                // the same cycle. After the last load-use stall, draining it
                // leaves one fetch bubble two instructions later.
                if (REGISTER_FETCH)
                    expected_gap[XLEN == 32 ? 20 : 16] = 2;
            end
        end
    endtask

    // Each private port is independently pipelined.  A command is
    // accepted only when STB and STALL permit it; a delayed response remains
    // associated with the one accepted command until ACK.
    wire i_stall_pattern = (cycle_q[2:0] == 3'd2) ||
                           (cycle_q[2:0] == 3'd3);
    wire d_stall_pattern = (cycle_q[2:0] == 3'd5) ||
                           (cycle_q[2:0] == 3'd6);
    wire i_accept = imem_cyc && imem_stb && !imem_stall;
    wire d_accept = dmem_cyc && dmem_stb && !dmem_stall;
    wire stream_d_accept = d_accept &&
                           dmem_addr >= STREAM_WORD &&
                           dmem_addr < STREAM_WORD + 16;
    wire [31:0] d_live_read;
    function automatic [31:0] read_word(input integer word_address);
        begin
            read_word = {mem[(word_address << 1) + 1],
                         mem[word_address << 1]};
        end
    endfunction
    assign d_live_read = read_word(dmem_addr);

    assign imem_stall = (stall_mode && imem_cyc && imem_stb) &&
                        ((i_response_pending_q &&
                          (i_response_wait_q == 3'd1)) ||
                         i_stall_pattern);
    assign dmem_stall = (stall_mode && dmem_cyc && dmem_stb) &&
                        ((d_response_pending_q &&
                          (d_response_wait_q == 3'd1)) ||
                         d_stall_pattern);
    assign imem_ack = i_response_pending_q &&
                      (i_response_wait_q == 3'd1);
    assign dmem_ack = d_response_pending_q &&
                      (d_response_wait_q == 3'd1);
    // The registered-fetch core retains a fetched response while Decode or
    // Execute is occupied, so the memory model must keep its last response
    // value valid while the port is idle in that mode.
    assign imem_rdata = i_response_pending_q ? i_response_data_q :
                        REGISTER_FETCH ? i_response_data_q : 16'hdead;
    assign dmem_rdata = d_response_pending_q ? d_response_data_q : 32'hdead_beef;

    // Instruction port model.
    always @(posedge clk) begin
        if (rst) begin
            i_response_pending_q <= 1'b0;
            i_response_addr_q <= '0;
            i_response_data_q <= 16'h0;
            i_response_wait_q <= 3'd0;
            i_mix_fast_q <= 1'b1;
            i_accepted_count <= 0;
            i_response_count <= 0;
            i_response_drop_count <= 0;
            fast_response_count <= 0;
            ack_stall_count <= 0;
            stalled_count <= 0;
            i_response_order_checks <= 0;
            literal_reads <= 0;
            i_response_drop_q <= 1'b0;
            i_last_response_data_q <= 16'hdead;
        end else begin
            if (i_accept) begin
                i_accepted_count <= i_accepted_count + 1;
                if (test_case == 3 && imem_addr == 3)
                    literal_reads <= literal_reads + 1;
                i_response_data_q <= mem[imem_addr];
                i_response_addr_q <= imem_addr;
                if (i_response_pending_q && imem_ack)
                    i_response_count <= i_response_count + 1;
                i_response_pending_q <= 1'b1;
                i_response_wait_q <= wait_mode ? 3'd2 :
                                     mix_mode ? (i_mix_fast_q ? 3'd1 : 3'd2) :
                                     3'd1;
                if (mix_mode && !i_response_pending_q)
                    i_mix_fast_q <= ~i_mix_fast_q;
            end else if (i_response_pending_q && imem_ack) begin
                i_response_pending_q <= 1'b0;
                i_response_wait_q <= 3'd0;
                i_response_count <= i_response_count + 1;
                i_response_drop_count <= i_response_drop_count + 1;
                i_response_drop_q <= 1'b1;
                i_last_response_data_q <= i_response_data_q;
            end else if (i_response_pending_q && i_response_wait_q > 1) begin
                i_response_wait_q <= i_response_wait_q - 1'b1;
            end
            if (i_response_pending_q && imem_ack &&
                i_response_wait_q == 3'd1)
                fast_response_count <= fast_response_count + 1;
            if (i_response_pending_q && imem_ack && imem_stall &&
                imem_cyc && imem_stb)
                ack_stall_count <= ack_stall_count + 1;
            if (imem_stall && imem_cyc && imem_stb) begin
                stalled_count <= stalled_count + 1;
            end
            if (imem_ack && !i_response_pending_q)
                fail("instruction ACK without an accepted request");
            if (i_response_pending_q && imem_ack) begin
                if (imem_rdata !== i_response_data_q)
                    fail("instruction response data changed after acceptance");
                i_response_order_checks <= i_response_order_checks + 1;
            end
            if (i_response_pending_q && !imem_cyc)
                fail("instruction CYC dropped before response");
            if (i_accept && i_response_pending_q && !imem_ack)
                fail("accepted second instruction request before response");
            if (i_response_drop_q && !i_response_pending_q && !imem_ack &&
                imem_rdata == i_last_response_data_q)
                fail("instruction response remained valid after ACK");
            i_response_drop_q <= 1'b0;
        end
    end

    // Data port model. Data addresses are native word addresses and reads
    // return the complete 32-bit little-endian word. A store is applied at
    // acceptance exactly once; its enabled halfword lanes count as the
    // architectural beats used by the existing checks.
    always @(posedge clk) begin
        if (rst) begin
            d_response_pending_q <= 1'b0;
            d_response_addr_q <= '0;
            d_response_data_q <= 32'h0;
            d_response_wait_q <= 3'd0;
            d_accepted_count <= 0;
            d_response_count <= 0;
            d_response_drop_count <= 0;
            d_response_order_checks <= 0;
            data_stalled_count <= 0;
            d_response_drop_q <= 1'b0;
            d_last_response_data_q <= 32'hdead_beef;
            write_count <= 0;
            stream_data_accepts <= 0;
            stream_data_gap_errors <= 0;
            stream_last_accept_cycle <= 0;
        end else begin
            if (d_accept) begin
                d_accepted_count <= d_accepted_count + 1;
                d_response_data_q <= d_live_read;
                d_response_addr_q <= dmem_addr;
                if (d_response_pending_q && dmem_ack)
                    d_response_count <= d_response_count + 1;
                // Cache and SRAM replies have a minimum latency of one clock.
                d_response_pending_q <= 1'b1;
                d_response_wait_q <= (test_case == 12 && !wait_mode &&
                                      !stall_mode && !mix_mode) ? 3'd6 :
                                     wait_mode ? 3'd2 : 3'd1;
                if (dmem_we) begin
                    if (dmem_wmask[0]) mem[(dmem_addr << 1)][7:0] <= dmem_wdata[7:0];
                    if (dmem_wmask[1]) mem[(dmem_addr << 1)][15:8] <= dmem_wdata[15:8];
                    if (dmem_wmask[2]) mem[(dmem_addr << 1) + 1][7:0] <= dmem_wdata[23:16];
                    if (dmem_wmask[3]) mem[(dmem_addr << 1) + 1][15:8] <= dmem_wdata[31:24];
                    write_count <= write_count +
                        ((|dmem_wmask[1:0]) ? 1 : 0) +
                        ((|dmem_wmask[3:2]) ? 1 : 0);
                    if (dmem_addr == (DONE_HALF >> 1) &&
                        dmem_wdata[7:0] == DONE_VALUE[7:0]) begin
                        done_seen_q <= 1'b1;
                        done_age_q <= 0;
                    end
                end
            end else if (d_response_pending_q && dmem_ack) begin
                d_response_pending_q <= 1'b0;
                d_response_wait_q <= 3'd0;
                d_response_count <= d_response_count + 1;
                d_response_drop_count <= d_response_drop_count + 1;
                d_response_drop_q <= 1'b1;
                d_last_response_data_q <= d_response_data_q;
            end else if (d_response_pending_q && d_response_wait_q > 1) begin
                d_response_wait_q <= d_response_wait_q - 1'b1;
            end
            if (stream_d_accept) begin
                if (stream_data_accepts != 0 &&
                    cycle_q != stream_last_accept_cycle + 1)
                    stream_data_gap_errors <= stream_data_gap_errors + 1;
                stream_data_accepts <= stream_data_accepts + 1;
                stream_last_accept_cycle <= cycle_q;
            end
            if (dmem_stall && dmem_cyc && dmem_stb)
                data_stalled_count <= data_stalled_count + 1;
            if (d_response_pending_q && dmem_ack) begin
                if (dmem_rdata !== d_response_data_q)
                    fail("data response changed after acceptance");
                d_response_order_checks <= d_response_order_checks + 1;
            end
            if (d_response_pending_q && !dmem_cyc)
                fail("data CYC dropped before response");
            if (d_accept && d_response_pending_q && !dmem_ack)
                fail("accepted second data request before response");
            if (d_response_drop_q && !d_response_pending_q && !dmem_ack &&
                dmem_rdata == d_last_response_data_q)
                fail("data response remained valid after ACK");
            d_response_drop_q <= 1'b0;
        end
    end

    // Decode is a single holding slot. Once a fetched instruction is held
    // without issue, it and its payload must stay stable while fetch retries.
    reg held_decode_q;
    reg [15:0] held_instr_snapshot_q;
    always @(posedge clk) begin
        if (rst) begin
            held_decode_q <= 1'b0;
            held_instr_snapshot_q <= 16'h0;
        end else begin
            if (held_decode_q && dut.d_valid_q && !dut.d_issue &&
                !dut.frontend_flush &&
                dut.d_instr_q != held_instr_snapshot_q)
                fail("Decode instruction changed while held");
            if (dut.d_valid_q && !dut.d_issue && !dut.frontend_flush) begin
                held_decode_q <= 1'b1;
                held_instr_snapshot_q <= dut.d_instr_q;
            end else begin
                held_decode_q <= 1'b0;
            end
        end
    end

    // Bus and IRQ-specific observations shared by the two models.
    always @(posedge clk) begin
        if (rst) begin
            cycle_q <= 0;
            data_beat_count <= 0;
            irq_take_count <= 0;
            irq_epc_errors <= 0;
            reti_count <= 0;
            main_data_accepts <= 0;
            irq_shift_entry_errors <= 0;
            irq_mul_entry_errors <= 0;
            alias_data_accepts <= 0;
            alias_addr_errors <= 0;
            alias_irq_entry_errors <= 0;
            target_pc_commits <= 0;
            early_jump_observed_q <= 1'b0;
            irq_raised_q <= 1'b0;
            irq_withdrawn_q <= 1'b0;
            irq_epc_pending_q <= 1'b0;
            irq_epc_expected_q <= 0;
            done_seen_q <= 1'b0;
            done_age_q <= 0;
        end else begin
            cycle_q <= cycle_q + 1'b1;
            // Every issued branch carries its actual Decode decision. This
            // also covers transient IRQ requests while Execute is empty.
            if (REGISTER_FETCH && dut.d_issue && dut.d_branch && !dut.d_flag_wait &&
                ((dut.d_redirected_q || dut.d_early_redirect) !==
                 (dut.d_ddd[2] ||
                  ((dut.d_ddd[1] ? dut.r0_negative_q : dut.r0_zero_q) ^
                   dut.d_ddd[0]))))
                fail("Decode branch decision differs from newest r0 flags");
            if (done_seen_q && done_age_q != 4'hf)
                done_age_q <= done_age_q + 1'b1;
            if (irq_epc_pending_q) begin
                if (!dut.rf_we || dut.rf_waddr !== 4'h8 ||
                    dut.rf_wdata !== irq_epc_expected_q)
                    irq_epc_errors <= irq_epc_errors + 1;
                irq_epc_pending_q <= 1'b0;
            end
            if ((test_case == 7 || test_case == 9) && dut.in_shift &&
                dut.x_pc_q == 14 && !irq_raised_q) begin
                irq_raised_q <= 1'b1;
                irq <= 1'b1;
            end
            if (test_case == 11 && dut.in_mul && !irq_raised_q) begin
                irq_raised_q <= 1'b1;
                irq <= 1'b1;
            end

            if (test_case == 12 && REGISTER_FETCH && dut.d_valid &&
                dut.x_valid_q && dut.x_pc_q == 3 && !dut.core_advance)
                early_jump_observed_q <= 1'b1;
            if (test_case == 9 && dut.take_irq &&
                (dut.fetch_pending || (REGISTER_FETCH && dut.fetch_held_q)) &&
                !imem_ack && !irq_withdrawn_q) begin
                irq <= 1'b0;
                irq_withdrawn_q <= 1'b1;
            end

            if (test_case == 8 && d_accept && !dmem_we) begin
                case (alias_data_accepts)
                    0: if (dmem_addr != (DATA_HALF >> 1))
                           alias_addr_errors <= alias_addr_errors + 1;
                    1: if (dmem_addr != ((DATA_HALF + 2) >> 1))
                           alias_addr_errors <= alias_addr_errors + 1;
                    default: alias_addr_errors <= alias_addr_errors + 1;
                endcase
                alias_data_accepts <= alias_data_accepts + 1;
                if (alias_data_accepts == 0 && !irq_raised_q) begin
                    irq_raised_q <= 1'b1;
                    irq <= 1'b1;
                end
            end
            if (test_case == 5 && d_accept && !dmem_we) begin
                data_beat_count <= data_beat_count + 1;
                main_data_accepts <= main_data_accepts + 1;
                if (data_beat_count + 1 == irq_beat)
                    irq <= 1'b1;
            end
            if ((test_case == 5 || test_case == 7 || test_case == 8 ||
                 test_case == 9 || test_case == 11) && dut.take_irq &&
                dut.frontend_flush) begin
                irq_take_count <= irq_take_count + 1;
                irq <= 1'b0;
                if ((test_case == 7 || test_case == 9) && dut.in_shift)
                    irq_shift_entry_errors <= irq_shift_entry_errors + 1;
                if (test_case == 11 && dut.in_mul)
                    irq_mul_entry_errors <= irq_mul_entry_errors + 1;
                if ((test_case == 5 || test_case == 8) && dut.data_pending)
                    fail("IRQ entered with a data request still pending");
                if (test_case == 5 &&
                    last_commit_pc != IRQ_MAIN_RETURN_PC &&
                    last_commit_pc != IRQ_MAIN_LOAD_PC)
                    fail("IRQ entered outside the completed load/store boundary");
                if (test_case == 5 && dut.x_pc_q != last_commit_pc + 1)
                    fail("load/store IRQ skipped or repeated an instruction");
                if (test_case == 8 &&
                    last_commit_pc != IRQ_ALIAS_RETURN_PC &&
                    last_commit_pc != IRQ_ALIAS_RETURN_PC - 1)
                    fail("aliased-load IRQ did not follow a completed load");
                // With one-cycle replies the second independent load can
                // issue before the sampled IRQ arrives. Either completed
                // load is a legal boundary; EPC must name its successor.
                if (test_case == 8 && dut.x_pc_q != last_commit_pc + 1)
                    fail("aliased-load IRQ skipped or repeated an instruction");
                // IRQ EPC writeback is the W-stage entry one edge after the
                // interrupt redirect, while X metadata remains this entry.
                irq_epc_pending_q <= 1'b1;
                irq_epc_expected_q <= dut.x_pc_q << 1;
            end
        end
    end

    // Commit counters use the internal X stage metadata, which avoids adding
    // test-only ports to the production core.  A run of adjacent commits is
    // the direct observable for one IPC on this in-order machine.
    always @(posedge clk) begin
        if (!rst) begin
            if (dut.commit_valid && !dut.run_commit &&
                test_case != 6 && test_case != 7 && test_case != 9 &&
                test_case != 10 && test_case != 11 && test_case != 15)
                fail("non-multicycle test committed without run_commit");
            if (dut.commit_valid) begin
                if (test_case == 12 && dut.x_pc_q == 8)
                    target_pc_commits <= target_pc_commits + 1;
                if (test_case == 15 && dut.x_pc_q == 4 &&
                    dut.x_result !== {{(XLEN-4){1'b0}}, 4'd11})
                    fail("A-forwarded ALU producer produced the wrong r0 result");
                if (test_case == 15 && dut.x_pc_q == 9 &&
                    dut.x_result !== {{(XLEN-4){1'b0}}, 4'd10})
                    fail("B-forwarded ALU producer produced the wrong r0 result");
                if (!have_last_commit && strict_timing &&
                    (test_case == 0 || test_case == 1)) begin
                    if (REGISTER_FETCH) begin
                        if (cycle_q != REGISTERED_FETCH_STARTUP_GAP)
                            fail("registered fetch startup did not take three edges");
                    end else if (cycle_q != COMPACT_FETCH_STARTUP_GAP) begin
                        fail("compact fetch startup did not take three edges");
                    end
                end
                if (test_case == 3) begin
                    if (dut.x_pc_q == 3)
                        fail("JALL literal issued as an instruction");
                    if (dut.x_pc_q == 2) call_commits <= call_commits + 1;
                    if (have_last_commit && strict_timing) begin
                        if (last_commit_pc == 2 &&
                            (dut.x_pc_q != (CALL_TARGET >> 1) ||
                             cycle_q - last_commit_cycle !=
                             (REGISTER_FETCH ? REGISTERED_JALL_REDIRECT_GAP :
                              COMPACT_FETCH_REDIRECT_GAP)))
                            fail(REGISTER_FETCH ?
                                 "JALL target did not commit after registered redirect" :
                                 "JALL target did not commit after one redirect bubble");
                        if (last_commit_pc == (CALL_TARGET >> 1) &&
                             (dut.x_pc_q != 4 ||
                             cycle_q - last_commit_cycle !=
                             (REGISTER_FETCH ? REGISTERED_INDIRECT_REDIRECT_GAP :
                              COMPACT_FETCH_REDIRECT_GAP)))
                            fail(REGISTER_FETCH ?
                                 "RET target did not commit after registered redirect" :
                                 "RET target did not commit after one redirect bubble");
                    end
                end
                if (test_case == 16 && strict_timing) begin
                    if (last_commit_pc == 2 &&
                        (dut.x_pc_q != 3 || cycle_q - last_commit_cycle != 1))
                        fail("ALU-dependent JALR inserted a producer-consumer bubble");
                    if (last_commit_pc == 3 &&
                        (dut.x_pc_q != 32 ||
                         cycle_q - last_commit_cycle !=
                         (REGISTER_FETCH ? REGISTERED_INDIRECT_REDIRECT_GAP :
                          COMPACT_FETCH_REDIRECT_GAP)))
                        fail("ALU-dependent JALR target did not commit at the expected gap");
                    if (last_commit_pc == 34 &&
                        (dut.x_pc_q != 4 ||
                         cycle_q - last_commit_cycle !=
                         (REGISTER_FETCH ? REGISTERED_INDIRECT_REDIRECT_GAP :
                          COMPACT_FETCH_REDIRECT_GAP)))
                        fail("RET target did not commit at the expected indirect gap");
                end
                if (test_case == 13 && strict_timing) begin
                    if (last_commit_pc == 3 &&
                        (dut.x_pc_q != 6 || cycle_q - last_commit_cycle != (REGISTER_FETCH ? 3 : 2)))
                        fail("BEQZ target did not commit after two cycles");
                    if (last_commit_pc == 8 &&
                        (dut.x_pc_q != 11 || cycle_q - last_commit_cycle != (REGISTER_FETCH ? 3 : 2)))
                        fail("BLTZ target did not commit after two cycles");
                    if (last_commit_pc == 11 &&
                        (dut.x_pc_q != 14 || cycle_q - last_commit_cycle != 2))
                        fail("BNEZ target did not commit after one taken bubble");
                end
                if (test_case == 18 && strict_timing) begin
                    if ((last_commit_pc == 2 || last_commit_pc == 3 ||
                         last_commit_pc == 7 || last_commit_pc == 8 ||
                         last_commit_pc == 9) &&
                        (dut.x_pc_q != last_commit_pc + 1 ||
                         cycle_q - last_commit_cycle != 1))
                        fail("scheduled CMPI/filler/branch inserted a dependency bubble");
                    if (last_commit_pc == 4 &&
                        (dut.x_pc_q != 7 || cycle_q - last_commit_cycle != 2))
                        fail("scheduled BEQZ did not have one taken bubble");
                    if (last_commit_pc == 10 &&
                        (dut.x_pc_q != 13 || cycle_q - last_commit_cycle != 2))
                        fail("scheduled BLTZ did not have one taken bubble");
                    if (last_commit_pc == 13 &&
                        (dut.x_pc_q != 16 || cycle_q - last_commit_cycle != 2))
                        fail("scheduled BNEZ did not have one taken bubble");
                end
                if (test_case == 5 && dut.x_pc_q == 6)
                    reti_count <= reti_count + 1;
                if ((test_case == 7 || test_case == 9) && dut.x_pc_q == 3)
                    reti_count <= reti_count + 1;
                if (test_case == 11 && dut.x_pc_q == 3)
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
                    test_case != 7 && test_case != 8 && test_case != 9 &&
                    test_case != 12 && test_case != 13 && test_case != 14 &&
                    test_case != 15 && test_case != 16 && test_case != 18) begin
                    wanted_gap = expected_gap[dut.x_pc_q];
                    if (test_case == 4 &&
                        ((last_commit_pc == 3 && dut.x_pc_q == 2) ||
                         (last_commit_pc == 4 && dut.x_pc_q == 7) ||
                         (last_commit_pc == 10 && dut.x_pc_q == 12)))
                        wanted_gap = COMPACT_FETCH_REDIRECT_GAP;
                    if (REGISTER_FETCH && test_case == 4 &&
                        ((last_commit_pc == 3 && dut.x_pc_q == 2) ||
                         (last_commit_pc == 10 && dut.x_pc_q == 12)))
                        wanted_gap = 3;
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
            if (i_response_count > i_accepted_count ||
                i_accepted_count - i_response_count > 1 ||
                d_response_count > d_accepted_count ||
                d_accepted_count - d_response_count > 1)
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
                if (stream_data_accepts != STREAM_OPS)
                    fail("independent load/store stream request count mismatch");
                if (!wait_mode && !stall_mode && !mix_mode &&
                    stream_data_gap_errors != 0)
                    fail("independent load/store stream did not sustain one request per cycle");
                if (mem[(STREAM_BYTE >> 1) + 16] !== 16'h0033 ||
                    mem[(STREAM_BYTE >> 1) + 17] !== 16'h0000 ||
                    mem[(STREAM_BYTE >> 1) + 18] !== 16'h0033 ||
                    mem[(STREAM_BYTE >> 1) + 19] !== 16'h0000 ||
                    mem[(STREAM_BYTE >> 1) + 20] !== 16'h0033 ||
                    mem[(STREAM_BYTE >> 1) + 21] !== 16'h0000 ||
                    mem[(STREAM_BYTE >> 1) + 22] !== 16'h0033 ||
                    mem[(STREAM_BYTE >> 1) + 23] !== 16'h0000)
                    fail("independent load/store stream final values mismatch");
            end else if (test_case == 1) begin
                if (mem[RESULT_HALF] !== 16'h0022)
                    fail("dependent ALU forwarding result mismatch");
                if (simple_gap_errors != 0)
                    fail("dependent ALU stream did not sustain one IPC");
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
                    fail("IRQ native-word request case requires RC32");
                if (mem[RESULT_HALF] !== 16'h80a5 ||
                    mem[RESULT_HALF + 1] !== 16'h1234)
                    fail("IRQ interrupted RC32 load result mismatch");
                if (mem[RESULT_HALF + 2][7:0] !== 8'h01)
                    fail("IRQ handler did not record exactly one entry");
                if (data_beat_count != 1 || main_data_accepts != 1)
                    fail("RC32 load request was replayed or lost around IRQ");
                if (irq_take_count != 1 || irq_epc_errors != 0)
                    fail("IRQ did not save the next instruction EPC");
                if (reti_count != 1)
                    fail("IRQ handler did not return through RETI");
            end else if (test_case == 6) begin
                if (mem[RESULT_HALF] !== 16'h0040 ||
                    mem[RESULT_HALF + 2] !== 16'h0008)
                    fail("shift or multiply result mismatch");
            end else if (test_case == 7 || test_case == 9) begin
                if (mem[RESULT_HALF] !== 16'h0002 ||
                    mem[RESULT_HALF + 2] !== 16'h0001)
                    fail("shift feedback or dependent result mismatch");
                if (irq_take_count != 1 || irq_epc_errors != 0 ||
                    irq_shift_entry_errors != 0)
                    fail("IRQ was not deferred until shift completion");
                if (reti_count != 1)
                    fail("shift IRQ handler did not return through RETI");
                if (test_case == 9 && wait_mode && !REGISTER_FETCH &&
                    !irq_withdrawn_q)
                    fail("IRQ was not withdrawn during a pending redirect");
            end else if (test_case == 8) begin
                if (XLEN != 32)
                    fail("aliased native-load case requires RC32");
                if (mem[RESULT_HALF] !== 16'h82a8 ||
                    mem[RESULT_HALF + 1] !== 16'h1234)
                    fail("aliased load or dependent result mismatch");
                if (mem[RESULT_HALF + 2][7:0] !== 8'h01)
                    fail("aliased-load IRQ handler did not record one entry");
                if (alias_data_accepts != 2 || alias_addr_errors != 0)
                    fail("aliased native-load requests were replayed or lost");
                if (irq_take_count != 1 || irq_epc_errors != 0 ||
                    alias_irq_entry_errors != 0)
                    fail("aliased-load IRQ did not save the second load EPC");
                if (reti_count != 1)
                    fail("aliased-load IRQ handler did not return through RETI");
            end else if (test_case == 10) begin
                if (mem[RESULT_HALF] !== 16'h000c ||
                    (XLEN == 32 && mem[RESULT_HALF + 1] !== 16'h0000) ||
                    mem[RESULT_HALF + 2] !== 16'h003c ||
                    (XLEN == 32 && mem[RESULT_HALF + 3] !== 16'h0000) ||
                    mem[RESULT_HALF + 4] !== 16'h0031 ||
                    (XLEN == 32 && mem[RESULT_HALF + 5] !== 16'h0000) ||
                    mem[RESULT_HALF + 6] !== 16'h89d0 ||
                    (XLEN == 32 && mem[RESULT_HALF + 7] !== 16'h0000) ||
                    mem[RESULT_HALF + 8] !== 16'h89dc ||
                    (XLEN == 32 && mem[RESULT_HALF + 9] !== 16'h0000) ||
                    mem[RESULT_HALF + 10] !== 16'h0000 ||
                    (XLEN == 32 && mem[RESULT_HALF + 11] !== 16'h0000))
                    fail("MUL alias or dependent result mismatch");
                if (simple_gap_errors != 0)
                    fail("MUL or dependent consumer latency changed");
            end else if (test_case == 11) begin
                if (mem[RESULT_HALF] !== 16'h0010 ||
                    (XLEN == 32 && mem[RESULT_HALF + 1] !== 16'h0000) ||
                    mem[RESULT_HALF + 2] !== 16'h000c ||
                    (XLEN == 32 && mem[RESULT_HALF + 3] !== 16'h0000))
                    fail("IRQ-interrupted MUL result mismatch");
                if (irq_take_count != 1 || irq_epc_errors != 0 ||
                    irq_mul_entry_errors != 0)
                    fail("IRQ was not deferred until MUL completion");
                if (reti_count != 1)
                    fail("MUL IRQ handler did not return through RETI");
            end else if (test_case == 12) begin
                if (mem[RESULT_HALF] !== 16'h002a)
                    fail("early JMP8 target did not execute exactly once");
                if (write_count != (XLEN == 32 ? 4 : 2))
                    fail("flushed JMP8 path produced an unexpected store");
                if (target_pc_commits != 1)
                    fail("JMP8 target committed more than once or not at all");
                if (REGISTER_FETCH && strict_timing && !early_jump_observed_q)
                    fail("registered fetch did not hold JMP8 target behind load");
            end else if (test_case == 13 || test_case == 14 || test_case == 18) begin
                if (mem[RESULT_HALF] !== 16'h002a)
                    fail("r0 branch chain did not reach final result");
                if (write_count != (XLEN == 32 ? 4 : 2))
                    fail("r0 branch chain executed a wrong-path store");
            end else if (test_case == 15) begin
                if (mem[RESULT_HALF] !== 16'h002a)
                    fail("slow r0 producer branch chain did not reach final result");
                if (write_count != (XLEN == 32 ? 4 : 2))
                    fail("slow r0 producer branch executed a wrong-path store");
            end else if (test_case == 16) begin
                if (mem[RESULT_HALF] !== 16'h002a ||
                    mem[RESULT_HALF + 2] !== 16'h0008 ||
                    mem[RESULT_HALF + 4] !== 16'h0014 ||
                    (XLEN == 32 &&
                     (mem[RESULT_HALF + 1] !== 16'h0000 ||
                      mem[RESULT_HALF + 3] !== 16'h0000 ||
                      mem[RESULT_HALF + 5] !== 16'h0000)))
                    fail("JALR link, load target, or return result mismatch");
                if (write_count != (XLEN == 32 ? 8 : 4))
                    fail("JALR or RET executed a wrong-path store");
            end else if (test_case == 17) begin
                if (XLEN != 32 || mem[RESULT_HALF] !== 16'hacf0 ||
                    mem[RESULT_HALF + 1] !== 16'h2468 ||
                    mem[DONE_HALF] !== DONE_VALUE ||
                    mem[DONE_HALF + 1] !== 16'h0000)
                    fail("LDPC producer or dependent consumer result mismatch");
                if (write_count != 4)
                    fail("LDPC program executed an unexpected store");
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
            $display("PASS CASE %0d XLEN=%0d cycles=%0d commits=%0d max_ipc_run=%0d accepts=%0d responses=%0d fast_responses=%0d ack_stalls=%0d stalls=%0d response_order=%0d response_drops=%0d",
                     test_case, XLEN, cycle_q, commit_count, max_commit_run,
                     i_accepted_count + d_accepted_count,
                     i_response_count + d_response_count, fast_response_count,
                     ack_stall_count, stalled_count + data_stalled_count,
                     i_response_order_checks + d_response_order_checks,
                     i_response_drop_count + d_response_drop_count);
            $finish(0);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        irq = 1'b0;
        wait_mode = $test$plusargs("WAIT");
        mix_mode = $test$plusargs("MIX");
        stall_mode = $test$plusargs("STALL") || mix_mode;
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
        i_accepted_count = 0;
        i_response_count = 0;
        d_accepted_count = 0;
        d_response_count = 0;
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
        if (irq_beat != 1)
            fail("IRQ_BEAT must be 1 for the native-word data port");
        i_response_drop_q = 1'b0;
        d_response_drop_q = 1'b0;
        fast_response_count = 0;
        ack_stall_count = 0;
        stalled_count = 0;
        i_response_order_checks = 0;
        d_response_order_checks = 0;
        i_response_drop_count = 0;
        d_response_drop_count = 0;
        i_mix_fast_q = 1'b1;
        i_last_response_data_q = 16'hdead;
        d_last_response_data_q = 32'hdead_beef;
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
