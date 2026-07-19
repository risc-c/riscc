// riscc_tiny_min.v : Min-profile serial RISC-C core (W=1, 2, 4, or 8).
//
// This core deliberately contains only the Min profile.  Keeping Sys/Full
// scheduling and decode out of this module makes its area-critical control
// logic visible and independently optimizable.

`default_nettype none

module riscc_tiny_min #(
    parameter integer W = 4,
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

    localparam integer SLICES = 16 / W;
    localparam integer SLICE_BITS = $clog2(SLICES);
    localparam integer RF_ADDR_WIDTH = 4 + SLICE_BITS;

    // The encoding is area-tuned: state_q[2] enables all counted states.
    localparam [2:0] ST_FETCH_WAIT    = 3'd0;
    localparam [2:0] ST_FETCH_CAPTURE = 3'd3;
    localparam [2:0] ST_DECODE        = 3'd2;
    localparam [2:0] ST_MEM_WAIT      = 3'd1;
    localparam [2:0] ST_EXECUTE       = 3'd5;
    localparam [2:0] ST_MEM_XFER      = 3'd7;
    localparam [2:0] ST_INIT          = 3'd4;
    localparam [2:0] ST_INIT2         = 3'd6;

    reg [2:0] state_q;
    reg [SLICE_BITS-1:0] slice_idx_q;

    wire in_fetch_capture = state_q == ST_FETCH_CAPTURE;
    wire in_decode = state_q == ST_DECODE;
    wire in_mem_xfer = state_q == ST_MEM_XFER;
    wire in_init = state_q == ST_INIT;
    wire in_init2 = state_q == ST_INIT2;
    wire in_execute = state_q == ST_EXECUTE;

    wire slice_count_en = state_q[2];
    wire [SLICE_BITS:0] slice_idx_sum =
        {1'b0, slice_idx_q} + {{SLICE_BITS{1'b0}}, 1'b1};
    wire [SLICE_BITS-1:0] slice_idx_next =
        slice_idx_sum[SLICE_BITS-1:0];
    wire last_slice = slice_idx_sum[SLICE_BITS];
    wire first_slice = ~|slice_idx_q;

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    reg [15:0] instr_q;

    wire [1:0] op_class = instr_q[15:14];
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5 = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group = ~op_class[1];
    wire immediate_group = op_class[1] & ~op_class[0];
    wire register_group = op_class[1] & op_class[0];

    wire branch_group = immediate_group & (aaa == 3'b111);
    wire immediate_alu_op = immediate_group & ~branch_group;
    wire add_immediate_op = immediate_group & (aaa == 3'b010);
    // Branches share aaa[1:0] with CMPI, but never write the ALU result.
    // Let them alias the internal subtract control to keep decode shallow.
    wire cmpi_op = immediate_group & aaa[1] & aaa[0];
    wire jmp8_op = branch_group & ddd[2];
    wire link_dest_nonzero = |ddd;

    wire f_group_01 = ~f5[4] & f5[3];
    wire system_op = register_group & f5[4] & f5[3];
    wire register_alu_op = register_group & ~f5[3];

    // Reserved 10_xxx aliases the funnel shifts in this RTL experiment.
    // Keeping the decode loose makes 10_000/10_010 cheap canonical encodings
    // for FSL1/FSR1; f5[1] selects the direction.
    wire funnel_op = register_alu_op & f5[4];
    wire funnel_right_op = funnel_op & f5[1];
    wire funnel_left_op = funnel_op & ~f5[1];

    // FSR shares the normal two-source ALU schedule.
    wire slt_op = register_alu_op & ~f5[2] & f5[1];
    wire signed_compare = ~instr_q[3];
    wire right_shift_op =
        register_group & f_group_01 & f5[2] & ~f5[1];
    wire arithmetic_shift = f5[0];
    wire any_shift_op = right_shift_op | funnel_right_op;

    wire register_memory_plane = register_group & f_group_01;
    wire register_store_op =
        register_memory_plane & ~f5[2] & f5[1] & f5[0];
    wire indexed_mem_op =
        register_memory_plane & ~f5[0] & (~f5[2] | f5[1]);

    wire system_move_op = system_op & ~bbb[2] & bbb[1];
    wire link_context = system_op & ~bbb[1] & bbb[0];
    wire register_target_op = system_op & ~bbb[1];

    wire store_op = (imm_mem_group & op_class[0]) | register_store_op;
    wire load_op = (imm_mem_group & ~op_class[0]) | indexed_mem_op;
    wire mem_op = store_op | load_op;
    wire sign_extend_byte = f5[2];
    wire needs_rb_pass = register_alu_op | indexed_mem_op;
    wire needs_init_pass = mem_op | slt_op | funnel_left_op;

    // ------------------------------------------------------------------
    // Register file and read schedule
    // ------------------------------------------------------------------
    wire src_system_bank = system_op & ~bbb[0];
    wire dst_system_bank = system_op & bbb[0];
    wire [3:0] rf_src_reg =
        {src_system_bank, immediate_group ? ddd : aaa};
    wire [3:0] rf_dst_reg = {dst_system_bank, ddd & {3{~cmpi_op}}};

    wire rf_read_rb = needs_rb_pass &
        (in_decode | (in_init2 & ~last_slice));
    wire rf_read_rd =
        (in_init & last_slice & store_op) |
        (in_mem_xfer & store_op);
    wire [3:0] rf_read_reg = rf_read_rb ? {1'b0, bbb} :
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

    wire writes_rd = immediate_alu_op | register_alu_op | load_op |
                     any_shift_op | system_move_op |
                     (link_dest_nonzero & link_context);
    wire rf_we = in_execute & writes_rd;

    wire [W-1:0] rf_rdata;
    wire [W-1:0] rf_wdata;

    wire byte_load = indexed_mem_op & f5[1];
    wire load_high_byte = (W != 1) & byte_load & memory_lane_q;

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
    wire alu_b_zero = system_op | register_store_op;
    // Logic operations ignore the adder, so their low function bits may
    // alias this control without decoding f5[2].
    wire alu_subtract =
        (register_alu_op & (f5[1] | f5[0])) | cmpi_op;
    wire slt_execute = slt_op & in_execute;

    wire [W-1:0] alu_a =
        rf_rdata & {W{alu_a_enable & ~slt_execute}};
    wire [W-1:0] alu_b_raw =
        (needs_rb_pass ? data_stream_q[W-1:0] : imm_slice) &
        {W{~(alu_b_zero | slt_execute)}};
    wire [W-1:0] alu_b =
        alu_b_raw ^ {W{alu_subtract & ~slt_execute}};

    reg alu_carry_q;
    reg funnel_bit_q;
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
            (f5[1] ? less_than_result : data_stream_q[W-1]) :
            alu_active ? alu_sum_ext[W] : alu_subtract;

    // INIT2 has staged rb in data_stream_q when INIT begins.  Preserve its
    // low bit while INIT streams ra; this is the only extra FSR1 storage.
    // On INIT's last slice, data_stream_q still exposes rb[15], allowing FSL1
    // to seed the existing ALU carry without another saved bit.
    always @(posedge clk)
        if (in_init & first_slice)
            funnel_bit_q <= data_stream_q[0];

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
    // Address and shift streams
    // ------------------------------------------------------------------
    reg [15:0] address_stream_q;
    reg pc_msb_q;
    wire [W-1:0] next_fetch_address_slice =
        (next_pc_slice << 1) | {{(W-1){1'b0}}, pc_msb_q};

    always @(posedge clk) begin
        pc_msb_q <= in_execute ? next_pc_slice[W-1] : 1'b0;
        if (rst)
            address_stream_q <= {RESET_PC[14:0], 1'b0};
        else if (in_init | in_execute)
            address_stream_q <= {
                in_init ? alu_sum : next_fetch_address_slice,
                address_stream_q[15:W]};
    end

    wire right_shift_input = last_slice ?
        (funnel_right_op ? funnel_bit_q :
         (arithmetic_shift & data_stream_q[W-1])) :
        data_stream_q[W];
    wire [W-1:0] shift_result_slice =
        (data_stream_q[W-1:0] >> 1) |
        ({{(W-1){1'b0}}, right_shift_input} << (W - 1));

    reg [15:0] data_stream_q;
    reg load_fill_q;
    reg memory_lane_q;

    wire [W-1:0] memory_read_slice =
        mem_rdata[slice_idx_q * W +: W];
    wire w1_memory_slice_high =
        byte_load ? address_stream_q[0] :
                    slice_idx_q[SLICE_BITS-1];
    wire w1_memory_data_bit =
        mem_rdata[(w1_memory_slice_high * 8) +
                  ((slice_idx_q * W) & 7)];
    wire w1_byte_fill_bit =
        sign_extend_byte &
        mem_rdata[(address_stream_q[0] * 8) + 7];
    wire w1_load_stream_bit =
        (byte_load & slice_idx_q[SLICE_BITS-1]) ?
        w1_byte_fill_bit : w1_memory_data_bit;
    wire [W-1:0] load_stream_slice = (W == 1) ?
        {{(W-1){1'b0}}, w1_load_stream_bit} :
        memory_read_slice;

    // MEM_XFER streams memory into a load or the source register into a
    // store.  Sharing this counted state avoids a separate store-pass flag.
    always @(posedge clk) begin
        if (slice_count_en)
            data_stream_q <= {
                (in_mem_xfer & load_op) ? load_stream_slice : rf_rdata,
                data_stream_q[15:W]};

        if (in_mem_xfer) begin
            memory_lane_q <= address_stream_q[0];
            load_fill_q <= sign_extend_byte &
                (address_stream_q[0] ?
                 mem_rdata[15] : mem_rdata[7]);
        end
    end

    // ------------------------------------------------------------------
    // Branch shadow and PC
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
                r0_zero_q <=
                    (rf_wdata == {W{1'b0}}) & r0_zero_so_far_q;
                r0_negative_q <=
                    load_high_byte ? load_fill_q : rf_wdata[W-1];
            end
        end

    wire branch_taken = branch_group & ~ddd[2] &
        ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]);
    wire use_pc_offset = branch_taken | jmp8_op;

    reg [15:0] pc_q;
    reg pc_carry_q;

    wire [W-1:0] pc_offset_slice =
        use_pc_offset ? imm_slice : {W{1'b0}};
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

    wire [W-1:0] load_slice =
        ((W != 1) & byte_load &
         (slice_idx_q[SLICE_BITS-1] ^ memory_lane_q)) ?
        {W{load_fill_q}} : data_stream_q[W-1:0];

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
            ST_FETCH_WAIT:
                state_q <= ST_FETCH_CAPTURE;
            ST_FETCH_CAPTURE:
                state_q <= ST_DECODE;
            ST_DECODE:
                state_q <=
                    (needs_rb_pass | register_target_op | any_shift_op) ?
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
                state_q <= ST_MEM_XFER;
            ST_MEM_XFER:
                if (last_slice)
                    state_q <= ST_EXECUTE;
            ST_EXECUTE:
                if (last_slice)
                    state_q <= ST_FETCH_WAIT;
        endcase

        if (rst)
            state_q <= ST_FETCH_WAIT;

        slice_idx_q <= slice_count_en ?
            slice_idx_next : {SLICE_BITS{1'b0}};

        if (in_fetch_capture)
            instr_q <= mem_rdata;
    end

    assign mem_addr = address_stream_q[15:1];
    assign mem_we = in_execute & first_slice & store_op;
    assign mem_wdata = data_stream_q;
    assign mem_wmask = store_high_byte ?
        {address_stream_q[0], ~address_stream_q[0]} : 2'b11;

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = W;
    localparam integer W_LOG2 = $clog2(W);
    wire tr_commit_i = in_execute & last_slice;
    wire [SLICE_BITS-1:0] tr_wr_slice_i = slice_idx_q ^
        {load_high_byte, {(SLICE_BITS-1){1'b0}}};
    wire [14:0] tr_pc_i = pc_q[14:0];
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
