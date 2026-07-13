// riscc_fast.v : compact full-profile pipelined RISC-C core.
//
// Fetch and execute overlap. ECP5 uses an asynchronous two-read LUTRAM RF;
// iCE40 uses two synchronous EBR copies and stalls on a preceding-result RAW.
// Results write directly from execute without a forwarding network.
// Memory, shifts, and soft MUL use small side states; JAL16 consumes the
// sequential target word already present in the fetch-response slot.

`default_nettype none

module riscc_fast #(
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
`ifdef RISCC_TRACE
    ,
`include "riscc_trace_ports.vh"
`endif
);

    // Area-tuned quadrant encoding. RUN is the pipelined steady state; the
    // soft build also uses the raw state bits in its side-result mux.
    localparam [1:0] ST_RUN   = 2'd1;
    localparam [1:0] ST_LOAD  = 2'd0;
    localparam [1:0] ST_SHIFT = 2'd3;
    localparam [1:0] ST_MUL   = 2'd2;
    reg [1:0] state_q;
`ifdef RISCC_FAST_DSP
    wire in_run   = state_q == ST_RUN;
    wire in_load  = state_q == ST_LOAD;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;
`else
    wire in_run   = ~state_q[1] &  state_q[0];
    wire in_load  = ~state_q[1] & ~state_q[0];
    wire in_shift =  state_q[1] &  state_q[0];
    wire in_mul   =  state_q[1] & ~state_q[0];
`endif

    reg interrupt_enable_q;

    // One tagged synchronous fetch request feeds X directly.
    reg [14:0] fetch_pc_q;
    reg        fetch_pending_q;
    reg [14:0] fetch_pending_pc_q;
    // Execute carries only the architectural instruction and its PC.
    reg        x_valid_q;
    reg [14:0] x_pc_q;
    reg [15:0] x_instr_q;
`ifdef RISCC_FAST_SYNC_RF
    reg        x_rf_wait_q;
`endif

    // Side-state storage.  Lifetimes do not overlap between operations.
    reg [15:0] side_data_q;
    reg [5:0]  side_aux_q;
`ifdef RISCC_FAST_DSP
    reg [2:0]  side_count_q;
`else
    reg [3:0]  side_count_q;
`endif
`ifdef RISCC_TRACE
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
    wire [1:0] x_class = x_instr_q[15:14];
    wire [2:0] x_ddd = x_instr_q[13:11];
    wire [2:0] x_aaa = x_instr_q[10:8];
    wire [4:0] x_f5 = x_instr_q[7:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

    wire x_imm_memory = ~x_class[1];
    wire x_imm_store = x_imm_memory & x_class[0];
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
    wire x_reg_alu = x_reg_alu_group & ~x_multiply;
    wire x_shift_right = x_reg_mem & x_f5[2] & ~x_f5[1];
    wire x_shift = x_shift_right | x_shift_left;
    wire x_indexed_memory = x_reg_mem & ~x_f5[0] &
                            (~x_f5[2] | x_f5[1]);
`ifndef RISCC_FAST_SYNC_RF
    // The asynchronous-RF mapper prefers the complete register-memory truth
    // set factored once: LDWX, LDB, STB, and LDBS.
    wire x_reg_memory = x_reg_mem &
        ((~x_f5[2] & (~x_f5[0] | x_f5[1])) |
         (x_f5[1] & ~x_f5[0]));
`endif
`ifdef RISCC_FAST_SYNC_RF
    wire x_memory = x_imm_memory | x_indexed_memory | x_reg_store;
`else
    wire x_memory = x_imm_memory | x_reg_memory;
`endif
    wire x_store = x_imm_store | x_reg_store;
    // Byte controls are observed only while a decoded memory operation is
    // active. Each RF/multiplier mapping uses the form that packs best there.
`ifdef RISCC_FAST_SYNC_RF
    wire x_load_byte = x_reg_store |
                       (x_indexed_memory & x_f5[1]);
`else
    wire x_load_byte = x_reg_memory & x_f5[1];
