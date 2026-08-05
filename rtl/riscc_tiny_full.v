// riscc_tiny_full.v : parameterized serial RISC-C Full core (W=1, 2, 4, or 8).
//
// Serial microarchitecture: doc/HARDWARE.md 'Implementation family' (branch
// shadow, one PC adder, address/data streams, and the INIT2 staging lap).
// W must be 1, 2, 4, or 8; Min uses riscc_tiny_min.v.

`ifndef RISCC_TINY_FULL_V
`define RISCC_TINY_FULL_V
`default_nettype none

// Full adds MUL, whose pass loop rides the existing shift machinery.

module riscc_tiny #(
    parameter integer W = 4,
    parameter [15:0] RESET_PC = 16'h0000           // word address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // level-sensitive, taken at fetch boundary

    output wire [14:0] mem_addr,   // word address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,  // byte lanes
    output wire        mem_we
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
    // The encoding is area-tuned: state_q[2] enables all counted states.
`ifdef RISCC_ECP5
`ifdef RISCC_FMAX_TINY
    // Timing-only state specialization; standard area encodings below
    // remain unchanged.
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd0 :
                                               (W == 4) ? 3'd0 : 3'd0;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd0 :
                                               (W == 2) ? 3'd3 :
                                               (W == 4) ? 3'd3 : 3'd2;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd2 :
                                               (W == 4) ? 3'd1 : 3'd3;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd1 :
                                               (W == 2) ? 3'd1 :
                                               (W == 4) ? 3'd2 : 3'd1;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd7 :
                                               (W == 2) ? 3'd5 :
                                               (W == 4) ? 3'd6 : 3'd7;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd4 :
                                               (W == 2) ? 3'd7 :
                                               (W == 4) ? 3'd7 : 3'd4;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd5 :
                                               (W == 2) ? 3'd4 :
                                               (W == 4) ? 3'd4 : 3'd5;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd6 :
                                               (W == 2) ? 3'd6 :
                                               (W == 4) ? 3'd5 : 3'd6;
`else
    // State codes are independently area-tuned by width and RF mapping;
    // every counted state retains state_q[2] set.
`ifdef RISCC_ECP5_BLOCK_RF
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd0 :
                                               (W == 4) ? 3'd3 : 3'd2;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd0 :
                                               (W == 2) ? 3'd3 :
                                               (W == 4) ? 3'd0 : 3'd1;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd1 :
                                               (W == 4) ? 3'd1 : 3'd3;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd1 :
                                               (W == 2) ? 3'd2 :
                                               (W == 4) ? 3'd2 : 3'd0;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd7 :
                                               (W == 2) ? 3'd7 :
                                               (W == 4) ? 3'd6 : 3'd4;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd4 :
                                               (W == 2) ? 3'd4 :
                                               (W == 4) ? 3'd5 : 3'd5;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd5 :
                                               (W == 2) ? 3'd6 :
                                               (W == 4) ? 3'd7 : 3'd6;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd6 :
                                               (W == 2) ? 3'd5 :
                                               (W == 4) ? 3'd4 : 3'd7;
`else
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd3 :
                                               (W == 4) ? 3'd0 : 3'd2;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd0 :
                                               (W == 2) ? 3'd0 :
                                               (W == 4) ? 3'd2 : 3'd1;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd1 :
                                               (W == 4) ? 3'd1 : 3'd0;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd1 :
                                               (W == 2) ? 3'd2 :
                                               (W == 4) ? 3'd3 : 3'd3;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd7 :
                                               (W == 2) ? 3'd7 :
                                               (W == 4) ? 3'd7 : 3'd7;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd4 :
                                               (W == 2) ? 3'd4 :
                                               (W == 4) ? 3'd6 : 3'd4;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd5 :
                                               (W == 2) ? 3'd6 :
                                               (W == 4) ? 3'd5 : 3'd5;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd6 :
                                               (W == 2) ? 3'd5 :
                                               (W == 4) ? 3'd4 : 3'd6;
`endif
`endif
`else
`ifdef RISCC_FMAX_TINY
    // The packed lookup constant-folds before the timing mapper and is
    // faster for generic W4 without changing the area-build encoding.
    localparam [11:0] ST_FETCH_WAIT_CODES = {3'd0, 3'd0, 3'd0, 3'd0};
    localparam [2:0] ST_FETCH_WAIT    = ST_FETCH_WAIT_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_FETCH_CAPTURE_CODES = {3'd1, 3'd2, 3'd1, 3'd1};
    localparam [2:0] ST_FETCH_CAPTURE = ST_FETCH_CAPTURE_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_DECODE_CODES = {3'd3, 3'd1, 3'd2, 3'd3};
    localparam [2:0] ST_DECODE        = ST_DECODE_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_MEM_WAIT_CODES = {3'd2, 3'd3, 3'd3, 3'd2};
    localparam [2:0] ST_MEM_WAIT      = ST_MEM_WAIT_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_EXECUTE_CODES = {3'd5, 3'd5, 3'd7, 3'd7};
    localparam [2:0] ST_EXECUTE       = ST_EXECUTE_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_MEM_XFER_CODES = {3'd6, 3'd6, 3'd4, 3'd5};
    localparam [2:0] ST_MEM_XFER      = ST_MEM_XFER_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_INIT_CODES = {3'd4, 3'd7, 3'd5, 3'd6};
    localparam [2:0] ST_INIT          = ST_INIT_CODES[(W_LOG2 * 3) +: 3];
    localparam [11:0] ST_INIT2_CODES = {3'd7, 3'd4, 3'd6, 3'd4};
    localparam [2:0] ST_INIT2         = ST_INIT2_CODES[(W_LOG2 * 3) +: 3];
