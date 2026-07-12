// riscc_tiny.v : parameterized serial RISC-C core (W=1, 2, 4, or 8).
//
// Shared serial microarchitecture: doc/HARDWARE.md 'Implementation family' (branch
// shadow, one PC adder, address/data streams, and the INIT2 staging lap).
// W must be 1, 2, 4, or 8.  This is the canonical implementation of all
// four serial datapath widths.

`ifndef RISCC_TINY_V
`define RISCC_TINY_V
`default_nettype none

// Every tiny profile has SLT and LDBS.  sys adds variable shifts; full adds
// MUL, whose pass loop rides the shift machinery.

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
`ifndef RISCC_SYS
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd3 : 3'd2;
    localparam [2:0] ST_FETCH_CAPTURE = 3'd1;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 : 3'd0;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd0 : 3'd3;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd5 : 3'd4;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd6 : 3'd5;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd7 : 3'd6;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd4 : 3'd7;
`elsif RISCC_FULL
`ifdef RISCC_ECP5
    // ECP5 keeps the original wide encodings, where they pack best.
    localparam [2:0] ST_FETCH_WAIT    = (W <= 2) ? 3'd0 : 3'd3;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd3 : 3'd0;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd2 : 3'd1;
    localparam [2:0] ST_MEM_WAIT      = (W <= 2) ? 3'd1 : 3'd2;
    localparam [2:0] ST_EXECUTE       = (W <= 2) ? 3'd5 : 3'd6;
    localparam [2:0] ST_MEM_XFER      = (W <= 2) ? 3'd7 : 3'd5;
    localparam [2:0] ST_INIT          = 3'd4;
    localparam [2:0] ST_INIT2         = (W <= 2) ? 3'd6 : 3'd7;
`else
    localparam [2:0] ST_FETCH_WAIT    = (W == 2) ? 3'd0 :
                                               (W == 4) ? 3'd3 : 3'd0;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd2 :
                                               (W == 2) ? 3'd3 :
                                               (W == 4) ? 3'd0 : 3'd1;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd2 :
                                               (W == 4) ? 3'd1 : 3'd3;
    localparam [2:0] ST_MEM_WAIT      = (W <= 2) ? 3'd1 : 3'd2;
    localparam [2:0] ST_EXECUTE       = (W <= 2) ? 3'd5 : 3'd6;
    localparam [2:0] ST_MEM_XFER      = (W <= 2) ? 3'd7 : 3'd5;
    localparam [2:0] ST_INIT          = 3'd4;
    localparam [2:0] ST_INIT2         = (W <= 2) ? 3'd6 : 3'd7;
`endif
`else
`ifdef RISCC_ECP5
    // The area-minimum /4 encoding costs substantial ECP5 timing for one
    // site. Use the timing-tuned 200-site encoding instead.
    localparam ECP5_SYS_W4_TIMING = (W == 4);
