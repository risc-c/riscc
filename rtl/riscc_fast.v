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
    output wire        mem_valid,  // request valid; held until mem_ready
    input  wire        mem_ready   // request accepted; read data is valid
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
`ifdef RISCC_FAST_SOFT_MUL
    localparam [1:0] ST_LONG  = 2'd3;
`endif
    (* syn_encoding = "user" *) reg [1:0] state_q;
    wire in_run   = state_q == ST_RUN;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;
`ifdef RISCC_FAST_SOFT_MUL
    wire in_long  = state_q == ST_LONG;
`endif
    wire core_advance;

    reg interrupt_enable_q;
    reg interrupt_request_q;

    // ------------------------------------------------------------------
    // IF and Decode/RF stages
    // ------------------------------------------------------------------
    // f_pc_q is the next sequential fetch request. Native ACK capture writes
    // the response directly into D.
    reg [XLEN-2:0] f_pc_q;
    reg        bus_wait_q;

    reg        d_valid_q;
    reg [XLEN-2:0] d_pc_q;
    reg [15:0] d_instr_q;

    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field. Prefixes identify the
    // Decode (d_) and Execute (x_) stages.
    wire [1:0] d_class = d_instr_q[15:14];
    wire [2:0] d_ddd = d_instr_q[13:11];
    wire [2:0] d_aaa = d_instr_q[10:8];
    wire [4:0] d_f5 = d_instr_q[7:3];
    wire [2:0] d_bbb = d_instr_q[2:0];

    wire d_imm_memory = ~d_class[1] & d_class[0];
    wire d_imm_store = d_imm_memory & d_instr_q[0];
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
`ifdef RISCC_FAST_SOFT_MUL
    // JALL is the only defined quadrant-00 instruction. In fabric,
    // reserved encodings can alias it instead of carrying a wide comparator.
    wire d_long_form = ~|d_class;
`else
    wire d_long_form = (d_instr_q & ((XLEN == 32) ? 16'hc03f : 16'hc7ff)) == 16'h0034;
`endif
    wire d_jall = d_long_form;
    wire d_link_jump = d_jal | d_jall;
    // RET/RETI and CLI/STI share bbb=000. ddd[1] selects a return versus a
    // direct IE operation; ddd[2] and ddd[0] duplicate the selected IE value.
    wire d_return = d_control_plane & ~d_ddd[1];
    wire d_move = d_system & ~d_bbb[2] & d_bbb[1];
    // Both final controls are predecoded to keep the packed selector off the
    // Execute instruction fanout.
`ifdef RISCC_FAST_SOFT_MUL
    wire d_control_ie_value = d_ddd[2];
