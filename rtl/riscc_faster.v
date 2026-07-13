// riscc_faster.v : three-stage Agilex-oriented full-profile RISC-C core.
//
// The pipeline is IF, Decode/RF, Execute.  Decode drives two replicated
// synchronous MLAB register files; their registered read outputs are the
// Execute operands.  There is deliberately no bypass network.  A decoded
// instruction that reads the live Execute destination remains in D through
// the producer's write edge, then repeats its RF read on the following edge.
//
// Loads, iterative shifts, MUL, and JAL16 use short Execute substates.  MUL
// uses a registered DSP by default; RISCC_FASTER_SOFT_MUL selects an iterative
// fabric implementation.  The instruction, destination, and operands remain
// owned by X until the operation commits.  The unified synchronous memory
// port is used for both fetch and data accesses.

`default_nettype none

module riscc_faster #(
    parameter [15:0] RESET_PC = 16'h0000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,
    output wire [14:0] mem_addr,
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,
    output wire        mem_we
);
    localparam [2:0] ST_RUN   = 3'd0;
    localparam [2:0] ST_LOAD  = 3'd1;
    localparam [2:0] ST_SHIFT = 3'd2;
    localparam [2:0] ST_MUL   = 3'd3;
    localparam [2:0] ST_JAL16 = 3'd4;

    reg [2:0] state_q;
    wire in_run   = state_q == ST_RUN;
    wire in_load  = state_q == ST_LOAD;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;
    wire in_jal16 = state_q == ST_JAL16;

    reg interrupt_enable_q;

    // ------------------------------------------------------------------
    // IF and Decode/RF stages
    // ------------------------------------------------------------------
    // f_pc_q is the next sequential request.  f_pending_q tags mem_rdata as
    // a fetch response in the current cycle.  A response blocked by D is
    // reissued in place; if X takes the port, f_pc_q rewinds to its tag.
    reg [14:0] f_pc_q;
    reg        f_pending_q;
    reg [14:0] f_pending_pc_q;

    reg        d_valid_q;
    reg [14:0] d_pc_q;
    reg [15:0] d_instr_q;

    wire [1:0] d_class = d_instr_q[15:14];
    wire [2:0] d_ddd = d_instr_q[13:11];
    wire [2:0] d_aaa = d_instr_q[10:8];
    wire [4:0] d_f5 = d_instr_q[7:3];
    wire [2:0] d_bbb = d_instr_q[2:0];

    wire d_imm_memory = ~d_class[1];
    wire d_imm_store = d_imm_memory & d_class[0];
    wire d_immediate = d_class[1] & ~d_class[0];
    wire d_register = &d_class;
    wire d_branch = d_immediate & (d_aaa == 3'b111);
    wire d_imm_alu = d_immediate & ~d_branch;
    wire d_reg_alu_group = d_register & (d_f5[4:3] == 2'b00);
    wire d_reg_mem = d_register & (d_f5[4:3] == 2'b01);
    wire d_system = d_register & d_f5[4] & d_f5[3];
    wire d_reg_store = d_reg_mem & ~d_f5[2] & d_f5[1] & d_f5[0];
    wire d_multiply = d_reg_alu_group & (&d_f5[2:0]);
    wire d_reg_alu = d_reg_alu_group & ~d_multiply;
    wire d_shift_right = d_reg_mem & d_f5[2] & ~d_f5[1];
    wire d_shift_left = d_reg_mem & (&d_f5[2:0]);
    wire d_shift = d_shift_right | d_shift_left;
    wire d_indexed_memory = d_reg_mem & ~d_f5[0] &
                            (~d_f5[2] | d_f5[1]);
    wire d_reg_memory = d_reg_mem &
        ((~d_f5[2] & (~d_f5[0] | d_f5[1])) |
         (d_f5[1] & ~d_f5[0]));
    wire d_memory = d_imm_memory | d_reg_memory;
    wire d_store = d_imm_store | d_reg_store;
    wire d_load = d_memory & ~d_store;
    wire d_link_jump = d_system & ~d_bbb[1] & d_bbb[0];
    wire d_jal = d_link_jump & ~d_bbb[2];
    wire d_jal16 = d_link_jump & d_bbb[2];
    // RET/RETI share bbb=000 and CLI/STI share bbb=110.  Register the direct
    // IE-control plane; Execute adds RETI using the retained ccc field.
    wire d_return = d_system & ~d_bbb[1] & ~d_bbb[0];
    wire d_move = d_system & ~d_bbb[2] & d_bbb[1];
    wire d_ie_control = d_system & d_bbb[2] & d_bbb[1];
    wire d_load_byte = d_reg_memory & d_f5[1];
    wire d_signed_byte = d_indexed_memory & d_f5[2];
    wire d_cmpi = d_imm_alu & (d_aaa == 3'b011);

    // Broad don't-care terms match riscc_fast's area-tuned source decode.
    // They can cause harmless extra stalls for reserved encodings.
    wire d_uses_a = ~d_class[1] | d_register |
        (d_immediate & (d_aaa[1] | d_aaa[2]));
    wire d_uses_b = d_imm_store | d_reg_store | d_reg_alu_group |
                    d_indexed_memory;
    wire [3:0] d_src_a = d_branch ? 4'h0 :
        d_system ? {~d_bbb[0], d_aaa} :
        d_immediate ? {1'b0, d_ddd} : {1'b0, d_aaa};
    wire d_src_b_is_ddd = d_class[0] &
                          (~d_class[1] | (d_f5[3] & d_f5[0]));
    wire [3:0] d_src_b = {1'b0,
        d_src_b_is_ddd ? d_ddd : d_bbb};

    wire d_result_we = d_imm_alu | d_shift | d_reg_alu | d_multiply |
                       d_move | (d_link_jump & (|d_ddd));
    wire d_we = d_load | d_result_we;
    wire d_result_system = d_system & d_bbb[0];
    wire [3:0] d_dst = {
        d_result_system,
        d_ddd & {3{~d_cmpi}}
    };

    // ------------------------------------------------------------------
    // Execute stage and factored instruction decode
    // ------------------------------------------------------------------
    reg        x_valid_q;
    reg [14:0] x_pc_q;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [13:0] x_instr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [3:0]  x_dst_q;
    reg        x_we_q;

    // Factored D-stage controls.  Registering these removes raw major-opcode
    // decode from the Execute adder/result path without introducing a broad
    // 32-way operation selector.
`ifndef RISCC_FASTER_SOFT_MUL
    reg x_imm_memory_q;