`endif
`ifdef RISCC_FAST_DSP
    wire x_signed_byte = x_f5[2];
`else
    wire x_signed_byte = x_indexed_memory & x_f5[2];
`endif
    // RET/RETI share bbb=000 and CLI/STI share bbb=110.  Defined controls
    // duplicate the new IE value in every ddd bit, allowing each characterized
    // FPGA mapping to use the better-packed copy.
`ifdef RISCC_FAST_AGILEX
    wire x_control_ie_value = x_ddd[0];
`elsif RISCC_FAST_DSP
`ifdef RISCC_ECP5
    wire x_control_ie_value = x_ddd[0];
`else
    wire x_control_ie_value = x_ddd[1];
`endif
`else
    wire x_control_ie_value = x_ddd[1];
`endif
    wire x_return = x_system & ~x_bbb[1] & ~x_bbb[0];
    wire x_return_sets_ie = x_return & x_control_ie_value;
    wire x_link_jump = x_system & ~x_bbb[1] & x_bbb[0];
    wire x_jal = x_link_jump & ~x_bbb[2];
    wire x_move = x_system & ~x_bbb[2] & x_bbb[1];
    wire x_jal16 = x_link_jump & x_bbb[2];
    wire x_ie_control = x_system & x_bbb[2] & x_bbb[1];

    wire [3:0] x_src_a = x_branch ? 4'h0 :
        x_system ? {~x_bbb[0], x_aaa} :
        x_immediate ? {1'b0, x_ddd} : {1'b0, x_aaa};
    // Only stores consume ddd on the B read port. Broaden the register-store
    // decode into otherwise don't-care shift/system encodings to keep this
    // address mux off the full memory/store decode cone.
    wire x_src_b_is_ddd = x_class[0] &
                          (~x_class[1] | (x_f5[3] & x_f5[0]));
    wire [3:0] x_src_b = {1'b0, x_src_b_is_ddd ? x_ddd : x_bbb};
    wire accept_fetch;
    wire [1:0] d_class = mem_rdata[15:14];
    wire [2:0] d_ddd = mem_rdata[13:11];
    wire [2:0] d_aaa = mem_rdata[10:8];
    wire [4:0] d_f5 = mem_rdata[7:3];
    wire [2:0] d_bbb = mem_rdata[2:0];
    wire d_imm_store = ~d_class[1] & d_class[0];
    wire d_immediate = d_class[1] & ~d_class[0];
    wire d_register = &d_class;
    wire d_reg_alu_group = d_register & (d_f5[4:3] == 2'b00);
    wire d_reg_mem = d_register & (d_f5[4:3] == 2'b01);
    wire d_high_group = d_register & d_f5[4] & d_f5[3];
    wire d_reg_store = d_reg_mem & ~d_f5[2] & d_f5[1] & d_f5[0];
    wire d_system = d_high_group;
    wire d_branch = d_immediate & (d_aaa == 3'b111);
    wire d_uses_a = ~d_class[1] | d_register |
        (d_immediate & (d_aaa[1] | d_aaa[2]));
    wire d_indexed_memory = d_reg_mem & ~d_f5[0] &
                            (~d_f5[2] | d_f5[1]);
    wire d_uses_b = d_imm_store | d_reg_store | d_reg_alu_group |
                    d_indexed_memory;
    wire [3:0] d_src_a = d_branch ? 4'h0 :
        d_system ? {~d_bbb[0], d_aaa} :
        d_immediate ? {1'b0, d_ddd} : {1'b0, d_aaa};
    wire d_src_b_is_ddd = d_class[0] &
                          (~d_class[1] | (d_f5[3] & d_f5[0]));
    wire [3:0] d_src_b = {1'b0, d_src_b_is_ddd ? d_ddd : d_bbb};
    wire [3:0] rf_raddr_a;
    wire [3:0] rf_raddr_b;
    wire [15:0] rf_a;
    wire [15:0] rf_b;

`ifdef RISCC_FAST_SYNC_RF
    assign rf_raddr_a = accept_fetch ? d_src_a : x_src_a;
    assign rf_raddr_b = accept_fetch ? d_src_b : x_src_b;
