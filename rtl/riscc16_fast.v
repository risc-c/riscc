// riscc16_fast.v : compact two-stage RC16 Full pipeline.
//
// Fetch and execute overlap. The RF can use either asynchronous two-read
// LUTRAM or two synchronous block-RAM copies. The block-RAM build stalls on a
// preceding-result RAW.
// Results write directly from execute without a forwarding network.
// Shifts and soft MUL use small side states. Loads complete directly from the
// acknowledged memory response. JALL consumes the following halfword already
// present in the fetch-response slot.

`default_nettype none

module riscc16_fast #(
    parameter [15:0] RESET_PC = 16'h0000  // halfword address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // level-sensitive; sampled between instructions

    output wire [14:0] mem_addr,   // halfword address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,  // byte-lane enables
    output wire        mem_we,
    output wire        mem_valid,  // request valid; held until mem_ready
    input  wire        mem_ready   // request accepted; read data is valid
`ifdef RISCC_TRACE
    ,
`include "riscc_trace_ports.vh"
`endif
);

    // ------------------------------------------------------------------
    // Pipeline state and side-state control
    // ------------------------------------------------------------------
    // RUN is the pipelined steady state; the remaining states finish operations
    // that retain X while a younger instruction waits at the frontend.
    localparam [1:0] ST_RUN   = 2'd1;
    localparam [1:0] ST_SHIFT = 2'd3;
    localparam [1:0] ST_MUL   = 2'd2;
    reg [1:0] state_q;
    wire core_advance;
    reg bus_wait_q;
    wire in_run   = state_q == ST_RUN;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;

    reg interrupt_enable_q;

    // One tagged acknowledged fetch response feeds X directly.
    reg [14:0] fetch_pc_q;
    reg        fetch_pending_q;
    reg [14:0] fetch_pending_pc_q;
    reg [15:0] mem_response_q;
    // Execute carries only the architectural instruction and its PC.
    reg        x_valid_q;
    reg [14:0] x_pc_q;
    reg [15:0] x_instr_q;
`ifdef RISCC_FAST_SYNC_RF
    // Retain accepted source addresses for a possible synchronous-RF replay.
    reg [3:0]  x_raddr_a_q;
    reg [2:0]  x_raddr_b_q;
    reg        x_rf_wait_q;
`endif

    // Side-state storage. Lifetimes do not overlap between operations.
    reg [15:0] side_data_q;
    reg [5:0]  side_aux_q;
`ifdef RISCC_FAST_DSP
    reg [2:0]  side_count_q;
`else
    reg [3:0]  side_count_q;
`endif
`ifdef RISCC_TRACE
    reg [15:0] x_trace_instr_q;
    reg [14:0] side_pc_q;
    reg [15:0] side_instr_q;
    reg [14:0] trace_pc_live_q;
    reg        trace_ie_live_q;
    reg        trace_rf_we_q;
    reg [3:0]  trace_rf_addr_q;
    reg [15:0] trace_rf_data_q;
