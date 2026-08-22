// riscc_min.v : area-oriented serial RC16 Min core (W=1, 2, 4, or 8).
//
// This core deliberately contains only the Min profile. Keeping Sys/Full
// scheduling and decode out of this module makes its area-critical control
// logic visible and independently optimizable.

`default_nettype none

module riscc_min #(
    parameter integer W = 4,
    parameter [15:0] RESET_PC = 16'h0000  // byte address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // unused by the Min profile

    output wire [14:0] mem_addr,   // halfword address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,
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
    localparam integer RF_ADDR_WIDTH = 4 + SLICE_BITS;

    // ------------------------------------------------------------------
    // State and serial-slice counter
    // ------------------------------------------------------------------
    // Structural encoding: state_q[2] marks counted states, while request
    // states share the 01x plane.
    localparam [2:0] ST_RESET         = 3'd0;
    localparam [2:0] ST_FETCH_WAIT    = 3'd3;
    localparam [2:0] ST_DECODE        = 3'd1;
    localparam [2:0] ST_MEM_WAIT      = 3'd2;
    localparam [2:0] ST_EXECUTE       = 3'd6;
    localparam [2:0] ST_MEM_XFER      = 3'd7;
    localparam [2:0] ST_INIT          = 3'd4;
    localparam [2:0] ST_INIT2         = 3'd5;

    reg [2:0] state_q;
    reg [SLICE_BITS-1:0] slice_idx_q;

    wire in_decode = state_q == ST_DECODE;
    wire in_mem_xfer = state_q == ST_MEM_XFER;
    wire in_init = state_q == ST_INIT;
    wire in_init2 = state_q == ST_INIT2;
    wire in_execute = state_q == ST_EXECUTE;

    wire [SLICE_BITS:0] slice_idx_sum =
        {1'b0, slice_idx_q} + {{SLICE_BITS{1'b0}}, 1'b1};
    wire [SLICE_BITS-1:0] slice_idx_next =
        slice_idx_sum[SLICE_BITS-1:0];
    wire last_slice = slice_idx_sum[SLICE_BITS];
    wire first_slice = ~|slice_idx_q;

    // ------------------------------------------------------------------
    // Instruction fields and decode
    // ------------------------------------------------------------------
    reg [15:0] instr_q;

    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field.
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group = ~instr_q[15];
    wire immediate_group = instr_q[15] & ~instr_q[14];
    wire register_group = instr_q[15] & instr_q[14];

    wire branch_group = immediate_group & (aaa == 3'b111);
    wire immediate_alu_op = immediate_group & ~branch_group;
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    // Branches share aaa[1:0] with CMPI, but never write the ALU result.
    // Let them alias the internal subtract control to keep decode shallow.
    wire cmpi_op = immediate_group & aaa[1] & aaa[0];
    wire link_dest_nonzero = |ddd;

    wire f_group_01 = ~f5[4] & f5[3];
    wire system_op = register_group & f5[4] & f5[3];
    wire register_alu_op = register_group & ~f5[3];

    // FSL1/FSR1 share the 10_001 two-operand group; bbb[0] selects
    // direction. Other reserved 10_xxx encodings and sub-operations may alias
    // them to keep this decode small.
    wire funnel_op = register_alu_op & f5[4];
    wire funnel_right_op = funnel_op & bbb[0];

    // FSR shares the normal two-source ALU schedule.
    wire ordinary_alu_op = register_alu_op & ~f5[4];
    wire slt_op = ordinary_alu_op & ~f5[2] & f5[1];
    wire signed_compare = ~instr_q[3];
    wire right_shift_op =
        register_group & f_group_01 & f5[2] & ~f5[1];
    wire arithmetic_shift = f5[0];
    wire any_shift_op = right_shift_op | funnel_right_op;

    wire register_memory_plane = register_group & f_group_01;
    // Native LDX uses 01_000. Direct unsigned loads, stores, and signed loads
    // use 01_010, 01_011, and 01_110. Min may alias reserved width selectors
    // within those families.
    wire indexed_mem_op =
        register_memory_plane & ~f5[2] & ~f5[1];
    wire direct_load_op =
        register_memory_plane & f5[1] & ~f5[0];
    wire register_store_op =
        register_memory_plane & ~f5[2] & f5[1] & f5[0];
    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = system_op & ~bbb[1] & bbb[0];
    wire register_target_op = system_op & ~bbb[1];

    wire store_op = (imm_mem_group & instr_q[0]) | register_store_op;
    wire load_op = (imm_mem_group & ~instr_q[0]) |
                   indexed_mem_op | direct_load_op;
    wire mem_op = store_op | load_op;
    wire slice_count_en = state_q[2];
    wire sign_extend_byte = f5[2];
    wire needs_rb_pass = register_alu_op | indexed_mem_op;
    // Funnel shifts stage aaa, then stream the old read/write destination ddd.
    wire needs_init_pass = mem_op | slt_op | funnel_op;

    // Shared serial streams. Address holds the active byte address; data holds
    // a staged operand or store value. Read responses use a separate register
    // so load writeback does not disturb either stream.
    reg [15:0] address_stream_q;
    reg [15:0] data_stream_q;
    reg [15:0] mem_response_q;
    wire load_fill = sign_extend_byte &
        (address_stream_q[0] ? mem_response_q[15] : mem_response_q[7]);

    // ------------------------------------------------------------------
    // Register file and read schedule
    // ------------------------------------------------------------------
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = system_op & bbb[0];
    // The funnel operand pass selects aaa; fallback is old ddd in INIT/EXECUTE.
    wire source_is_rd = instr_q[15] &
        (~instr_q[14] | (f5[4] & ~f5[3]));
    wire [3:0] rf_src_reg = {src_system_bank,
        source_is_rd ? ddd : aaa};
    wire [3:0] rf_dst_reg = {dst_system_bank, ddd & {3{~cmpi_op}}};

    wire rf_read_rb = needs_rb_pass &
        (in_decode | (in_init2 & ~last_slice));
    wire rf_read_rd =
        (in_init & last_slice & store_op) |
        (in_mem_xfer & store_op);
    wire [3:0] rf_read_reg = rf_read_rb ?
                             {1'b0, (f5[4] ? aaa : bbb)} :
                             rf_read_rd ? {1'b0, ddd} : rf_src_reg;

    wire store_high_byte = register_store_op;
    wire rf_read_lane_flip =
        (in_mem_xfer & store_high_byte &
         address_stream_q[0]) |
        (in_init & last_slice & store_high_byte & address_stream_q[W]);
    wire [SLICE_BITS-1:0] byte_lane_offset =
        {rf_read_lane_flip, {(SLICE_BITS-1){1'b0}}};
    wire [SLICE_BITS-1:0] rf_read_slice =
        (slice_count_en ? slice_idx_next : {SLICE_BITS{1'b0}}) ^
        byte_lane_offset;

    wire writes_rd = immediate_alu_op | register_alu_op |
                     right_shift_op | system_move_op |
                     (link_dest_nonzero & link_context);
    wire rf_we = (in_execute & writes_rd) | (in_mem_xfer & load_op);

    wire [W-1:0] rf_rdata;
    wire [W-1:0] rf_wdata;

    // RC16 has only direct byte accesses; reserved width selectors may alias.
    wire byte_load = direct_load_op;
    // All defined non-byte loads are aligned, so only a byte load can reach
    // writeback with an odd address.
    wire load_high_byte = (W != 1) & load_op & address_stream_q[0];
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
    // The branch ALU value is unused; aliasing it onto the signed-immediate
    // path keeps the shared immediate decode compact.
    wire sign_extend_imm =
        imm_mem_group | add_immediate_op | cmpi_op | branch_group;
    wire lui_op = immediate_group & (aaa == 3'b001);
    wire [SLICE_BITS-1:0] immediate_slice_index =
        slice_idx_q ^ {lui_op, {(SLICE_BITS-1){1'b0}}};
    wire [W-1:0] immediate_low_slice =
        instr_q[((immediate_slice_index * W) & 7) +: W];
    wire [W-1:0] imm_slice = immediate_slice_index[SLICE_BITS-1] ?
        {W{sign_extend_imm & instr_q[7]}} : immediate_low_slice;

    // ------------------------------------------------------------------
    // Serial ALU
    // ------------------------------------------------------------------
    wire alu_a_enable =
        ~(immediate_group & ~aaa[2] & ~aaa[1]);
    wire alu_b_zero = system_op | byte_load | register_store_op;
    // Logic operations ignore the adder, so their low function bits may
    // alias this control without decoding f5[2].
    wire alu_subtract =
        (ordinary_alu_op & (f5[1] | f5[0])) | cmpi_op;
    wire slt_execute = slt_op & in_execute;

    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute}};
    wire [W-1:0] alu_b_raw =
        (needs_rb_pass ? data_stream_q[W-1:0] : imm_slice) &
        {W{~(alu_b_zero | slt_execute)}};
    wire [W-1:0] alu_b =
        alu_b_raw ^ {W{alu_subtract & ~slt_execute}};

    reg alu_carry_q;
    // Funnel shifts preserve one endpoint bit between serial passes.
    reg serial_bit_q;
    wire [W:0] alu_sum_ext =
        {1'b0, alu_a} + {1'b0, alu_b} +
        {{W{1'b0}}, alu_carry_q};
    wire [W-1:0] alu_sum = alu_sum_ext[W-1:0];
    wire alu_active = slice_count_en & (in_init | in_execute);

    wire less_than_result =
        (rf_rdata[W-1] & signed_compare) ^
        ~(alu_b_raw[W-1] & signed_compare) ^ alu_sum_ext[W];

    always @(posedge clk)
        alu_carry_q <= (register_alu_op & in_init & last_slice) ?
            (slt_op ? less_than_result : data_stream_q[W-1]) :
            alu_active ? alu_sum_ext[W] : alu_subtract;

    always @(posedge clk)
        if (in_init & first_slice)
            serial_bit_q <= data_stream_q[0];

    // INIT2 has staged ra in data_stream_q when a funnel INIT begins. Preserve
    // its low bit while INIT streams the old rd; this is the only extra FSR1
    // storage. On INIT's last slice, data_stream_q still exposes ra[15],
    // allowing FSL1 to seed the existing ALU carry without another saved bit.
    wire logic_op =
        (immediate_alu_op & aaa[2]) |
        (register_alu_op & f5[2]);
    wire [1:0] logic_select =
        immediate_group ? aaa[1:0] : f5[1:0];
    wire [W-1:0] logic_result =
        ((rf_rdata ^ alu_b_raw) &
         {W{logic_select[1] | logic_select[0]}}) |
        ((rf_rdata & alu_b_raw) & {W{~logic_select[1]}});
    wire [W-1:0] alu_result =
        logic_op ? logic_result : alu_sum;

    // ------------------------------------------------------------------
    // Branch shadow and PC
    // ------------------------------------------------------------------
    reg r0_zero_q;
    reg r0_negative_q;
    reg r0_zero_so_far_q;
    wire writes_r0 = rf_we & ~(|rf_dst_reg);
    always @(posedge clk)
        if (writes_r0) begin
            if (W <= 2)
                r0_zero_q <= (rf_wdata == {W{1'b0}}) &
                             (first_slice | r0_zero_q);
            else begin
                r0_zero_so_far_q <=
                    (rf_wdata == {W{1'b0}}) &
                    (first_slice | r0_zero_so_far_q);
                if (last_slice)
                    r0_zero_q <=
                        (rf_wdata == {W{1'b0}}) & r0_zero_so_far_q;
            end

            if ((W == 1) |
                &(slice_idx_q ^
                  {load_high_byte, {(SLICE_BITS-1){1'b0}}}))
                // The rotated write address identifies the architectural
                // sign slice for ordinary and high-byte load writeback.
                r0_negative_q <= rf_wdata[W-1];
        end

    wire use_pc_offset = branch_group &
        (ddd[2] |
         ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]));

    reg [15:0] pc_q;
    reg pc_carry_q;

    // Encoded bits 7:1 already occupy byte-offset bits 7:1. The sequential-PC
    // step replaces bit zero; encoded bit zero supplies only the upper fill.
    wire [W-1:0] branch_offset_slice =
        slice_idx_q[SLICE_BITS-1] ? {W{instr_q[0]}} :
        immediate_low_slice;
    wire [W-1:0] pc_step_slice =
        {{(W-1){1'b0}}, first_slice};
    wire [W-1:0] pc_offset_slice =
        (branch_offset_slice & {W{use_pc_offset}}) | pc_step_slice;
    wire [W:0] pc_sum_ext =
        {1'b0, pc_q[W-1:0]} +
        {1'b0, pc_offset_slice} +
        {{W{1'b0}}, pc_carry_q};
    wire [W-1:0] pc_sum = pc_sum_ext[W-1:0];

    always @(posedge clk)
        pc_carry_q <= in_execute ? pc_sum_ext[W] : 1'b1;

    wire [W-1:0] next_pc_slice =
        register_target_op ? data_stream_q[W-1:0] : pc_sum;

    always @(posedge clk)
        if (rst)
            pc_q <= RESET_PC;
        else if (in_execute)
            pc_q <= {next_pc_slice, pc_q[15:W]};

    // ------------------------------------------------------------------
    // Address and shift streams
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)
            address_stream_q <= RESET_PC;
        else if (in_init | in_execute)
            address_stream_q <= {
                in_init ? alu_sum : next_pc_slice,
                address_stream_q[15:W]};
    end

    wire right_shift_input = last_slice ?
        (f5[3] ? (arithmetic_shift & data_stream_q[W-1]) :
                 serial_bit_q) :
        data_stream_q[W];
    wire [W:0] right_shift_base =
        {1'b0, data_stream_q[W-1:0]} >> 1;
    wire [W-1:0] shift_result_slice =
        right_shift_base[W-1:0] |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));

    wire [W-1:0] memory_read_slice =
        mem_response_q[slice_idx_q * W +: W];
    wire w1_memory_slice_high =
        byte_load ? address_stream_q[0] :
                    slice_idx_q[SLICE_BITS-1];
    wire w1_memory_data_bit =
        mem_response_q[(w1_memory_slice_high * 8) +
                       ((slice_idx_q * W) & 7)];
    wire w1_load_stream_bit =
        (byte_load & slice_idx_q[SLICE_BITS-1]) ?
        load_fill : w1_memory_data_bit;
    wire [W-1:0] load_stream_slice = (W == 1) ?
        {{(W-1){1'b0}}, w1_load_stream_bit} :
        memory_read_slice;

    // A completing read is captured once, then selected a slice at a time for
    // direct RF writeback. The shared shift stream remains store/operand-only.
    always @(posedge clk) begin
        if (mem_valid)
            mem_response_q <= mem_rdata;

        if (state_q[2])
            data_stream_q <= {
                rf_rdata,
                data_stream_q[15:W]};
    end

    wire [W-1:0] load_slice =
        ((W != 1) & byte_load &
         (slice_idx_q[SLICE_BITS-1] ^ address_stream_q[0])) ?
        {W{load_fill}} : load_stream_slice;

    assign rf_wdata =
        (system_op & ~bbb[1]) ? pc_sum :
        load_op ? load_slice :
        any_shift_op ? shift_result_slice :
        alu_result;

    // ------------------------------------------------------------------
    // Sequencer and memory interface
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        case (state_q)
            ST_RESET:
                state_q <= ST_FETCH_WAIT;
            ST_FETCH_WAIT:
                if (mem_ready)
                    state_q <= ST_DECODE;
            ST_DECODE:
                state_q <=
                    (needs_rb_pass | register_target_op | right_shift_op) ?
                    ST_INIT2 :
                    needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT2:
                if (last_slice)
                    state_q <= needs_init_pass ? ST_INIT : ST_EXECUTE;
            ST_INIT:
                if (last_slice)
                    state_q <= store_op ? ST_MEM_XFER :
                               mem_op ? ST_MEM_WAIT : ST_EXECUTE;
            ST_MEM_WAIT:
                if (mem_ready)
                    state_q <= store_op ? ST_EXECUTE : ST_MEM_XFER;
            ST_MEM_XFER:
                if (last_slice)
                    state_q <= store_op ? ST_MEM_WAIT : ST_EXECUTE;
            ST_EXECUTE:
                if (last_slice)
                    state_q <= ST_FETCH_WAIT;
            default:
                state_q <= state_q;
        endcase

        if (rst)
            state_q <= ST_RESET;

        slice_idx_q <= slice_count_en ?
            slice_idx_next : {SLICE_BITS{1'b0}};

        if (mem_valid & mem_ready & state_q[0])
            instr_q <= mem_rdata;
    end

    assign mem_addr = address_stream_q[15:1];
    assign mem_valid = state_q[1] & ~state_q[2];
    // During a valid cycle state_q[0] distinguishes fetch (1) from data (0).
    // mem_we and mem_wmask are don't-care whenever mem_valid is low.
    assign mem_we = ~state_q[0] & store_op;
    assign mem_wdata = data_stream_q;
    assign mem_wmask = (~state_q[0] & store_high_byte) ?
        {address_stream_q[0], ~address_stream_q[0]} : 2'b11;

    // ------------------------------------------------------------------
    // Trace interface
    // ------------------------------------------------------------------
`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = W;
    localparam integer W_LOG2 = $clog2(W);
    wire tr_commit_i = in_execute & last_slice;
    wire [SLICE_BITS-1:0] tr_wr_slice_i = slice_idx_q ^
        {load_high_byte, {(SLICE_BITS-1){1'b0}}};
    wire [14:0] tr_pc_i = pc_q[15:1];
    wire [15:0] tr_ir_i = instr_q;
    wire tr_ie_i = 1'b0;
    wire tr_rf_we_i = rf_we;
    wire tr_rf_bank_i = rf_dst_reg[3];
    wire [2:0] tr_rf_reg_i = rf_dst_reg[2:0];
    wire [3:0] tr_rf_lsb_i =
        {tr_wr_slice_i, {W_LOG2{1'b0}}};
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif

    wire _unused_irq = irq;

endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
