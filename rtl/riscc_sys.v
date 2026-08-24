// riscc_sys.v : area-oriented serial RC16 Sys core (W=1, 2, 4, or 8).
//
// Serial microarchitecture: doc/HARDWARE.md 'Implementation family' (branch
// shadow, one PC adder, address/data streams, and the INIT2 staging lap).
// W must be 1, 2, 4, or 8; Min uses riscc_min.v.

`ifndef RISCC_RC16_SYS_V
`define RISCC_RC16_SYS_V
`default_nettype none

// Sys adds interrupt/IE control and the two-halfword JALL/JMPL form to Min.

module riscc #(
    parameter integer W = 4,
    parameter [15:0] RESET_PC = 16'h0000  // byte address
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

    localparam integer SLICES = 16 / W;
    localparam integer SLICE_BITS = $clog2(SLICES);
    localparam integer W_LOG2 = $clog2(W);
    localparam integer RF_ADDR_WIDTH = 4 + SLICE_BITS;

    // ------------------------------------------------------------------
    // State and serial-slice counter
    // ------------------------------------------------------------------
    // Bit 2 enables every counted state; request and decode states keep it
    // clear. One encoding is used for every width and target.
    localparam [2:0] ST_FETCH_WAIT    = 3'd1;
    localparam [2:0] ST_DECODE        = 3'd3;
    localparam [2:0] ST_MEM_WAIT      = 3'd0;
    localparam [2:0] ST_EXECUTE       = 3'd4;
    localparam [2:0] ST_MEM_XFER      = 3'd7;
    localparam [2:0] ST_INIT          = 3'd5;
    localparam [2:0] ST_INIT2         = 3'd6;

    reg  [2:0] state_q;
    reg  [SLICE_BITS-1:0] slice_idx_q;

    wire in_fetch_wait    = (state_q == ST_FETCH_WAIT);
    wire in_decode        = (state_q == ST_DECODE);
    wire in_mem_wait      = (state_q == ST_MEM_WAIT);
    wire in_mem_xfer      = (state_q == ST_MEM_XFER);
    wire in_init          = (state_q == ST_INIT);
    wire in_init2         = (state_q == ST_INIT2);
    wire in_execute       = (state_q == ST_EXECUTE);

    // MEM_XFER, INIT, INIT2, and EXECUTE are counted states.
    wire slice_count_en = state_q[2];
    wire [SLICE_BITS:0] slice_idx_sum =
        {1'b0, slice_idx_q} + {{SLICE_BITS{1'b0}}, 1'b1};
    wire [SLICE_BITS-1:0] slice_idx_next = slice_idx_sum[SLICE_BITS-1:0];
    wire last_slice = slice_idx_sum[SLICE_BITS];
    wire first_slice = ~|slice_idx_q;

    // ------------------------------------------------------------------
    // Instruction fields and decode
    // ------------------------------------------------------------------
    reg [15:0] instr_q;

    // System-profile state.
    reg ie_q;
    reg trap_q;
    reg jall_target_phase_q;
    wire take_irq = ie_q & irq;
    wire trap_active = trap_q;

    // Shared serial streams and their small pieces of side state.
    reg [15:0] address_stream_q;
    reg [15:0] data_stream_q;
    reg [15:0] mem_response_q;
    reg load_fill_q;
    reg memory_lane_q;
    reg funnel_bit_q;

    wire [1:0] op_class = instr_q[15:14];
    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field.
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group = ~op_class[1] & op_class[0];
    wire immediate_group = op_class[1] & ~op_class[0];
    wire register_group = op_class[1] & op_class[0];

    wire branch_group = immediate_group & (aaa == 3'b111) & ~trap_active;
    // A preempted branch is still not an ALU operation: trap writeback and
    // the IRQ PC path override its normal result. At W=1, immediate decode
    // therefore does not need trap_active in the branch term.
    wire immediate_alu_op = immediate_group &
        ((W == 1) ? ~(&aaa) : ~branch_group);
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    // Branches share aaa[1:0] with CMPI, but never consume the ALU result.
    wire cmpi_op = immediate_group & aaa[1] & aaa[0];
    // Loose JMP8: reserved ccc=101/110/111 alias as JMP8.
    wire jmp8_op = branch_group & ddd[2];
    // JALL uses the 00 major space; other long heads share its datapath.
    wire long_form_op = ~op_class[1] & ~op_class[0];
    wire jall_target_phase = jall_target_phase_q;
    wire link_dest_nonzero = |ddd;   // Sd == S0 writes no link (plain jump)

    wire f_group_01 = ~f5[4] &  f5[3];
    wire f_group_11 = f5[4] & f5[3];
    wire system_op = register_group & f_group_11;

    // FSL1/FSR1 share the broad group-10 execution plane; bbb[0] selects
    // direction. Reserved group-10 encodings and sub-operations may alias.
    wire register_execute_plane = register_group & ~f5[3];
    wire ordinary_alu_op = register_execute_plane & ~f5[4];
    wire funnel_op = register_execute_plane & f5[4];
    wire funnel_right_op = funnel_op & bbb[0];

    wire slt_op = ordinary_alu_op & ~f5[2] & f5[1];
    wire signed_compare = ~instr_q[3];
    // Sys retains Min's single-step SRLI/SRAI. Larger right shifts compose
    // those steps; SLLI is deliberately absent.
    wire right_shift_op =
        register_group & f_group_01 & f5[2] & ~f5[1];
    wire arithmetic_shift = f5[0];
    wire shift_writeback_op = right_shift_op | funnel_right_op;

    // Native LDX uses 01_000. LDB, LDBS, and STB use 01_010, 01_110,
    // and 01_011 respectively.
    wire register_memory_plane = register_group & f_group_01;
    wire register_store_op = register_memory_plane & ~f5[2] &
                             f5[1] & f5[0];
    wire native_load_op = register_memory_plane & ~f5[2] & ~f5[1];
    wire direct_load_op = register_memory_plane & f5[1] & ~f5[0];
    wire indexed_mem_op = native_load_op | direct_load_op;

    // All controls share bbb=000. ddd[1] selects return versus direct IE
    // control; ddd[2] and ddd[0] duplicate the new/set IE value. Thus
    // 000/101 are RET/RETI and 010/111 are CLI/STI.
    wire control_ie_value = ddd[2];
    wire control_plane = system_op & ~bbb[1];
    wire control_ie_next = bbb[0] ? ie_q :
                           (control_ie_value | (~ddd[1] & ie_q));
    // The register-target plane shares one mux-shaped decode between packed
    // returns and register jumps.
    wire register_jal_op = system_op & ~bbb[1] & bbb[0];
    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = register_jal_op | jall_target_phase;
    wire register_target_op = system_op & ~bbb[1] &
                              (bbb[0] | ~ddd[1]);
    wire register_link_data_op = register_target_op;
    wire ie_write_op = control_plane & ~bbb[0];
    wire ie_next = control_ie_next;

    wire store_op = (imm_mem_group & instr_q[0]) | register_store_op;
    wire load_op = (imm_mem_group & ~instr_q[0]) | indexed_mem_op;
    wire load_writeback_op = load_op;
    wire mem_op = store_op | load_op;
    wire byte_access = register_memory_plane & f5[1] & ~bbb[0];
    wire sign_extend_byte = f5[2];
    // Register ALU operations stage bbb; funnels use the same operand pass but
    // select aaa.
    wire alu_uses_rb_stream = register_execute_plane | native_load_op;
    wire needs_rb_pass = alu_uses_rb_stream;
    wire needs_operand_pass =
        needs_rb_pass | (register_memory_plane & ~byte_access);
    wire needs_init_pass = mem_op | slt_op | funnel_op;

    // ------------------------------------------------------------------
    // Register file: 16 regs x 16 bits in one synchronous RAM (one EBR),
    // addressed {reg, slice}, read one W-bit slice ahead of use.
    //
    // Read schedule (one stream at a time):
    //   INIT2 first lap : bbb/aaa -> data_stream_q    (two-source operations)
    //   INIT            : aaa -> ALU                  (B is the staged operand)
    //   store-data lap  : rd  -> data_stream_q        (MEM_XFER)
    //   EXECUTE         : rs1 -> ALU / pc_q   (single-stage ops)
    // ------------------------------------------------------------------
    wire store_data_mem_pass = in_mem_xfer & store_op;
    wire memory_stream_pass = in_mem_xfer & ~store_op;
    // bbb[0] is the bank-select bit: 0 reads S[aaa], 1 writes S[ddd]
    // (links share MTS's write path; CLI/STI have no RF traffic).
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = (system_op & bbb[0]) | jall_target_phase;
    // The funnel operand leg stages aaa; once it releases, the fallback source
    // remains old ddd through INIT and EXECUTE.
    wire source_is_rd = instr_q[15] &
                        (~instr_q[14] | (f5[4] & ~f5[3]));
    wire [3:0] rf_src_reg = {src_system_bank, source_is_rd ? ddd : aaa};
    wire [2:0] rf_dst_low = ddd & {3{~(trap_active | cmpi_op)}};
    wire [3:0] rf_dst_reg = {trap_active | dst_system_bank, rf_dst_low};

    wire rf_read_rb =
        needs_rb_pass &
        (in_decode | (in_init2 & ~last_slice));
    wire rf_read_rd = (in_init & last_slice & store_op) |
                      store_data_mem_pass;
    wire [3:0] rf_read_reg = rf_read_rb ?
                                 {1'b0, source_is_rd ? aaa : bbb} :
                                 rf_read_rd ? {1'b0, ddd} : rf_src_reg;

    // STB to the high byte lane: read the store data rotated by 8 so the
    // byte lands in data_stream_q[15:8], avoiding a byte-duplication mux.
    wire store_high_byte = byte_access & store_op;
    wire rf_read_lane_flip =
        (store_data_mem_pass &
         store_high_byte & address_stream_q[0]) |
        (in_init & last_slice & store_high_byte & address_stream_q[W]);
    wire [SLICE_BITS-1:0] byte_lane_offset =
        {rf_read_lane_flip, {(SLICE_BITS-1){1'b0}}};
    wire [SLICE_BITS-1:0] rf_read_slice =
        (slice_count_en ? slice_idx_next : {SLICE_BITS{1'b0}}) ^
        byte_lane_offset;

    wire writes_rd = immediate_alu_op | register_execute_plane |
                     load_writeback_op |
                     ((W == 1) ? right_shift_op : shift_writeback_op) |
                     system_move_op |
                     (link_dest_nonzero & link_context);
    wire rf_we = in_execute & (trap_active | writes_rd);

    wire [W-1:0] rf_rdata;
    wire [W-1:0] rf_wdata;

    // High-lane byte loads rotate on the write side.  Clear the saved lane
    // after writeback so a later trap always writes EPC to the native S0
    // slice address.
    wire load_high_byte = (W != 1) & byte_access & load_op & memory_lane_q;

    riscc_rf #(
        .WIDTH(W),
        .ADDR_WIDTH(RF_ADDR_WIDTH)
    ) regs (
        .clk(clk),
        .raddr({rf_read_reg, rf_read_slice}),
        .rdata(rf_rdata),
        .waddr({rf_dst_reg, slice_idx_q ^
               {load_high_byte, {(SLICE_BITS-1){1'b0}}}}),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Immediate stream
    // ------------------------------------------------------------------
    // LUI rotates the zero-extended imm8 stream by one byte. Since SLICES is
    // a power of two, flipping the counter MSB performs that rotation.
    // ADDI/CMPI sign-extend. Wider variants leave a branch's unused ALU
    // upper half clear so the PC can reuse this slice selector below.
    wire sign_extend_imm = (W == 1) ?
        (imm_mem_group | add_immediate_op | cmpi_op | branch_group) :
        (imm_mem_group | (immediate_group & ~aaa[2] & aaa[1]));
    wire lui_op = immediate_group & (aaa == 3'b001);
    wire [SLICE_BITS-1:0] immediate_slice_index =
        slice_idx_q ^ {lui_op, {(SLICE_BITS-1){1'b0}}};
    wire [W-1:0] immediate_low_slice =
        instr_q[((immediate_slice_index * W) & 7) +: W];
    wire [W-1:0] imm_slice = immediate_slice_index[SLICE_BITS-1] ?
                           {W{sign_extend_imm & instr_q[7]}} :
                           immediate_low_slice;

    // ------------------------------------------------------------------
    // Serial ALU (also generates the memory address)
    // ------------------------------------------------------------------
    // Sys /1 uses one extra store pass and omits the direct-store operand path.
    wire slow_direct_store = (W == 1);
    wire direct_store_stream_base = register_store_op & slow_direct_store;
    wire alu_a_enable =
        ~(immediate_group & ~aaa[2] & ~aaa[1]) & ~direct_store_stream_base;
    // At /1, a store's source takes the slow stream path and must reach B.
    // Wider variants may share the direct-memory plane because the remaining
    // aliases are reserved encodings.
    wire alu_b_zero = system_op | ((W == 1) ?
        (direct_load_op & ~bbb[0]) :
        (register_memory_plane & f5[1] & ~bbb[0]));
    // Logic operations ignore the adder, so their low function bits may alias
    // this control. W=1 excludes funnels from both terms; wider variants retain
    // the reserved f5[1] subtract alias.
    wire alu_subtract =
        ((W == 1) ?
             (ordinary_alu_op & (f5[1] | f5[0])) :
             (register_execute_plane & (f5[1] | f5[0]) &
              (~funnel_op | f5[1]))) |
        cmpi_op;

    // During SLT EXECUTE, force both operands (and alu_b_raw inversion) to
    // zero so the comparison result rides the parked carry into result bit 0.
    wire slt_execute = slt_op & in_execute;

    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute}};
    wire [W-1:0] alu_b_raw =
        ((needs_operand_pass | direct_store_stream_base) ?
         data_stream_q[W-1:0] : imm_slice) &
                       {W{~(alu_b_zero | slt_execute)}};
    wire [W-1:0] alu_b = alu_b_raw ^ {W{alu_subtract & ~slt_execute}};

    reg  alu_carry_q;
    wire [W:0] alu_sum_ext = {1'b0, alu_a} + {1'b0, alu_b} +
                             {{W{1'b0}}, alu_carry_q};
    wire [W-1:0] alu_sum = alu_sum_ext[W-1:0];
    wire alu_active = slice_count_en & (in_init | in_execute);

    // SLT/SLTU: signed-aware borrow, complete at the end of INIT and
    // parked in the carry FF for the EXECUTE pass.
    wire less_than_result =
        (rf_rdata[W-1] & signed_compare) ^
        ~(alu_b_raw[W-1] & signed_compare) ^ alu_sum_ext[W];

    always @(posedge clk)
        alu_carry_q <= (register_execute_plane & in_init & last_slice) ?
                           ((W == 1) ?
                                (f5[4] ? data_stream_q[W-1] :
                                         less_than_result) :
                                (slt_op ? less_than_result :
                                          data_stream_q[W-1])) :
                       alu_active ? alu_sum_ext[W] : alu_subtract;

    wire logic_op = (immediate_alu_op & aaa[2]) |
                    (((W == 1) ? ordinary_alu_op : register_execute_plane) &
                     f5[2]);
    // 00 AND, 01 OR, 10 XOR.
    wire [1:0] logic_select = immediate_group ? aaa[1:0] : f5[1:0];
    wire [W-1:0] logic_result =
        ((rf_rdata ^ alu_b_raw) &
         {W{logic_select[1] | logic_select[0]}}) |
        ((rf_rdata & alu_b_raw) & {W{~logic_select[1]}});
    wire [W-1:0] alu_result = logic_op ? logic_result : alu_sum;

    // Funnel INIT2 stages ra, then INIT streams old rd into data_stream_q.
    // FSR1 preserves ra[0]; FSL1 seeds the existing ALU carry from ra[15].
    wire right_shift_input = last_slice ?
        (f5[4] ? funnel_bit_q :
                   (arithmetic_shift & data_stream_q[W-1])) :
        data_stream_q[W];
    wire [W:0] right_shift_base =
        {1'b0, data_stream_q[W-1:0]} >> 1;
    wire [W-1:0] right_shift_slice =
        right_shift_base[W-1:0] |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));
    wire [W-1:0] shift_result_slice = right_shift_slice;

    // ------------------------------------------------------------------
    // Data stream: operands, stores, loads, one-step shifts, and JALL targets
    // ------------------------------------------------------------------
    // The stream shifts on every counted cycle, including MEM_XFER. Loads
    // enter in W-bit slices, leaving the lower 16-W bits as a pure shift with
    // no input muxing. INIT2 fills and consumers shift too; idle passes rotate
    // don't-care data that the next fill/load overwrites.
    wire [W-1:0] memory_read_slice =
        mem_response_q[slice_idx_q * W +: W];
    // W=1 can select the requested byte directly while the word is streamed.
    // Wider variants stream the whole word and rotate the RF write address.
    wire byte_load = byte_access & load_op;
    wire w1_memory_slice_high = byte_load ? address_stream_q[0] :
                                            slice_idx_q[SLICE_BITS-1];
    wire w1_memory_data_bit =
        mem_response_q[(w1_memory_slice_high * 8) +
                       ((slice_idx_q * W) & 7)];
    wire w1_byte_fill_bit = sign_extend_byte &
        mem_response_q[(address_stream_q[0] * 8) + 7];
    wire w1_load_stream_bit = (byte_load & slice_idx_q[SLICE_BITS-1]) ?
                              w1_byte_fill_bit : w1_memory_data_bit;
    wire [W-1:0] load_stream_slice = (W == 1) ?
        {{(W-1){1'b0}}, w1_load_stream_bit} : memory_read_slice;
    always @(posedge clk) begin
        if (mem_valid)
            mem_response_q <= mem_rdata;

        if (slice_count_en)
            // A one-step shift replaces its source stream with the result.
            data_stream_q <= {
                memory_stream_pass ? load_stream_slice :
                (in_execute & right_shift_op) ?
                    shift_result_slice : rf_rdata,
                data_stream_q[15:W]};
        if (in_mem_xfer) begin
            memory_lane_q <= address_stream_q[0];
            load_fill_q <= sign_extend_byte &
                           (address_stream_q[0] ?
                                mem_response_q[15] : mem_response_q[7]);
        end
        if (in_execute & last_slice)
            memory_lane_q <= 1'b0;
        if (in_init & first_slice)
            funnel_bit_q <= data_stream_q[0];
    end


    // ------------------------------------------------------------------
    // Branch shadow: r0 zero/negative flags, updated on every r0 write
    // ------------------------------------------------------------------
    reg r0_zero_q;
    reg r0_negative_q;
    wire writes_r0 = rf_we & ~(|rf_dst_reg);

    always @(posedge clk)
        if (writes_r0) begin
            r0_zero_q <= (rf_wdata == {W{1'b0}}) &
                         (first_slice | r0_zero_q);

            if ((W == 1) |
                &(slice_idx_q ^
                  {load_high_byte, {(SLICE_BITS-1){1'b0}}}))
                // Test the architectural top write slice, including the
                // high-byte rotation, rather than special-casing widths.
                r0_negative_q <= rf_wdata[W-1];
        end

    wire branch_taken = branch_group & ~ddd[2] &
        ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]);
    wire use_pc_offset = branch_taken | jmp8_op;

    // ------------------------------------------------------------------
    // PC stream and serial adder (byte PC + offset + two-byte step).
    // The adder output is also every link/EPC value: PC+2 for JALR/JALL;
    // for IRQ entry the parked carry is forced to 0 (and the
    // offset gated off) so the same adder yields the raw preempted pc_q.
    // ------------------------------------------------------------------
    reg [15:0] pc_q;
    reg pc_carry_q;

    // Encoded bits 7:1 wire directly to byte-offset bits 7:1. The forced
    // sequential step replaces bit zero; encoded bit zero supplies the fill.
    wire branch_sign_fill = slice_idx_q[SLICE_BITS-1] & instr_q[0];
    wire [W-1:0] pc_step_slice =
        {{(W-1){1'b0}}, first_slice & ~trap_active};
    wire [W-1:0] pc_offset_slice = (W == 1) ?
        ((slice_idx_q[SLICE_BITS-1] ?
            {W{use_pc_offset & instr_q[0]}} :
            (immediate_low_slice & {W{use_pc_offset}})) | pc_step_slice) :
        ((imm_slice & {W{use_pc_offset}}) |
         {W{branch_sign_fill & use_pc_offset}} | pc_step_slice);
    wire [W:0] pc_sum_ext = {1'b0, pc_q[W-1:0]} +
                            {1'b0, pc_offset_slice} +
                            {{W{1'b0}}, pc_carry_q};
    wire [W-1:0] pc_sum = pc_sum_ext[W-1:0];

    always @(posedge clk)
        pc_carry_q <= in_execute ? pc_sum_ext[W] : ~(in_decode & take_irq);

    // Register jumps and JALL targets both use data_stream_q.
    wire pc_from_register = register_target_op;
    wire pc_from_stream = pc_from_register | jall_target_phase;
    wire [15:0] irq_pc_word = 16'h0004 >> (slice_idx_q * W);
    wire [W-1:0] irq_pc_slice = irq_pc_word[W-1:0];
    wire [W-1:0] next_pc_slice =
        trap_active ? irq_pc_slice :
        pc_from_stream ?
                                         data_stream_q[W-1:0] :
                                                 pc_sum;

    always @(posedge clk)
        if (rst)
            pc_q <= RESET_PC;
        else if (in_execute)
            pc_q <= {next_pc_slice, pc_q[15:W]};

    // Address follows the serial ALU during effective-address formation and
    // the PC stream while the instruction commits.
    always @(posedge clk) begin
        if (rst)
            address_stream_q <= RESET_PC;
        else if (in_init | in_execute)
            address_stream_q <= {
                in_init ? alu_sum : next_pc_slice,
                address_stream_q[15:W]};
    end

    // rd write data; EPC uses the same link path.
    wire [W-1:0] link_slice = pc_sum;
    wire [W-1:0] load_slice =
        ((W != 1) & byte_access &
         (slice_idx_q[SLICE_BITS-1] ^ memory_lane_q)) ?
            {W{load_fill_q}} : data_stream_q[W-1:0];
    assign rf_wdata =
        (trap_active | register_link_data_op | jall_target_phase) ?
            link_slice :
        load_writeback_op ? load_slice :
        shift_writeback_op ? shift_result_slice :
        alu_result;

    // ------------------------------------------------------------------
    // System profile state
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (in_decode)
            trap_q <= take_irq;
        if (in_execute) begin
            if (trap_q) begin
                if (last_slice)
                    ie_q <= 1'b0;
            end else if (ie_write_op & last_slice)
                ie_q <= ie_next;
        end
        if (rst) begin
            ie_q   <= 1'b0;
            trap_q <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        /* verilator lint_off CASEINCOMPLETE */
        case (state_q)
            ST_FETCH_WAIT:
                if (mem_ready)
                    state_q <= ST_DECODE;
            ST_DECODE:
                state_q <= take_irq ? ST_EXECUTE :
                    (needs_operand_pass |
                     direct_store_stream_base |
                     pc_from_register |
                     right_shift_op) ? ST_INIT2 :
                    needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT2:
                if (last_slice)
                    state_q <= needs_init_pass ? ST_INIT :
                               store_op ? ST_MEM_WAIT : ST_EXECUTE;
            ST_INIT:
                if (last_slice)
                    state_q <= store_op ? ST_MEM_XFER :
                               mem_op   ? ST_MEM_WAIT : ST_EXECUTE;
            // Loads remain in the request state through ACK.
            ST_MEM_WAIT:
                if (mem_ready)
                    state_q <= store_op ? ST_EXECUTE : ST_MEM_XFER;
            ST_MEM_XFER:
                if (last_slice)
                    state_q <= store_op ? ST_MEM_WAIT : ST_EXECUTE;
            ST_EXECUTE:
                if (last_slice)
                    state_q <= (long_form_op & ~jall_target_phase_q &
                                ~trap_active) ? ST_MEM_WAIT : ST_FETCH_WAIT;
        endcase
        /* verilator lint_on CASEINCOMPLETE */
        if (rst)
            state_q <= ST_FETCH_WAIT;

        slice_idx_q <= slice_count_en ? slice_idx_next :
                                       {SLICE_BITS{1'b0}};

        if (in_fetch_wait & mem_ready)
            instr_q <= mem_rdata;

        if (in_execute & last_slice)
            jall_target_phase_q <= long_form_op & ~jall_target_phase_q &
                                  ~trap_active;
        if (rst)
            jall_target_phase_q <= 1'b0;

    end

    // ------------------------------------------------------------------
    // Wishbone-compatible request. The request states hold the address,
    // data, write qualifier, and byte lanes stable until mem_ready.
    // ------------------------------------------------------------------
    // address_stream_q shadows pc_q as a byte address.
    assign mem_addr = address_stream_q[15:1];
    assign mem_valid = in_fetch_wait | in_mem_wait;
    assign mem_we = in_mem_wait & store_op;
    assign mem_wdata = data_stream_q;  // STB data is pre-rotated to its lane.
    assign mem_wmask = (in_mem_wait & byte_access) ?
                       {address_stream_q[0], ~address_stream_q[0]} :
                       2'b11;

    // ------------------------------------------------------------------
    // Trace interface
    // ------------------------------------------------------------------
`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = W;
    wire tr_commit_i = in_execute & last_slice &
        ~(long_form_op & ~jall_target_phase_q &
                         ~trap_active);
    wire [SLICE_BITS-1:0] tr_wr_slice_i = slice_idx_q ^
        {load_high_byte, {(SLICE_BITS-1){1'b0}}};
    wire [14:0] tr_pc_i = pc_q[15:1];
    wire [15:0] tr_ir_i = instr_q;
    wire        tr_ie_i = ie_q;
    wire        tr_rf_we_i = rf_we;
    wire        tr_rf_bank_i = rf_dst_reg[3];
    wire [2:0]  tr_rf_reg_i = rf_dst_reg[2:0];
    wire [3:0]  tr_rf_lsb_i = {tr_wr_slice_i, {W_LOG2{1'b0}}};
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif

endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
`endif