`else
    localparam ECP5_SYS_W4_TIMING = 1'b0;
`endif
    localparam [2:0] ST_FETCH_WAIT    = (W == 1) ? 3'd0 :
                                               (W == 2) ? 3'd2 :
                        ECP5_SYS_W4_TIMING ? 3'd0 : 3'd1;
    localparam [2:0] ST_FETCH_CAPTURE = (W == 1) ? 3'd3 :
                                               (W == 2) ? 3'd1 : 3'd2;
    localparam [2:0] ST_DECODE        = (W == 1) ? 3'd2 :
                        ECP5_SYS_W4_TIMING ? 3'd3 : 3'd0;
    localparam [2:0] ST_MEM_WAIT      = (W == 1) ? 3'd1 :
                        ECP5_SYS_W4_TIMING ? 3'd1 : 3'd3;
    localparam [2:0] ST_EXECUTE       = (W == 1) ? 3'd7 :
                                               (W == 2) ? 3'd5 :
                        ECP5_SYS_W4_TIMING ? 3'd5 : 3'd6;
    localparam [2:0] ST_MEM_XFER      = (W == 1) ? 3'd6 :
                        ECP5_SYS_W4_TIMING ? 3'd7 : 3'd4;
    localparam [2:0] ST_INIT          = (W == 1) ? 3'd5 :
                        ECP5_SYS_W4_TIMING ? 3'd4 : 3'd7;
    localparam [2:0] ST_INIT2         = (W == 1) ? 3'd4 :
                                               (W == 2) ? 3'd6 :
                        ECP5_SYS_W4_TIMING ? 3'd6 : 3'd5;
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

    // Contiguous register-format fields: 11 ddd aaa fffff bbb.
    wire [1:0] op_class = instr_q[15:14];
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group  = ~op_class[1];                   // 00 LDW / 01 STW
    wire immediate_group = op_class[1] & ~op_class[0];    // 10 immediate/branch
    wire register_group  = op_class[1] &  op_class[0];    // 11 register

    wire branch_group = immediate_group & (aaa == 3'b111) & ~trap_active;
    wire immediate_alu_op = immediate_group & ~branch_group;
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    wire cmpi_op = immediate_group & (aaa == 3'b011);
    // Loose JMP8: reserved ccc=101/110/111 alias as JMP8.
    wire jmp8_op = branch_group & ddd[2];
`ifdef RISCC_SYS
    wire jal16_op = system_op & bbb[2] & ~bbb[1] & bbb[0];
`else
    // JAL16 is in the sys profile; min makes far calls with LDI16 + JAL.
    wire jal16_op = 1'b0;
`endif
    wire link_dest_nonzero = |ddd;   // Sd == S0 writes no link (plain jump)

    wire f_group_00 = ~f5[4] & ~f5[3];
    wire f_group_01 = ~f5[4] &  f5[3];
`ifdef RISCC_FULL
    // At W>1 the reserved 10_xxx plane may alias system operations.
    wire f_group_11 = f5[4] & (f5[3] | (W != 1));
`else
    wire f_group_11 = f5[4] & f5[3];
`endif
    wire system_op = register_group & f_group_11;

    wire slt_op = register_alu_op & ~f5[2] & f5[1];
    wire signed_compare = ~instr_q[3];
    // SHRI/SARI (01_100/101) shift by one in min. In sys/full EXECUTE repeats
    // bbb+1 times; SHLI occupies 01_111.
    wire right_shift_op = register_group & f_group_01 & f5[2] & ~f5[1];
`ifdef RISCC_FULL
    // MUL rd, ra, rb takes 16 EXECUTE passes.  The product accumulates in rd
    // via the RF read-old/write-new path, ra doubles through data_stream_q's
    // SHLI recycle path, and rb parks in address_stream_q.  mul_bit_buffer_q
    // emits one bit per pass and reloads W bits at each W-pass boundary.
    // The final pass refills the fetch address stream.
    reg  [W-1:0] mul_bit_buffer_q;
    wire mul_bit = mul_bit_buffer_q[0];
    wire multiply_op = register_group & f_group_00 & (&f5[2:0]);
`else
    wire mul_bit = 1'b0;
    wire multiply_op = 1'b0;
`endif
`ifdef RISCC_SYS
    wire left_shift_op = register_group & f_group_01 &
                         f5[2] & f5[1] & f5[0];
    wire variable_shift_op = right_shift_op | left_shift_op;
    wire arithmetic_shift = f5[0];
    wire use_left_shift_path = left_shift_op | multiply_op;
    // Previous slice's MSB, used as the SHLI carry-in.
    reg left_shift_carry_q;
`ifdef RISCC_FULL
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
`else
    reg  [2:0] repeat_pass_idx_q;
    // ~trap_active: see the FULL branch note -- preempted shifts must not loop
    wire repeat_exec = variable_shift_op & ~trap_active &
                       (repeat_pass_idx_q != 3'h7);
    wire mul_clear_product = 1'b0;
`endif
`else
    // Min: SHRI/SARI count-one only; immediate shifts are undefined.
    wire variable_shift_op = 1'b0;
    wire arithmetic_shift = f5[0];
    wire repeat_exec = 1'b0;
    wire mul_clear_product = 1'b0;
`endif
`ifndef RISCC_SYS
    // SHLI is undefined in min and may alias ordinary logic.
    wire register_alu_op = register_group & f_group_00;
`else
    wire register_alu_op = register_group & f_group_00 & ~(&f5[2:0]);
`endif
    wire any_shift_op = right_shift_op | variable_shift_op;

    // 01_000/010/110 are LDWX/LDB/LDBS; 01_011 is direct STB.
    // This placement makes every byte operation share f5[1].
    wire register_memory_plane = register_group & f_group_01;
    wire register_store_op = register_memory_plane & ~f5[2] &
                             f5[1] & f5[0];
`ifdef RISCC_FULL
    // The reserved 01_001 slot may alias an indexed load.  Factoring the
    // broad memory plane before removing STB maps smaller in full builds.
    wire register_memory_op = register_memory_plane &
                              (~f5[2] | (f5[1] & ~f5[0]));
    wire indexed_mem_op = register_memory_op & ~register_store_op;
`else
    wire indexed_mem_op = register_memory_plane & ~f5[0] &
                          (~f5[2] | f5[1]);
`endif

    // Register-indirect group; the bbb[2]=0 plane is mandatory:
    //   000 RET Sa   001 JAL Sd, ra   010 MFS rd, Sa   011 MTS Sd, ra
    //   100 RETI Sa  101 JAL16 Sd     110 CLI          111 STI
    wire return_op = system_op & ~bbb[1] & ~bbb[0];
    wire register_jal_op = system_op & ~bbb[2] & ~bbb[1] & bbb[0];
    wire system_move_op = system_op & ~bbb[2] & bbb[1];
`ifdef RISCC_SYS
    wire link_context = register_jal_op | jal16_target_phase_q;
    wire register_target_op = system_op & ~bbb[1] & ~(bbb[2] & bbb[0]);
`else
    // Min implements only the bbb[2]=0 plane; sys-only slots alias freely.
    wire link_context = system_op & ~bbb[1] & bbb[0];
    wire register_target_op = system_op & ~bbb[1];
`endif

    wire store_op = (imm_mem_group & op_class[0]) | register_store_op;
    wire load_op = (imm_mem_group & ~op_class[0]) | indexed_mem_op;
    wire mem_op = store_op | load_op;
    wire byte_access = register_group & f5[1];
    wire sign_extend_byte = f5[2];
    wire needs_rb_pass = register_alu_op | indexed_mem_op;
    wire needs_init_pass = mem_op | slt_op | multiply_op;

    // ------------------------------------------------------------------
    // System profile
    // ------------------------------------------------------------------
`ifdef RISCC_SYS
    reg ie_q;
    reg trap_q;
    wire ie_control_op = system_op & bbb[2] & bbb[1];
    // Missing optional ops are undefined on builds that lack them.
    // IRQ enters via word 2.
    // No ~jal16_target_phase_q guard is needed: the target-word fetch runs
    // through FETCH_WAIT/FETCH_CAPTURE, so no decode occurs mid-JAL16.
    wire take_irq = ie_q & irq;
    wire trap_active = trap_q;
`else
    wire take_irq = 1'b0;
    wire trap_active = 1'b0;
`endif

    // ------------------------------------------------------------------
    // Two-word JAL16/JMP16 sequencing.  The flag is set after the first-word
    // pass and spans the target-word fetch plus its jump/link pass.
    // ------------------------------------------------------------------
`ifdef RISCC_SYS
    reg jal16_target_phase_q;
`else
    wire jal16_target_phase_q = 1'b0;
`endif

    // ------------------------------------------------------------------
    // Register file: 16 regs x 16 bits in one synchronous RAM (one EBR),
    // addressed {reg, slice}, read one W-bit slice ahead of use.
    //
    // Read schedule (one stream at a time):
    //   INIT2 first lap : rb  -> data_stream_q        (reg-reg ALU, indexed memory)
    //   INIT            : rs1 -> ALU        (alu_b_raw = imm or rotating data_stream_q)
    //   store-data lap  : rd  -> data_stream_q        (second INIT2 or
    //                                                   MEM_XFER by mapping)
    //   EXECUTE         : rs1 -> ALU / pc_q   (single-stage ops)
    // ------------------------------------------------------------------
`ifndef RISCC_SYS
`define RISCC_TINY_STORE_INIT2
`elsif RISCC_FULL
`ifndef RISCC_ECP5
`define RISCC_TINY_STORE_MEM_XFER
`endif
`else
`define RISCC_TINY_STORE_MEM_XFER
`endif
`ifndef RISCC_TINY_STORE_MEM_XFER
    // Min and wide ECP5 full builds retain the second INIT2 store-data lap.
    reg init_pass_done_q;
`endif
`ifdef RISCC_FULL
`ifdef RISCC_ECP5
    localparam STORE_DATA_IN_MEM_XFER = (W <= 2);
`endif
`endif
    // bbb[0] is the bank-select bit: 0 reads S[aaa], 1 writes S[ddd]
    // (links share MTS's write path; CLI/STI have no RF traffic).
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = system_op &  bbb[0];
    wire [3:0] rf_src_reg = {src_system_bank, immediate_group ? ddd : aaa};
    wire [2:0] rf_dst_low = ddd & {3{~(trap_active | cmpi_op)}};
    wire [3:0] rf_dst_reg = {trap_active | dst_system_bank, rf_dst_low};

    wire rf_read_rb =
        (needs_rb_pass &
`ifdef RISCC_TINY_STORE_INIT2
         (in_decode | (in_init2 & ~init_pass_done_q & ~last_slice))) |
`elsif RISCC_TINY_STORE_MEM_XFER
         (in_decode | (in_init2 & ~last_slice))) |
`else
         (in_decode | (in_init2 &
          (STORE_DATA_IN_MEM_XFER | ~init_pass_done_q) & ~last_slice))) |
`endif
        (multiply_op & ((in_init2 & last_slice) |
                        (in_init & ~last_slice)));
    wire rf_read_rd = (in_init & last_slice & (store_op | multiply_op)) |
`ifdef RISCC_TINY_STORE_INIT2
                      (in_init2 & init_pass_done_q) |
`elsif RISCC_TINY_STORE_MEM_XFER
                      (in_mem_xfer & store_op) |
`else
                      (in_init2 & ~STORE_DATA_IN_MEM_XFER &
                       init_pass_done_q) |
                      (in_mem_xfer & STORE_DATA_IN_MEM_XFER & store_op) |
`endif
                      (in_execute & multiply_op);
    wire [3:0] rf_read_reg = rf_read_rb ? {1'b0, bbb} :
                                 rf_read_rd ? {1'b0, ddd} : rf_src_reg;

    // STB to the high byte lane: read the store data rotated by 8 so the
    // byte lands in data_stream_q[15:8], avoiding a byte-duplication mux.
    wire store_high_byte = byte_access & store_op;
    wire rf_read_lane_flip =
`ifdef RISCC_TINY_STORE_INIT2
        (in_init2 & init_pass_done_q & store_high_byte & address_stream_q[0]) |
`elsif RISCC_TINY_STORE_MEM_XFER
        (in_mem_xfer & store_op & store_high_byte & address_stream_q[0]) |
`else
        (((in_init2 & ~STORE_DATA_IN_MEM_XFER & init_pass_done_q) |
          (in_mem_xfer & STORE_DATA_IN_MEM_XFER & store_op)) &
         store_high_byte & address_stream_q[0]) |
`endif
        (in_init & last_slice & store_high_byte & address_stream_q[W]);
    wire [SLICE_BITS-1:0] byte_lane_offset =
        {rf_read_lane_flip, {(SLICE_BITS-1){1'b0}}};
    wire [SLICE_BITS-1:0] rf_read_slice =
        (slice_count_en ? slice_idx_next : {SLICE_BITS{1'b0}}) ^
        byte_lane_offset;

    wire writes_rd = immediate_alu_op | register_alu_op | load_op |
                     any_shift_op | multiply_op | system_move_op |
                     (link_dest_nonzero & link_context);
`ifdef RISCC_FULL
    wire rf_we = in_execute & (trap_active | writes_rd);
`elsif RISCC_ECP5
    // The direct form keeps the faster ECP5 writeback placement.
    wire rf_we = in_execute & (trap_active | writes_rd);
`else
    // Factoring the W=1 iCE40 case this way removes one writeback LUT.
    wire rf_we = in_execute &
        (trap_active | (writes_rd & (~trap_active | (W != 1))));
`endif

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
    wire sign_extend_imm = imm_mem_group | add_immediate_op | cmpi_op | branch_group;
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
    // The smaller store schedule trades one extra pass for one LUT4 only in
    // sys /1 and full /4,/8. Min retains its original direct-store path.
`ifdef RISCC_SYS
`ifdef RISCC_FULL
    wire slow_direct_store = (W == 4) | (W == 8);
`else
    wire slow_direct_store = (W == 1);
`endif
    wire direct_store_stream_base = register_store_op & slow_direct_store;
`endif
`ifndef RISCC_SYS
    wire alu_a_enable = ~(immediate_group & ~aaa[2] & ~aaa[1]);
    wire alu_b_zero = system_op | register_store_op;
`else
    wire alu_a_enable =
        ~(immediate_group & ~aaa[2] & ~aaa[1]) & ~direct_store_stream_base;
    wire alu_b_zero = system_op |
                     ((W != 1) & register_store_op & ~slow_direct_store);
`endif
    wire alu_subtract = (register_alu_op & ~f5[2] & (f5[1] | f5[0])) | cmpi_op;

    // During SLT EXECUTE, force both operands (and alu_b_raw inversion) to
    // zero so the comparison result rides the parked carry into result bit 0.
    wire slt_execute = slt_op & in_execute;

    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute & ~mul_clear_product}};
    wire [W-1:0] alu_b_raw =
`ifndef RISCC_SYS
        ((needs_rb_pass | multiply_op) ? data_stream_q[W-1:0] : imm_slice) &
`else
        ((needs_rb_pass | multiply_op | direct_store_stream_base) ?
         data_stream_q[W-1:0] : imm_slice) &
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

`ifdef RISCC_FULL
    always @(posedge clk)   // each MUL pass adds afresh: clear between passes
        alu_carry_q <= (slt_op & in_init & last_slice) ? less_than_result :
                    alu_active ? (alu_sum_ext[W] & ~(last_slice & repeat_exec)) : alu_subtract;
`else
    always @(posedge clk)
        alu_carry_q <= (slt_op & in_init & last_slice) ? less_than_result :
                    alu_active                     ? alu_sum_ext[W] : alu_subtract;
`endif

    wire logic_op = (immediate_alu_op & aaa[2]) | (register_alu_op & f5[2]);
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
`ifdef RISCC_FULL
        // During MUL, address_stream_q parks the multiplier.  Rotate one
        // slice at each W-pass boundary; the final pass refills the fetch
        // address stream.
        else if (in_init | (in_execute & (~(multiply_op & repeat_exec) |
                                       (last_slice & mul_reload_boundary))))
            address_stream_q <= {
                in_init ?
`ifndef RISCC_SYS
                          alu_sum :
`else
                          (((W == 1) & register_store_op &
                            ~slow_direct_store) ? rf_rdata : alu_sum) :
`endif
                (multiply_op & repeat_exec) ? address_stream_q[W-1:0] :
                next_fetch_address_slice,
                address_stream_q[15:W]};