`else
    assign rf_raddr_a = x_src_a;
    assign rf_raddr_b = x_src_b;
`endif

    wire [15:0] x_imm_z = {8'h00, x_instr_q[7:0]};
    wire [15:0] x_imm_s = {{8{x_instr_q[7]}}, x_instr_q[7:0]};
    wire [15:0] x_imm_u = {x_instr_q[7:0], 8'h00};

    wire [1:0] x_logic_op = x_imm_alu ? x_aaa[1:0] : x_f5[1:0];
    wire [15:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [15:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) : (rf_a & x_logic_rhs)) :
        (rf_a ^ x_logic_rhs);

    // A load reuses count[0] for its captured byte lane.  side_aux_q holds
    // {signed, byte, destination} while X retains the younger instruction.
    wire load_high_lane = side_count_q[0];
    wire saved_load_byte = side_aux_q[3];
    wire saved_load_signed = side_aux_q[4];
    wire [7:0] load_low_byte = (saved_load_byte & load_high_lane) ?
        mem_rdata[15:8] : mem_rdata[7:0];
    wire load_byte_sign = load_high_lane ? mem_rdata[15] : mem_rdata[7];
    wire [7:0] load_high_byte = saved_load_byte ?
        {8{saved_load_signed & load_byte_sign}} : mem_rdata[15:8];
    wire [15:0] load_value = {load_high_byte, load_low_byte};

    wire [15:0] x_shift_step = x_shift_left ?
        {rf_a[14:0], 1'b0} :
        {x_shift_right & x_f5[0] & rf_a[15], rf_a[15:1]};
    wire saved_shift_left = side_aux_q[3];
    wire saved_shift_arithmetic = side_aux_q[4];
    wire [15:0] shift_step = saved_shift_left ?
        {side_data_q[14:0], 1'b0} :
        {saved_shift_arithmetic & side_data_q[15], side_data_q[15:1]};
    wire shift_finish = in_shift & (side_count_q[2:0] == 3'd1);

`ifdef RISCC_FAST_DSP
    // RISC-C exposes only the low product word.  Express that width directly
    // so the DSP mapper need not preserve a routed high-half result bus.
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
         x_imm_arithmetic | x_reg_arithmetic | x_memory));
`ifdef RISCC_FAST_DSP
    wire [15:0] alu_a = alu_a_is_pc ?
        {1'b0, x_pc_q} :
        alu_a_is_rf ? rf_a : 16'h0000;
`else
    wire [15:0] alu_a = alu_a_is_pc ? {1'b0, x_pc_q} :
        alu_a_is_rf ? rf_a : 16'h0000;
    // Consume the saved RF multiplier MSB first. This Horner-form multiply,
    // acc = (acc << 1) + (bit ? multiplicand : 0), needs only one 16-bit
    // side register; the low product is complete after the sixteenth step.
`endif

    // This arm is selected only for LDI/LDIH; arithmetic and logic immediates
    // have already been classified above it.
    wire [15:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
    wire run_imm_s = x_branch | x_imm_memory |
                     (x_imm_alu & ~x_aaa[2] & x_aaa[1]);
    wire run_logic = (x_imm_alu & x_aaa[2]) |
                     (x_reg_alu & x_f5[2]);
    wire run_rf_b = x_reg_arithmetic | x_indexed_memory;
    wire run_short_imm = x_imm_alu & ~x_aaa[2] & ~x_aaa[1];
    wire [15:0] run_result = run_logic ? x_logic_result :
        run_imm_s ? x_imm_s :
        run_rf_b ? rf_b :
        run_short_imm ? immediate_result :
        x_move ? rf_a :
        x_shift ? x_shift_step :
        x_jal16 ? 16'h0001 : 16'h0000;
`ifdef RISCC_FAST_DSP
    wire [15:0] alu_b = in_shift ? shift_step :
        in_load ? load_value :
        normal_x ? run_result : 16'h0000;
`else
    wire [15:0] alu_b = normal_x ? run_result :
        state_q[1] ?
            (state_q[0] ? shift_step : {side_data_q[14:0], 1'b0}) :
        ~state_q[0] ? load_value : 16'h0000;
`endif
    wire alu_subtract = normal_x &
        ((x_imm_arithmetic & x_aaa[0]) |
         (x_reg_arithmetic & (|x_f5[1:0])));
    wire alu_carry_in = alu_subtract |
        (normal_x & (x_branch | x_link_jump));

    wire [15:0] adjusted_alu_b = alu_b ^ {16{alu_subtract}};
`ifdef RISCC_FAST_DSP
    wire [15:0] alu_result = alu_a + adjusted_alu_b +
                             {15'h0000, alu_carry_in};
    wire alu_carry_out = (alu_a[15] & adjusted_alu_b[15]) |
        ((alu_a[15] ^ adjusted_alu_b[15]) & ~alu_result[15]);
`else
    wire [16:0] alu_sum = {1'b0, alu_a} + {1'b0, adjusted_alu_b} +
                          {{16{1'b0}}, alu_carry_in};
    wire [15:0] alu_result = alu_sum[15:0];
    wire alu_carry_out = alu_sum[16];
`endif
    wire alu_overflow = (alu_a[15] ^ alu_b[15]) &
                        (alu_result[15] ^ alu_a[15]);
    wire signed_less = alu_result[15] ^ alu_overflow;
    wire unsigned_less = ~alu_carry_out;
    wire x_compare = x_reg_alu_group & ~x_f5[2] & x_f5[1];
    wire [15:0] execute_result =
`ifdef RISCC_FAST_DSP
        (normal_x && x_multiply) ? direct_mul_result :
`endif
        (normal_x && x_compare) ?
        {15'h0000, x_f5[0] ? unsigned_less : signed_less} : alu_result;

    wire x_r0_zero = ~|rf_a;
    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? rf_a[15] : x_r0_zero) ^ x_ddd[0]);
`ifdef RISCC_FAST_SYNC_RF
    wire x_jal16_wait = normal_x & x_jal16 & ~fetch_pending_q;
    wire x_jal16_execute = x_jal16 & fetch_pending_q;
    wire x_redirect = normal_x &
        ((x_branch & x_branch_taken) | x_jal | x_return | x_jal16_execute);
`else
    wire x_jal16_wait = run_x & x_jal16 & ~fetch_pending_q;
    wire x_jal16_execute = run_x & x_jal16 & fetch_pending_q;
    wire x_redirect = run_x &
        ((x_branch & x_branch_taken) | x_jal | x_return | x_jal16_execute);
`endif
    wire [14:0] x_redirect_pc = x_jal16 ? mem_rdata[14:0] :
        x_branch ? alu_result[14:0] : rf_a[14:0];

    // ------------------------------------------------------------------
    // Commit, hazards, and RF writeback
    // ------------------------------------------------------------------
    wire x_result_we = x_imm_alu | x_shift |
`ifdef RISCC_FAST_DSP
        x_reg_alu | x_multiply |
`else
        x_reg_alu |
`endif
        x_move | (x_link_jump & (|x_ddd));
    // All defined S-bank writes have bbb[0]=1; control-group forms have no
    // result write, so this broad bank select remains unobservable there.
    wire x_result_system = x_system & x_bbb[0];
    wire x_cmpi = x_imm_alu & (x_aaa == 3'b011);

    // Interrupt at the next populated X boundary.  Waiting for an outstanding
    // fetch response avoids a second EPC/instruction selection path.
    wire [14:0] irq_epc = x_pc_q;
    wire [15:0] irq_instr = x_instr_q;

    wire x_load_start = normal_x & x_memory & ~x_store;
    // The first bit shifts directly in X.  A count-one shift therefore
    // completes like an ALU op; only the remaining bits use ST_SHIFT.
    wire x_multi_shift = x_shift & (|x_bbb);
    wire x_shift_start = normal_x & x_multi_shift;
`ifdef RISCC_FAST_DSP
    wire x_mul_start = 1'b0;
`else
    wire x_mul_start = normal_x & x_multiply;
`endif
    wire x_side_start = x_load_start | x_shift_start | x_mul_start;
`ifndef RISCC_FAST_DSP
    wire side_data_start = x_shift_start | x_mul_start;
    // Soft MUL consumes bit 15 in X, seeding the Horner accumulator before
    // the side state continues with bit 14.
    wire [15:0] side_data_input = alu_result;
`endif
    wire run_commit = normal_x & ~x_side_start &
                      ~x_jal16_wait;
    wire side_commit = in_load | shift_finish | mul_finish;
    wire commit_valid = take_irq | run_commit | side_commit;

    wire run_rf_we = run_commit & x_result_we;
    wire load_rf_we = in_load;
    wire shift_rf_we = shift_finish;
    wire mul_rf_we = mul_finish;
    wire rf_we = take_irq | load_rf_we |
                 shift_rf_we | mul_rf_we | run_rf_we;
`ifdef RISCC_FAST_DSP
    wire side_rf_we = load_rf_we | shift_rf_we;
    wire [3:0] rf_waddr = {
        ~side_rf_we & (take_irq | x_result_system),
        side_rf_we ? side_aux_q[2:0] :
            (x_ddd & {3{~(take_irq | x_cmpi)}})
    };
`else
    wire saved_side_rf_we = load_rf_we | shift_rf_we;
    wire gpr_side_rf_we = saved_side_rf_we | mul_rf_we;
    wire [3:0] rf_waddr = {
        ~gpr_side_rf_we & (take_irq | x_result_system),
        saved_side_rf_we ? side_aux_q[2:0] :
            (x_ddd & {3{~(take_irq | x_cmpi)}})
    };
`endif
    wire [15:0] rf_wdata = execute_result;
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
                if (x_load_start)
                    state_next = ST_LOAD;
                else if (x_shift_start)
                    state_next = ST_SHIFT;
                else if (x_mul_start)
                    state_next = ST_MUL;
            end
            ST_LOAD:
                state_next = ST_RUN;
            ST_SHIFT: if (shift_finish)
                state_next = ST_RUN;
            ST_MUL: if (mul_finish)
                state_next = ST_RUN;
            default: state_next = ST_RUN;
        endcase
    end

    riscc_fast_rf regs (
        .clk(clk),
        .raddr_a(rf_raddr_a), .rdata_a(rf_a),
        .raddr_b(rf_raddr_b), .rdata_b(rf_b),
        .waddr(rf_waddr), .wdata(rf_wdata), .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Unified memory and fetch arbitration
    // ------------------------------------------------------------------
    wire run_data_port = normal_x & x_memory;
`ifdef RISCC_FAST_SYNC_RF
`ifdef RISCC_FAST_DSP
    wire rf_wait_cycle = in_run & x_rf_wait_q;
`else
    wire rf_wait_cycle = in_run & x_valid_q & x_rf_wait_q;
`endif
`else
    wire rf_wait_cycle = 1'b0;
`endif
    // Shifts move their younger instruction into X immediately.  A load uses
    // its response cycle to launch the fetch following the held successor.
    // Soft MUL launches its successor with final result writeback.
    wire issue_fetch = in_load | mul_finish |
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
    assign accept_fetch = fetch_pending_q &
        ((in_run & ~rf_wait_cycle & ~x_redirect & ~take_irq &
          (~x_side_start | x_shift_start | x_load_start)) |
         (frontend_side_finish & ~x_valid_q));
    wire fetch_hold = rf_wait_cycle |
        (in_shift & (~shift_finish | x_valid_q));

    assign mem_addr = run_data_port ? alu_result[15:1] : fetch_pc_q;
    assign mem_we = run_data_port & x_store;
    wire store_byte = x_load_byte;
    wire [15:0] store_value = rf_b;
    wire store_lane = alu_result[0];
    assign mem_wdata = store_byte ? {2{store_value[7:0]}} : store_value;
    assign mem_wmask = store_byte ? {store_lane, ~store_lane} : 2'b11;

    // ------------------------------------------------------------------
    // Sequential pipeline and side states
    // ------------------------------------------------------------------
    always @(posedge clk) begin
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

        // Start a side state from X.  The younger D instruction is retained,
        // except for JAL16 which is an unconditional redirect.
        if (x_side_start) begin
`ifdef RISCC_TRACE
            side_pc_q <= x_pc_q;
            side_instr_q <= x_instr_q;
`endif
`ifdef RISCC_FAST_DSP
            // DSP builds have only load and shift side states. Destination
            // bits are common; mux only the two operation-specific bits.
            side_aux_q[2:0] <= x_ddd;
            if (x_load_start) begin
                side_aux_q[4:3] <= {x_signed_byte, x_load_byte};
                side_count_q <= {2'b00, alu_result[0]};
            end else begin
                side_aux_q[4:3] <= {x_f5[0], x_shift_left};
                side_count_q <= x_bbb;
`ifdef RISCC_FAST_SYNC_RF
                side_aux_q[5] <= shift_successor_hazard;
`endif
            end
`else
            if (x_load_start | x_shift_start)
                side_aux_q[2:0] <= x_ddd;
            if (x_load_start) begin
                side_aux_q[4:3] <= {x_signed_byte, x_load_byte};
                side_count_q <= {3'b000, alu_result[0]};
            end else if (x_shift_start) begin
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

        // X completes directly while the previous synchronous fetch response
        // replaces it. The synchronous-RF build holds X for a repeated read
        // when that edge also writes one of its source addresses.
        if (in_run) begin
`ifdef RISCC_FAST_SYNC_RF
            if (rf_wait_cycle) begin
                x_rf_wait_q <= 1'b0;
            end else begin
`endif
            x_valid_q <= (~take_irq & x_jal16_wait) | accept_fetch;
            if (accept_fetch) begin
                x_pc_q <= fetch_pending_pc_q;
                x_instr_q <= mem_rdata;
            end
`ifdef RISCC_FAST_SYNC_RF
            x_rf_wait_q <= incoming_rf_hazard | load_successor_hazard;
            end
`endif
        end else if (frontend_side_finish) begin
            if (accept_fetch) begin
                x_valid_q <= 1'b1;
                x_pc_q <= fetch_pending_pc_q;
                x_instr_q <= mem_rdata;
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
                 ~incoming_rf_hazard && ~(in_load && x_rf_wait_q))
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

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = 16;
    wire [15:0] commit_instr = take_irq ? irq_instr :
        run_commit ? x_instr_q : side_instr_q;
    wire tr_commit_i = commit_valid;
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

// ECP5 uses two distributed-RAM replicas for asynchronous reads. iCE40 uses
// two synchronous EBR replicas, one read port each, with broadcast writes.
module riscc_fast_rf (
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
`ifdef SYNTHESIS
    wire [10:0] raddr_a_phys = {7'b0000000, raddr_a};
    wire [10:0] raddr_b_phys = {7'b0000000, raddr_b};
    wire [10:0] waddr_phys = {7'b0000000, waddr};

    SB_RAM40_4K #(.READ_MODE(0), .WRITE_MODE(0)) ram_a (
        .RDATA(rdata_a), .RADDR(raddr_a_phys),
        .RCLK(clk), .RCLKE(1'b1), .RE(1'b1),
        .WADDR(waddr_phys), .WCLK(clk), .WCLKE(1'b1), .WE(we),
        .MASK(16'h0000), .WDATA(wdata)
    );
    SB_RAM40_4K #(.READ_MODE(0), .WRITE_MODE(0)) ram_b (
        .RDATA(rdata_b), .RADDR(raddr_b_phys),
        .RCLK(clk), .RCLKE(1'b1), .RE(1'b1),
        .WADDR(waddr_phys), .WCLK(clk), .WCLKE(1'b1), .WE(we),
        .MASK(16'h0000), .WDATA(wdata)
    );
`else
    reg [15:0] mem_a [0:15];
    reg [15:0] mem_b [0:15];
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
`endif
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
    // overlay.  Crucially, `we` itself is not in the read mux: the executing
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