`endif
    reg x_branch_q;
    reg x_imm_alu_q;
    reg x_reg_alu_group_q;
`ifndef RISCC_FASTER_SOFT_MUL
    reg x_reg_alu_q;
`endif
    reg x_multiply_q;
    reg x_shift_q;
    reg x_shift_left_q;
`ifndef RISCC_FASTER_SOFT_MUL
    reg x_indexed_memory_q;
`endif
    reg x_memory_q;
    reg x_store_q;
    reg x_load_byte_q;
    reg x_signed_byte_q;
    reg x_return_q;
    reg x_jal_q;
    reg x_jal16_q;
    reg x_move_q;
    reg x_ie_control_q;
`ifdef RISCC_FASTER_SOFT_MUL
    // Registering these mutually exclusive result selects keeps major-opcode
    // qualification out of the Execute result mux in the fabric-only build.
    reg x_run_imm_s_q;
    reg x_run_logic_q;
    reg x_run_rf_b_q;
    reg x_run_short_imm_q;
    reg x_imm_arithmetic_q;
    reg x_reg_arithmetic_q;
`endif

    wire [2:0] x_ddd = x_instr_q[13:11];
`ifdef RISCC_FASTER_SOFT_MUL
    wire [1:0] x_aaa = x_instr_q[9:8];