`endif

    // ------------------------------------------------------------------
    // Instruction decode
    // ------------------------------------------------------------------
    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field. The x_ prefix denotes
    // the Execute-stage copy.
    wire [1:0] x_class = x_instr_q[15:14];
    wire [2:0] x_ddd = x_instr_q[13:11];
    wire [2:0] x_aaa = x_instr_q[10:8];
    wire [4:0] x_f5 = x_instr_q[7:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

    wire x_imm_memory = ~x_class[1] & x_class[0];
    wire x_imm_store = x_imm_memory & x_instr_q[0];
    wire x_immediate = x_class[1] & ~x_class[0];
    wire x_register = &x_class;
    wire x_branch = x_immediate & (x_aaa == 3'b111);
    wire x_imm_alu = x_immediate & ~x_branch;
    wire x_reg_alu_group = x_register & (x_f5[4:3] == 2'b00);
    wire x_reg_mem = x_register & (x_f5[4:3] == 2'b01);
    wire x_high_group = x_register & x_f5[4] & x_f5[3];
    wire x_reg_store = x_reg_mem & ~x_f5[2] & x_f5[1] & x_f5[0];
    wire x_system = x_high_group;
    wire x_multiply = x_reg_alu_group & (&x_f5[2:0]);
    wire x_shift_left = x_reg_mem & (&x_f5[2:0]);
    // f5[0] selects the compact funnel group and ooo[1] excludes every
    // defined vector-shift selector.
    wire x_funnel = x_register & x_f5[4] & ~x_f5[3] &
                      x_f5[0] & ~x_bbb[1];
    wire x_reg_alu = x_reg_alu_group & ~x_multiply;
    wire x_shift_right = x_reg_mem & x_f5[2] & ~x_f5[1];
    wire x_shift = x_shift_right | x_shift_left;
    // LDX uses ra+rb. Direct typed accesses use ra.
    wire x_indexed_memory = x_reg_mem & ~x_f5[2] & ~x_f5[1] & ~x_f5[0];
    wire x_direct_load = x_reg_mem & x_f5[1] & ~x_f5[0];
    wire x_memory =
        x_imm_memory | x_indexed_memory | x_direct_load | x_reg_store;
    wire x_store = x_imm_store | x_reg_store;
    wire x_load_byte = (x_direct_load | x_reg_store) & ~(|x_bbb);
    wire x_signed_byte = x_load_byte & x_f5[2];
    // RET/RETI and CLI/STI share bbb=000. ddd[1] selects a return versus a
    // direct IE operation; ddd[2] and ddd[0] duplicate the selected IE value.
    wire x_control_ie_value = x_ddd[0];
    wire x_control_plane = x_system & ~x_bbb[1] & ~x_bbb[0];
    wire x_return = x_control_plane & ~x_ddd[1];
    wire x_return_sets_ie = x_return & x_control_ie_value;
    wire x_ie_control = x_control_plane & x_ddd[1];
    wire x_jal = x_system & ~x_bbb[2] & ~x_bbb[1] & x_bbb[0];
    wire x_move = x_system & ~x_bbb[2] & x_bbb[1];
    wire x_long_form = (x_instr_q & 16'hc7ff) == 16'h0034;
    wire x_jall = x_long_form;
    wire x_link_jump = x_jal | x_jall;

    wire x_src_a_is_ddd = x_immediate | x_funnel;
    wire [3:0] x_src_a = x_branch ? 4'h0 :
        x_system ? {~x_bbb[0], x_aaa} :
        x_src_a_is_ddd ? {1'b0, x_ddd} : {1'b0, x_aaa};
    // Stores consume ddd on B. Direct typed loads broaden that existing
    // select because their B value is ignored; bbb remains decode-only.
    wire x_src_b_is_ddd = x_class[0] &
        (~x_class[1] | (x_f5[3] & x_f5[1]));
    wire [2:0] x_src_b_low = x_src_b_is_ddd ? x_ddd :
                             (x_funnel ? x_aaa : x_bbb);
    wire [3:0] x_src_b = {1'b0, x_src_b_low};
    wire accept_fetch;
    wire rf_accept_fetch = accept_fetch & core_advance;
    wire [1:0] d_class = mem_response_q[15:14];
    wire [2:0] d_ddd_raw = mem_response_q[13:11];
    wire [2:0] d_ddd = d_ddd_raw;
    wire [2:0] d_aaa = mem_response_q[10:8];
    wire [4:0] d_f5 = mem_response_q[7:3];
    wire [2:0] d_bbb = mem_response_q[2:0];
    wire d_immediate = d_class[1] & ~d_class[0];
    wire d_register = &d_class;
    wire d_funnel = d_register & d_f5[4] & ~d_f5[3] &
                    d_f5[0] & ~d_bbb[1];
    wire d_high_group = d_register & d_f5[4] & d_f5[3];
    wire d_system = d_high_group;
    wire d_branch = d_immediate & (d_aaa == 3'b111);
    wire d_direct_load = d_register & ~d_f5[4] & d_f5[3] &
                         d_f5[1] & ~d_f5[0];
    wire d_uses_a = (~d_class[1] & d_class[0]) | d_register |
        (d_immediate & (d_aaa[1] | d_aaa[2]));
    // Immediate stores and non-system register operations may read B. Direct
    // loads need only the A hazard check because both RF addresses select aaa.
    wire d_uses_b = d_class[0] &
        (~d_class[1] | ~d_f5[4] | ~d_f5[3]) & ~d_direct_load;
    wire d_src_a_is_ddd = d_immediate | d_funnel;
    wire [3:0] d_src_a = d_branch ? 4'h0 :
        d_system ? {~d_bbb[0], d_aaa} :
        d_src_a_is_ddd ? {1'b0, d_ddd} : {1'b0, d_aaa};
    wire d_src_b_is_ddd = d_class[0] &
        (~d_class[1] | (d_f5[3] & d_f5[1]));
    wire [2:0] d_src_b_low = d_src_b_is_ddd ? d_ddd :
                             (d_funnel ? d_aaa : d_bbb);
    wire [3:0] d_src_b = {1'b0, d_src_b_low};
    wire [3:0] rf_raddr_a;
    wire [3:0] rf_raddr_b;
    wire [15:0] rf_a;
    wire [15:0] rf_b;

`ifdef RISCC_FAST_SYNC_RF
    assign rf_raddr_a = rf_accept_fetch ? d_src_a : x_raddr_a_q;
    assign rf_raddr_b = rf_accept_fetch ? d_src_b : {1'b0, x_raddr_b_q};
`else
    assign rf_raddr_a = x_src_a;
    assign rf_raddr_b = x_src_b;
`endif

    wire [15:0] x_imm_z = {8'h00, x_instr_q[7:0]};
    wire x_imm_sign = x_branch ? x_instr_q[0] : x_instr_q[7];
    wire [15:0] x_imm_s = {{8{x_imm_sign}}, x_instr_q[7:0]};
    wire [15:0] x_imm_u = {x_instr_q[7:0], 8'h00};

    wire [1:0] x_logic_op = x_imm_alu ? x_aaa[1:0] : x_f5[1:0];
    wire [15:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [15:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) : (rf_a & x_logic_rhs)) :
        (rf_a ^ x_logic_rhs);
    wire [15:0] alu_result;

    wire [7:0] accepted_load_byte = alu_result[0] ?
        mem_rdata[15:8] : mem_rdata[7:0];
    wire [15:0] accepted_load_value = x_load_byte ?
        {{8{x_signed_byte & accepted_load_byte[7]}}, accepted_load_byte} :
        mem_rdata;
    wire [15:0] long_value = mem_response_q;

    wire x_shift_step_left =
        x_shift_left | (x_funnel & ~x_bbb[0]);
    wire x_funnel_left_bit = x_funnel & rf_b[15];
    wire [15:0] x_shift_step = x_shift_step_left ?
        {rf_a[14:0], x_funnel_left_bit} :
        {(x_funnel & rf_b[0]) |
         (~x_funnel & x_f5[0] & rf_a[15]), rf_a[15:1]};
    wire saved_shift_left = side_aux_q[3];
    wire saved_shift_arithmetic = side_aux_q[4];
    wire [15:0] shift_step = saved_shift_left ?
        {side_data_q[14:0], 1'b0} :
        {saved_shift_arithmetic & side_data_q[15], side_data_q[15:1]};
    wire shift_finish = in_shift & (side_count_q[2:0] == 3'd1);

`ifdef RISCC_FAST_DSP
    // RISC-C exposes only the low product half; the high half is unobservable.
    wire [15:0] direct_mul_result = rf_a * rf_b;
    wire mul_finish = 1'b0;
`else
    wire [15:0] direct_mul_result = 16'h0000;
    wire mul_finish = in_mul & (side_count_q == 4'd0);
`endif

    // ------------------------------------------------------------------
    // Shared ALU/result path
    // ------------------------------------------------------------------
`ifdef RISCC_FAST_SYNC_RF
    wire run_x = in_run & x_valid_q & ~x_rf_wait_q;
`else
    wire run_x = in_run & x_valid_q;
`endif
    wire take_irq = run_x & irq & interrupt_enable_q;
    wire normal_x = run_x & ~take_irq;
    wire x_imm_arithmetic = x_imm_alu & ~x_aaa[2] & x_aaa[1];
    wire x_reg_arithmetic = x_reg_alu_group & ~x_f5[2];
    wire run_logic = (x_imm_alu & x_aaa[2]) |
                     (x_reg_alu & x_f5[2]);
    wire alu_a_is_pc = take_irq |
        (normal_x & (x_branch | x_link_jump));
    wire alu_a_is_rf =
`ifndef RISCC_FAST_DSP
        (in_mul & rf_b[side_count_q]) |
`endif
        (normal_x & (
`ifndef RISCC_FAST_DSP
         (x_multiply & rf_b[15]) |
`endif
         x_imm_arithmetic | x_reg_arithmetic |
`ifdef RISCC_FAST_DSP
         x_memory));
`else
         x_memory));
`endif
    wire [15:0] alu_a =
        alu_a_is_pc ? {x_pc_q, 1'b0} :
        alu_a_is_rf ? rf_a : 16'h0000;
`ifndef RISCC_FAST_DSP
    // Consume the saved RF multiplier MSB first. This Horner-form multiply,
    // acc = (acc << 1) + (bit ? multiplicand : 0), needs only one 16-bit
    // side register; the low product is complete after the sixteenth step.
`endif

    // This arm is selected only for LDI/LDIH; arithmetic and logic immediates
    // have already been classified above it.
    wire [15:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
    wire run_imm_s = x_branch | x_imm_memory |
                     (x_imm_alu & ~x_aaa[2] & x_aaa[1]);
    wire run_rf_b = x_reg_arithmetic | x_indexed_memory;
    wire run_short_imm = x_imm_alu & ~x_aaa[2] & ~x_aaa[1];
    wire x_bit_result = x_shift | x_funnel;
    wire [15:0] run_result =
        run_logic ? x_logic_result :
        run_imm_s ? x_imm_s :
`ifndef RISCC_FAST_DSP
        x_move ? rf_a :
`endif
        run_rf_b ?
            rf_b :
        run_short_imm ? immediate_result :
`ifdef RISCC_FAST_DSP
        x_move ? rf_a :
`endif
        x_bit_result ? x_shift_step :
        x_jall ? 16'h0003 :
        16'h0000;
`ifdef RISCC_FAST_DSP
    wire [15:0] alu_b = in_shift ? shift_step :
        normal_x ? run_result : 16'h0000;
`else
    wire [15:0] alu_b = normal_x ? run_result :
        state_q[1] ?
            (state_q[0] ? shift_step : {side_data_q[14:0], 1'b0}) :
        16'h0000;
`endif
    wire alu_subtract = normal_x &
        ((x_imm_arithmetic & x_aaa[0]) |
         (x_reg_arithmetic & (|x_f5[1:0])));
    wire alu_carry_in = alu_subtract |
        (normal_x & (x_branch | x_link_jump));

    wire pc_step = normal_x & (x_branch | x_link_jump);
    wire [15:0] stepped_alu_b =
        {alu_b[15:1], alu_b[0] | pc_step};
    wire [15:0] adjusted_alu_b = stepped_alu_b ^ {16{alu_subtract}};
`ifdef RISCC_FAST_DSP
    assign alu_result = alu_a + adjusted_alu_b +
                        {15'h0000, alu_carry_in};
    wire alu_carry_out = (alu_a[15] & adjusted_alu_b[15]) |
        ((alu_a[15] ^ adjusted_alu_b[15]) & ~alu_result[15]);
`else
    wire [16:0] alu_sum = {1'b0, alu_a} + {1'b0, adjusted_alu_b} +
                          {{16{1'b0}}, alu_carry_in};
    assign alu_result = alu_sum[15:0];
    wire alu_carry_out = alu_sum[16];
`endif
    wire alu_overflow = (alu_a[15] ^ alu_b[15]) &
                        (alu_result[15] ^ alu_a[15]);
    wire signed_less = alu_result[15] ^ alu_overflow;
    wire unsigned_less = ~alu_carry_out;
    wire x_compare =
`ifdef RISCC_FAST_DSP
        x_reg_alu_group & ~x_f5[2] & x_f5[1];
`else
        x_reg_arithmetic & x_f5[1];
`endif
    wire [15:0] execute_result =
`ifdef RISCC_FAST_DSP
        (normal_x && x_multiply) ? direct_mul_result :
`endif
        (normal_x && x_compare) ?
        {15'h0000, x_f5[0] ? unsigned_less : signed_less} :
        alu_result;

    wire x_r0_zero = ~|rf_a;
    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? rf_a[15] : x_r0_zero) ^ x_ddd[0]);
`ifdef RISCC_FAST_SYNC_RF
    wire x_long_wait = normal_x & x_long_form & ~fetch_pending_q;
    wire x_jall_execute = x_jall & fetch_pending_q;
    wire x_redirect = normal_x &
        ((x_branch & x_branch_taken) | x_jal | x_return | x_jall_execute);
`else
    wire x_long_wait = run_x & x_long_form & ~fetch_pending_q;
    wire x_jall_execute = run_x & x_jall & fetch_pending_q;
    wire x_redirect = run_x &
        ((x_branch & x_branch_taken) | x_jal | x_return | x_jall_execute);
`endif
    wire [14:0] x_redirect_pc = x_jall ? long_value[15:1] :
        x_branch ? alu_result[15:1] : rf_a[15:1];

    // ------------------------------------------------------------------
    // Commit, hazards, and RF writeback
    // ------------------------------------------------------------------
    wire x_result_we =
        x_imm_alu | x_shift | x_funnel |
`ifdef RISCC_FAST_DSP
        x_reg_alu | x_multiply |
`else
        x_reg_alu |
`endif
        x_move | (x_link_jump & (|x_ddd));
    // All defined S-bank writes have bbb[0]=1; control-group forms have no
    // result write, so this broad bank select remains unobservable there.
    wire x_result_system = (x_system & x_bbb[0]) | x_jall;
    wire x_cmpi = x_imm_alu & (x_aaa == 3'b011);

    // Interrupt at the next populated X boundary. Waiting for an outstanding
    // fetch response avoids a second EPC/instruction selection path.
    wire [14:0] irq_epc = x_pc_q;
    wire [15:0] irq_instr = x_instr_q;

    wire x_load_start = normal_x & x_memory & ~x_store;
    // The first bit shifts directly in X. A count-one shift therefore
    // completes like an ALU op; only the remaining bits use ST_SHIFT.
    wire x_multi_shift = x_shift & (|x_bbb);
    wire x_shift_start = normal_x & x_multi_shift;
`ifdef RISCC_FAST_DSP
    wire x_mul_start = 1'b0;
`else
    wire x_mul_start = normal_x & x_multiply;
`endif
    wire x_side_start =
        x_shift_start | x_mul_start;
`ifndef RISCC_FAST_DSP
    wire side_data_start = x_shift_start | x_mul_start;
    // Soft MUL consumes bit 15 in X, seeding the Horner accumulator before
    // the side state continues with bit 14.
    wire [15:0] side_data_input = alu_result;
`endif
    wire run_commit = normal_x & ~x_side_start &
                      ~x_long_wait;
    wire side_commit = shift_finish | mul_finish;
    wire commit_valid = take_irq | run_commit | side_commit;

    wire run_rf_we = run_commit & x_result_we;
    wire load_rf_we = x_load_start;
    wire shift_rf_we = shift_finish;
    wire mul_rf_we = mul_finish;
    wire rf_we = core_advance & (take_irq | load_rf_we |
                 shift_rf_we | mul_rf_we | run_rf_we);
`ifdef RISCC_FAST_DSP
    wire side_rf_we = shift_rf_we;
    wire [3:0] rf_waddr = {
        ~side_rf_we & (take_irq | x_result_system),
        side_rf_we ? side_aux_q[2:0] :
            (x_ddd & {3{~(take_irq | x_cmpi)}})
    };
`else
    wire saved_side_rf_we = shift_rf_we;
    wire gpr_side_rf_we = saved_side_rf_we | mul_rf_we;
    wire [3:0] rf_waddr = {
        ~gpr_side_rf_we & (take_irq | x_result_system),
        saved_side_rf_we ? side_aux_q[2:0] :
            (x_ddd & {3{~(take_irq | x_cmpi)}})
    };
`endif
    wire [15:0] rf_wdata = x_load_start ? accepted_load_value :
                            execute_result;
`ifdef RISCC_FAST_SYNC_RF
    // A simultaneous EBR read/write may return the old word. Hold the
    // incoming instruction for one repeated read instead of forwarding.
    // rf_waddr already equals the current load/shift destination at a side
    // start, so one dependency comparison serves ordinary writeback and both
    // delayed-result cases.
    wire pending_rf_hazard = accept_fetch &
        ((d_uses_a & (d_src_a == rf_waddr)) |
         (d_uses_b & (d_src_b == rf_waddr)));
    wire incoming_rf_hazard = rf_we & pending_rf_hazard;
    wire shift_successor_hazard = pending_rf_hazard;
    wire load_successor_hazard = x_load_start & pending_rf_hazard;
`endif

    reg [1:0] state_next;
    always @* begin
        state_next = state_q;
        case (state_q)
            ST_RUN: begin
                if (x_shift_start)
                    state_next = ST_SHIFT;
                else if (x_mul_start)
                    state_next = ST_MUL;
            end
            ST_SHIFT: if (shift_finish)
                state_next = ST_RUN;
            ST_MUL: if (mul_finish)
                state_next = ST_RUN;
            default: state_next = ST_RUN;
        endcase
    end

    riscc16_fast_rf regs (
        .clk(clk),
        .raddr_a(rf_raddr_a),
        .rdata_a(rf_a),
        .raddr_b(rf_raddr_b),
        .rdata_b(rf_b),
        .waddr(rf_waddr),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Unified memory and fetch arbitration
    // ------------------------------------------------------------------
    // bus_wait_q keeps a data request selected even if a newly asserted IRQ
    // suppresses normal_x. Fetch requests need only the valid hold below;
    // their address is already the default memory-port selection.
    wire hold_irq_request = bus_wait_q & take_irq;
    wire run_data_port = (normal_x | hold_irq_request) & x_memory;
`ifdef RISCC_FAST_SYNC_RF
`ifdef RISCC_FAST_DSP
    wire rf_wait_cycle = in_run & x_rf_wait_q;
`else
    wire rf_wait_cycle = in_run & x_valid_q & x_rf_wait_q;
`endif
`else
    wire rf_wait_cycle = 1'b0;
`endif
    // Shifts move their younger instruction into X immediately. Soft MUL
    // launches its successor with final result writeback.
    wire issue_fetch =
        mul_finish |
        (in_run & ~rf_wait_cycle & ~x_side_start &
        ~x_redirect & ~take_irq & ~run_data_port) |
        (x_shift_start & ~fetch_pending_q);
    wire fetch_redirect = take_irq | x_redirect;
    wire [14:0] fetch_redirect_pc = take_irq ? 15'd2 :
        x_redirect_pc;
    wire x_refetch_start = x_mul_start;
    // Soft MUL rewinds fetch_pc_q below; the normal no-issue path already
    // clears its pending request, so it needs no separate cancel term.
    wire fetch_cancel = take_irq | x_redirect;
    wire frontend_side_finish = shift_finish;
    wire accept_fetch_raw = fetch_pending_q &
        ((in_run & ~rf_wait_cycle & ~x_redirect & ~take_irq &
          (~x_side_start | x_shift_start | x_load_start)) |
         (frontend_side_finish & ~x_valid_q));
    assign accept_fetch = accept_fetch_raw;
    wire fetch_hold = rf_wait_cycle |
        (in_shift & (~shift_finish | x_valid_q));
    assign mem_addr = run_data_port ? alu_result[15:1] : fetch_pc_q;
    assign mem_we = run_data_port & x_store;
    wire store_byte = x_load_byte;
    wire [15:0] store_value = rf_b;
    wire store_lane = alu_result[0];
    assign mem_wdata = store_byte ? {2{store_value[7:0]}} : store_value;
    assign mem_wmask = (run_data_port & store_byte) ?
                       {store_lane, ~store_lane} : 2'b11;
    assign mem_valid = ~rst &
                       (hold_irq_request | run_data_port | issue_fetch);
    wire memory_stall = mem_valid & ~mem_ready;
    assign core_advance = ~memory_stall;

    always @(posedge clk)
        if (mem_valid & mem_ready)
            mem_response_q <= mem_rdata;

    always @(posedge clk)
        bus_wait_q <= ~core_advance;

    // ------------------------------------------------------------------
    // Sequential pipeline and side states
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (core_advance) begin
            state_q <= state_next;
`ifdef RISCC_TRACE
            trace_rf_we_q <= rf_we;
            trace_rf_addr_q <= rf_waddr;
            trace_rf_data_q <= rf_wdata;
            if (take_irq) begin
                trace_pc_live_q <= 15'd2;
                trace_ie_live_q <= 1'b0;
            end else if (run_commit) begin
                trace_pc_live_q <= x_redirect ? x_redirect_pc : x_pc_q + 15'd1;
                if (x_ie_control | x_return_sets_ie)
                    trace_ie_live_q <= x_control_ie_value;
            end else if (side_commit) begin
                trace_pc_live_q <= side_pc_q + 15'd1;
            end
`endif

            // Architectural interrupt-enable updates commit with their op.
            if (run_commit && (x_ie_control | x_return_sets_ie))
                interrupt_enable_q <= x_control_ie_value;

            // Side datapath updates. The data register holds either the iterative
            // shift value or the soft-MUL accumulator.
`ifdef RISCC_FAST_DSP
            if (in_shift && !shift_finish)
                side_count_q <= side_count_q - 1'b1;
            if (in_shift | x_shift_start)
                side_data_q <= alu_result;
`else
            if (state_q[1]) begin
                side_data_q <= alu_result;
                side_count_q <= side_count_q - 1'b1;
            end else if (side_data_start) begin
                side_data_q <= side_data_input;
            end
`endif

            // Start a side state from X. The younger D instruction is retained.
            if (x_side_start) begin
`ifdef RISCC_TRACE
                side_pc_q <= x_pc_q;
                side_instr_q <= x_trace_instr_q;
`endif
`ifdef RISCC_FAST_DSP
                // DSP side storage serves variable shifts.
                side_aux_q[2:0] <= x_ddd;
                begin
                    side_aux_q[4:3] <= {x_f5[0], x_shift_left};
                    side_count_q <= x_bbb;
`ifdef RISCC_FAST_SYNC_RF
                    side_aux_q[5] <= shift_successor_hazard;
`endif
                end
`else
                if (x_shift_start)
                    side_aux_q[2:0] <= x_ddd;
                if (x_shift_start) begin
                    side_aux_q[4:3] <= {x_f5[0], x_shift_left};
`ifdef RISCC_FAST_SYNC_RF
                    side_aux_q[5] <= shift_successor_hazard;
`endif
                    side_count_q <= {1'b0, x_bbb};
                end else if (x_mul_start) begin
                    side_count_q <= 4'd14;
                end
`endif
            end

`ifdef RISCC_FAST_SYNC_RF
            if (accept_fetch) begin
                x_raddr_a_q <= d_src_a;
                x_raddr_b_q <= d_src_b[2:0];
            end
`endif

            // X completes directly while the previous acknowledged fetch response
            // replaces it. The synchronous-RF build holds X for a repeated read
            // when that edge also writes one of its source addresses.
            if (in_run) begin
`ifdef RISCC_FAST_SYNC_RF
                if (rf_wait_cycle) begin
                    x_rf_wait_q <= 1'b0;
                end else begin
`endif
                x_valid_q <= (~take_irq & x_long_wait) | accept_fetch;
                if (accept_fetch) begin
                    x_pc_q <= fetch_pending_pc_q;
                    x_instr_q <= mem_response_q;
                end
`ifdef RISCC_FAST_SYNC_RF
                x_rf_wait_q <= incoming_rf_hazard | load_successor_hazard;
                end
`endif
            end else if (frontend_side_finish) begin
                if (accept_fetch) begin
                    x_valid_q <= 1'b1;
                    x_pc_q <= fetch_pending_pc_q;
                    x_instr_q <= mem_response_q;
                end
`ifdef RISCC_FAST_SYNC_RF
                x_rf_wait_q <= x_valid_q ? side_aux_q[5] : incoming_rf_hazard;
`endif
            end

            // RAW stalls and iterative shifts repeat the younger instruction read
            // in place. Advance to its successor just before it can enter X.
            if (fetch_redirect)
                fetch_pc_q <= fetch_redirect_pc;
            else if (x_refetch_start && fetch_pending_q)
                fetch_pc_q <= fetch_pending_pc_q;
`ifdef RISCC_FAST_SYNC_RF
            else if (rf_wait_cycle && fetch_pending_q)
                fetch_pc_q <= fetch_pc_q + 1'b1;
`endif
            else if (frontend_side_finish && ~x_valid_q)
                fetch_pc_q <= fetch_pc_q + 1'b1;
`ifdef RISCC_FAST_SYNC_RF
            else if (issue_fetch && ~x_shift_start &&
                     ~incoming_rf_hazard)
`else
            else if (issue_fetch && ~x_shift_start)
`endif
                fetch_pc_q <= fetch_pc_q + 1'b1;

            if (fetch_cancel) begin
                fetch_pending_q <= 1'b0;
            end else if (!fetch_hold) begin
                fetch_pending_q <= issue_fetch;
                if (issue_fetch)
                    fetch_pending_pc_q <= fetch_pc_q;
            end

            if (take_irq)
                interrupt_enable_q <= 1'b0;

`ifdef RISCC_TRACE
            // Execute may normalize compact encodings internally; traces retain
            // the architectural instruction word accepted from memory.
            if (accept_fetch)
                x_trace_instr_q <= mem_response_q;
`endif

            if (rst) begin
                state_q <= ST_RUN;
                interrupt_enable_q <= 1'b0;
                fetch_pc_q <= RESET_PC[14:0];
                fetch_pending_q <= 1'b0;
                x_valid_q <= 1'b0;
`ifdef RISCC_FAST_SYNC_RF
                x_rf_wait_q <= 1'b0;
`endif
`ifdef RISCC_TRACE
                trace_pc_live_q <= RESET_PC[14:0];
                trace_ie_live_q <= 1'b0;
                trace_rf_we_q <= 1'b0;
`endif
            end
        end
    end

    // ------------------------------------------------------------------
    // Trace interface
    // ------------------------------------------------------------------
`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = 16;
    wire [15:0] commit_instr = take_irq ? irq_instr :
        run_commit ? x_trace_instr_q : side_instr_q;
    // A stalled request holds the Execute stage in place. Do not let the
    // trace shadow observe that held instruction as an architectural commit.
    wire tr_commit_i = commit_valid & core_advance;
    wire [14:0] tr_pc_i = trace_pc_live_q;
    wire [15:0] tr_ir_i = commit_instr;
    wire tr_ie_i = trace_ie_live_q;
    wire tr_rf_we_i = trace_rf_we_q;
    wire tr_rf_bank_i = trace_rf_addr_q[3];
    wire [2:0] tr_rf_reg_i = trace_rf_addr_q[2:0];
    wire [3:0] tr_rf_lsb_i = 4'h0;
    wire [15:0] tr_rf_data_i = trace_rf_data_q;
`include "riscc_trace_state.vh"
`endif

endmodule

// ECP5 can use two distributed-RAM replicas for asynchronous reads or two
// synchronous EBR replicas, one read port each, with broadcast writes.
module riscc16_fast_rf (
    input  wire        clk,
    input  wire [3:0]  raddr_a,
    output wire [15:0] rdata_a,
    input  wire [3:0]  raddr_b,
    output wire [15:0] rdata_b,
    input  wire [3:0]  waddr,
    input  wire [15:0] wdata,
    input  wire        we
);
`ifdef RISCC_FAST_SYNC_RF
    (* ram_style = "block" *) reg [15:0] mem_a [0:15];
    (* ram_style = "block" *) reg [15:0] mem_b [0:15];
    reg [15:0] rdata_a_q;
    reg [15:0] rdata_b_q;

    assign rdata_a = rdata_a_q;
    assign rdata_b = rdata_b_q;

    always @(posedge clk) begin
        rdata_a_q <= mem_a[raddr_a];
        rdata_b_q <= mem_b[raddr_b];
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`elsif RISCC_ECP5
    (* ram_style = "distributed" *) reg [15:0] mem_a [0:15];
    (* ram_style = "distributed" *) reg [15:0] mem_b [0:15];

    assign rdata_a = mem_a[raddr_a];
    assign rdata_b = mem_b[raddr_b];

    always @(posedge clk) begin
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end
`else
    // Keep the storage as an ordinary asynchronous-read MLAB and provide
    // Fast's write-first architectural view with a registered last-write
    // overlay. Crucially, `we` itself is not in the read mux: the executing
    // instruction must still see the old operand before its write edge.
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] mem [0:15];
    reg        last_we_q;
    reg [3:0]  last_waddr_q;
    reg [15:0] last_wdata_q;
    wire [15:0] mem_rdata_a = mem[raddr_a];
    wire [15:0] mem_rdata_b = mem[raddr_b];

    assign rdata_a = last_we_q && last_waddr_q == raddr_a ?
                     last_wdata_q : mem_rdata_a;
    assign rdata_b = last_we_q && last_waddr_q == raddr_b ?
                     last_wdata_q : mem_rdata_b;

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        last_we_q <= we;
        last_waddr_q <= waddr;
        last_wdata_q <= wdata;
    end
`endif
endmodule

`default_nettype wire
