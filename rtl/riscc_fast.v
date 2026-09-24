// riscc_fast.v : three-stage RC16/RC32 Full pipeline.
//
// The pipeline is IF, Decode/RF, Execute. Decode drives two replicated
// synchronous MLAB register files; their registered read outputs are the
// Execute operands. Both RF mappings provide a write-first architectural
// view so dependent instructions can issue without a pipeline bubble.
//
// Iterative shifts and MUL hold Execute until complete. RC32 native loads
// and stores take two memory beats; typed accesses take one. MUL uses a
// registered DSP by default; RISCC_FAST_SOFT_MUL selects an iterative fabric
// implementation. The instruction, destination, and operands remain owned by
// X until the operation commits. The unified synchronous memory port is used
// for both fetch and data accesses.

`default_nettype none

module riscc_fast #(
    parameter integer XLEN = 16,
    parameter [XLEN-1:0] RESET_PC = 0  // halfword address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // level-sensitive; sampled between instructions

    output wire [XLEN-2:0] mem_addr,   // halfword address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,  // byte-lane enables
    output wire        mem_we,
    output wire        mem_cyc,    // Wishbone cycle, including pending response
    output wire        mem_stb,    // command valid until accepted
    input  wire        mem_stall,  // target cannot accept this command
    input  wire        mem_ack     // response, including on the acceptance edge
);
    initial begin
        if (XLEN != 16 && XLEN != 32)
            $error("riscc_fast: XLEN must be 16 or 32");
    end

    // ------------------------------------------------------------------
    // Pipeline state and side-state control
    // ------------------------------------------------------------------
    localparam [1:0] ST_RUN   = 2'd0;
    localparam [1:0] ST_SHIFT = 2'd1;
    localparam [1:0] ST_MUL   = 2'd2;
    (* syn_encoding = "user" *) reg [1:0] state_q;
    wire in_run   = state_q == ST_RUN;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;

    reg interrupt_enable_q;
    reg interrupt_request_q;

    // ------------------------------------------------------------------
    // IF and Decode/RF stages
    // ------------------------------------------------------------------
    // One accepted request may await a response. ACK can complete it while
    // the next command is offered; STALL controls only that next acceptance.
    // Immediate replies use the existing Decode and writeback data paths.
    // Last accepted fetch address: also D's PC, and X's PC+1 whenever
    // X is valid. This one register supplies every stage's PC base.
    reg [XLEN-2:0] f_pc_q;
    reg bus_pending_q;
    reg d_valid_q;
    wire core_advance = !bus_pending_q || mem_ack;
    // A pending fetch owns the empty Decode slot. A pending data beat
    // retains the younger instruction there, so its valid bit is the tag.
    wire data_pending = bus_pending_q && d_valid_q;
    wire fetch_pending = bus_pending_q && !d_valid_q;

    // Decode normally reads the SRAM output directly. Its existing holding
    // register saves a response when Execute is occupied. JALL issues like
    // an ordinary opcode; its sequential literal returns directly to Execute.
    reg [15:0] d_instr_q;
    // Response ownership selects the front-end action. core_advance below
    // waits for ACK before either issuing or capturing a pending fetch.
    wire d_valid = d_valid_q || bus_pending_q;
    wire [15:0] d_instr = d_valid_q ? d_instr_q : mem_rdata;

    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field. Prefixes identify the
    // Decode (d_) and Execute (x_) stages.
    wire [1:0] d_class = d_instr[15:14];
    wire [2:0] d_ddd = d_instr[13:11];
    wire [2:0] d_aaa = d_instr[10:8];
    wire [4:0] d_f5 = d_instr[7:3];
    wire [2:0] d_bbb = d_instr[2:0];

    wire d_imm_memory = ~d_class[1] & d_class[0];
    wire d_imm_store = d_imm_memory & d_instr[0];
    wire d_immediate = d_class[1] & ~d_class[0];
    wire d_register = &d_class;
    wire d_branch = d_immediate & (d_aaa == 3'b111);
    wire d_ldpc = (XLEN == 32) && d_immediate && d_aaa == 1;
    wire d_imm_alu = d_immediate & ~d_branch & ~d_ldpc;
    wire d_reg_alu_group = d_register & (d_f5[4:3] == 2'b00);
    wire d_reg_mem = d_register & (d_f5[4:3] == 2'b01);
    wire d_system = d_register & d_f5[4] & d_f5[3];
    wire d_reg_store = d_reg_mem & ~d_f5[2] & d_f5[1] & d_f5[0];
    wire d_multiply = d_reg_alu_group & (&d_f5[2:0]);
    wire d_reg_alu = d_reg_alu_group & ~d_multiply;
    // FSL1/FSR1 use f5=10_001 with ooo[0] selecting right versus left.
    // Reserved functions in the group-10 plane may alias the same paths.
    wire d_funnel = d_register & d_f5[4] & ~d_f5[3];
    wire d_shift_right = d_reg_mem & d_f5[2] & ~d_f5[1];
    wire d_shift_left = d_reg_mem & (&d_f5[2:0]);
    wire d_shift = d_shift_right | d_shift_left;
    // LDX uses ra+rb. Direct typed accesses use ra.
    wire d_native_load = d_reg_mem & ~d_f5[2] &
                         ~d_f5[1] & ~d_f5[0];
    wire d_direct_load = d_reg_mem & d_f5[1] & ~d_f5[0];
    wire d_indexed_memory = d_native_load;
    wire d_reg_memory = d_native_load | d_direct_load | d_reg_store;
    wire d_memory = d_imm_memory | d_reg_memory | d_ldpc;
    wire d_store = d_imm_store | d_reg_store;
    wire d_load = d_memory & ~d_store;
    wire d_jal = d_system & ~d_bbb[2] & ~d_bbb[1] & d_bbb[0];
    wire d_control_plane = d_system & ~d_bbb[1] & ~d_bbb[0];
    // JALL is the only defined quadrant-00 instruction at either width.
    // Other encodings in this quadrant are undefined in the base ISA.
    wire d_jall = ~|d_class;
    wire d_link_jump = d_jal | d_jall;
    // RET/RETI and CLI/STI share bbb=000. ddd[1] selects a return versus a
    // direct IE operation; ddd[2] and ddd[0] duplicate the selected IE value.
    wire d_return = d_control_plane & ~d_ddd[1];
    wire d_move = d_system & ~d_bbb[2] & d_bbb[1];
    // Both final controls are predecoded to keep the packed selector off the
    // Execute instruction fanout.
    wire d_control_ie_value = d_ddd[2];
    wire d_ie_write = d_control_plane &
                      (d_ddd[1] | d_control_ie_value);
    // Defined byte and halfword selectors differ in bbb[1]. The remaining
    // selectors are reserved and need not enter the width-control cone.
    wire d_load_byte = (d_direct_load | d_reg_store) & ~d_bbb[1];
    wire d_signed_byte = d_load_byte & d_f5[2];
    wire d_cmpi = d_imm_alu & (d_aaa == 3'b011);

    // Compact funnels read old rd on A and ra on B before writing rd.
    wire d_src_a_is_ddd = d_class[1] & (~d_class[0] | d_f5[4]);
    wire [3:0] d_src_a = d_system ? {~d_bbb[0], d_aaa} :
        d_src_a_is_ddd ? {1'b0, d_ddd} : {1'b0, d_aaa};
    wire d_src_b_is_ddd = d_class[0] &
        (~d_class[1] | (d_f5[3] & d_f5[0]));
    wire d_src_b_is_aaa = (d_class[1] & d_f5[4]) |
        (d_class[0] & ~d_f5[4] & d_f5[3] & d_f5[1]);
    wire [3:0] d_src_b = {1'b0,
        d_src_b_is_ddd ? d_ddd :
        d_src_b_is_aaa ? d_aaa : d_bbb};

    wire d_result_we = d_imm_alu | d_shift | d_funnel |
                       d_reg_alu | d_multiply |
                       d_move | (d_link_jump & (|d_ddd));
    wire d_we = d_load | d_result_we;
    wire d_result_system = (d_system & d_bbb[0]) | d_jall;
    wire [3:0] d_dst = {
        d_result_system,
        d_ddd & {3{~d_cmpi}}
    };

    // ------------------------------------------------------------------
    // Execute stage and factored instruction decode
    // ------------------------------------------------------------------
    reg        x_valid_q;
    // Whenever X is valid, the accepted fetch address is exactly X PC+1.
    // This architectural PC view is only used by simulation monitors; the
    // datapath uses f_pc_q directly and needs no Execute PC register.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [XLEN-2:0] x_pc_q = f_pc_q - 1'b1;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */
    reg [13:0] x_instr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [3:0]  x_dst_q;
    reg        x_we_q;

    // Factored D-stage controls. Registering these removes raw major-opcode
    // decode from the Execute adder/result path without introducing a broad
    // 32-way operation selector.
    reg x_branch_q;
    reg x_imm_alu_q;
    reg x_multiply_q;
    // Predecode one-step bit operations and variable-shift continuation.
    reg x_bitop_q;
    reg x_shift_nonzero_q;
    reg x_shift_left_q;
    reg x_ldpc_q, x_native_immediate_q, x_native_word_q;
    reg memory_second_q;
    reg x_memory_q;
    reg x_store_q;
    reg x_load_byte_q;
    reg x_signed_byte_q;
    reg x_indirect_q;
    reg x_jall_q;
    reg x_move_q;
    reg x_ie_write_q;
    // Decode also registers the result and arithmetic operand selects.
    reg x_run_imm_s_q;
    reg x_run_rf_b_q;
    reg x_run_short_imm_q;
    // Bit 1 selects subtraction; bit 0 selects an arithmetic result.
    // 00 bypass, 01 add, 11 subtract, 10 compare. No extra control state.
    reg [1:0] x_alu_kind_q;

`ifdef RISCC_FAST_SOFT_MUL
    wire [2:0] x_ddd = x_instr_q[13:11];