`else
    wire [2:0] x_aaa = x_instr_q[10:8];
`endif
    wire [2:0] x_f3 = x_instr_q[5:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

`ifndef RISCC_FASTER_SOFT_MUL
    wire x_imm_memory = x_imm_memory_q;
`endif
    wire x_branch = x_branch_q;
    wire x_imm_alu = x_imm_alu_q;
    wire x_reg_alu_group = x_reg_alu_group_q;
`ifndef RISCC_FASTER_SOFT_MUL
    wire x_reg_alu = x_reg_alu_q;
`endif
    wire x_multiply = x_multiply_q;
    wire x_shift = x_shift_q;
    wire x_shift_left = x_shift_left_q;
`ifndef RISCC_FASTER_SOFT_MUL
    wire x_indexed_memory = x_indexed_memory_q;
`endif
    wire x_memory = x_memory_q;
    wire x_store = x_store_q;
    wire x_load_byte = x_load_byte_q;
    wire x_signed_byte = x_signed_byte_q;
    wire x_return = x_return_q;
    wire x_jal = x_jal_q;
    wire x_jal16 = x_jal16_q;
    wire x_link_jump = x_jal | x_jal16;
    wire x_move = x_move_q;
    wire x_ie_control = x_ie_control_q;
    wire x_ie_write = x_ie_control | (x_return & x_ddd[2]);

    wire [15:0] rf_a;
    wire [15:0] rf_b;

    wire run_x = in_run & x_valid_q;
    // Interrupts are sampled before the populated X instruction executes.
    // Side states are indivisible; the following instruction is sampled.
    wire take_irq = run_x & irq & interrupt_enable_q;
    wire normal_x = run_x & ~take_irq;

    wire [15:0] x_imm_z = {8'h00, x_instr_q[7:0]};
    wire [15:0] x_imm_s = {{8{x_instr_q[7]}}, x_instr_q[7:0]};
    wire [15:0] x_imm_u = {x_instr_q[7:0], 8'h00};

    wire [1:0] x_logic_op = x_imm_alu ? x_aaa[1:0] : x_f3[1:0];
    wire [15:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [15:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) :
                         (rf_a & x_logic_rhs)) :
        (rf_a ^ x_logic_rhs);

    // One-bit shift hardware is shared by the initial X step and ST_SHIFT.
    reg [15:0] side_data_q;
    reg [2:0]  side_count_q;
    reg        load_lane_q;

`ifdef RISCC_FASTER_SOFT_MUL
    // X shift, ST_SHIFT, and the multiplier's accumulator-left shift share
    // one source/direction mux.  MUL has a separate carry chain so its
    // recurrence does not lengthen the normal Execute result path.
    wire side_shift_active = in_shift | in_mul;
    wire [15:0] side_shift_source = side_shift_active ? side_data_q : rf_a;
    wire side_shift_left = in_mul | x_shift_left;
    wire [15:0] side_shift_step = side_shift_left ?
        {side_shift_source[14:0], 1'b0} :
        {x_f3[0] & side_shift_source[15], side_shift_source[15:1]};
    wire [15:0] x_shift_step = side_shift_step;
    wire [15:0] shift_step = side_shift_step;
`else
    wire [15:0] x_shift_step = x_shift_left ?
        {rf_a[14:0], 1'b0} :
        {x_f3[0] & rf_a[15], rf_a[15:1]};
    wire [15:0] shift_step = x_shift_left ?
        {side_data_q[14:0], 1'b0} :
        {x_f3[0] & side_data_q[15], side_data_q[15:1]};
`endif
    wire shift_finish = in_shift & (side_count_q == 3'd1);

`ifdef RISCC_FASTER_SOFT_MUL
    // Consume multiplier bits MSB first.  load_lane_q is idle during MUL and
    // doubles as the high bit of the 4-bit iteration count.
    wire [3:0] mul_count = {load_lane_q, side_count_q};
    wire mul_finish = in_mul & (mul_count == 4'd0);
    wire [15:0] mul_addend = rf_b[mul_count] ? rf_a : 16'h0000;
    wire [15:0] mul_step = side_shift_step + mul_addend;
`else
    // The register on side_data_q is the multiplier output boundary.  Only
    // the low product word is architectural, allowing one 16x16 DSP block.
    wire [15:0] x_mul_result = rf_a * rf_b;
`endif

    // Shared add/subtract and result path, kept close to riscc_fast's compact
    // factoring.  RF selection is now in the preceding pipeline stage.
`ifdef RISCC_FASTER_SOFT_MUL
    wire x_imm_arithmetic = x_imm_arithmetic_q;
    wire x_reg_arithmetic = x_reg_arithmetic_q;
`else
    wire x_imm_arithmetic = x_imm_alu & ~x_aaa[2] & x_aaa[1];
    wire x_reg_arithmetic = x_reg_alu_group & ~x_f3[2];
`endif
    wire alu_a_is_pc = normal_x & (x_branch | x_link_jump);
    wire alu_a_is_rf = normal_x &
        (x_imm_arithmetic | x_reg_arithmetic | x_memory);
    wire [15:0] alu_a = alu_a_is_pc ? {1'b0, x_pc_q} :
                            alu_a_is_rf ? rf_a : 16'h0000;

    wire [15:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
`ifdef RISCC_FASTER_SOFT_MUL
    wire run_imm_s = x_run_imm_s_q;
    wire run_logic = x_run_logic_q;
    wire run_rf_b = x_run_rf_b_q;
    wire run_short_imm = x_run_short_imm_q;
`else
    wire run_imm_s = x_branch | x_imm_memory |
                     (x_imm_alu & ~x_aaa[2] & x_aaa[1]);
    wire run_logic = (x_imm_alu & x_aaa[2]) |
                     (x_reg_alu & x_f3[2]);
    wire run_rf_b = x_reg_arithmetic | x_indexed_memory;
    wire run_short_imm = x_imm_alu & ~x_aaa[2] & ~x_aaa[1];
`endif
    wire [15:0] run_result = run_logic ? x_logic_result :
        run_imm_s ? x_imm_s :
        run_rf_b ? rf_b :
        run_short_imm ? immediate_result :
        x_move ? rf_a :
        x_shift ? x_shift_step :
        x_jal16 ? 16'h0001 : 16'h0000;

    wire alu_subtract = normal_x &
        ((x_imm_arithmetic & x_aaa[0]) |
         (x_reg_arithmetic & (|x_f3[1:0])));
    wire alu_carry_in = alu_subtract |
        (normal_x & (x_branch | x_link_jump));
    wire [15:0] adjusted_alu_b = run_result ^ {16{alu_subtract}};
    wire [16:0] alu_sum = {1'b0, alu_a} +
                          {1'b0, adjusted_alu_b} +
                          {{16{1'b0}}, alu_carry_in};
    wire [15:0] alu_result = alu_sum[15:0];
    wire alu_carry_out = alu_sum[16];
    wire alu_overflow = (alu_a[15] ^ run_result[15]) &
                        (alu_result[15] ^ alu_a[15]);
    wire signed_less = alu_result[15] ^ alu_overflow;
    wire unsigned_less = ~alu_carry_out;
    wire x_compare = x_reg_alu_group & ~x_f3[2] & x_f3[1];
    wire [15:0] execute_result = x_compare ?
        {15'h0000, x_f3[0] ? unsigned_less : signed_less} :
        alu_result;

    wire [15:0] x_effective_address = alu_result;
    wire [14:0] x_pc_plus1 = x_pc_q + 15'd1;
    wire [14:0] x_pc_plus2 = x_pc_q + 15'd2;

    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? rf_a[15] : ~|rf_a) ^ x_ddd[0]);

    // ------------------------------------------------------------------
    // X side-state starts, completion, redirects, and RAW interlock
    // ------------------------------------------------------------------
    wire x_load_start = normal_x & x_memory & ~x_store;
    wire x_shift_start = normal_x & x_shift & (|x_bbb);
    wire x_mul_start = normal_x & x_multiply;
    wire x_jal16_start = normal_x & x_jal16;
    wire x_side_start = x_load_start | x_shift_start |
                        x_mul_start | x_jal16_start;

    wire run_commit = normal_x & ~x_side_start;
    wire load_commit = in_load;
    wire shift_commit = shift_finish;
`ifdef RISCC_FASTER_SOFT_MUL
    wire mul_commit = mul_finish;
`else
    wire mul_commit = in_mul;
`endif
    wire jal16_commit = in_jal16;
    wire commit_valid = run_commit | load_commit | shift_commit |
                        mul_commit | jal16_commit;

    wire run_redirect = run_commit &
        ((x_branch & x_branch_taken) | x_jal | x_return);
    wire x_redirect = run_redirect | jal16_commit;
    wire [14:0] x_redirect_pc = jal16_commit ? mem_rdata[14:0] :
        x_branch ? alu_result[14:0] : rf_a[14:0];
    wire frontend_flush = take_irq | x_redirect;
    wire [14:0] frontend_redirect_pc = take_irq ? 15'd2 :
                                              x_redirect_pc;

    wire x_finish = take_irq | commit_valid;
    wire x_slot_available = ~x_valid_q | x_finish;
    wire d_data_hazard = d_valid_q & x_valid_q & x_we_q &
        ((d_uses_a & (d_src_a == x_dst_q)) |
         (d_uses_b & (d_src_b == x_dst_q)));
    wire d_issue = d_valid_q & x_slot_available &
                   ~d_data_hazard & ~frontend_flush;
    wire d_can_accept = ~d_valid_q | d_issue;

    // ------------------------------------------------------------------
    // Load response and architectural writeback
    // ------------------------------------------------------------------
    wire [7:0] load_byte = load_lane_q ?
                           mem_rdata[15:8] : mem_rdata[7:0];
    wire [15:0] load_value = x_load_byte ?
        {{8{x_signed_byte & load_byte[7]}}, load_byte} : mem_rdata;

    wire [15:0] run_write_data = x_jal ?
        {1'b0, x_pc_plus1} : execute_result;
`ifdef RISCC_FASTER_SOFT_MUL
    wire [15:0] mul_write_data = mul_step;
`else
    wire [15:0] mul_write_data = side_data_q;
`endif
    wire [15:0] commit_data = in_load ? load_value :
        in_shift ? shift_step :
`ifdef RISCC_FASTER_SOFT_MUL
        in_mul ? mul_write_data :
`else
        in_mul ? mul_write_data :
`endif
        in_jal16 ? {1'b0, x_pc_plus2} : run_write_data;
    wire rf_we = take_irq | (commit_valid & x_we_q);
    wire [3:0] rf_waddr = take_irq ? 4'h8 : x_dst_q;
    wire [15:0] rf_wdata = take_irq ? {1'b0, x_pc_q} : commit_data;

    riscc_faster_rf regs (
        .clk(clk),
        .read_en(d_issue),
        .raddr_a(d_src_a), .rdata_a(rf_a),
        .raddr_b(d_src_b), .rdata_b(rf_b),
        .waddr(rf_waddr), .wdata(rf_wdata), .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Unified memory and IF bookkeeping
    // ------------------------------------------------------------------
    wire x_memory_request = normal_x & x_memory;
    wire x_port_request = x_memory_request | x_jal16_start;

    wire f_accept = f_pending_q & d_can_accept & ~frontend_flush;
    wire f_response_held = f_pending_q & ~d_can_accept;
    wire [14:0] fetch_request_pc = f_response_held ?
                                   f_pending_pc_q : f_pc_q;

    assign mem_addr = x_memory_request ? x_effective_address[15:1] :
                      x_jal16_start ? x_pc_plus1 : fetch_request_pc;
    assign mem_we = x_memory_request & x_store;
    assign mem_wdata = x_load_byte ? {2{rf_b[7:0]}} : rf_b;
    assign mem_wmask = x_load_byte ?
                       {x_effective_address[0],
                        ~x_effective_address[0]} : 2'b11;

    // ------------------------------------------------------------------
    // Pipeline and side-state updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        // D/RF -> X.  The RF module samples the same decoded addresses on
        // this edge; its registered outputs and these controls stay aligned.
        if (d_issue) begin
            x_pc_q <= d_pc_q;
            x_instr_q <= d_instr_q[13:0];
            x_dst_q <= d_dst;
            x_we_q <= d_we;
`ifndef RISCC_FASTER_SOFT_MUL
            x_imm_memory_q <= d_imm_memory;
`endif
            x_branch_q <= d_branch;
            x_imm_alu_q <= d_imm_alu;
            x_reg_alu_group_q <= d_reg_alu_group;
`ifndef RISCC_FASTER_SOFT_MUL
            x_reg_alu_q <= d_reg_alu;
`endif
            x_multiply_q <= d_multiply;
            x_shift_q <= d_shift;
            x_shift_left_q <= d_shift_left;
`ifndef RISCC_FASTER_SOFT_MUL
            x_indexed_memory_q <= d_indexed_memory;
`endif
            x_memory_q <= d_memory;
            x_store_q <= d_store;
            x_load_byte_q <= d_load_byte;
            x_signed_byte_q <= d_signed_byte;
            x_return_q <= d_return;
            x_jal_q <= d_jal;
            x_jal16_q <= d_jal16;
            x_move_q <= d_move;
            x_ie_control_q <= d_ie_control;
`ifdef RISCC_FASTER_SOFT_MUL
            x_run_imm_s_q <= d_branch | d_imm_memory |
                             (d_imm_alu & ~d_aaa[2] & d_aaa[1]);
            x_run_logic_q <= (d_imm_alu & d_aaa[2]) |
                             (d_reg_alu & d_f5[2]);
            x_run_rf_b_q <= (d_reg_alu_group & ~d_f5[2]) |
                            d_indexed_memory;
            x_run_short_imm_q <= d_imm_alu & ~d_aaa[2] & ~d_aaa[1];
            x_imm_arithmetic_q <= d_imm_alu & ~d_aaa[2] & d_aaa[1];
            x_reg_arithmetic_q <= d_reg_alu_group & ~d_f5[2];
`endif
        end

        if (frontend_flush) begin
            state_q <= ST_RUN;
            x_valid_q <= 1'b0;
        end else if (x_load_start) begin
            state_q <= ST_LOAD;
            load_lane_q <= x_effective_address[0];
        end else if (x_shift_start) begin
            state_q <= ST_SHIFT;
            side_data_q <= x_shift_step;
            side_count_q <= x_bbb;
        end else if (x_mul_start) begin
            state_q <= ST_MUL;
`ifdef RISCC_FASTER_SOFT_MUL
            // Consume bit 15 in X, then iterate bits 14 through 0.
            side_data_q <= rf_b[15] ? rf_a : 16'h0000;
            load_lane_q <= 1'b1;
            side_count_q <= 3'd6;
`else
            side_data_q <= x_mul_result;
`endif
        end else if (x_jal16_start) begin
            state_q <= ST_JAL16;
`ifdef RISCC_FASTER_SOFT_MUL
        end else if (in_mul & ~mul_finish) begin
            side_data_q <= mul_step;
            side_count_q <= side_count_q - 1'b1;
            if (~|side_count_q)
                load_lane_q <= 1'b0;
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

        // Fetch request/response tags.  A data/JAL16 request invalidates the
        // following mem_rdata as an instruction response.  If a blocked
        // response was displaced, rewind the sequential request pointer.
        if (frontend_flush) begin
            f_pc_q <= frontend_redirect_pc;
            f_pending_q <= 1'b0;
        end else if (x_port_request) begin
            f_pending_q <= 1'b0;
            if (f_pending_q & ~f_accept)
                f_pc_q <= f_pending_pc_q;
        end else begin
            f_pending_q <= 1'b1;
            f_pending_pc_q <= fetch_request_pc;
            if (~f_response_held)
                f_pc_q <= f_pc_q + 1'b1;
        end

        if (frontend_flush) begin
            d_valid_q <= 1'b0;
        end else if (f_accept) begin
            d_valid_q <= 1'b1;
            d_pc_q <= f_pending_pc_q;
            d_instr_q <= mem_rdata;
        end else if (d_issue) begin
            d_valid_q <= 1'b0;
        end

        if (rst) begin
            state_q <= ST_RUN;
            interrupt_enable_q <= 1'b0;
            f_pc_q <= RESET_PC[14:0];
            f_pending_q <= 1'b0;
            d_valid_q <= 1'b0;
            x_valid_q <= 1'b0;
        end
    end
endmodule

// Two synchronous one-read/one-write copies provide the two architectural
// read ports.  The core never consumes a colliding read: a RAW match suppresses
// read_en through the producer's write edge, then repeats the read next cycle.
module riscc_faster_rf (
    input  wire        clk,
    input  wire        read_en,
    input  wire [3:0]  raddr_a,
    output wire [15:0] rdata_a,
    input  wire [3:0]  raddr_b,
    output wire [15:0] rdata_b,
    input  wire [3:0]  waddr,
    input  wire [15:0] wdata,
    input  wire        we
);
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] mem_a [0:15];
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] mem_b [0:15];
    reg [15:0] rdata_a_q;
    reg [15:0] rdata_b_q;

    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    always @(posedge clk) begin
        if (read_en) begin
            rdata_a_q <= mem_a[raddr_a];
            rdata_b_q <= mem_b[raddr_b];
        end
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
endmodule

`default_nettype wire