`else
        else if (in_init | in_execute)
            address_stream_q <= {
                in_init ?
`ifndef RISCC_SYS
                          alu_sum :
`else
                          (((W == 1) & register_store_op &
                            ~slow_direct_store) ? rf_rdata : alu_sum) :
`endif
                          next_fetch_address_slice,
                address_stream_q[15:W]};
`endif
    end

    // Shift operations stream rs1 into data_stream_q during INIT2.  As that
    // stream rotates, result slice k is data_stream_q[W:1].
    wire right_shift_input =
        last_slice ? (arithmetic_shift & data_stream_q[W-1]) :
                     data_stream_q[W];
    wire [W-1:0] right_shift_slice =
        (data_stream_q[W-1:0] >> 1) |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));
`ifdef RISCC_SYS
    // A left shift appends the previous slice's delayed MSB.
    wire left_shift_input = ~first_slice & left_shift_carry_q;
    wire [W-1:0] shift_result_slice = use_left_shift_path ?
        ((data_stream_q[W-1:0] << 1) |
         {{(W-1){1'b0}}, left_shift_input}) :
        right_shift_slice;
`else
    wire [W-1:0] shift_result_slice = right_shift_slice;
`endif

    // ------------------------------------------------------------------
    // Data stream: operands, stores, loads, and JAL16 targets
    // ------------------------------------------------------------------
    reg [15:0] data_stream_q;
    reg load_fill_q;
    reg memory_lane_q;
    // The stream shifts on every counted cycle, including MEM_XFER.  Loads and
    // JAL16 targets enter in W-bit slices, leaving the lower 16-W bits as a
    // pure shift with no input muxing.  INIT2 fills and consumers shift too;
    // idle passes rotate don't-care data that the next fill/load overwrites.
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
`ifdef RISCC_SYS
            // Repeated shift/MUL passes recycle the stream's shifted output.
            data_stream_q <= {
`ifdef RISCC_TINY_STORE_MEM_XFER
                (in_mem_xfer & ~store_op) ? load_stream_slice :
`else
                (in_mem_xfer &
                 (~STORE_DATA_IN_MEM_XFER | ~store_op)) ? load_stream_slice :
`endif
                (in_execute & (variable_shift_op | multiply_op)) ?
                    shift_result_slice : rf_rdata,
                data_stream_q[15:W]};
`else
            data_stream_q <= {
                in_mem_xfer ? load_stream_slice : rf_rdata,
                data_stream_q[15:W]};
`endif
        if (in_mem_xfer) begin
            memory_lane_q <= address_stream_q[0];
            load_fill_q <= sign_extend_byte &
                           (address_stream_q[0] ?
                                mem_rdata[15] : mem_rdata[7]);
        end
`ifdef RISCC_SYS
        left_shift_carry_q <= data_stream_q[W-1];
        if (in_decode)
`ifdef RISCC_FULL
            repeat_pass_idx_q <= multiply_op ? 4'd0 : {1'b1, ~bbb};
`else
            repeat_pass_idx_q <= ~bbb;  // count to 7: bbb+1 passes
`endif
        else if (in_execute & last_slice & repeat_exec)
            repeat_pass_idx_q <= repeat_pass_idx_q + 1'b1;
`endif
    end

`ifdef RISCC_FULL
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
`endif

    // ------------------------------------------------------------------
    // Branch shadow: r0 zero/negative flags, updated on every r0 write
    // ------------------------------------------------------------------
    reg r0_zero_q;
    reg r0_negative_q;
    reg r0_zero_so_far_q;
    wire writes_r0 = rf_we & ~(|rf_dst_reg);
    always @(posedge clk)
        if (writes_r0) begin
            r0_zero_so_far_q <=
                (rf_wdata == {W{1'b0}}) &
                (first_slice | r0_zero_so_far_q);
            if (last_slice) begin
                r0_zero_q <= (rf_wdata == {W{1'b0}}) & r0_zero_so_far_q;
                // High-lane byte loads write the fill at slice_idx_q zero.
                r0_negative_q <= load_high_byte ? load_fill_q : rf_wdata[W-1];
            end
        end

    wire branch_taken = branch_group & ~ddd[2] &
        ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]);
    wire use_pc_offset = branch_taken | jmp8_op;

    // ------------------------------------------------------------------
    // PC stream and serial adder (PC + offset + forced carry 1).
    // The adder output is also every link/EPC value: PC+1 for JAL/JAL16;
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
        (pc_from_register | jal16_target_phase_q) ? data_stream_q[W-1:0] :
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
        (trap_active | (system_op & ~bbb[1])) ? link_slice :
        load_op ? load_slice :
        any_shift_op ? shift_result_slice :
        alu_result;  // MUL passes write the sum

    // ------------------------------------------------------------------
    // System profile state
    // ------------------------------------------------------------------
`ifdef RISCC_SYS
    always @(posedge clk) begin
        if (in_decode)
            trap_q <= take_irq;
        if (in_execute) begin
            if (trap_q) begin
                if (last_slice)
                    ie_q <= 1'b0;
            end else if (ie_control_op)
                ie_q <= bbb[0];
            else if (return_op & bbb[2] & last_slice)
                ie_q <= 1'b1;       // RETI
        end
        if (rst) begin
            ie_q   <= 1'b0;
            trap_q <= 1'b0;
        end
    end
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
                    (needs_rb_pass |
`ifdef RISCC_SYS
                     direct_store_stream_base |
`endif
                     pc_from_register |
                     any_shift_op | multiply_op) ? ST_INIT2 :
                    needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT2:
                if (last_slice)
`ifdef RISCC_TINY_STORE_INIT2
                    state_q <= (needs_init_pass & ~init_pass_done_q) ?
                               ST_INIT : ST_EXECUTE;
`elsif RISCC_TINY_STORE_MEM_XFER
                    state_q <= needs_init_pass ? ST_INIT : ST_EXECUTE;
`else
                    state_q <= (needs_init_pass &
                                (STORE_DATA_IN_MEM_XFER |
                                 ~init_pass_done_q)) ?
                               ST_INIT : ST_EXECUTE;
`endif
            ST_INIT:
                if (last_slice)
`ifdef RISCC_TINY_STORE_INIT2
                    state_q <= store_op ? ST_INIT2 :
`elsif RISCC_TINY_STORE_MEM_XFER
                    state_q <= store_op ? ST_MEM_XFER :
`else
                    state_q <= store_op ?
                               (STORE_DATA_IN_MEM_XFER ? ST_MEM_XFER :
                                                         ST_INIT2) :
`endif
                               mem_op   ? ST_MEM_WAIT : ST_EXECUTE;
            // Loads and JAL16 target words observe one memory-wait cycle.
            ST_MEM_WAIT:
                state_q <= ST_MEM_XFER;
            ST_MEM_XFER:
                if (last_slice)
                    state_q <= ST_EXECUTE;
            ST_EXECUTE:
                if (last_slice & ~repeat_exec)
                    // A first-word JAL16 fetches its target through
                    // MEM_WAIT/MEM_XFER; address_stream_q already holds pc_q.
                    state_q <= (jal16_op & ~jal16_target_phase_q &
                                ~trap_active) ?
                               ST_MEM_WAIT : ST_FETCH_WAIT;
        endcase
        if (rst)
            state_q <= ST_FETCH_WAIT;

`ifndef RISCC_TINY_STORE_MEM_XFER
        if (in_fetch_capture)
            init_pass_done_q <= 1'b0;
        if (in_init & last_slice)
            init_pass_done_q <= 1'b1;
`endif

        slice_idx_q <= slice_count_en ? slice_idx_next :
                                       {SLICE_BITS{1'b0}};

        if (in_fetch_capture)
            instr_q <= mem_rdata;

`ifdef RISCC_SYS
        if (in_execute & last_slice)
            jal16_target_phase_q <= jal16_op & ~jal16_target_phase_q &
                                  ~trap_active;
        if (rst)
            jal16_target_phase_q <= 1'b0;
`endif

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
                       ~(jal16_op & ~jal16_target_phase_q & ~trap_active);
    wire [SLICE_BITS-1:0] tr_wr_slice_i = slice_idx_q ^
        {load_high_byte, {(SLICE_BITS-1){1'b0}}};
    wire [14:0] tr_pc_i = pc_q[14:0];
    wire [15:0] tr_ir_i = instr_q;
`ifdef RISCC_SYS
    wire        tr_ie_i = ie_q;
`else
    wire        tr_ie_i = 1'b0;
`endif
    wire        tr_rf_we_i = rf_we;
    wire        tr_rf_bank_i = rf_dst_reg[3];
    wire [2:0]  tr_rf_reg_i = rf_dst_reg[2:0];
    wire [3:0]  tr_rf_lsb_i = {tr_wr_slice_i, {W_LOG2{1'b0}}};
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif

`ifdef RISCC_TINY_STORE_INIT2
`undef RISCC_TINY_STORE_INIT2
`endif
`ifdef RISCC_TINY_STORE_MEM_XFER
`undef RISCC_TINY_STORE_MEM_XFER
`endif

endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
`endif