`else
    wire d_control_ie_value = d_ddd[0];
`endif
    wire d_ie_write = d_control_plane &
                      (d_ddd[1] | d_control_ie_value);
    // Defined byte and halfword selectors differ in bbb[1]. The remaining
    // selectors are reserved and need not enter the width-control cone.
    wire d_load_byte = (d_direct_load | d_reg_store) & ~d_bbb[1];
    wire d_signed_byte = d_load_byte & d_f5[2];
    wire d_cmpi = d_imm_alu & (d_aaa == 3'b011);

    // Compact funnels read old rd on A and ra on B before writing rd.
    wire d_src_a_is_ddd = d_class[1] & (~d_class[0] | d_f5[4]);
    wire [3:0] d_src_a = d_branch ? 4'h0 :
        d_system ? {~d_bbb[0], d_aaa} :
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
    reg [XLEN-2:0] x_pc_q;
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
    // The fabric build merges one-step bit operations and predecodes whether a
    // variable shift needs its side state. The DSP build keeps those controls
    // separate from the registered multiplier path.
`ifdef RISCC_FAST_SOFT_MUL
    reg x_bitop_q;
    reg x_shift_nonzero_q;
`else
    reg x_shift_q;
    reg x_funnel_q;
`endif
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
    reg x_run_logic_q;
    reg x_run_rf_b_q;
    reg x_run_short_imm_q;
    reg x_imm_arithmetic_q;
    reg x_reg_arithmetic_q;

    wire [2:0] x_ddd = x_instr_q[13:11];
    wire [1:0] x_aaa = x_instr_q[9:8];
    wire [2:0] x_f3 = x_instr_q[5:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

    wire x_branch = x_branch_q;
    wire x_imm_alu = x_imm_alu_q;
    wire x_multiply = x_multiply_q;
`ifdef RISCC_FAST_SOFT_MUL
    wire x_bitop = x_bitop_q;
`else
    wire x_shift = x_shift_q;
    wire x_funnel = x_funnel_q;
`endif
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

    wire run_x = in_run & x_valid_q;
    // Interrupts are sampled only when the core advances. An already-visible
    // bus request is therefore indivisible; its handshake completes before
    // the request can interrupt the following X instruction.
    wire take_irq = run_x & ~memory_second_q & interrupt_request_q & interrupt_enable_q;
    wire normal_x = run_x & ~take_irq;

    // The DSP build has an independent registered multiply result and uses a
    // halfword control-flow adder. The iterative build shares more of its
    // result path and carries byte PCs directly.
`ifdef RISCC_FAST_SOFT_MUL
    localparam HALFWORD_CONTROL_ALU = 1'b0;
`else
    localparam HALFWORD_CONTROL_ALU = 1'b1;
`endif
    wire [XLEN-1:0] x_imm_z = {{(XLEN-8){1'b0}}, x_instr_q[7:0]};
    wire x_imm_sign = x_ldpc_q ? x_instr_q[0] :
        ((XLEN == 32) && x_native_immediate_q) ? x_instr_q[1] :
        (!HALFWORD_CONTROL_ALU && x_branch) ? x_instr_q[0] : x_instr_q[7];
    wire [7:0] immediate_byte = ((XLEN == 32) && x_native_immediate_q) ?
        {x_instr_q[7:2], 2'b00} : x_instr_q[7:0];
    wire [XLEN-1:0] x_imm_s = {{(XLEN-8){x_imm_sign}}, immediate_byte};
    wire [XLEN-1:0] x_imm_u = {{(XLEN-16){1'b0}}, x_instr_q[7:0], 8'h00};
    reg [XLEN-1:0] side_data_q;
    wire [XLEN-1:0] side_long_value = side_data_q;
    wire [31:0] long_address = {11'b0, x_instr_q[10:6], mem_rdata};
    wire [XLEN-1:0] long_target = long_address[XLEN-1:0];

    wire [1:0] x_logic_op = x_imm_alu ? x_aaa[1:0] : x_f3[1:0];
    wire [XLEN-1:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [XLEN-1:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) :
                         (rf_a & x_logic_rhs)) :
        (rf_a ^ x_logic_rhs);

    // One-bit shift hardware is shared by the initial X step and ST_SHIFT.
    `ifdef RISCC_FAST_SOFT_MUL
    localparam integer COUNT_BITS = $clog2(XLEN/2);
`else
    localparam integer COUNT_BITS = 3;
`endif
    reg [COUNT_BITS-1:0] side_count_q;

`ifdef RISCC_FAST_SOFT_MUL
    // X and ST_SHIFT share this shifter. The multiplier shifts its
    // accumulator through the ALU input instead.
    wire side_shift_active = in_shift;
    wire [XLEN-1:0] side_shift_source = side_shift_active ? side_data_q : rf_a;
    wire side_shift_left = x_shift_left;
    wire side_shift_endpoint = x_instr_q[7] ? rf_b[0] :
                               (x_f3[0] & side_shift_source[XLEN-1]);
    wire [XLEN-1:0] side_shift_step = side_shift_left ?
        {side_shift_source[XLEN-2:0], x_instr_q[7] & rf_b[XLEN-1]} :
        {side_shift_endpoint, side_shift_source[XLEN-1:1]};
    wire [XLEN-1:0] x_shift_step = side_shift_step;
    wire [XLEN-1:0] shift_step = side_shift_step;
`else
    wire x_shift_endpoint = x_instr_q[7] ? rf_b[0] :
                            (x_f3[0] & rf_a[XLEN-1]);
    wire [XLEN-1:0] x_shift_step = x_shift_left ?
        {rf_a[XLEN-2:0], x_instr_q[7] & rf_b[XLEN-1]} :
        {x_shift_endpoint, rf_a[XLEN-1:1]};
    wire [XLEN-1:0] shift_step = x_shift_left ?
        {side_data_q[XLEN-2:0], 1'b0} :
        {x_f3[0] & side_data_q[XLEN-1], side_data_q[XLEN-1:1]};
`endif
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
        if (core_advance) begin
            booth_one_q <= next_booth[1] ^ next_booth[0];
            booth_two_q <= (next_booth == 3'b011) || (next_booth == 3'b100);
            booth_negative_q <= next_booth[2];
        end
    wire [XLEN-1:0] mul_magnitude = booth_two_q ? {rf_a[XLEN-2:0], 1'b0} : rf_a;
    wire [XLEN-1:0] mul_addend = mul_magnitude & {XLEN{booth_one_q || booth_two_q}};
    wire [XLEN-1:0] mul_step = alu_result;
    wire mul_finish = in_mul && !(|side_count_q);
`else
    // DSP multiplication takes two Execute clocks at either width. RC16
    // needs one product; RC32 keeps its partial products across that boundary.
    wire [XLEN-1:0] x_mul_result;
    wire [XLEN-1:0] mul_write_data;
    generate
        if (XLEN == 16) begin : g_mul16
            assign x_mul_result = rf_a * rf_b;
            assign mul_write_data = side_data_q;
        end else begin : g_mul32
            // Keep the low product and cross products separate across the
            // register boundary. Only a 16-bit addition remains at writeback.
            wire [15:0] cross_a = rf_a[31:16] * rf_b[15:0];
            wire [15:0] cross_b = rf_a[15:0] * rf_b[31:16];
            reg [15:0] cross_q;
            assign x_mul_result = rf_a[15:0] * rf_b[15:0];
            wire [15:0] product_high = side_data_q[31:16] + cross_q;
            assign mul_write_data = {product_high, side_data_q[15:0]};
            always @(posedge clk)
                if (core_advance && x_mul_start)
                    cross_q <= cross_a + cross_b;
        end
    endgenerate
`endif

    // Arithmetic and addresses use the adder; other results bypass it.
    wire x_imm_arithmetic = x_imm_arithmetic_q;
    wire x_reg_arithmetic = x_reg_arithmetic_q;

    // Links are formed directly from x_pc_plus1/2 below. Only branches need
    // the shared ALU's PC input.
    wire alu_a_is_pc = x_branch | x_ldpc_q;
    wire alu_a_is_rf =
        (x_imm_arithmetic | x_reg_arithmetic | x_memory);
    wire [XLEN-1:0] ordinary_alu_a = alu_a_is_pc ?
        ((HALFWORD_CONTROL_ALU && !x_ldpc_q) ? {1'b0, x_pc_q} : {x_pc_q, 1'b0}) :
                            alu_a_is_rf ? rf_a : 0;

    wire [XLEN-1:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
    wire run_imm_s = x_run_imm_s_q;
    wire run_logic = x_run_logic_q;
    wire run_rf_b = x_run_rf_b_q;
    wire run_short_imm = x_run_short_imm_q;

    wire [XLEN-1:0] run_result =
        run_logic ? x_logic_result :
        run_imm_s ? x_imm_s :
        run_rf_b ? rf_b :
        run_short_imm ? immediate_result :
        x_move ? rf_a :
`ifdef RISCC_FAST_SOFT_MUL
        x_bitop ? x_shift_step :
`else
        (x_shift | x_funnel) ? x_shift_step :
`endif
        0;

    // Decode supplies the two arithmetic operand selects. Logical, move
    // and shift results do not pass through this mux or the carry chain.
    wire [XLEN-1:0] ordinary_alu_b = x_run_rf_b_q ? rf_b :
                        x_run_imm_s_q ? x_imm_s : 0;

    wire ordinary_subtract =
        ((x_imm_arithmetic & x_aaa[0]) |
         (x_reg_arithmetic & (|x_f3[1:0])));
`ifdef RISCC_FAST_SOFT_MUL
    // MUL's decoded ordinary operands are zero. Its radix-4 step can use
    // the same adder: shift the accumulator, then add/subtract the digit.
    wire [XLEN-1:0] alu_a = ordinary_alu_a |
        ({side_data_q[XLEN-3:0], 2'b00} & {XLEN{in_mul}});
    wire [XLEN-1:0] alu_b = ordinary_alu_b | (mul_addend & {XLEN{in_mul}});
    wire alu_subtract = ordinary_subtract | (in_mul && booth_negative_q);
`else
    wire [XLEN-1:0] alu_a = ordinary_alu_a;
    wire [XLEN-1:0] alu_b = ordinary_alu_b;
    wire alu_subtract = ordinary_subtract;
`endif
    wire control_step = x_branch | x_ldpc_q;
    wire alu_carry_in = alu_subtract | control_step;
    wire pc_step = control_step & (!HALFWORD_CONTROL_ALU || x_ldpc_q);
    wire [XLEN-1:0] stepped_alu_b =
        {alu_b[XLEN-1:1], alu_b[0] | pc_step};
    wire [XLEN-1:0] adjusted_alu_b = stepped_alu_b ^ {XLEN{alu_subtract}};
    wire [XLEN:0] alu_sum = {1'b0, alu_a} +
                          {1'b0, adjusted_alu_b} +
                          {{XLEN{1'b0}}, alu_carry_in};
    wire [XLEN-1:0] alu_result = alu_sum[XLEN-1:0];
    wire alu_carry_out = alu_sum[XLEN];
    wire alu_overflow = (alu_a[XLEN-1] ^ alu_b[XLEN-1]) &
                        (alu_result[XLEN-1] ^ alu_a[XLEN-1]);
    wire signed_less = alu_result[XLEN-1] ^ alu_overflow;
    wire unsigned_less = ~alu_carry_out;
    wire x_compare =
        x_reg_arithmetic & x_f3[1];
    wire [XLEN-1:0] execute_result = x_compare ?
        {{(XLEN-1){1'b0}}, x_f3[0] ? unsigned_less : signed_less} :
        (x_run_imm_s_q | x_run_rf_b_q) ? alu_result : run_result;

    // The literal address (+1 halfword) and long-call link (+2) share
    // the upper increment. Adding one carries into it only when PC is odd.
    wire [XLEN-3:0] x_pc_upper_next = x_pc_q[XLEN-2:1] + 1'b1;
    wire [XLEN-2:0] x_pc_plus1 = {
        x_pc_q[0] ? x_pc_upper_next : x_pc_q[XLEN-2:1], ~x_pc_q[0]};
    wire [XLEN-2:0] x_pc_plus2 = {x_pc_upper_next, x_pc_q[0]};

    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? rf_a[XLEN-1] : ~|rf_a) ^ x_ddd[0]);

    // ------------------------------------------------------------------
    // X side-state starts, completion, redirects, and RAW interlock
    // ------------------------------------------------------------------
    wire x_load_start = normal_x & x_memory & ~x_store;
`ifdef RISCC_FAST_SOFT_MUL
    wire x_shift_start = normal_x & x_shift_nonzero_q;
`else
    wire x_shift_start = normal_x & x_shift & (|x_bbb);
`endif
    wire x_mul_start = normal_x & x_multiply;
    wire x_long_start = normal_x & x_jall;
    wire x_side_start =
                        x_shift_start | x_mul_start |
`ifdef RISCC_FAST_SOFT_MUL
                        x_long_start |
`endif
                        1'b0;

    // A native RC32 word owns X and the memory port for both halfwords.
    // Holding the RF outputs also holds the address and store data stable.
    wire first_word_beat = normal_x && x_memory && x_native_word_q && !memory_second_q;
    wire run_commit = normal_x & ~x_side_start & ~first_word_beat;
    wire shift_commit = shift_finish;
`ifdef RISCC_FAST_SOFT_MUL
    wire mul_commit = mul_finish;
`else
    wire mul_commit = in_mul;
`endif
    wire commit_valid = run_commit |
                        shift_commit |
                        mul_commit |
`ifdef RISCC_FAST_SOFT_MUL
                        in_long |
`endif
                        1'b0;

    wire run_redirect = run_commit &
        ((x_branch & x_branch_taken) |
         x_indirect |
`ifndef RISCC_FAST_SOFT_MUL
         x_jall |
`endif
         1'b0);
`ifndef RISCC_FAST_SOFT_MUL
    wire x_redirect = run_redirect;
    wire [XLEN-2:0] x_redirect_pc = x_jall ? long_target[XLEN-1:1] :
        x_branch ? (HALFWORD_CONTROL_ALU ?
                    alu_result[XLEN-2:0] : alu_result[XLEN-1:1]) : rf_a[XLEN-1:1];
`else
    wire long_commit = in_long;
    wire x_redirect = run_redirect | long_commit;
    wire [XLEN-2:0] long_redirect_pc = side_long_value[XLEN-1:1];
    wire [XLEN-2:0] x_redirect_pc = long_commit ? long_redirect_pc :
        x_branch ? (HALFWORD_CONTROL_ALU ?
                    alu_result[XLEN-2:0] : alu_result[XLEN-1:1]) : rf_a[XLEN-1:1];
`endif
    wire frontend_flush = take_irq | x_redirect;
    wire [XLEN-2:0] frontend_redirect_pc = take_irq ? 2 :
                                              x_redirect_pc;

    wire x_finish = take_irq | commit_valid;
    wire x_slot_available = ~x_valid_q | x_finish;
    wire d_issue_raw = d_valid_q & x_slot_available & ~frontend_flush;
    wire d_issue = d_issue_raw;
    wire d_can_accept = ~d_valid_q | d_issue;

    // ------------------------------------------------------------------
    // Load response and architectural writeback
    // ------------------------------------------------------------------
    wire [7:0] accepted_load_byte = alu_result[0] ?
                                    mem_rdata[15:8] : mem_rdata[7:0];
    wire load_sign = x_signed_byte &&
        (x_load_byte ? accepted_load_byte[7] : mem_rdata[15]);
    wire [31:0] native_load_value = {mem_rdata, side_data_q[15:0]};
    wire [XLEN-1:0] accepted_load_value = x_native_word_q ?
        native_load_value[XLEN-1:0] : x_load_byte ?
        {{(XLEN-8){load_sign}}, accepted_load_byte} :
        {{(XLEN-16){load_sign}}, mem_rdata};
    // Branch targets use the ALU but never write the RF. Suppressing that
    // dead value keeps the rotated immediate out of the synchronous-RF
    // write/bypass cone.
    // Returns never enable RF writeback, so merging their selector with JAL is
    // unobservable on the write-data path.
    wire [XLEN-1:0] run_write_data =
`ifndef RISCC_FAST_SOFT_MUL
        x_memory ? accepted_load_value :
`endif
`ifndef RISCC_FAST_SOFT_MUL
        x_jall ? {x_pc_plus2, 1'b0} :
`endif
        x_indirect ?
        {x_pc_plus1, 1'b0} :
        (~HALFWORD_CONTROL_ALU & x_branch) ? 0 : execute_result;
`ifdef RISCC_FAST_SOFT_MUL
    wire [XLEN-1:0] mul_write_data = mul_step;
`endif
    wire [XLEN-1:0] commit_data =
`ifdef RISCC_FAST_SOFT_MUL
        x_load_start ? accepted_load_value :
`endif
        in_shift ? shift_step :
`ifdef RISCC_FAST_SOFT_MUL
        in_mul ? mul_write_data :
`else
        in_mul ? mul_write_data :
`endif
`ifdef RISCC_FAST_SOFT_MUL
        in_long ? {x_pc_plus2, 1'b0} :
`endif
        run_write_data;
    wire rf_we = core_advance &
                 (take_irq | (commit_valid & x_we_q));
    wire [3:0] rf_waddr = take_irq ? 4'h8 : x_dst_q;
    wire [XLEN-1:0] rf_wdata = take_irq ? {x_pc_q, 1'b0} : commit_data;

    riscc_fast_rf #(.XLEN(XLEN)) regs (
        .clk(clk),
        .read_en(d_issue & core_advance),
        .raddr_a(d_src_a),
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
    wire x_memory_request = normal_x & x_memory;
    wire x_long_request = x_long_start;
    wire x_port_request = x_memory_request | x_long_request;

    wire fetch_request = ~x_port_request & d_can_accept & ~frontend_flush;
    wire fetch_cycle = mem_valid & ~x_port_request;
    wire fetch_accepted = fetch_cycle & mem_ready;

    wire [XLEN-2:0] data_address = x_native_word_q ?
        {alu_result[XLEN-1:2], memory_second_q} : alu_result[XLEN-1:1];
    assign mem_addr = x_memory_request ? data_address :
                      x_long_request ? x_pc_plus1 : f_pc_q;
    assign mem_we = x_memory_request & x_store;
    wire [XLEN-1:0] store_data = memory_second_q ? (rf_b >> 16) : rf_b;
    assign mem_wdata = x_load_byte ? {2{rf_b[7:0]}} : store_data[15:0];
    assign mem_wmask = (x_memory_request & x_load_byte) ?
                       {alu_result[0], ~alu_result[0]} : 2'b11;
    assign mem_valid = ~rst & (x_port_request | fetch_request);
    assign core_advance = ~mem_valid | mem_ready;

    always @(posedge clk) begin
        if (rst)
            bus_wait_q <= 1'b0;
        else
            bus_wait_q <= mem_valid & ~mem_ready;
    end

    always @(posedge clk) begin
        if (rst)
            interrupt_request_q <= 1'b0;
        else if (core_advance)
            interrupt_request_q <= irq;
    end

    // ------------------------------------------------------------------
    // Pipeline and side-state updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (core_advance) begin
            memory_second_q <= first_word_beat;
            if (first_word_beat && !x_store)
                side_data_q[15:0] <= mem_rdata;
            // D/RF -> X. The RF module samples the same decoded addresses on
            // this edge; its registered outputs and these controls stay aligned.
            if (d_issue) begin
                x_pc_q <= d_pc_q;
`ifdef RISCC_FAST_SOFT_MUL
                x_instr_q <= d_instr_q[13:0];
`else
                x_instr_q <= d_branch ?
                    {d_instr_q[13:8], d_instr_q[0], d_instr_q[7:1]} :
                    d_instr_q[13:0];
`endif
                x_dst_q <= d_dst;
                x_we_q <= d_we;
                x_branch_q <= d_branch;
                x_imm_alu_q <= d_imm_alu;
                x_multiply_q <= d_multiply;
`ifdef RISCC_FAST_SOFT_MUL
                x_bitop_q <= d_shift | d_funnel;
                x_shift_nonzero_q <= d_shift & (|d_bbb);
`else
                x_shift_q <= d_shift;
                x_funnel_q <= d_funnel;
`endif
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
                x_run_logic_q <= (d_imm_alu & d_aaa[2]) |
                                 (d_reg_alu & d_f5[2]);
                x_run_rf_b_q <= (d_reg_alu_group & ~d_f5[2]) |
                                d_indexed_memory;
                x_run_short_imm_q <= d_imm_alu & ~d_aaa[2] & ~d_aaa[1];
                x_imm_arithmetic_q <= d_imm_alu & ~d_aaa[2] & d_aaa[1];
                x_reg_arithmetic_q <= d_reg_alu_group & ~d_f5[2];
            end

            if (frontend_flush) begin
                state_q <= ST_RUN;
                x_valid_q <= 1'b0;
            end else if (x_shift_start) begin
                state_q <= ST_SHIFT;
                side_data_q <= x_shift_step;
                side_count_q <= {{(COUNT_BITS-3){1'b0}}, x_bbb};
            end else if (x_mul_start) begin
                state_q <= ST_MUL;
`ifdef RISCC_FAST_SOFT_MUL
                side_data_q <= 0;
                side_count_q <= {COUNT_BITS{1'b1}};
`else
                side_data_q <= x_mul_result;
`endif
`ifdef RISCC_FAST_SOFT_MUL
            end else if (x_long_start) begin
                state_q <= ST_LONG;
                side_data_q <= long_target;
`endif
`ifdef RISCC_FAST_SOFT_MUL
            end else if (in_mul & ~mul_finish) begin
                side_data_q <= mul_step;
                side_count_q <= side_count_q - 1'b1;
`endif
            end else if (in_shift & ~shift_finish) begin
                side_data_q <= shift_step;
                side_count_q <= side_count_q - 1'b1;
            end else if (x_finish | ~x_valid_q) begin
                state_q <= ST_RUN;
                x_valid_q <= d_issue;
            end

            // Architectural IE changes only at completed instruction boundaries.
            if (take_irq)
                interrupt_enable_q <= 1'b0;
            else if (normal_x & x_ie_write)
                interrupt_enable_q <= x_ddd[2];

            // A data or long-form access takes priority over fetch. A full D
            // stage suppresses fetch until its instruction can issue.
            if (frontend_flush) begin
                f_pc_q <= frontend_redirect_pc;
            end else if (fetch_accepted) begin
                f_pc_q <= f_pc_q + 1'b1;
            end

            if (frontend_flush) begin
                d_valid_q <= 1'b0;
            end else if (fetch_accepted) begin
                d_valid_q <= 1'b1;
                d_pc_q <= f_pc_q;
                d_instr_q <= mem_rdata;
            end else if (d_issue) begin
                d_valid_q <= 1'b0;
            end

            if (rst) begin
                state_q <= ST_RUN;
                memory_second_q <= 1'b0;
                interrupt_enable_q <= 1'b0;
                f_pc_q <= RESET_PC[XLEN-2:0];
                d_valid_q <= 1'b0;
                x_valid_q <= 1'b0;
            end
        end
    end
endmodule

// Two synchronous one-read/one-write copies provide the two architectural
// read ports. Folding the collision choice into each registered read avoids
// separate bypass-data and bypass-valid registers in the block-RF build.
module riscc_fast_rf #(parameter integer XLEN = 16) (
    input  wire        clk,
    input  wire        read_en,
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
        if (read_en) begin
            ram_rdata_a_q <= (we && (waddr == raddr_a)) ?
                             wdata : mem_a[raddr_a];
            ram_rdata_b_q <= (we && (waddr == raddr_b)) ?
                             wdata : mem_b[raddr_b];
        end
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
        if (read_en) begin
            rdata_a_q <= (we && (waddr == raddr_a)) ? wdata : mem_a[raddr_a];
            rdata_b_q <= (we && (waddr == raddr_b)) ? wdata : mem_b[raddr_b];
        end
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`endif
endmodule

`default_nettype wire
