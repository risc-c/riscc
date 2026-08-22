// riscc32_min.v : area-oriented serial RC32 Min core.
//
// This is the RC32 counterpart to riscc_min. It keeps the one-port,
// 16-bit synchronous memory interface and serializes both the 32-bit
// register file and the native 32-bit data transfers through W-bit slices.
// W may be 1, 2, 4, 8, or 16. PC, links, and all pointers are architectural
// byte addresses; mem_addr is the corresponding physical halfword address.
//
// The core intentionally implements only the RC32 Min profile. In
// particular, it replaces compact LUI and RC32 long immediates
// with compact LDPC rd,rel8, and has no IRQ, long control transfers, variable
// shifts, or multiply machinery.

`default_nettype none

module riscc32_min #(
    parameter integer W = 4,
    parameter [31:0] RESET_PC = 32'h0000_0000  // byte address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // unused by the Min profile

    // Halfword address. A native data word takes two consecutive accesses.
    output wire [31:0] mem_addr,
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,
    output wire        mem_we,
    output wire        mem_valid,  // request valid; held until mem_ready
    input  wire        mem_ready   // request accepted; read data is valid
`ifdef RISCC_TRACE
    ,
`include "riscc_trace_ports32.vh"
`endif
);

    localparam integer SLICES = 32 / W;
    localparam integer SLICE_BITS = $clog2(SLICES);
    localparam integer RF_ADDR_WIDTH = 4 + SLICE_BITS;
    localparam [SLICE_BITS-1:0] LAST_MEMORY_SLICE =
        {1'b0, {(SLICE_BITS-1){1'b1}}};

    // ------------------------------------------------------------------
    // Width-dependent datapath choices
    // ------------------------------------------------------------------
    // At /1, /2, and /4 the PC has a dedicated adder. Wider configurations
    // share the ALU and accept one extra Execute pass.
    localparam SHARE_PC_ADDER = (W >= 8);
    // Wide datapaths form an LDPC address with the PC-update path, load the
    // word, then subtract the displacement to recover pc_next. Narrow paths
    // form the address directly in INIT because their extra ALU input is less
    // expensive than the deferred control schedule.
    localparam DEFER_LDPC = (W >= 8);
    // At /8, LDPC reuses INIT for the restoring PC pass. At /16, a one-bit
    // load phase is retained across the memory transfer.
    localparam RESTORE_LDPC_IN_INIT = (W == 8);
    // At wide datapaths, a stalled store boundary is the bitwise complement
    // of the already-available next slice, avoiding a third synchronous-RF
    // address choice.
    localparam USE_BOUNDARY_COMPLEMENT = (W >= 8);

    // ------------------------------------------------------------------
    // State and serial-slice counter
    // ------------------------------------------------------------------
    // State bit 2 distinguishes the four counted datapath passes from the
    // three control/wait states. Keep one encoding for every width and target;
    // the schedule, rather than synthesis-specific state numbering, defines
    // the microarchitecture.
    localparam [2:0] ST_DECODE = 3'b001;
    localparam [2:0] ST_FETCH_WAIT = 3'b000;
    localparam [2:0] ST_MEM_WAIT = 3'b010;
    localparam [2:0] ST_MEM_XFER = 3'b100;
    localparam [2:0] ST_INIT2 = 3'b101;
    localparam [2:0] ST_EXECUTE = 3'b110;
    localparam [2:0] ST_INIT = 3'b111;

    // Counted passes always expose the current slice in bits [W-1:0].
    // INIT2 stages a second operand, INIT forms an effective address, and
    // MEM_XFER streams a transfer. EXECUTE writes the result; at /8 and
    // wider a second EXECUTE pass reuses the ALU to advance the PC.
    reg [2:0] state_q;
    reg [SLICE_BITS-1:0] slice_idx_q;
    reg pc_phase_q;
    reg ldpc_loaded_q;

    wire in_decode = state_q == ST_DECODE;
    wire in_init2 = state_q == ST_INIT2;
    wire in_init = state_q == ST_INIT;
    wire in_mem_wait = state_q == ST_MEM_WAIT;
    wire in_mem_xfer = state_q == ST_MEM_XFER;
    wire in_execute = state_q == ST_EXECUTE;
    wire ldpc_op;
    wire deferred_ldpc_op;
    wire ldpc_restore_init_op;
    wire deferred_ldpc_pre;
    wire data_execute = in_execute &
        (~SHARE_PC_ADDER | ~pc_phase_q);
    wire pc_execute =
        (in_execute & (~SHARE_PC_ADDER | pc_phase_q)) |
        (in_init & ldpc_restore_init_op);
    wire slice_count_en = state_q[2];
    wire memory_write_wait;
    wire [SLICE_BITS:0] slice_idx_sum =
        {1'b0, slice_idx_q} + {{SLICE_BITS{1'b0}}, 1'b1};
    wire [SLICE_BITS-1:0] slice_idx_next =
        slice_idx_sum[SLICE_BITS-1:0];
    wire last_slice = slice_idx_sum[SLICE_BITS];
    wire first_slice = ~|slice_idx_q;
    wire last_memory_half = slice_idx_q == LAST_MEMORY_SLICE;

    // ------------------------------------------------------------------
    // Instruction decode
    // ------------------------------------------------------------------
    // Keep the architectural instruction word unchanged.
    reg [15:0] instr_q;
    reg [31:0] instr_pc_q;
    reg [31:0] address_stream_q;
    reg [31:0] data_stream_q;
    reg [15:0] mem_response_q;
    reg [31:0] pc_q;
    reg pc_carry_q;

    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field.
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group = ~instr_q[15] & instr_q[14];
    wire immediate_group = instr_q[15] & ~instr_q[14];
    wire register_group = instr_q[15] & instr_q[14];
    wire [W-1:0] data_stream_input;

    wire branch_group = immediate_group & (aaa == 3'b111);
    // Compact opcode 001 loads M32[pc_next + 2*rel8]. It replaces compact LUI
    // and addresses a linker-managed literal directly.
    assign ldpc_op = immediate_group & (aaa == 3'b001);
    wire ldpc_init = ldpc_op & in_init & ~DEFER_LDPC;
    assign deferred_ldpc_op = ldpc_op & DEFER_LDPC;
    assign ldpc_restore_init_op =
        deferred_ldpc_op & RESTORE_LDPC_IN_INIT;
    wire ldpc_restore_flag_op =
        deferred_ldpc_op & ~RESTORE_LDPC_IN_INIT;
    assign deferred_ldpc_pre =
        (ldpc_restore_init_op & in_execute) |
        (ldpc_restore_flag_op & ~ldpc_loaded_q);
    wire deferred_ldpc_restore =
        (ldpc_restore_init_op & in_init) |
        (ldpc_restore_flag_op & ldpc_loaded_q);
    wire immediate_alu_op = immediate_group & ~branch_group & ~ldpc_op;
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    wire cmpi_op = immediate_group & aaa[1] & aaa[0];
    wire link_dest_nonzero = |ddd;

    wire f_group_01 = ~f5[4] & f5[3];
    wire system_op = register_group & f5[4] & f5[3];
    wire register_alu_op = register_group & ~f5[3];
    wire funnel_op = register_alu_op & f5[4];
    wire funnel_right_op = funnel_op & bbb[0];
    wire ordinary_alu_op = register_alu_op & ~f5[4];
    wire slt_op = ordinary_alu_op & ~f5[2] & f5[1];
    wire signed_compare = ~instr_q[3];
    wire right_shift_op =
        register_group & f_group_01 & f5[2] & ~f5[1];
    wire arithmetic_shift = f5[0];
    wire any_shift_op = right_shift_op | funnel_right_op;

    wire register_memory_plane = register_group & f_group_01;
    wire indexed_mem_op =
        register_memory_plane & ~f5[2] & ~f5[1];
    wire direct_load_op =
        register_memory_plane & f5[1] & ~f5[0];
    wire register_store_op =
        register_memory_plane & ~f5[2] & f5[1] & f5[0];
    wire direct_mem_op = register_memory_plane & f5[1];

    // Unified memory needs no P selector or program-load address conversion.
    wire byte_load = direct_load_op & ~bbb[1];
    wire direct_data_op = direct_mem_op;
    wire sign_extend_typed = f5[2];

    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = system_op & ~bbb[1] & bbb[0];
    wire register_target_op = system_op & ~bbb[1];

    wire store_op = (imm_mem_group & instr_q[0]) | register_store_op;
    wire load_op = (imm_mem_group & ~instr_q[0]) |
                   indexed_mem_op | direct_load_op | ldpc_op;
    wire mem_op = store_op | load_op;
    wire native_word_load = load_op & ~direct_load_op;
    wire native_store = imm_mem_group & instr_q[0];
    wire byte_store = store_op & ~native_store & ~bbb[1];

    wire needs_rb_pass = register_alu_op | indexed_mem_op;
    wire needs_operand_pass = needs_rb_pass;
    wire needs_init_pass =
        (mem_op & ~deferred_ldpc_op) | slt_op | funnel_op;
    // Preserve a compact register target between its data and PC passes.
    wire hold_pc_operand = SHARE_PC_ADDER & data_execute &
        register_target_op;
    wire stream_en = slice_count_en & ~memory_write_wait &
        ~hold_pc_operand;

    // Shared serial position expressed as both a 5-bit word index and a
    // halfword-local bit offset.
    wire [4:0] slice_idx_5 =
        {{(5-SLICE_BITS){1'b0}}, slice_idx_q};
    wire upper_half = slice_idx_5[SLICE_BITS-1];
    wire [4:0] stream_bit_offset_wide =
        {1'b0, slice_idx_5[3:0]} << $clog2(W);
    wire [3:0] stream_bit_offset = stream_bit_offset_wide[3:0];

    // ------------------------------------------------------------------
    // One-port serial register file
    // ------------------------------------------------------------------
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = system_op & bbb[0];
    wire source_is_rd = immediate_group | funnel_op;
    wire [2:0] rf_src_gpr = source_is_rd ? ddd : aaa;
    wire [3:0] rf_src_reg = {src_system_bank, rf_src_gpr};
    wire [3:0] rf_dst_reg =
        {dst_system_bank, ddd & {3{~cmpi_op}}};

    wire rf_read_rb = needs_rb_pass &
        (in_decode | (in_init2 & ~last_slice));
    wire rf_read_rd =
        (in_init & last_slice & store_op) |
        (in_mem_xfer & store_op);
    wire [3:0] rf_read_reg = rf_read_rb ?
        {1'b0, (f5[4] ? aaa : bbb)} :
        rf_read_rd ? {1'b0, ddd} : rf_src_reg;
    wire [SLICE_BITS-1:0] rf_read_lane_offset;
    generate
        if (W == 16) begin : g_no_byte_read_rotate
            assign rf_read_lane_offset = {SLICE_BITS{1'b0}};
        end else begin : g_byte_read_rotate
            wire rf_read_byte_rotate = byte_store &
                ((in_mem_xfer & address_stream_q[0]) |
                 (in_init & last_slice & address_stream_q[W]));
            assign rf_read_lane_offset = {
                1'b0, rf_read_byte_rotate,
                {(SLICE_BITS-2){1'b0}}};
        end
    endgenerate
    wire [SLICE_BITS-1:0] rf_read_slice;
    generate
        if (USE_BOUNDARY_COMPLEMENT) begin : g_rf_boundary_complement
            assign rf_read_slice =
                ((slice_idx_next ^ {SLICE_BITS{memory_write_wait}}) &
                 {SLICE_BITS{slice_count_en}}) ^ rf_read_lane_offset;
        end else begin : g_rf_boundary_hold
            assign rf_read_slice =
                (slice_count_en ?
                 (memory_write_wait ? slice_idx_q : slice_idx_next) :
                 {SLICE_BITS{1'b0}}) ^ rf_read_lane_offset;
        end
    endgenerate

    wire [SLICE_BITS-1:0] rf_write_lane_offset;
    wire byte_load_unselected;
    generate
        if ((W == 1) || (W == 16)) begin : g_no_byte_write_rotate
            assign rf_write_lane_offset = {SLICE_BITS{1'b0}};
            assign byte_load_unselected = 1'b0;
        end else begin : g_byte_write_rotate
            wire byte_load_lane = address_stream_q[0];
            assign rf_write_lane_offset = {
                1'b0, byte_load & byte_load_lane,
                {(SLICE_BITS-2){1'b0}}};
            assign byte_load_unselected = byte_load & ~upper_half &
                (slice_idx_q[SLICE_BITS-2] ^ byte_load_lane);
        end
    endgenerate

    wire writes_data_result = immediate_alu_op | register_alu_op |
        any_shift_op | system_move_op;
    wire rf_we_normal =
        (data_execute & writes_data_result) |
        (pc_execute & link_context & link_dest_nonzero);
    wire rf_we = (in_mem_xfer & load_op) | rf_we_normal;
    wire [W-1:0] rf_rdata;
    wire [W-1:0] rf_wdata;

    riscc_rf #(
        .WIDTH(W),
        .ADDR_WIDTH(RF_ADDR_WIDTH)
    ) regs (
        .clk(clk),
        .raddr({rf_read_reg, rf_read_slice}),
        .rdata(rf_rdata),
        .waddr({rf_dst_reg, slice_idx_q ^ rf_write_lane_offset}),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Immediate and serial ALU
    // ------------------------------------------------------------------
    wire sign_extend_imm =
        add_immediate_op | cmpi_op | branch_group | ldpc_op;
    // Select a halfword before the serial part-select. A 32-bit indexed mux is
    // particularly expensive for W=1, so every width uses the offset above.
    // RC32 rotates compact word displacement bit i[1] above i[7:2], then
    // appends two alignment zeroes. Other compact immediates retain their
    // ordinary bit-7 sign.
    wire relative_immediate_op = branch_group | ldpc_op;
    wire compact_sign_bit = ((W != 16) & relative_immediate_op) ?
        instr_q[0] : instr_q[7];
    wire compact_fill_bit = imm_mem_group ? instr_q[1] :
        (sign_extend_imm & compact_sign_bit);
    wire [W-1:0] imm_slice;
    generate
        if (W == 16) begin : g_compact_imm_16
            wire [7:0] compact_fill_byte = {8{compact_fill_bit}};
            wire [7:0] compact_payload = {
                instr_q[7:2],
                instr_q[1:0] & {2{~imm_mem_group}}};
            assign imm_slice = upper_half ? {W{compact_fill_bit}} :
                {compact_fill_byte, compact_payload};
        end else if (W == 8) begin : g_compact_imm_8
            wire below_bit8 = ~slice_idx_q[SLICE_BITS-2];
            wire [7:0] compact_payload_byte = {
                instr_q[7:2],
                instr_q[1:0] & {2{~imm_mem_group}}};
            assign imm_slice =
                (~upper_half & below_bit8) ?
                    compact_payload_byte : {W{compact_fill_bit}};
        end else begin : g_compact_imm_serial
            wire below_bit8 = ~slice_idx_q[SLICE_BITS-2];
            wire [7:0] compact_payload_byte = {
                instr_q[7:2],
                instr_q[1:0] & {2{~imm_mem_group}}};
            wire [W-1:0] instr_byte_slice =
                compact_payload_byte[stream_bit_offset[2:0] +: W];
            wire [W-1:0] low_half_slice = below_bit8 ?
                instr_byte_slice : {W{compact_fill_bit}};
            assign imm_slice = upper_half ?
                {W{compact_fill_bit}} : low_half_slice;
        end
    endgenerate

    wire alu_a_enable =
        ~(immediate_group & ~aaa[2] & ~aaa[1]);
    wire alu_b_zero = system_op | direct_data_op | register_store_op;
    wire alu_subtract =
        (ordinary_alu_op & (f5[1] | f5[0])) | cmpi_op;
    wire slt_execute = slt_op & data_execute;
    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute}};
    wire [W-1:0] alu_b_source;
    wire [W-1:0] alu_b_raw = alu_b_source &
        {W{~(alu_b_zero | slt_execute)}};
    wire [W-1:0] alu_b =
        alu_b_raw ^ {W{alu_subtract & ~slt_execute}};

    reg alu_carry_q;
    // One endpoint bit connects consecutive funnel-shift slices.
    reg serial_bit_q;
    // The rotated rel8 field is already a signed byte displacement: bit zero
    // is its sign, bits 7:1 are byte-offset bits 7:1, and bit zero of the byte
    // address is the implicit alignment zero.
    wire [W-1:0] relative_offset_slice;
    generate
        if (W == 16) begin : g_relative_offset_w16
            assign relative_offset_slice =
                {{8{instr_q[0]}}, imm_slice[7:0]};
        end else begin : g_relative_offset_narrow
            assign relative_offset_slice = imm_slice;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Branch shadow and PC offset
    // ------------------------------------------------------------------
    reg r0_zero_q;
    reg r0_negative_q;
    wire writes_r0 = rf_we & ~(|rf_dst_reg);

    always @(posedge clk)
        if (writes_r0) begin
            r0_zero_q <= (rf_wdata == {W{1'b0}}) &
                         (first_slice | r0_zero_q);

            if (last_slice)
                r0_negative_q <= rf_wdata[W-1];
        end

    wire use_pc_offset =
        (branch_group &
         (ddd[2] ? 1'b1 :
          ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]))) |
        deferred_ldpc_pre;
    wire restore_pc_after_ldpc = deferred_ldpc_restore;
    wire [W-1:0] pc_step_slice =
        {{(W-1){1'b0}}, first_slice};
    wire [W-1:0] pc_offset_slice = restore_pc_after_ldpc ?
        ~relative_offset_slice :
        (relative_offset_slice & {W{use_pc_offset}}) | pc_step_slice;
    wire pc_uses_alu = SHARE_PC_ADDER & pc_execute;
    wire alu_uses_pc = ldpc_init | pc_uses_alu;
    wire [W-1:0] alu_sum_a =
        (alu_a & {W{~alu_uses_pc}}) |
        (address_stream_q[W-1:0] & {W{ldpc_init}}) |
        (pc_q[W-1:0] & {W{pc_uses_alu}});
    wire [W-1:0] alu_sum_b =
        (alu_b & {W{~alu_uses_pc}}) |
        (relative_offset_slice & {W{ldpc_init}}) |
        (pc_offset_slice & {W{pc_uses_alu}}) |
        (pc_step_slice & {W{ldpc_init}});
    wire alu_sum_carry = pc_uses_alu ? pc_carry_q : alu_carry_q;
    wire [W:0] alu_sum_ext =
        {1'b0, alu_sum_a} + {1'b0, alu_sum_b} +
        {{W{1'b0}}, alu_sum_carry};
    wire [W-1:0] alu_sum = alu_sum_ext[W-1:0];
    wire alu_active = in_init | data_execute;
    wire less_than_result =
        (rf_rdata[W-1] & signed_compare) ^
        ~(alu_b_raw[W-1] & signed_compare) ^ alu_sum_ext[W];

    always @(posedge clk)
        alu_carry_q <= (register_alu_op & in_init & last_slice) ?
            (slt_op ? less_than_result : data_stream_q[W-1]) :
            alu_active ? alu_sum_ext[W] :
            (alu_subtract | (ldpc_op & ~DEFER_LDPC));

    assign alu_b_source = needs_operand_pass ?
        data_stream_q[W-1:0] : imm_slice;
    assign data_stream_input = rf_rdata;

    always @(posedge clk)
        if (in_init & first_slice)
            serial_bit_q <= data_stream_q[0];

    wire logic_op =
        (immediate_alu_op & aaa[2]) |
        (register_alu_op & f5[2]);
    wire [1:0] logic_select =
        immediate_group ? aaa[1:0] : f5[1:0];
    wire [W-1:0] logic_result =
        ((rf_rdata ^ alu_b_raw) &
         {W{logic_select[1] | logic_select[0]}}) |
        ((rf_rdata & alu_b_raw) & {W{~logic_select[1]}});
    wire [W-1:0] alu_result = logic_op ? logic_result : alu_sum;

    wire [W:0] separate_pc_sum_ext =
        {1'b0, pc_q[W-1:0]} + {1'b0, pc_offset_slice} +
        {{W{1'b0}}, pc_carry_q};
    wire [W:0] pc_sum_ext = SHARE_PC_ADDER ?
        alu_sum_ext : separate_pc_sum_ext;
    wire [W-1:0] pc_sum = pc_sum_ext[W-1:0];
    wire [W-1:0] next_pc_slice = register_target_op ?
        data_stream_q[W-1:0] : pc_sum;

    always @(posedge clk) begin
        pc_carry_q <= pc_execute ?
                      (last_slice ? 1'b0 : pc_sum_ext[W]) : 1'b1;
        if (rst)
            pc_q <= RESET_PC;
        else if (pc_execute)
            pc_q <= {next_pc_slice, pc_q[31:W]};
    end

    // ------------------------------------------------------------------
    // Address, load, and shift streams
    // ------------------------------------------------------------------
    // As in RC16 Min, keep the address stream directly on the memory port.
    // INIT replaces it with an effective byte address; each PC pass replaces
    // it with the next byte PC.
    always @(posedge clk) begin
        if (rst)
            address_stream_q <= RESET_PC;
        else if (pc_execute)
            address_stream_q <= {
                next_pc_slice, address_stream_q[31:W]};
        else if (in_init)
            address_stream_q <= {alu_sum, address_stream_q[31:W]};
    end

    wire right_shift_input = last_slice ?
        (f5[4] ? serial_bit_q :
                 (arithmetic_shift & data_stream_q[W-1])) :
        data_stream_q[W];
    wire [W:0] right_shift_base =
        {1'b0, data_stream_q[W-1:0]} >> 1;
    wire [W-1:0] shift_result_slice =
        right_shift_base[W-1:0] |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));

    wire [W-1:0] memory_read_slice =
        mem_response_q[stream_bit_offset +: W];
    wire typed_fill_bit = sign_extend_typed &
        ((byte_load & ~address_stream_q[0]) ?
            mem_response_q[7] : mem_response_q[15]);
    wire [W-1:0] load_stream_slice;
    generate
        if (W == 1) begin : g_typed_load_w1
            wire [3:0] typed_memory_index = byte_load ?
                {address_stream_q[0], slice_idx_q[2:0]} : slice_idx_q[3:0];
            wire typed_data_bit = mem_response_q[typed_memory_index];
            wire typed_done = byte_load ?
                (slice_idx_q[4] | slice_idx_q[3]) : slice_idx_q[4];
            assign load_stream_slice = native_word_load ? memory_read_slice :
                typed_done ? typed_fill_bit : typed_data_bit;
        end else if (W == 16) begin : g_typed_load_w16
            wire [7:0] addressed_byte = address_stream_q[0] ?
                mem_response_q[15:8] : mem_response_q[7:0];
            wire typed_upper = upper_half & ~native_word_load;
            wire typed_byte_low = byte_load & ~upper_half;
            assign load_stream_slice[15:8] = typed_upper |
                typed_byte_low ? {8{typed_fill_bit}} :
                memory_read_slice[15:8];
            assign load_stream_slice[7:0] = typed_upper ?
                {8{typed_fill_bit}} :
                typed_byte_low ? addressed_byte :
                memory_read_slice[7:0];
        end else begin : g_typed_load_serial
            assign load_stream_slice = native_word_load ? memory_read_slice :
                upper_half ? {W{typed_fill_bit}} : memory_read_slice;
        end
    endgenerate

    // Shift operands and stores share one serial staging register. A store
    // request is issued on the final slice of each transferred halfword. If
    // ACK is late, the slice counter and stream hold, keeping RF data and the
    // assembled halfword stable without a separate memory-data register.
    always @(posedge clk)
        if (stream_en)
            data_stream_q <= {
                data_stream_input,
                data_stream_q[31:W]};

    // Loads write their formatted slices directly during MEM_XFER. This is
    // the same schedule at every datapath width and keeps memory data out of
    // the general operand stream.
    wire [W-1:0] direct_load_slice = byte_load_unselected ?
        {W{typed_fill_bit}} : load_stream_slice;
    assign rf_wdata =
        any_shift_op ? shift_result_slice :
        in_mem_xfer ? direct_load_slice :
        (system_op & ~bbb[1]) ? pc_sum : alu_result;

    // ------------------------------------------------------------------
    // Sequencer and memory interface
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        /* verilator lint_off CASEINCOMPLETE */
        case (state_q)
            ST_FETCH_WAIT:
                if (mem_ready)
                    state_q <= ST_DECODE;
            ST_DECODE:
                state_q <=
                    (needs_operand_pass | register_target_op | any_shift_op) ?
                    ST_INIT2 : needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT2:
                if (last_slice)
                    state_q <= needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT:
                if (last_slice)
                    state_q <= ldpc_restore_init_op ? ST_FETCH_WAIT :
                               store_op ? ST_MEM_XFER :
                               mem_op ? ST_MEM_WAIT : ST_EXECUTE;
            ST_MEM_WAIT:
                if (mem_ready)
                    state_q <= ST_MEM_XFER;
            ST_MEM_XFER:
                if (~memory_write_wait) begin
                    if (last_slice)
                        state_q <= ldpc_restore_init_op ? ST_INIT : ST_EXECUTE;
                    else if (last_memory_half & native_word_load)
                        state_q <= ST_MEM_WAIT;
                end
            ST_EXECUTE:
                if (last_slice & (~SHARE_PC_ADDER | pc_phase_q))
                    state_q <= deferred_ldpc_pre ?
                        ST_MEM_WAIT : ST_FETCH_WAIT;
            default:
                state_q <= ST_FETCH_WAIT;
        endcase
        /* verilator lint_on CASEINCOMPLETE */

        if (rst)
            state_q <= ST_FETCH_WAIT;

        if (rst)
            instr_pc_q <= RESET_PC;
        else if ((state_q == ST_FETCH_WAIT) & mem_ready)
            instr_pc_q <= address_stream_q;

        if (rst)
            pc_phase_q <= 1'b0;
        else if (SHARE_PC_ADDER & in_execute & last_slice)
            pc_phase_q <= (ldpc_restore_flag_op & deferred_ldpc_pre) ?
                1'b1 : ~pc_phase_q;

        if (rst)
            ldpc_loaded_q <= 1'b0;
        else if (ldpc_restore_flag_op & pc_execute & last_slice)
            ldpc_loaded_q <= deferred_ldpc_pre;

        // Keep the global stream position while waiting for a native word's
        // high halfword response.
        slice_idx_q <= USE_BOUNDARY_COMPLEMENT ?
            (slice_count_en ?
                (slice_idx_next ^ {SLICE_BITS{memory_write_wait}}) :
                (in_mem_wait & slice_idx_q[SLICE_BITS-1]) ?
                    slice_idx_q : {SLICE_BITS{1'b0}}) :
            (slice_count_en ?
                (memory_write_wait ? slice_idx_q : slice_idx_next) :
             (in_mem_wait & slice_idx_q[SLICE_BITS-1]) ?
                slice_idx_q : {SLICE_BITS{1'b0}});

        if ((state_q == ST_FETCH_WAIT) & mem_ready)
            instr_q <= mem_rdata;

        if (mem_valid)
            mem_response_q <= mem_rdata;
    end

    wire store_low_write = in_mem_xfer & store_op & last_memory_half;
    wire native_store_high_write =
        in_mem_xfer & native_store & last_slice;
    wire memory_write_request = store_low_write | native_store_high_write;
    assign memory_write_wait = memory_write_request & ~mem_ready;
    wire memory_high_half =
        (in_mem_wait & native_word_load & slice_idx_q[SLICE_BITS-1]) |
        native_store_high_write;
    assign mem_addr = {1'b0, address_stream_q[31:1]} |
        {{31{1'b0}}, memory_high_half};
    assign mem_valid = (state_q == ST_FETCH_WAIT) | in_mem_wait |
                       memory_write_request;
    assign mem_we = memory_write_request;
    wire [15:0] completed_store_half;
    generate
        if (W == 16) begin : g_store_half_16
            assign completed_store_half = rf_rdata;
        end else begin : g_store_half_narrow
            assign completed_store_half =
                {rf_rdata, data_stream_q[31:16+W]};
        end
    endgenerate
    generate
        if (W == 16) begin : g_byte_write_16
            assign mem_wdata = {
                (byte_store & address_stream_q[0]) ?
                    completed_store_half[7:0] : completed_store_half[15:8],
                completed_store_half[7:0]};
        end else begin : g_byte_write_narrow
            assign mem_wdata = completed_store_half;
        end
    endgenerate
    assign mem_wmask = (memory_write_request & byte_store) ?
        {address_stream_q[0], ~address_stream_q[0]} : 2'b11;

    // ------------------------------------------------------------------
    // Trace interface
    // ------------------------------------------------------------------
`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = W;
    wire tr_commit_i = pc_execute & last_slice &
        ~deferred_ldpc_pre;
    wire [31:0] tr_pc_i = instr_pc_q;
    wire [15:0] tr_ir_i = instr_q;
    wire tr_ie_i = 1'b0;
    wire tr_rf_we_i = rf_we;
    wire tr_rf_bank_i = rf_dst_reg[3];
    wire [2:0] tr_rf_reg_i = rf_dst_reg[2:0];
    wire [4:0] tr_rf_lsb_i =
        {{(5-SLICE_BITS){1'b0}},
         slice_idx_q ^ rf_write_lane_offset} << $clog2(W);
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state32.vh"
`endif

    wire _unused_irq = irq;

endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
