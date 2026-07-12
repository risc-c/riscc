// RISC-C nano1 bit-serial implementation.
//
// Nano keeps the tiny1 serial datapath shape but removes the expensive
// architectural conveniences: no S-bank, no system/interrupt profile,
// no CMPI, no signed SLT, and CALL writes its link to rd.

`default_nettype none

module riscc_nano1 #(
    parameter [15:0] RESET_PC = 16'h0000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,

    output wire [14:0] mem_addr,
    output wire        mem_valid,
    output wire        mem_we,
    output wire [1:0]  mem_wmask,
    output wire [15:0] mem_wdata,
    input  wire [15:0] mem_rdata
`ifdef RISCC_TRACE
    ,
`include "riscc_trace_ports.vh"
`endif
);
    /* verilator lint_off UNUSED */
    wire unused_irq = irq;
    /* verilator lint_on UNUSED */

    // ------------------------------------------------------------------
    // State encoding and stored datapath state
    // ------------------------------------------------------------------
    // The encoding is intentional: state_q[2] is high throughout the four
    // 16-cycle serial phases, and state_q[0] also simplifies the RF schedule.
    localparam [2:0] ST_FETCH_WAIT    = 3'd0;  // issue synchronous fetch
    localparam [2:0] ST_FETCH_CAPTURE = 3'd1;  // capture fetched instruction
    localparam [2:0] ST_DECODE        = 3'd2;
    localparam [2:0] ST_MEM_WAIT      = 3'd3;  // memory read latency
    localparam [2:0] ST_READ_RB       = 3'd4;  // stream rb into operand_b_q
    localparam [2:0] ST_PREP          = 3'd5;  // address/SLTU prepass
    localparam [2:0] ST_MEM_XFER      = 3'd6;  // load/store data stream
    localparam [2:0] ST_EXECUTE       = 3'd7;

    reg [2:0] state_q;
    reg [15:0] instr_q;
    reg [15:0] pc_q;
    reg [15:0] addr_q;
    reg [15:0] operand_b_q;
    reg [3:0]  bit_idx_q;
    reg        alu_carry_q;
    reg        pc_carry_q;
    reg        r0_zero_q;
    reg        r0_negative_q;

    wire in_fetch_capture = (state_q == ST_FETCH_CAPTURE);
    wire in_mem_xfer      = (state_q == ST_MEM_XFER);
    wire in_prep          = (state_q == ST_PREP);
    wire in_execute       = (state_q == ST_EXECUTE);

    wire serial_active = state_q[2];
    wire [3:0] bit_idx_next = bit_idx_q + 4'd1;
    wire first_bit = ~(|bit_idx_q);
    wire last_bit  = &bit_idx_q;

    // ------------------------------------------------------------------
    // Instruction fields and deliberately loose nano decode
    // ------------------------------------------------------------------
    // Contiguous register-format fields: 11 ddd aaa fffff bbb.
    wire [1:0] op_class = instr_q[15:14];
    wire [2:0] ddd = instr_q[13:11];
    wire [2:0] aaa = instr_q[10:8];
    wire [4:0] f5  = instr_q[7:3];
    wire [2:0] bbb = instr_q[2:0];

    wire imm_mem_group   = ~op_class[1];
    wire immediate_group =  op_class[1] & ~op_class[0];
    wire register_group  =  op_class[1] &  op_class[0];

    wire branch_group = immediate_group & (aaa == 3'b111);
    wire immediate_write_op = immediate_group & ~branch_group;
    // Undefined nano encodings intentionally alias implemented operations;
    // software must not depend on the aliases.  Loose decode costs fewer LUTs.

    wire alu_function_group = ~f5[4] & ~f5[3];
    wire memory_shift_function_group = ~f5[4] &  f5[3];

    wire register_alu_op = register_group & alu_function_group;
    wire register_memory_shift_group = register_group & memory_shift_function_group;

    // SLT is undefined in nano; let its slot alias to SLTU.
    wire sltu_op = register_alu_op & ~f5[2] & f5[1];
    // Nano keeps only the right-shift arm. Full-only 01_110/111 may alias it.
    wire right_shift_op = register_group & memory_shift_function_group & f5[2];
    wire arithmetic_shift = f5[0];
    // Keep the serial memory plane deliberately loose.  In the architectural
    // map it contains LDWX (8), LDB (A), and STB (B); 9 is reserved. Letting
    // the reserved code alias the existing stream is substantially cheaper
    // than separating the direct store from the old indexed-memory schedule.
    wire register_memory_op = register_memory_shift_group & ~right_shift_op;
    // JAL rd, ra lives in the register-indirect group (11_111, bbb=001);
    // nano has no S-bank, so ddd names a general register and rd == r0
    // writes no link (plain jump).
    wire register_jump_op = register_group & f5[4];
    wire call_op = register_jump_op & (|ddd);

    // ------------------------------------------------------------------
    // Memory decode and serial read stream
    // ------------------------------------------------------------------
    wire mem_op = imm_mem_group | register_memory_op;
    wire mem_store_decode = imm_mem_group ? op_class[0] : f5[0];
    wire store_op = mem_op & mem_store_decode;
    wire load_op = mem_op & ~mem_store_decode;
    wire byte_access = register_memory_op & f5[1];
    // The memory stream is ignored on stores, so the byte decode need not
    // distinguish loads here.
    wire mem_bit_index_hi = byte_access ? addr_q[0] : bit_idx_q[3];
    wire mem_data_bit = mem_rdata[{mem_bit_index_hi, bit_idx_q[2:0]}];
    // Nano byte loads are unsigned, so the streamed upper byte is zero.
    wire mem_stream_bit = mem_data_bit &
                          ~(byte_access & bit_idx_q[3]);
    wire needs_rb_pass = register_alu_op | register_memory_op;
    wire [2:0] source_reg_idx = immediate_group ? ddd : aaa;
    wire [2:0] dest_reg_idx = ddd;

    // ------------------------------------------------------------------
    // Synchronous register-file schedule
    // ------------------------------------------------------------------
    // With this state encoding, ~state_q[0] selects DECODE/READ_RB plus two
    // harmless don't-care phases.  select_ddd wins in MEM_XFER, so stores
    // still read their data register.
    wire select_bbb = needs_rb_pass & ~state_q[0] & ~last_bit;
    // The RF output is ignored while MEM_XFER streams a load, so selecting
    // ddd throughout the phase gives stores the right source cheaply.
    wire select_ddd = (in_prep & last_bit) | in_mem_xfer;
    wire [2:0] rf_read_reg = select_ddd ? ddd :
                             select_bbb ? bbb : source_reg_idx;
    // The synchronous RF is addressed one cycle ahead.  Flipping address bit
    // 3 rotates a high-lane byte by eight bits; extra rotation in unrelated
    // register slots is unobserved.
    wire loose_byte_decode = register_group & f5[1];
    wire rf_byte_rotate =
        (in_mem_xfer & loose_byte_decode & addr_q[0]) |
        (in_prep & last_bit & loose_byte_decode & addr_q[1]);
    wire [3:0] rf_read_bit_idx =
        (serial_active ? bit_idx_next : 4'h0) ^ {rf_byte_rotate, 3'b000};
    wire [6:0] rf_raddr = {rf_read_reg, rf_read_bit_idx};

    wire rf_read_bit;
    wire rf_we;
    wire rf_wdata;
    wire [6:0] rf_waddr = {dest_reg_idx, bit_idx_q};

    riscc_rf #(
        .WIDTH(1),
        .ADDR_WIDTH(7)
    ) regs (
        .clk(clk),
        .raddr(rf_raddr),
        .rdata(rf_read_bit),
        .waddr(rf_waddr),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Immediate stream
    // ------------------------------------------------------------------
    wire [3:0] imm_low_idx = {1'b0, bit_idx_q[2:0]};
    wire sign_extend_imm = imm_mem_group |
                           (immediate_group & (aaa == 3'b010)) | branch_group;
    wire lui_op = immediate_group & (aaa == 3'b001);
    wire imm_stream_bit =
        lui_op ? (bit_idx_q[3] ? instr_q[imm_low_idx] : 1'b0) :
        bit_idx_q[3] ? (sign_extend_imm & instr_q[7]) : instr_q[imm_low_idx];

    // ------------------------------------------------------------------
    // Bit-serial ALU
    // ------------------------------------------------------------------
    wire lhs_enable = ~(immediate_group & ~aaa[2] & ~aaa[1]);
    wire subtract = register_alu_op & ~f5[2] & (f5[1] | f5[0]);

    wire lhs_bit = rf_read_bit & lhs_enable;
    // Shift/jump ALU results are discarded, so every register-class opcode
    // may select the parked register operand here.
    wire rhs_bit = register_group ? operand_b_q[0] : imm_stream_bit;
    wire adder_rhs_bit = rhs_bit ^ subtract;
    wire [1:0] alu_sum = {1'b0, lhs_bit} + {1'b0, adder_rhs_bit} +
                         {1'b0, alu_carry_q};
    wire sum_bit = alu_sum[0];
    // SLTU subtracts during PREP; only result bit zero emits the parked borrow.
    wire sltu_result = ~alu_carry_q;

    wire logic_op = (immediate_write_op & aaa[2]) | (register_alu_op & f5[2]);
    wire [1:0] logic_fn = immediate_group ? aaa[1:0] : f5[1:0];
    wire logic_result_bit = ((lhs_bit ^ rhs_bit) & (logic_fn[1] | logic_fn[0])) |
                            ((lhs_bit & rhs_bit) & ~logic_fn[1]);
    wire alu_result_bit = logic_op ? logic_result_bit : sum_bit;

    // ------------------------------------------------------------------
    // Branch, PC, shift, and RF writeback
    // ------------------------------------------------------------------
    wire use_pc_offset = branch_group &
        (ddd[2] | ((ddd[1] ? r0_negative_q : r0_zero_q) ^ ddd[0]));
    wire pc_offset_bit = use_pc_offset ? imm_stream_bit : 1'b0;
    wire [1:0] pc_sum = {1'b0, pc_q[0]} + {1'b0, pc_offset_bit} +
                        {1'b0, pc_carry_q};
    wire pc_sum_bit = pc_sum[0];

    wire pc_from_operand = register_jump_op;
    wire next_pc_bit = pc_from_operand ? operand_b_q[0] : pc_sum_bit;
    wire link_pc_bit = pc_sum_bit;

    // The final SARI fill is the source/result sign still in operand_b_q[0].
    wire shift_result_bit = last_bit ?
                            (arithmetic_shift & operand_b_q[0]) : operand_b_q[1];

    wire writes_rd = immediate_write_op | register_alu_op | right_shift_op | call_op;
    // Loads stream directly into the RF during MEM_XFER.  Store-side data is
    // don't-care because rf_we remains low.
    assign rf_wdata =
        in_mem_xfer ? mem_stream_bit :
        call_op ? link_pc_bit :
        right_shift_op ? shift_result_bit :
        sltu_op ? (first_bit & sltu_result) :
        alu_result_bit;
    assign rf_we = (in_execute & writes_rd) | (in_mem_xfer & load_op);
    wire writes_r0 = rf_we & (dest_reg_idx == 3'd0);

    // ------------------------------------------------------------------
    // Datapath state updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (state_q[2] & state_q[0])
            alu_carry_q <= alu_sum[1];
        else
            alu_carry_q <= subtract;

        pc_carry_q <= in_execute ? pc_sum[1] : 1'b1;

        if (in_execute) begin
            pc_q <= {next_pc_bit, pc_q[15:1]};
            addr_q <= {first_bit ? 1'b0 : pc_q[15], addr_q[15:1]};
        end else if (in_prep) begin
            // STB rs,[ra] has no physical index register. Copy the streamed
            // base into the address register instead of inserting a zero
            // mux in every bit of the shared serial adder.
            addr_q <= {(register_memory_op & f5[0]) ? rf_read_bit : sum_bit,
                       addr_q[15:1]};
        end

        if (serial_active)
            operand_b_q <= {rf_read_bit, operand_b_q[15:1]};

        if (writes_r0) begin
            if (first_bit)
                r0_zero_q <= ~rf_wdata;
            else
                r0_zero_q <= r0_zero_q & ~rf_wdata;
            if (last_bit)
                r0_negative_q <= rf_wdata;
        end

        // Reset assignments are last intentionally: reset has priority.
        // Other datapath registers are overwritten before they are observed.
        if (rst) begin
            pc_q <= RESET_PC;
            addr_q <= {RESET_PC[14:0], 1'b0};
            r0_zero_q <= 1'b1;
            r0_negative_q <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        case (state_q)
            ST_FETCH_WAIT:    state_q <= ST_FETCH_CAPTURE;
            ST_FETCH_CAPTURE: state_q <= ST_DECODE;
            ST_DECODE:        state_q <= register_group ? ST_READ_RB :
                                          imm_mem_group ? ST_PREP : ST_EXECUTE;
            ST_READ_RB:       if (last_bit)
                                  state_q <= (register_memory_op | sltu_op) ?
                                             ST_PREP : ST_EXECUTE;
            ST_PREP:          if (last_bit)
                                  state_q <= store_op ? ST_MEM_XFER :
                                             mem_op   ? ST_MEM_WAIT : ST_EXECUTE;
            ST_MEM_WAIT:      state_q <= ST_MEM_XFER;
            ST_MEM_XFER:      if (last_bit) state_q <= ST_EXECUTE;
            ST_EXECUTE:       if (last_bit) state_q <= ST_FETCH_WAIT;
        endcase

        bit_idx_q <= serial_active ? bit_idx_next : 4'd0;

        if (in_fetch_capture)
            instr_q <= mem_rdata;

        if (rst) begin
            state_q <= ST_FETCH_WAIT;
            bit_idx_q <= 4'd0;
        end
    end

    // ------------------------------------------------------------------
    // Memory interface
    // ------------------------------------------------------------------
    // mem_valid is always asserted; mem_we is the one-cycle store strobe and
    // addr_q[0] selects the active byte lane.
    assign mem_addr  = addr_q[15:1];
    assign mem_valid = 1'b1;
    assign mem_we    = in_execute & first_bit & store_op;
    assign mem_wdata = operand_b_q;
    assign mem_wmask = byte_access ? {addr_q[0], ~addr_q[0]} : 2'b11;

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = 1;
    wire        tr_commit_i = in_execute & last_bit;
    wire [14:0] tr_pc_i = pc_q[14:0];
    wire [15:0] tr_ir_i = instr_q;
    wire        tr_ie_i = 1'b0;
    wire        tr_rf_we_i = rf_we;
    wire        tr_rf_bank_i = 1'b0;
    wire [2:0]  tr_rf_reg_i = rf_waddr[6:4];
    wire [3:0]  tr_rf_lsb_i = rf_waddr[3:0];
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif
endmodule

`include "rtl/riscc_rf.vh"

`default_nettype wire