`else
    wire [2:0] x_ddd = x_dst_q[2:0];
`endif
    wire [1:0] x_aaa = x_instr_q[9:8];
    wire [2:0] x_f3 = x_instr_q[5:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

    wire x_branch = x_branch_q;
    wire x_imm_alu = x_imm_alu_q;
    wire x_multiply = x_multiply_q;
    wire x_bitop = x_bitop_q;
    // Registering direction keeps ooo decode out of the Execute shifter and
    // improves both DSP and fabric timing.
    wire x_shift_left = x_shift_left_q;
    wire x_memory = x_memory_q;
    wire x_store = x_store_q;
    wire x_load_byte = x_load_byte_q;
    wire x_signed_byte = x_signed_byte_q;
    wire x_indirect = x_indirect_q;
    wire x_jall = x_jall_q;
    wire x_move = x_move_q;
    wire x_ie_write = x_ie_write_q;

    wire [XLEN-1:0] rf_a;
    wire [XLEN-1:0] rf_b;
    wire [XLEN-1:0] alu_result;
    wire x_mul_start, first_data_complete, data_accept, x_finish;

    wire run_x = in_run & x_valid_q;
    // IRQ enters before a RUN instruction starts, never between data beats.
    // Waiting for an ACK also holds the architectural instruction boundary.
    wire take_irq = run_x && !memory_second_q && !data_pending &&
                    interrupt_request_q && interrupt_enable_q;
    wire normal_x = run_x & ~take_irq;

    // Branches, LDPC, and arithmetic share the byte-addressed ALU. Keep the
    // instruction unchanged between D and X; branch displacement decoding
    // does not need a second mux on the Execute instruction register.
    wire [XLEN-1:0] x_imm_z = {{(XLEN-8){1'b0}}, x_instr_q[7:0]};
    wire x_imm_sign = x_ldpc_q ? x_instr_q[0] :
        ((XLEN == 32) && x_native_immediate_q) ? x_instr_q[1] :
        x_branch ? x_instr_q[0] : x_instr_q[7];
    wire [7:0] immediate_byte = ((XLEN == 32) && x_native_immediate_q) ?
        {x_instr_q[7:2], 2'b00} : x_instr_q[7:0];
    wire [XLEN-1:0] x_imm_s = {{(XLEN-8){x_imm_sign}}, immediate_byte};
    wire [XLEN-1:0] x_imm_u = {{(XLEN-16){1'b0}}, x_instr_q[7:0], 8'h00};
    reg [XLEN-1:0] side_data_q;

    wire [1:0] x_logic_op = x_move ? 2'b11 :
        x_imm_alu ? x_aaa[1:0] : x_f3[1:0];
    wire [XLEN-1:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [XLEN-1:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) :
                         (rf_a & x_logic_rhs)) :
        (x_logic_op[0] ? rf_a : (rf_a ^ x_logic_rhs));

    // One-bit shift hardware is shared by the initial X step and ST_SHIFT.
    `ifdef RISCC_FAST_SOFT_MUL
    localparam integer COUNT_BITS = $clog2(XLEN/2);
`else
    localparam integer COUNT_BITS = 3;
`endif
`ifdef RISCC_FAST_SOFT_MUL
    // The multiplier's digit counter stays separate from instruction decode.
    reg [COUNT_BITS-1:0] side_count_q;
`else
    // With DSP multiplication only shifts count; their source index is dead.
    wire [COUNT_BITS-1:0] side_count_q = x_instr_q[2:0];
`endif

    // Shifts reuse the destination RF register as their accumulator. IRQs
    // remain deferred until the final step; both RAM mappings forward each write.
    wire [XLEN-1:0] side_shift_source = rf_a;
    wire side_shift_left = x_shift_left;
    wire side_shift_endpoint = x_instr_q[7] ? rf_b[0] :
                               (x_f3[0] & side_shift_source[XLEN-1]);
    wire [XLEN-1:0] side_shift_step = side_shift_left ?
        {side_shift_source[XLEN-2:0], x_instr_q[7] & rf_b[XLEN-1]} :
        {side_shift_endpoint, side_shift_source[XLEN-1:1]};
    wire [XLEN-1:0] x_shift_step = side_shift_step;
    wire [XLEN-1:0] shift_step = side_shift_step;
    wire shift_finish = in_shift & (side_count_q == 1);

`ifdef RISCC_FAST_SOFT_MUL
    // MUL visits XLEN/2 radix-4 Booth digits, from high to low. Each step
    // doubles the accumulator twice and adds 0, +/-ra, or +/-2*ra. Only
    // the low XLEN bits matter. X selects the first digit; each multiply
    // cycle selects the next, keeping that decode off the carry path.
    wire [COUNT_BITS-1:0] next_mul_digit = in_mul ? side_count_q - 1'b1 : {COUNT_BITS{1'b1}};
    wire [XLEN:0] multiplier_bits = {rf_b, 1'b0};
    wire [2:0] next_booth = multiplier_bits[{1'b0, next_mul_digit, 1'b0} +: 3];
    reg booth_one_q, booth_two_q, booth_negative_q;
    always @(posedge clk)
        if (!rst && core_advance) begin
            booth_one_q <= next_booth[1] ^ next_booth[0];
            booth_two_q <= (next_booth == 3'b011) || (next_booth == 3'b100);
            booth_negative_q <= next_booth[2];
        end
    wire [XLEN-1:0] mul_magnitude = booth_two_q ? {rf_a[XLEN-2:0], 1'b0} : rf_a;
    wire [XLEN-1:0] mul_addend = mul_magnitude & {XLEN{booth_one_q || booth_two_q}};
    wire [XLEN-1:0] mul_step = alu_result;
    wire mul_finish = in_mul && !(|side_count_q);
`else
    // The truncated product uses the same registered path at either width.
    // MUL occupies two Execute clocks; the second writes the saved product.
    wire [XLEN-1:0] x_mul_result = rf_a * rf_b;
    wire [XLEN-1:0] mul_write_data = side_data_q;
    // The operation selects the low-half payload; completion only enables
    // capture. Native loads and multiplication never use this storage together.
    always @(posedge clk) begin
        if (!rst && core_advance) begin
            if (x_mul_start) side_data_q <= x_mul_result;
            if (x_mul_start || (first_data_complete && !x_store))
                side_data_q[15:0] <= x_native_word_q ? mem_rdata : x_mul_result[15:0];
        end
    end
`endif

    // Arithmetic and addresses use the adder; other results bypass it.

    // Calls and IRQ entry have no ordinary ALU work. They use the same
    // PC operand path as branches and LDPC, with no separate PC adder.
    wire pc_write = take_irq || x_indirect || x_jall;
    wire alu_a_is_pc = x_branch || x_ldpc_q || pc_write;
    // Non-arithmetic instructions do not consume the ALU result. Keeping
    // ra as the default removes a full-width zeroing gate on the input.
    wire [XLEN-1:0] ordinary_alu_a = alu_a_is_pc ? {f_pc_q, 1'b0} : rf_a;

    wire [XLEN-1:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
    wire run_short_imm = x_run_short_imm_q;
    // These instruction classes are mutually exclusive. Arithmetic operands
    // never select this bypass path, including in the soft multiplier build.
    wire run_shift = x_bitop;
    wire [XLEN-1:0] run_result = run_short_imm ? immediate_result :
        run_shift ? x_shift_step : x_logic_result;
    // Decode supplies the two arithmetic operand selects. Logical, move
    // and shift results do not pass through this mux or the carry chain.
    wire [XLEN-1:0] ordinary_alu_b =
        (rf_b & {XLEN{x_run_rf_b_q && !take_irq}}) |
        (x_imm_s & {XLEN{x_run_imm_s_q && !take_irq}}) |
        {{(XLEN-2){1'b0}}, x_jall || take_irq, 1'b0};

    wire ordinary_subtract =
        take_irq || x_alu_kind_q[1];
`ifdef RISCC_FAST_SOFT_MUL
    // MUL shares the adder, selecting its accumulator and digit only
    // during the iterative steps. Other instructions use the ordinary ALU.
    wire [XLEN-1:0] alu_a = in_mul ?
        {side_data_q[XLEN-3:0], 2'b00} : ordinary_alu_a;
    wire [XLEN-1:0] alu_b = in_mul ? mul_addend : ordinary_alu_b;
    wire alu_subtract = ordinary_subtract | (in_mul && booth_negative_q);
`else
    wire [XLEN-1:0] alu_a = ordinary_alu_a;
    wire [XLEN-1:0] alu_b = ordinary_alu_b;
    wire alu_subtract = ordinary_subtract;
`endif
    // f_pc_q already supplies PC+2 bytes. Branch/LDPC offsets clear the
    // encoded sign bit in bit 0. Calls add zero, JALL adds two, and IRQ
    // subtracts two to recover the interrupted instruction's EPC.
    // Only these offsets encode their sign in bit 0. Calls and IRQ
    // already supply an even constant and need no extra clearing control.
    wire control_step = x_branch || x_ldpc_q;
    wire alu_carry_in = alu_subtract;
    wire [XLEN-1:0] stepped_alu_b =
        {alu_b[XLEN-1:1], alu_b[0] && !control_step};
    wire [XLEN-1:0] adjusted_alu_b = stepped_alu_b ^ {XLEN{alu_subtract}};
    wire [XLEN:0] alu_sum = {1'b0, alu_a} +
                          {1'b0, adjusted_alu_b} +
                          {{XLEN{1'b0}}, alu_carry_in};
    assign alu_result = alu_sum[XLEN-1:0];
    wire x_compare = x_alu_kind_q[1] && !x_alu_kind_q[0];

    reg r0_negative_q, r0_zero_q;
    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? r0_negative_q : r0_zero_q) ^ x_ddd[0]);

    // ------------------------------------------------------------------
    // X side-state starts, completion, redirects, and Decode issue
    // ------------------------------------------------------------------
    wire x_shift_start = normal_x & x_shift_nonzero_q;
    assign x_mul_start = normal_x & x_multiply;
    wire x_side_start = x_shift_start | x_mul_start;
    // Pending ownership determines the next beat and writeback selection.
    // core_advance admits these updates only when its response is acknowledged.
    wire first_word_beat = data_pending && x_native_word_q && !memory_second_q;
    // Older replies are qualified by core_advance at every consuming edge.
    wire data_complete = data_pending ||
        (!bus_pending_q && data_accept && mem_ack);
    assign first_data_complete = data_complete && x_native_word_q && !memory_second_q;
    wire final_data_complete = data_complete && (!x_native_word_q || memory_second_q);
    wire run_commit = normal_x && !x_side_start &&
        (!x_memory || final_data_complete);
    // Decide which command to offer without using its own immediate ACK.
    wire run_slot_ready = normal_x && !x_side_start &&
        (!x_memory || (data_pending && !first_word_beat));
`ifdef RISCC_FAST_SOFT_MUL
    wire mul_commit = mul_finish;
`else
    wire mul_commit = in_mul;
`endif
    wire x_complete = run_commit | shift_finish | mul_commit;
    wire commit_valid = core_advance && x_finish;
    // Control transfers are RUN instructions with no side state or data
    // transaction. Their redirect does not depend on memory completion logic.
    wire x_redirect = normal_x &&
        ((x_branch && x_branch_taken) || x_indirect || x_jall);
    wire [31:0] x_long_target = {11'b0, x_instr_q[10:6], d_instr};
    wire [XLEN-2:0] x_redirect_pc = x_jall ? x_long_target[XLEN-1:1] :
        x_branch ? alu_result[XLEN-1:1] : rf_a[XLEN-1:1];
    wire redirect = take_irq | x_redirect;
    wire frontend_flush = core_advance && !mem_stall && redirect;
    wire [XLEN-2:0] frontend_redirect_pc = take_irq ? 2 :
                                              x_redirect_pc;

    // Keep a stalled redirect's target and link operands in Execute.
    assign x_finish = x_complete && (!redirect || !mem_stall);
    wire x_slot_available = !x_valid_q || run_slot_ready || shift_finish || mul_commit;
    // Each issuing instruction must accept its successor's fetch, keeping
    // the single shared PC exactly one halfword ahead of Execute.
    wire d_issue = core_advance && !mem_stall && d_valid && x_slot_available && !redirect;

    // ------------------------------------------------------------------
    // Load response and architectural writeback
    // ------------------------------------------------------------------
    // Byte loads use ra directly; lane selection does not need the adder.
    wire [7:0] accepted_load_byte = rf_a[0] ?
                                    mem_rdata[15:8] : mem_rdata[7:0];
    wire load_sign = x_signed_byte &&
        (x_load_byte ? accepted_load_byte[7] : mem_rdata[15]);
    wire [31:0] native_load_value = {mem_rdata, side_data_q[15:0]};
    wire [XLEN-1:0] accepted_load_value = x_native_word_q ?
        native_load_value[XLEN-1:0] : x_load_byte ?
        {{(XLEN-8){load_sign}}, accepted_load_byte} :
        {{(XLEN-16){load_sign}}, mem_rdata};
`ifdef RISCC_FAST_SOFT_MUL
    wire [XLEN-1:0] mul_write_data = mul_step;
`endif
    // ACK controls state enables, not the operand/result selectors. Their
    // values are immaterial while the pipeline and RF write port are held.
    wire rf_we = !rst && core_advance &&
                 ((take_irq && !mem_stall) || (x_finish && x_we_q) ||
                  x_shift_start || in_shift);
    wire [3:0] rf_waddr = take_irq ? 4'h8 : x_dst_q;
    // Calls and interrupts share the PC writeback path. IRQ saves PC;
    // short and long calls save PC+1 and PC+2 halfwords respectively.
    wire [XLEN-1:0] pc_write_data = alu_result;
    // Calls/EPC and arithmetic now use the same ALU result. Select that
    // shared source once; compares, memory, multiply and bypass are disjoint.
    // Signed and unsigned order differ only when the operand signs differ.
    wire compare_value = !alu_sum[XLEN] ^
        ((alu_a[XLEN-1] ^ alu_b[XLEN-1]) && !x_f3[0]);
    wire write_arithmetic = pc_write || x_alu_kind_q[0];
    wire [XLEN-1:0] rf_wdata = write_arithmetic ? alu_result :
        in_mul ? mul_write_data :
        x_memory ? accepted_load_value :
        x_compare ? {{(XLEN-1){1'b0}}, compare_value} : run_result;

    // Branch conditions observe the last architectural write to r0.
    // Updating alongside RF writeback forwards directly to a following branch.
    always @(posedge clk)
        if (rf_we && !(|rf_waddr)) begin
            r0_negative_q <= rf_wdata[XLEN-1];
            r0_zero_q <= !(|rf_wdata);
        end

    wire shift_feedback = core_advance && (x_shift_start || in_shift) && !d_issue;
    riscc_fast_rf #(.XLEN(XLEN)) regs (
        .clk(clk),
        .read_en_a((d_issue || shift_feedback) && !rst),
        .read_en_b(d_issue && !rst),
        .raddr_a(shift_feedback ? x_dst_q : d_src_a),
        .rdata_a(rf_a),
        .raddr_b(d_src_b),
        .rdata_b(rf_b),
        .waddr(rf_waddr),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Unified memory and IF bookkeeping
    // ------------------------------------------------------------------
    // Command selection is independent of STALL and immediate ACK. A reply
    // belongs to the older accepted request, or to this command if none is pending.
    wire data_request = normal_x && x_memory && (!data_pending || first_word_beat);
    // Reserve the holding slot before fetching. An issuing JALL launches
    // its literal on this edge, so the response reaches X in its RUN cycle.
    // A late ACK holds X; redirect discards the literal from Decode.
    wire fetch_space = !d_valid || x_slot_available;
    assign mem_stb = !rst && core_advance &&
                     (take_irq || data_request || fetch_space);
    assign mem_cyc = !rst && (bus_pending_q || mem_stb);
    wire command_accept = mem_stb && !mem_stall;
    wire fetch_accept = command_accept && !data_request;
    assign data_accept = command_accept && data_request;
    wire early_fetch_reply = !bus_pending_q && fetch_accept && mem_ack;
    wire fetch_reply = fetch_pending && mem_ack;
    wire data_high = memory_second_q || first_word_beat;
    wire [XLEN-2:0] data_address = x_native_word_q ?
        {alu_result[XLEN-1:2], data_high} : alu_result[XLEN-1:1];
    // The retiring redirect consumes/discards the old fetch response on
    // this edge and replaces it with the target request. Target data reaches
    // D next clock; no drain state or outstanding-request queue is needed.
    wire [XLEN-2:0] fetch_address = redirect ? frontend_redirect_pc : f_pc_q + 1'b1;
    assign mem_addr = data_request ? data_address : fetch_address;
    assign mem_we = data_request && x_store;
    wire [XLEN+15:0] store_data = data_high ? ({16'b0, rf_b} >> 16) : {16'b0, rf_b};
    assign mem_wdata = x_load_byte ? {2{rf_b[7:0]}} : store_data[15:0];
    assign mem_wmask = (data_request && x_load_byte) ?
                       {rf_a[0], ~rf_a[0]} : 2'b11;

    always @(posedge clk) begin
        if (rst) begin
            bus_pending_q <= 0;
            f_pc_q <= RESET_PC[XLEN-2:0] - 1'b1;
            interrupt_request_q <= 0;
        end else if (core_advance) begin
            if (!mem_stb || !mem_stall) interrupt_request_q <= irq;
            bus_pending_q <= command_accept && (bus_pending_q || !mem_ack);
            if (fetch_accept) f_pc_q <= fetch_address;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            d_valid_q <= 0;
        end else if (core_advance) begin
            // A new immediate reply replaces the issued/discarded word.
            d_valid_q <= early_fetch_reply ||
                (d_valid && !fetch_accept);
            if (early_fetch_reply || fetch_reply) d_instr_q <= mem_rdata;
        end
    end

    // ------------------------------------------------------------------
    // Pipeline and side-state updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst && core_advance) begin
            // ACK advances the word phase even if the high command stalls.
            // Retain it until the next instruction to keep bus outputs stable.
            if (d_issue) memory_second_q <= 0;
            else if (first_data_complete) memory_second_q <= 1;
`ifdef RISCC_FAST_SOFT_MUL
            if (first_data_complete && !x_store)
                side_data_q[15:0] <= mem_rdata;
`endif
            // D/RF -> X. The RF module samples the same decoded addresses on
            // this edge; its registered outputs and these controls stay aligned.
            if (d_issue) begin
                x_instr_q <= d_instr[13:0];
                x_dst_q <= d_dst;
                x_we_q <= d_we;
                x_branch_q <= d_branch;
                x_imm_alu_q <= d_imm_alu;
                x_multiply_q <= d_multiply;
                x_bitop_q <= d_shift | d_funnel;
                x_shift_nonzero_q <= d_shift & (|d_bbb);
                x_shift_left_q <= d_f5[1] | (d_f5[4] & ~d_bbb[0]);
                x_ldpc_q <= d_ldpc;
                x_native_immediate_q <= d_imm_memory;
                x_native_word_q <= (XLEN == 32) && (d_imm_memory || d_native_load || d_ldpc);
                x_memory_q <= d_memory;
                x_store_q <= d_store;
                x_load_byte_q <= d_load_byte;
                x_signed_byte_q <= (XLEN == 32) ? d_f5[2] : d_signed_byte;
                x_indirect_q <= d_return | d_jal;
                x_jall_q <= d_jall;
                x_move_q <= d_move;
                x_ie_write_q <= d_ie_write;
                x_run_imm_s_q <= d_branch | d_ldpc | d_imm_memory |
                                 (d_imm_alu & ~d_aaa[2] & d_aaa[1]);
                x_run_rf_b_q <= (d_reg_alu_group & ~d_f5[2]) |
                                d_indexed_memory;
                x_run_short_imm_q <= d_imm_alu & ~d_aaa[2] & ~d_aaa[1];
                x_alu_kind_q <= {
                    (d_imm_alu & ~d_aaa[2] & d_aaa[1] & d_aaa[0]) |
                    (d_reg_alu_group & ~d_f5[2] & (|d_f5[1:0])),
                    (d_imm_alu & ~d_aaa[2] & d_aaa[1]) |
                    (d_reg_alu_group & ~d_f5[2] & ~d_f5[1])
                };
            end

            if (frontend_flush) begin
                state_q <= ST_RUN;
                x_valid_q <= 1'b0;
            end else if (x_shift_start) begin
                state_q <= ST_SHIFT;
`ifdef RISCC_FAST_SOFT_MUL
                side_count_q <= {{(COUNT_BITS-3){1'b0}}, x_bbb};
`endif
            end else if (x_mul_start) begin
                state_q <= ST_MUL;
`ifdef RISCC_FAST_SOFT_MUL
                side_data_q <= 0;
                side_count_q <= {COUNT_BITS{1'b1}};
`endif
`ifdef RISCC_FAST_SOFT_MUL
            end else if (in_mul & ~mul_finish) begin
                side_data_q <= mul_step;
                side_count_q <= side_count_q - 1'b1;
`endif
            end else if (in_shift & ~shift_finish) begin
`ifdef RISCC_FAST_SOFT_MUL
                side_count_q <= side_count_q - 1'b1;
`else
                x_instr_q[2:0] <= side_count_q - 1'b1;
`endif
            end else if (x_finish | ~x_valid_q) begin
                state_q <= ST_RUN;
                x_valid_q <= d_issue;
            end

            // Architectural IE changes only at completed instruction boundaries.
            if (frontend_flush && take_irq)
                interrupt_enable_q <= 1'b0;
            else if (x_finish && run_commit && x_ie_write)
                interrupt_enable_q <= x_ddd[2];

        end
        if (rst) begin
            state_q <= ST_RUN;
            memory_second_q <= 0;
            interrupt_enable_q <= 0;
            x_valid_q <= 0;
        end
    end

endmodule

// Two synchronous one-read/one-write copies provide the two architectural
// read ports. Folding the collision choice into each registered read avoids
// separate bypass-data and bypass-valid registers in the block-RF build.
module riscc_fast_rf #(parameter integer XLEN = 16) (
    input  wire        clk,
    input  wire        read_en_a,
    input  wire        read_en_b,
    input  wire [3:0]  raddr_a,
    output wire [XLEN-1:0] rdata_a,
    input  wire [3:0]  raddr_b,
    output wire [XLEN-1:0] rdata_b,
    input  wire [3:0]  waddr,
    input  wire [XLEN-1:0] wdata,
    input  wire        we
);
`ifdef RISCC_FAST_BLOCK_RF
    (* ram_style = "block" *) reg [XLEN-1:0] mem_a [0:15];
    (* ram_style = "block" *) reg [XLEN-1:0] mem_b [0:15];
    reg  [XLEN-1:0] ram_rdata_a_q;
    reg  [XLEN-1:0] ram_rdata_b_q;

    assign rdata_a = ram_rdata_a_q;
    assign rdata_b = ram_rdata_b_q;

    always @(posedge clk) begin
        if (read_en_a)
            ram_rdata_a_q <= (we && (waddr == raddr_a)) ?
                             wdata : mem_a[raddr_a];
        if (read_en_b)
            ram_rdata_b_q <= (we && (waddr == raddr_b)) ?
                             wdata : mem_b[raddr_b];
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`else
`ifdef RISCC_ECP5
    (* ram_style = "distributed" *) reg [XLEN-1:0] mem_a [0:15];
    (* ram_style = "distributed" *) reg [XLEN-1:0] mem_b [0:15];
`else
    (* ramstyle = "MLAB, no_rw_check" *) reg [XLEN-1:0] mem_a [0:15];
    (* ramstyle = "MLAB, no_rw_check" *) reg [XLEN-1:0] mem_b [0:15];
`endif
    reg [XLEN-1:0] rdata_a_q;
    reg [XLEN-1:0] rdata_b_q;

    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    always @(posedge clk) begin
        if (read_en_a)
            rdata_a_q <= (we && (waddr == raddr_a)) ? wdata : mem_a[raddr_a];
        if (read_en_b)
            rdata_b_q <= (we && (waddr == raddr_b)) ? wdata : mem_b[raddr_b];
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`endif
endmodule

`default_nettype wire