`else
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd1 :
                                               (W == 4) ? 3'd0 : 3'd0;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd0 :
                                               (W == 2) ? 3'd2 :
                                               (W == 4) ? 3'd1 : 3'd1;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd3 :
                                               (W == 4) ? 3'd3 : 3'd2;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd1 :
                                               (W == 2) ? 3'd0 :
                                               (W == 4) ? 3'd2 : 3'd3;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd5 :
                                               (W == 2) ? 3'd5 :
                                               (W == 4) ? 3'd7 : 3'd7;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd4 :
                                               (W == 2) ? 3'd4 :
                                               (W == 4) ? 3'd6 : 3'd5;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd7 :
                                               (W == 2) ? 3'd7 :
                                               (W == 4) ? 3'd5 : 3'd6;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd6 :
                                               (W == 2) ? 3'd6 :
                                               (W == 4) ? 3'd4 : 3'd4;
`endif
`endif

    reg  [2:0] state_q;
    reg  [SLICE_BITS-1:0] slice_idx_q;

    wire in_fetch_capture = (state_q == ST_FETCH_CAPTURE);
    wire in_decode        = (state_q == ST_DECODE);
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
    reg        register_format_q;
`ifdef RISCC_TINY_CONTROL_NORMALIZE
    // Normalize the packed control row at capture on timing-oriented targets.
    // This keeps its new architectural encoding out of the serial datapath's
    // established writeback and register-target decode cones.
    wire fetch_packed_control = (&mem_rdata[15:14]) &
                                (&mem_rdata[7:3]) & ~(|mem_rdata[2:0]);
    wire [15:0] fetch_instr = fetch_packed_control ?
        {mem_rdata[15:14], {3{mem_rdata[13]}}, mem_rdata[10:8],
         mem_rdata[7:3], mem_rdata[12], mem_rdata[12], 1'b0} :
        mem_rdata;
`ifdef RISCC_TRACE
    reg [15:0] trace_instr_q;
`endif
`endif

    // Contiguous register-format fields: 11 ddd aaa fffff bbb.
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group = ~instr_q[15] & register_format_q;
    wire immediate_group = instr_q[15] & ~register_format_q;
    wire register_group = instr_q[15] & register_format_q;

    wire branch_group = immediate_group & (aaa == 3'b111) & ~trap_active;
    // A preempted branch is still not an ALU operation; trap writeback and
    // the IRQ PC path override its normal result. This broader W=1 form maps
    // smaller than routing trap_active through the branch decoder.
    wire immediate_alu_op = immediate_group &
        ((W == 1) ? ~(&aaa) : ~branch_group);
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    // Branches share aaa[1:0] with CMPI, but never consume the ALU result.
    wire cmpi_op = immediate_group & aaa[1] & aaa[0];
    // Loose JMP8: reserved ccc=101/110/111 alias as JMP8.
    wire jmp8_op = branch_group & ddd[2];
    wire long_form_op = ~instr_q[15] & ~register_format_q;
    wire link_dest_nonzero = |ddd;   // Sd == S0 writes no link (plain jump)

    wire f_group_00 = ~f5[4] & ~f5[3];
    wire f_group_01 = ~f5[4] &  f5[3];
    wire f_group_11 = ((W == 4) | (W == 8)) ?
        (f5[4] & (f5[3] | f5[2])) : (f5[4] & f5[3]);
    wire system_op = register_group & f_group_11;

    // Full keeps 00_111 separate for MUL. Group 00 is the ordinary ALU;
    // reserved group-10 functions may alias the compact funnel plane.
    wire register_alu_plane = register_group & ~f5[3];
    wire ordinary_alu_op = register_alu_plane & ~f5[4] & ~(&f5[2:0]);
    wire funnel_op = register_alu_plane & f5[4];
    wire register_write_op;
    generate
        if (W == 1) begin : g_w1_register_write
            // MUL is unioned into writes_rd below, making the full plane exact.
            assign register_write_op = register_alu_plane;
        end else begin : g_serial_register_write
            assign register_write_op = register_alu_plane &
                                       (f5[4] | ~(&f5[2:0]));
        end
    endgenerate

    // At /2 and /8, reserved group-10 values with f5[1]=1 may alias
    // SLT controls; /1 and /4 retain the timing-better exact decode.
    wire slt_op = ((W == 2) || (W == 8)) ?
        (register_alu_plane & ~f5[2] & f5[1]) :
        (ordinary_alu_op & ~f5[2] & f5[1]);
    wire signed_compare = ~instr_q[3];
    // SRLI/SRAI (01_100/101) and SLLI (01_111) repeat EXECUTE bbb+1
    // times.
    wire right_shift_op =
        register_group & f_group_01 & f5[2] & ~f5[1];
    // MUL rd, ra, rb takes 16 EXECUTE passes.  The product accumulates in rd
    // via the RF read-old/write-new path, ra doubles through data_stream_q's
    // SLLI recycle path, and rb parks in address_stream_q.  mul_bit_buffer_q
    // emits one bit per pass and reloads W bits at each W-pass boundary.
    // The final pass refills the fetch address stream.
    reg  [W-1:0] mul_bit_buffer_q;
    wire mul_bit = mul_bit_buffer_q[0];
    wire multiply_op = register_group & f_group_00 & (&f5[2:0]);
    wire left_shift_op = register_group & f_group_01 &
                         f5[2] & f5[1] & f5[0];
    wire variable_shift_op = right_shift_op | left_shift_op;
    wire arithmetic_shift = f5[0];
    wire funnel_right_op = funnel_op & bbb[0];
    // SLLI and MUL retain their shared left-shift path. FSL1 uses the adder.
    wire use_left_shift_path = f5[1] & f5[0];
    // Previous slice's MSB, used as the SLLI carry-in.
    reg left_shift_carry_q;
    reg  [3:0] repeat_pass_idx_q;
    localparam [3:0] MUL_RELOAD_MASK =
        (W == 1) ? 4'h0 : (W == 2) ? 4'h1 :
        (W == 4) ? 4'h3 : 4'h7;
    wire mul_reload_boundary =
        (repeat_pass_idx_q & MUL_RELOAD_MASK) == MUL_RELOAD_MASK;
    // ~trap_active: a preempted shift/MUL must not drive the pass loop -- the
    // looping trap EXECUTE re-parks pc_carry_q and corrupts EPC.
    wire repeat_exec = (variable_shift_op | multiply_op) & ~trap_active &
                       (repeat_pass_idx_q != 4'hF);
    // Pass zero starts with a cleared product.
    wire mul_clear_product = multiply_op & in_execute &
                             (repeat_pass_idx_q == 4'd0);
    wire shift_writeback_op = variable_shift_op | funnel_right_op;

    // Native LDX uses 01_000. Reserved 01_001 may alias its indexed path but
    // is never a program load. LDB/LDPH share 01_010, LDBS uses 01_110, and
    // STB uses 01_011. For LDPH, bbb=011 is a modifier; aaa is the sole source.
    wire register_memory_plane = register_group & f_group_01;
    wire direct_memory_plane = register_memory_plane & f5[1];
`ifdef RISCC_TINY_DIRECT_PLANE_FACTOR
    wire register_store_op = direct_memory_plane & ~f5[2] & f5[0];
    wire native_load_op = register_memory_plane & ~f5[2] & ~f5[1];
    wire direct_load_op = direct_memory_plane & ~f5[0];
`else
    wire register_store_op = register_memory_plane & ~f5[2] &
                             f5[1] & f5[0];
    wire native_load_op = register_memory_plane & ~f5[2] & ~f5[1];
    wire direct_load_op = register_memory_plane & f5[1] & ~f5[0];
`endif
`ifdef RISCC_TINY_W2_OPT
    wire register_memory_op = register_memory_plane &
                              (~f5[2] | (f5[1] & ~f5[0]));
    // W=2 benefits from factoring the broad memory plane before removing STB.
    // Other widths retain their selected decode exactly after elaboration.
    wire indexed_mem_op = (W == 2) ?
        (register_memory_op & ~register_store_op) :
        (W == 8) ?
            (register_memory_plane &
             ((~f5[2] & ~f5[1]) | (f5[1] & ~f5[0]))) :
            (native_load_op | (register_memory_plane & f5[1] & ~f5[0]));
`else
    // The direct /8 sum-of-products form is materially faster on both targets;
    // it is area-neutral on iCE40/ECP5 block RF and costs one ECP5 LUTRAM site.
    wire indexed_mem_op = (W == 8) ?
        (register_memory_plane &
         ((~f5[2] & ~f5[1]) | (f5[1] & ~f5[0]))) :
        (native_load_op | (register_memory_plane & f5[1] & ~f5[0]));
`endif

`ifdef RISCC_TINY_CONTROL_NORMALIZE
    // Capture normalization presents the former internal control layout:
    // returns use bbb=000, direct IE controls use bbb=110, and every ddd bit
    // carries the selected IE value.
    wire control_ie_value = ddd[2];
    wire return_op = system_op & ~bbb[1] & ~bbb[0];
    wire return_sets_ie = return_op & control_ie_value &
                          ((W == 1) ? f5[1] : ~bbb[2]);
    wire ie_control_op = system_op & bbb[2] & bbb[1];
    wire ie_write_op = ie_control_op | return_sets_ie;
    wire ie_next = control_ie_value;
    wire register_jal_op = system_op & ~bbb[2] & ~bbb[1] & bbb[0];
    wire register_target_op = system_op & ~bbb[2] & ~bbb[1];
    wire register_link_data_op = register_target_op;
    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = register_jal_op | jal16_target_phase_q;
`else
    // All controls share bbb=000. ddd[1] selects return versus direct IE
    // control; ddd[2] and ddd[0] duplicate the new/set IE value. Thus
    // 000/101 are RET/RETI and 010/111 are CLI/STI.
    wire control_ie_value = ddd[2];
    wire control_plane = system_op & ~bbb[1] & ~bbb[0];
    // RET feeds the old value back; RETI/STI force one and CLI forces zero.
    // Equivalent Boolean forms route differently after width specialization.
`ifdef RISCC_TINY_W4_CONTROL
    wire control_ie_next = control_ie_value | (~ddd[1] & ie_q);
`else
`ifdef RISCC_ECP5
    wire control_ie_next = (W == 2) ?
        (control_ie_value | (~ddd[1] & ie_q)) :
        ~(~control_ie_value & (ddd[1] | ~ie_q));
`else
    wire control_ie_next =
        ~(~control_ie_value & (ddd[1] | ~ie_q));
`endif
`endif
    // Reserved bbb=101 aliases JALR, allowing the register-target plane to
    // share one mux-shaped decode between packed returns and register jumps.
    wire register_jal_op = system_op & ~bbb[1] & bbb[0];
`ifdef RISCC_ECP5
`ifdef RISCC_TINY_W4_CONTROL
    wire register_target_op = system_op & ~bbb[1] &
                              ~(~bbb[0] & ddd[1]);
`else
    wire register_target_op = system_op & ~bbb[1] &
                              (bbb[0] | ~ddd[1]);
`endif
`else
    wire register_target_op = system_op & ~bbb[1] &
                              (bbb[0] | ~ddd[1]);
`endif
    // CLI/STI never write the RF, so either the exact or broad target plane
    // is valid here; select the smaller mapping after width specialization.
`ifdef RISCC_TINY_W4_CONTROL
    wire register_link_data_op = register_target_op;
`else
`ifdef RISCC_ECP5
    wire register_link_data_op =
        ((W == 1) || (W == 2) || (W == 4)) ? register_target_op :
                                              (system_op & ~bbb[1]);
`else
    wire register_link_data_op = system_op & ~bbb[1];
`endif
`endif
    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = register_jal_op | jal16_target_phase_q;
    wire ie_write_op = control_plane;
    wire ie_next = control_ie_next;
`endif

    wire store_op = (imm_mem_group & instr_q[14]) | register_store_op;
    wire load_op = (imm_mem_group & ~instr_q[14]) | indexed_mem_op;
    wire mem_op = store_op | load_op;
    wire byte_access = direct_memory_plane & ~bbb[0];
    wire sign_extend_byte = f5[2];
    // Ordinary ALU operations stage bbb. Funnels and LDPH stage aaa through
    // the same pass; LDPH then reuses it as both address-adder operands.
`ifdef RISCC_TINY_DIRECT_STREAM_INDEX
    wire alu_uses_rb_stream = ordinary_alu_op |
                              (indexed_mem_op & ~f5[1]);
`elsif RISCC_TINY_DIRECT_STREAM_SUBTRACT
    wire alu_uses_rb_stream =
        (ordinary_alu_op | indexed_mem_op) & ~direct_load_op;
`else
    wire alu_uses_rb_stream = ordinary_alu_op | native_load_op;
`endif
    wire needs_rb_pass = alu_uses_rb_stream | funnel_op;
    wire needs_operand_pass =
        needs_rb_pass | (indexed_mem_op & ~byte_access);
    wire needs_init_pass = mem_op | slt_op | multiply_op | funnel_op;

    // ------------------------------------------------------------------
    // System profile
    // ------------------------------------------------------------------
    reg ie_q;
    reg trap_q;
    // Missing optional ops are undefined on builds that lack them.
    // IRQ enters via word 2.
    wire take_irq = ie_q & irq;
    wire trap_active = trap_q;

    // Set after the long head and cleared after its extension executes.
    reg jal16_target_phase_q;

    // ------------------------------------------------------------------
    // Register file: 16 regs x 16 bits in one synchronous RAM (one EBR),
    // addressed {reg, slice}, read one W-bit slice ahead of use.
    //
    // Read schedule (one stream at a time):
    //   INIT2 first lap : bbb/aaa -> data_stream_q    (two-source ops / LDPH)
    //   INIT            : aaa -> ALU / ddd -> funnel stream
    //   store-data lap  : rd  -> data_stream_q        (MEM_XFER normally;
    //                                                   second INIT2 for
    //                                                   wide ECP5 Full)
    //   EXECUTE         : rs1 -> ALU / pc_q   (single-stage ops)
    // ------------------------------------------------------------------
    // This private define compile-removes the alternate scheduler everywhere
    // except the one mapping that benefits from it; it is not a build option.
`ifdef RISCC_ECP5
`define RISCC_TINY_SPLIT_STORE_SCHEDULE
`endif
`ifdef RISCC_TINY_SPLIT_STORE_SCHEDULE
    // A second INIT2 store-data lap maps smaller for ECP5 Full /4 and /8.
    // /1 and /2 keep the normal MEM_XFER lap.
    localparam STORE_DATA_IN_SECOND_INIT2 = (W >= 4);
    reg init_pass_done_q;
    wire init2_operand_pass =
        in_init2 &
        (~STORE_DATA_IN_SECOND_INIT2 | ~init_pass_done_q);
    wire store_data_init2_pass =
        in_init2 & STORE_DATA_IN_SECOND_INIT2 & init_pass_done_q;
    wire store_data_mem_pass =
        in_mem_xfer & ~STORE_DATA_IN_SECOND_INIT2 & store_op;
    wire memory_stream_pass =
        in_mem_xfer & (STORE_DATA_IN_SECOND_INIT2 | ~store_op);
    wire init_after_init2 =
        needs_init_pass &
        (~STORE_DATA_IN_SECOND_INIT2 | ~init_pass_done_q);
`else
    localparam STORE_DATA_IN_SECOND_INIT2 = 1'b0;
    wire init_pass_done_q = 1'b0;
    wire init2_operand_pass = in_init2;
    wire store_data_init2_pass = 1'b0;
    wire store_data_mem_pass = in_mem_xfer & store_op;
    wire memory_stream_pass = in_mem_xfer & ~store_op;
    wire init_after_init2 = needs_init_pass;
`endif
    // bbb[0] is the bank-select bit: 0 reads S[aaa], 1 writes S[ddd]
    // (links share MTS's write path; CLI/STI have no RF traffic).
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = (system_op & bbb[0]) | jal16_target_phase_q;
    // At /8, the natural aaa fallback is smaller than the equivalent operand
    // mux; narrower mappings retain the direct mux. Both schedules read aaa in
    // INIT2 and ddd in INIT/EXECUTE.
    wire source_is_rd;
    wire rf_read_rb;
    wire rf_read_rd;
    wire [2:0] rf_operand_reg;
    wire [2:0] rf_src_low;
    generate
        if (W == 8) begin : g_funnel_aaa_fallback
            wire rf_operand_pass =
                in_decode | (init2_operand_pass & ~last_slice);
            assign source_is_rd = immediate_group;
            assign rf_read_rb =
                (alu_uses_rb_stream & rf_operand_pass) |
                (multiply_op & ((in_init2 & last_slice) |
                                (in_init & ~last_slice)));
            assign rf_read_rd = (funnel_op & ~rf_operand_pass) |
                (in_init & last_slice & (store_op | multiply_op)) |
                store_data_init2_pass |
                store_data_mem_pass |
                (in_execute & multiply_op);
            assign rf_operand_reg = bbb;
        end else begin : g_funnel_operand_mux
            assign source_is_rd = immediate_group | funnel_op;
            assign rf_read_rb =
                (needs_rb_pass &
                 (in_decode | (init2_operand_pass & ~last_slice))) |
                (multiply_op & ((in_init2 & last_slice) |
                                (in_init & ~last_slice)));
            assign rf_read_rd =
                (in_init & last_slice & (store_op | multiply_op)) |
                store_data_init2_pass |
                store_data_mem_pass |
                (in_execute & multiply_op);
`ifdef RISCC_ECP5
`ifdef RISCC_ECP5_BLOCK_RF
            assign rf_operand_reg = (W == 4) ?
                (f5[4] ? aaa : bbb) :
                (bbb ^ ({3{f5[4]}} & (bbb ^ aaa)));
`else
            assign rf_operand_reg =
                bbb ^ ({3{f5[4]}} & (bbb ^ aaa));
`endif
`else
            assign rf_operand_reg = (W == 4) ?
                (f5[4] ? aaa : bbb) :
                (bbb ^ ({3{f5[4]}} & (bbb ^ aaa)));
`endif
        end
    endgenerate
    // The sum-of-products fallback pairs with the ternary operand mux above
    // for the timing-better generic and block-RF /4 mappings. LUTRAM /4 packs
    // better with the simple source mux.
`ifdef RISCC_ECP5
`ifdef RISCC_ECP5_BLOCK_RF
    assign rf_src_low = (W == 4) ?
        ((aaa & {3{~source_is_rd}}) | (ddd & {3{source_is_rd}})) :
        (source_is_rd ? ddd : aaa);
`else
    assign rf_src_low = source_is_rd ? ddd : aaa;
`endif
`else
    assign rf_src_low = (W == 4) ?
        ((aaa & {3{~source_is_rd}}) | (ddd & {3{source_is_rd}})) :
        (source_is_rd ? ddd : aaa);
`endif
    wire [3:0] rf_src_reg = {src_system_bank, rf_src_low};
    wire [2:0] rf_dst_low = ddd & {3{~(trap_active | cmpi_op)}};
    wire [3:0] rf_dst_reg = {trap_active | dst_system_bank, rf_dst_low};
    wire [3:0] rf_read_reg = rf_read_rb ? {1'b0, rf_operand_reg} :
                                 rf_read_rd ? {1'b0, ddd} : rf_src_reg;

    // STB to the high byte lane: read the store data rotated by 8 so the
    // byte lands in data_stream_q[15:8], avoiding a byte-duplication mux.
    wire store_high_byte = byte_access & store_op;
    wire rf_read_lane_flip =
        ((store_data_init2_pass | store_data_mem_pass) &
         store_high_byte & address_stream_q[0]) |
        (in_init & last_slice & store_high_byte & address_stream_q[W]);
    wire [SLICE_BITS-1:0] byte_lane_offset =
        {rf_read_lane_flip, {(SLICE_BITS-1){1'b0}}};
    wire [SLICE_BITS-1:0] rf_read_slice =
        (slice_count_en ? slice_idx_next : {SLICE_BITS{1'b0}}) ^
        byte_lane_offset;

    wire writes_rd = immediate_alu_op | register_write_op | load_op |
                     variable_shift_op | multiply_op |
                     system_move_op |
                     (link_dest_nonzero & link_context);
    wire rf_we = in_execute & (trap_active | writes_rd);

    wire [W-1:0] rf_rdata;
    wire [W-1:0] rf_wdata;

    // High-lane byte loads rotate on the write side: slices leave
    // data_stream_q in place and land in rd two counts later.
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
    // LUI rotates the zero-extended imm8 stream by one byte.  Since SLICES is
    // a power of two, flipping the counter MSB performs that rotation.
    // ADDI/CMPI and branches sign-extend. Their selectors factor as
    // 01x and 111; the remaining immediate ALU operations zero-extend.
    wire sign_extend_imm = (W == 1) ?
        (~instr_q[15] | add_immediate_op | cmpi_op | branch_group) :
        (~instr_q[15] |
         (immediate_group & aaa[1] & (~aaa[2] | aaa[0])));
    wire lui_op = immediate_group & (aaa == 3'b001);
    wire [SLICE_BITS-1:0] immediate_slice_index =
        slice_idx_q ^ {lui_op, {(SLICE_BITS-1){1'b0}}};
    wire [W-1:0] immediate_low_slice =
`ifdef RISCC_TINY_DIRECT_IMM_MASK
        instr_q[((immediate_slice_index * W) & 7) +: W] &
        {W{~(indexed_mem_op & f5[1])}};
`else
        instr_q[((immediate_slice_index * W) & 7) +: W];
`endif
    wire [W-1:0] imm_slice = immediate_slice_index[SLICE_BITS-1] ?
                           {W{sign_extend_imm & instr_q[7]}} :
                           immediate_low_slice;

    // ------------------------------------------------------------------
    // Serial ALU (also generates the memory address)
    // ------------------------------------------------------------------
    // The smaller store schedule trades one extra pass for less logic in
    // Sys /1 and Full /4,/8.
    wire slow_direct_store = (W == 4) | (W == 8);
    wire direct_store_stream_base = register_store_op & slow_direct_store;
    wire alu_a_enable =
        ~(immediate_group & ~aaa[2] & ~aaa[1]) & ~direct_store_stream_base;
`ifdef RISCC_TINY_DIRECT_ZERO_MERGED
    wire alu_b_zero = system_op |
                     (register_memory_plane & f5[1] & ~bbb[0] &
                      ((W <= 2) | ~f5[0]));
`elsif RISCC_TINY_DIRECT_IMM_MASK
    wire alu_b_zero = system_op |
                     ((W != 1) & register_store_op & ~slow_direct_store);
`elsif RISCC_TINY_DIRECT_SOURCE_EXACT
    wire alu_b_zero = system_op |
                     ((W != 1) & register_store_op & ~slow_direct_store);
`else
    wire alu_b_zero = system_op | (direct_load_op & ~bbb[0]) |
                     ((W != 1) & register_store_op & ~slow_direct_store);
`endif
    // Logic operations ignore the adder, so their low function bits may
    // alias this control without decoding f5[2].
    wire alu_subtract =
        (ordinary_alu_op & (f5[1] | f5[0])) | cmpi_op;

    // During SLT EXECUTE, force both operands (and alu_b_raw inversion) to
    // zero so the comparison result rides the parked carry into result bit 0.
    wire slt_execute = slt_op & in_execute;

    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute & ~mul_clear_product}};
    wire [W-1:0] alu_b_raw =
        ((needs_operand_pass | multiply_op | direct_store_stream_base) ?
         data_stream_q[W-1:0] :
`ifdef RISCC_TINY_DIRECT_SOURCE_EXACT
         (imm_slice & {W{~direct_load_op}})) &
`else
         imm_slice) &
`endif
                       {W{~(alu_b_zero | slt_execute) &
                          (~multiply_op | (in_execute & mul_bit))}};
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

`ifdef RISCC_FMAX_TINY
`ifdef RISCC_ECP5
`ifdef RISCC_TINY_DIRECT_STREAM_INDEX
`define RISCC_TINY_FULL_ECP5_W8_FMAX
`endif
`else
`ifdef RISCC_TINY_DIRECT_PLANE_FACTOR
`ifdef RISCC_TINY_DIRECT_STREAM_INDEX
`define RISCC_TINY_FULL_GENERIC_W8_FMAX
`endif
`endif
`endif
`endif
`ifdef RISCC_TINY_FULL_ECP5_W8_FMAX
    wire timing_init_carry =
        (funnel_op & data_stream_q[W-1]) |
        (slt_op & less_than_result);
    always @(posedge clk)
        alu_carry_q <= (in_init & last_slice) ? timing_init_carry :
                       alu_active ?
                           (alu_sum_ext[W] & ~(last_slice & repeat_exec)) :
                           alu_subtract;
`elsif RISCC_TINY_FULL_GENERIC_W8_FMAX
    always @(posedge clk)
        alu_carry_q <= (funnel_op & in_init & last_slice) ?
                           data_stream_q[W-1] :
                       (slt_op & in_init & last_slice) ? less_than_result :
                       alu_active ?
                           (alu_sum_ext[W] & ~(last_slice & repeat_exec)) :
                           alu_subtract;
`else
`ifdef RISCC_ECP5
    // In INIT, memory operations never consume the ALU carry. Let those dead
    // values alias the funnel/SLT seed mux to reduce the carry-input cone.
    always @(posedge clk)   // each MUL pass adds afresh: clear between passes
        alu_carry_q <= (in_init & last_slice) ?
                           (~multiply_op &
                            (f5[4] ? data_stream_q[W-1] : less_than_result)) :
                       alu_active ?
                           (alu_sum_ext[W] & ~(last_slice & repeat_exec)) :
                           alu_subtract;
`else
    generate
        if (W == 4) begin : g_exact_carry_seed
            wire carry_seed_op = funnel_op | slt_op;
            always @(posedge clk)
                alu_carry_q <= (carry_seed_op & in_init & last_slice) ?
                                   (f5[4] ? data_stream_q[W-1] :
                                            less_than_result) :
                               alu_active ?
                                   (alu_sum_ext[W] &
                                    ~(last_slice & repeat_exec)) :
                                   alu_subtract;
        end else begin : g_dead_carry_alias
            // Memory INIT carry is dead before EXECUTE and may share this mux.
            always @(posedge clk)
                alu_carry_q <= (in_init & last_slice) ?
                                   (~multiply_op &
                                    (f5[4] ? data_stream_q[W-1] :
                                             less_than_result)) :
                               alu_active ?
                                   (alu_sum_ext[W] &
                                    ~(last_slice & repeat_exec)) :
                                   alu_subtract;
        end
    endgenerate
`endif
`endif
`ifdef RISCC_TINY_FULL_ECP5_W8_FMAX
`undef RISCC_TINY_FULL_ECP5_W8_FMAX
`endif
`ifdef RISCC_TINY_FULL_GENERIC_W8_FMAX
`undef RISCC_TINY_FULL_GENERIC_W8_FMAX
`endif

    wire logic_op = (immediate_alu_op & aaa[2]) | (ordinary_alu_op & f5[2]);
    // 00 AND, 01 OR, 10 XOR.
    wire [1:0] logic_select = immediate_group ? aaa[1:0] : f5[1:0];
    wire [W-1:0] logic_result =
        ((rf_rdata ^ alu_b_raw) &
         {W{logic_select[1] | logic_select[0]}}) |
        ((rf_rdata & alu_b_raw) & {W{~logic_select[1]}});
    wire [W-1:0] alu_result = logic_op ? logic_result : alu_sum;

    // ------------------------------------------------------------------
    // Address stream: data byte address or next fetch address
    // During EXECUTE it shifts in next_pc_slice<<1, avoiding a fetch/data
    // address mux at the memory port.
    // ------------------------------------------------------------------
    reg [15:0] address_stream_q;
    reg pc_msb_q;
    wire [W-1:0] next_fetch_address_slice =
        (next_pc_slice << 1) | {{(W-1){1'b0}}, pc_msb_q};
    always @(posedge clk) begin
        pc_msb_q <= in_execute ? next_pc_slice[W-1] : 1'b0;
        if (rst)
            address_stream_q <= {RESET_PC[14:0], 1'b0};
        // During MUL, address_stream_q parks the multiplier.  Rotate one
        // slice at each W-pass boundary; the final pass refills the fetch
        // address stream.
        else if (in_init | (in_execute & (~(multiply_op & repeat_exec) |
                                       (last_slice & mul_reload_boundary))))
            address_stream_q <= {
                in_init ?
                          (((W == 1) & register_store_op &
                            ~slow_direct_store) ? rf_rdata : alu_sum) :
                (multiply_op & repeat_exec) ? address_stream_q[W-1:0] :
                next_fetch_address_slice,
                address_stream_q[15:W]};
    end

    // Shift operations stream ra into data_stream_q. Funnels instead stage ra,
    // then stream old rd while retaining ra[0] for FSR1; FSL1 seeds the adder
    // carry directly from staged ra[15].
    reg funnel_bit_q;
`ifdef RISCC_INFERRED_SYNC_RF
    // The equivalent f5[4] boundary maps better at the middle serial widths.
    localparam F4_SHIFT_BOUNDARY = (W == 2) || (W == 4);
    wire right_shift_input = last_slice ?
        (F4_SHIFT_BOUNDARY ?
             (f5[4] ? funnel_bit_q :
                      (arithmetic_shift & data_stream_q[W-1])) :
             (f5[3] ? (arithmetic_shift & data_stream_q[W-1]) :
                      funnel_bit_q)) :
        data_stream_q[W];
`else
    wire right_shift_input = last_slice ?
        (f5[3] ? (arithmetic_shift & data_stream_q[W-1]) :
                   funnel_bit_q) :
        data_stream_q[W];
`endif
    wire [W-1:0] right_shift_slice =
        (data_stream_q[W-1:0] >> 1) |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));
    // A left shift appends the previous slice's delayed MSB.
    wire left_shift_input = ~first_slice & left_shift_carry_q;
    wire [W-1:0] shift_result_slice = use_left_shift_path ?
        ((data_stream_q[W-1:0] << 1) |
         {{(W-1){1'b0}}, left_shift_input}) :
        right_shift_slice;

    // ------------------------------------------------------------------
    // Data stream: operands, stores, loads, and JAL16 targets
    // ------------------------------------------------------------------
    reg [15:0] data_stream_q;
    reg load_fill_q;
    reg memory_lane_q;
    // The stream shifts on every counted cycle, including MEM_XFER.  INIT2
    // fills and consumers shift too; idle passes rotate don't-care data that
    // the next fill/load overwrites.
    wire [W-1:0] memory_read_slice =
        mem_rdata[slice_idx_q * W +: W];
    // W=1 can select the requested byte directly while the word is streamed.
    // Wider variants stream the whole word and rotate the RF write address.
    wire byte_load = byte_access & load_op;
    wire w1_memory_slice_high = byte_load ? address_stream_q[0] :
                                            slice_idx_q[SLICE_BITS-1];
    wire w1_memory_data_bit =
        mem_rdata[(w1_memory_slice_high * 8) +
                  ((slice_idx_q * W) & 7)];
    wire w1_byte_fill_bit = sign_extend_byte &
                            mem_rdata[(address_stream_q[0] * 8) + 7];
    wire w1_load_stream_bit = (byte_load & slice_idx_q[SLICE_BITS-1]) ?
                              w1_byte_fill_bit : w1_memory_data_bit;
    wire [W-1:0] load_stream_slice = (W == 1) ?
        {{(W-1){1'b0}}, w1_load_stream_bit} : memory_read_slice;
    always @(posedge clk) begin
        // MUL holds A in data_stream_q during INIT.
        if (slice_count_en & ~(in_init & multiply_op))
            // Repeated shift/MUL passes recycle the stream's shifted output.
            data_stream_q <= {
                memory_stream_pass ? load_stream_slice :
                (in_execute & (variable_shift_op | multiply_op)) ?
                    shift_result_slice : rf_rdata,
                data_stream_q[15:W]};
        if (in_mem_xfer) begin
            memory_lane_q <= address_stream_q[0];
            load_fill_q <= sign_extend_byte &
                           (address_stream_q[0] ?
                                mem_rdata[15] : mem_rdata[7]);
        end
        if (in_init & first_slice)
            funnel_bit_q <= data_stream_q[0];
        left_shift_carry_q <= data_stream_q[W-1];
        if (in_decode)
            repeat_pass_idx_q <= multiply_op ? 4'd0 : {1'b1, ~bbb};
        else if (in_execute & last_slice & repeat_exec)
            repeat_pass_idx_q <= repeat_pass_idx_q + 1'b1;
    end

    generate
        // At W=1 the multiplier consumes a new bit every pass, so no
        // shiftable refill buffer is needed.
        if (W == 1) begin : g_w1_mul_bit
            always @(posedge clk)
                if ((in_init & last_slice & multiply_op) |
                    (in_execute & last_slice & repeat_exec & multiply_op))
                    mul_bit_buffer_q <= address_stream_q[1];
        end else begin : g_wide_mul_bits
            always @(posedge clk) begin
                if ((in_init & last_slice & multiply_op) |
                    (in_execute & last_slice & repeat_exec & multiply_op &
                     mul_reload_boundary))
                    mul_bit_buffer_q <= address_stream_q[(2*W)-1:W];
                else if (in_execute & last_slice & repeat_exec & multiply_op)
                    mul_bit_buffer_q <= mul_bit_buffer_q >> 1;
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Branch shadow: r0 zero/negative flags, updated on every r0 write
    // ------------------------------------------------------------------
    reg r0_zero_q;
    reg r0_negative_q;
    reg r0_zero_so_far_q;
    wire writes_r0 = rf_we & ~(|rf_dst_reg);

`ifdef RISCC_FMAX_TINY
`ifdef RISCC_ECP5
`ifdef RISCC_TINY_DIRECT_STREAM_INDEX
`define RISCC_TINY_FULL_W8_FMAX
`endif
`else
`ifdef RISCC_TINY_DIRECT_PLANE_FACTOR
`ifdef RISCC_TINY_DIRECT_STREAM_INDEX
`define RISCC_TINY_FULL_W8_FMAX
`endif
`endif
`endif
`endif
`ifdef RISCC_TINY_FULL_W8_FMAX
    // Under writes_r0, trap/link/EPC write data is unreachable.
    wire [W-1:0] r0_load_slice =
        (byte_access &
         (slice_idx_q[SLICE_BITS-1] ^ memory_lane_q)) ?
            {W{load_fill_q}} : data_stream_q[W-1:0];
    wire [W-1:0] r0_result_slice = load_op ? r0_load_slice :
        shift_writeback_op ? shift_result_slice : alu_result;
    wire r0_slice_zero = ~|r0_result_slice;
    always @(posedge clk)
        if (writes_r0) begin
            r0_zero_so_far_q <=
                r0_slice_zero & (first_slice | r0_zero_so_far_q);
            if (last_slice) begin
                r0_zero_q <= r0_slice_zero & r0_zero_so_far_q;
                r0_negative_q <= load_high_byte ? load_fill_q :
                                                    r0_result_slice[W-1];
            end
        end
`else
    // Keeping the architectural zero flag stable until the final /4 slice
    // maps one LUT smaller. Other widths can accumulate directly in the flag
    // because no following instruction observes an intermediate serial value.
    always @(posedge clk)
        if (writes_r0) begin
            if (W == 4) begin
                r0_zero_so_far_q <=
                    (rf_wdata == {W{1'b0}}) &
                    (first_slice | r0_zero_so_far_q);
                if (last_slice)
                    r0_zero_q <=
                        (rf_wdata == {W{1'b0}}) & r0_zero_so_far_q;
            end else
                r0_zero_q <= (rf_wdata == {W{1'b0}}) &
                             (first_slice | r0_zero_q);

            if (W == 1)
                // Intermediate serial bits are unobservable; the final write
                // leaves bit 15 or a byte-load fill in the flag.
                r0_negative_q <= rf_wdata[0];
            else if (last_slice)
                r0_negative_q <=
                    load_high_byte ? load_fill_q : rf_wdata[W-1];
        end
`endif
`ifdef RISCC_TINY_FULL_W8_FMAX
`undef RISCC_TINY_FULL_W8_FMAX
`endif

    wire branch_taken = branch_group & ~ddd[2] &
        ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]);
    wire use_pc_offset = branch_taken | jmp8_op;

    // ------------------------------------------------------------------
    // PC stream and serial adder (PC + offset + forced carry 1).
    // The adder output is also every link/EPC value: PC+1 for JALR/JAL16;
    // for IRQ entry the parked carry is forced to 0 (and the
    // offset gated off) so the same adder yields the raw preempted pc_q.
    // ------------------------------------------------------------------
    reg [15:0] pc_q;
    reg pc_carry_q;

    wire [W-1:0] pc_offset_slice = use_pc_offset ? imm_slice : {W{1'b0}};
    wire [W:0] pc_sum_ext = {1'b0, pc_q[W-1:0]} +
                            {1'b0, pc_offset_slice} +
                            {{W{1'b0}}, pc_carry_q};
    wire [W-1:0] pc_sum = pc_sum_ext[W-1:0];

    // Park at one through repeated shift/MUL passes.
    always @(posedge clk)
        pc_carry_q <= (in_execute & ~repeat_exec) ? pc_sum_ext[W]
                                                   : ~(in_decode & take_irq);

    // Register jumps stream rs1 into data_stream_q during INIT2, sharing the
    // same PC path used by a JAL16 target word.
    wire pc_from_register = register_target_op;
    wire [15:0] irq_pc_word = 16'h0002 >> (slice_idx_q * W);
    wire [W-1:0] irq_pc_slice = irq_pc_word[W-1:0];
    wire [W-1:0] next_pc_slice =
        trap_active ? irq_pc_slice :
        (pc_from_register | jal16_target_phase_q) ?
                                                data_stream_q[W-1:0] :
                                                 pc_sum;

    always @(posedge clk)
        if (rst)
            pc_q <= RESET_PC;
        else if (in_execute & ~repeat_exec)
            pc_q <= {next_pc_slice, pc_q[15:W]};

    // rd write data; EPC uses the same link path.
    wire [W-1:0] link_slice = pc_sum;
    wire [W-1:0] load_slice =
        ((W != 1) & byte_access &
         (slice_idx_q[SLICE_BITS-1] ^ memory_lane_q)) ?
            {W{load_fill_q}} : data_stream_q[W-1:0];
    assign rf_wdata =
        (trap_active | register_link_data_op | jal16_target_phase_q) ?
            link_slice :
        load_op ? load_slice :
        shift_writeback_op ? shift_result_slice :
        alu_result;  // MUL passes write the sum

    // ------------------------------------------------------------------
    // System profile state
    // ------------------------------------------------------------------
`ifdef RISCC_ECP5
    // Keep this top-level for ECP5; Yosys mis-lowers the same logic under a
    // constant generate branch.
    always @(posedge clk) begin
        if (in_decode) begin
            trap_q <= take_irq;
            if (ie_write_op)
                ie_q <= ie_next;
        end else if (in_execute & trap_q & last_slice)
            ie_q <= 1'b0;
        if (rst) begin
            ie_q   <= 1'b0;
            trap_q <= 1'b0;
        end
    end
`else
    localparam DECODE_IE_UPDATE = (W == 2) || (W == 4);
    // Updating controls at decode packs best for W=2/4.  IE is not sampled
    // again until the next decode boundary, so this is architecturally
    // equivalent to the execute-boundary form used for W=1/8 and ECP5.
    generate
        if (DECODE_IE_UPDATE) begin : g_decode_ie_update
            always @(posedge clk) begin
                if (in_decode) begin
                    trap_q <= take_irq;
                    if (ie_write_op)
                        ie_q <= ie_next;
                end
                if (in_execute & trap_q & last_slice)
                    ie_q <= 1'b0;
                if (rst) begin
                    ie_q   <= 1'b0;
                    trap_q <= 1'b0;
                end
            end
        end else begin : g_execute_ie_update
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
        end
    endgenerate
`endif

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        case (state_q)
            ST_FETCH_WAIT:
                state_q <= ST_FETCH_CAPTURE;
            ST_FETCH_CAPTURE:
                state_q <= ST_DECODE;
            ST_DECODE:
                state_q <= take_irq ? ST_EXECUTE :
                    (needs_operand_pass |
                     direct_store_stream_base |
                     pc_from_register |
                     variable_shift_op | multiply_op) ? ST_INIT2 :
                    needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT2:
                if (last_slice)
                    state_q <= init_after_init2 ? ST_INIT : ST_EXECUTE;
            ST_INIT:
                if (last_slice)
                    state_q <= store_op ?
                               (STORE_DATA_IN_SECOND_INIT2 ? ST_INIT2 :
                                                             ST_MEM_XFER) :
                               mem_op   ? ST_MEM_WAIT : ST_EXECUTE;
            // Loads and JAL16 target words observe one memory-wait cycle.
            ST_MEM_WAIT:
                state_q <= ST_MEM_XFER;
            ST_MEM_XFER:
                if (last_slice)
                    state_q <= ST_EXECUTE;
            ST_EXECUTE:
                if (last_slice & ~repeat_exec)
                    state_q <= (long_form_op & ~jal16_target_phase_q &
                                ~trap_active) ?
                               ST_MEM_WAIT : ST_FETCH_WAIT;
        endcase
        if (rst)
            state_q <= ST_FETCH_WAIT;

`ifdef RISCC_TINY_SPLIT_STORE_SCHEDULE
        if (in_fetch_capture)
            init_pass_done_q <= 1'b0;
        if (in_init & last_slice)
            init_pass_done_q <= 1'b1;
`endif

        slice_idx_q <= slice_count_en ? slice_idx_next :
                                       {SLICE_BITS{1'b0}};

        if (in_fetch_capture) begin
`ifdef RISCC_TINY_CONTROL_NORMALIZE
            instr_q <= {fetch_instr[15], fetch_instr[0], fetch_instr[13:0]};
`ifdef RISCC_TRACE
            trace_instr_q <= mem_rdata;
`endif
`else
            instr_q <= {mem_rdata[15], mem_rdata[0], mem_rdata[13:0]};
`endif
            register_format_q <= mem_rdata[14];
        end

        if (in_execute & last_slice)
            jal16_target_phase_q <= long_form_op & ~jal16_target_phase_q &
                                  ~trap_active;
        if (rst)
            jal16_target_phase_q <= 1'b0;

    end

    // ------------------------------------------------------------------
    // Memory interface.  Stores commit on EXECUTE's first cycle, while both
    // streams still hold their pre-shift address and data.
    // ------------------------------------------------------------------
    // address_stream_q shadows pc_q as a byte address.
    assign mem_addr = address_stream_q[15:1];
    assign mem_we = in_execute & first_slice & store_op & ~trap_active;
    assign mem_wdata = data_stream_q;  // STB data is pre-rotated to its lane.
    assign mem_wmask = byte_access ?
                       {address_stream_q[0], ~address_stream_q[0]} :
                       2'b11;

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = W;
    wire tr_commit_i = in_execute & last_slice & ~repeat_exec &
                       ~(long_form_op & ~jal16_target_phase_q &
                         ~trap_active);
    wire [SLICE_BITS-1:0] tr_wr_slice_i = slice_idx_q ^
        {load_high_byte, {(SLICE_BITS-1){1'b0}}};
    wire [14:0] tr_pc_i = pc_q[14:0];
`ifdef RISCC_TINY_CONTROL_NORMALIZE
    wire [15:0] tr_ir_i = trace_instr_q;
`else
    wire [15:0] tr_ir_i =
        {instr_q[15], register_format_q, instr_q[13:0]};
`endif
    wire        tr_ie_i = ie_q;
    wire        tr_rf_we_i = rf_we;
    wire        tr_rf_bank_i = rf_dst_reg[3];
    wire [2:0]  tr_rf_reg_i = rf_dst_reg[2:0];
    wire [3:0]  tr_rf_lsb_i = {tr_wr_slice_i, {W_LOG2{1'b0}}};
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif

`ifdef RISCC_TINY_SPLIT_STORE_SCHEDULE
`undef RISCC_TINY_SPLIT_STORE_SCHEDULE
`endif
endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
`endif
