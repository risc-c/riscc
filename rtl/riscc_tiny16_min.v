// riscc_tiny16_min.v : area-specialized RISC-C/16 Min core.
//
// This full-width Min implementation uses one shared 17-bit adder/result
// path, one memory-data register, and a one-port synchronous register file.
// Sys IRQ, JAL16, variable-shift, and Full multiply machinery remain in the
// separate riscc_tiny16 Sys/Full core.

`default_nettype none

module riscc_tiny16_min #(
    parameter [15:0] RESET_PC = 16'h0000           // word address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,

    output wire [14:0] mem_addr,   // word address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_wmask,
    output wire        mem_we
`ifdef RISCC_TRACE
    ,
`include "riscc_trace_ports.vh"
`endif
);

    /* verilator lint_off UNUSED */
    wire unused_irq = irq;
    /* verilator lint_on UNUSED */

    // ------------------------------------------------------------------
    // One-hot sequencer
    // ------------------------------------------------------------------
    localparam ST_DECODE              = 1;
    localparam ST_OPERAND_LOAD        = 2;
    localparam ST_EXECUTE             = 3;
    localparam ST_FETCH_REQUEST       = 4;
    localparam ST_MEMORY_ACCESS       = 5;
    localparam ST_LOAD_CAPTURE        = 6;
    localparam ST_JUMP_COMMIT         = 7;
    localparam ST_COMPARE_WRITEBACK   = 8;
    localparam ST_INSTRUCTION_CAPTURE = 9;
    localparam ST_MDR_WRITEBACK       = 10;

    (* fsm_encoding = "none" *) reg [10:1] state_q;

    wire in_decode              = state_q[ST_DECODE];
    wire in_operand_load        = state_q[ST_OPERAND_LOAD];
    wire in_execute             = state_q[ST_EXECUTE];
    wire in_fetch_request       = state_q[ST_FETCH_REQUEST];
    wire in_memory_access       = state_q[ST_MEMORY_ACCESS];
    wire in_load_capture        = state_q[ST_LOAD_CAPTURE];
    wire in_jump_commit         = state_q[ST_JUMP_COMMIT];
    wire in_compare_writeback   = state_q[ST_COMPARE_WRITEBACK];
    wire in_instruction_capture = state_q[ST_INSTRUCTION_CAPTURE];
    wire in_mdr_writeback       = state_q[ST_MDR_WRITEBACK];

    // ------------------------------------------------------------------
    // Stored datapath state and instruction decode
    // ------------------------------------------------------------------
    reg [15:0] instruction_q;
    reg [14:0] pc_q;
    reg [15:0] mdr_q;
    // The byte lane and less-than result have disjoint lifetimes.
    reg        captured_bit_q;
    reg        r0_zero_q;
    reg        r0_negative_q;

    wire immediate_store_word = !instruction_q[15] && instruction_q[14];
    wire immediate_class = instruction_q[15] && !instruction_q[14];
    wire register_class  = instruction_q[15] && instruction_q[14];
    wire immediate_memory = !instruction_q[15];

    wire [2:0] rd = instruction_q[13:11];
    wire [2:0] ra = instruction_q[10:8];
    wire [2:0] immediate_opcode = instruction_q[10:8];
    wire [1:0] register_group = instruction_q[7:6];
    wire [2:0] register_opcode = instruction_q[5:3];
    wire [2:0] rb = instruction_q[2:0];

    wire immediate_load_group =
        immediate_class && !immediate_opcode[2] && !immediate_opcode[1];
    wire load_immediate = immediate_load_group && !immediate_opcode[0];
    wire load_upper_immediate =
        immediate_load_group && immediate_opcode[0];
    wire immediate_arithmetic =
        immediate_class && !immediate_opcode[2] && immediate_opcode[1];
    // Branches never execute the ALU state, so their low opcode bits may
    // alias CMPI's internal destination/subtract plane.
    wire compare_immediate =
        immediate_class && immediate_opcode[1] && immediate_opcode[0];
    wire immediate_logic =
        immediate_class && immediate_opcode[2] &&
        !(immediate_opcode[1] && immediate_opcode[0]);
    wire branch_op =
        immediate_class && immediate_opcode[2] &&
        immediate_opcode[1] && immediate_opcode[0];

    wire register_alu_group =
        register_class && !register_group[1] && !register_group[0];
    wire register_memory_group =
        register_class && !register_group[1] && register_group[0];
    // Reserved register-memory selectors may alias these loose planes.
    wire register_memory_decode =
        register_memory_group &&
        (!register_opcode[2] ||
         (register_opcode[1] && !register_opcode[0]));
    wire register_store_group =
        register_memory_group &&
        register_opcode[1] && register_opcode[0];
    wire register_compare =
        register_alu_group && !register_opcode[2] && register_opcode[1];
    wire register_subtract_or_compare =
        register_alu_group && !register_opcode[2] &&
        (register_opcode[1] | register_opcode[0]);
    wire register_logic_op =
        register_alu_group && register_opcode[2];

    wire right_shift_slot =
        register_memory_group &&
        register_opcode[2] && !register_opcode[1];
    wire funnel_op =
        register_class && register_group[1] && !register_group[0];
    wire funnel_right_op = funnel_op && !register_opcode[0];
    wire funnel_left_op = funnel_op && register_opcode[0];
    wire single_step_shift_op = right_shift_slot | funnel_right_op;

    wire system_group = register_class && (&register_group);
    // Min lets the Sys-only high selector bit alias RET/JAL.
    wire jal_register_op = system_group && !rb[1] && rb[0];
    wire return_op = system_group && !rb[1] && !rb[0];
    wire mfs_op = system_group && !rb[2] && rb[1] && !rb[0];
    wire mts_op = system_group && !rb[2] && rb[1] && rb[0];
    wire link_enabled = |rd;

    wire direct_address_op = immediate_memory | register_store_group;
    wire memory_op = direct_address_op | register_memory_decode;
    wire store_op = immediate_store_word | register_store_group;
    wire byte_memory_op =
        register_memory_group && register_opcode[1];
    wire signed_byte_load = register_opcode[2];

    wire immediate_alu_op = immediate_arithmetic | immediate_logic;
    wire executes_directly =
        immediate_load_group | immediate_alu_op | direct_address_op |
        right_shift_slot | mfs_op | mts_op;
    // STB has no rb operand; its ra address executes directly.
    wire ordinary_rb_operand =
        register_alu_group |
        (register_memory_decode & ~register_store_group);
    wire needs_rb_operand = ordinary_rb_operand | funnel_op;

    // ------------------------------------------------------------------
    // Sequencer and synchronous RF schedule
    // ------------------------------------------------------------------
    wire start_register_call = in_decode && jal_register_op;
    wire start_direct_execute = in_decode && executes_directly;
    wire start_operand_load = in_decode && needs_rb_operand;
    wire memory_address_ready = in_execute && memory_op;
    wire funnel_left_execute = in_execute && funnel_left_op;
    wire update_mdr_from_alu =
        in_operand_load | memory_address_ready | funnel_left_execute;
    wire execute_complete =
        (in_execute && !memory_op && !register_compare &&
         !funnel_left_op) |
        in_mdr_writeback;
    wire writeback_complete =
        execute_complete | in_compare_writeback;
    wire start_fetch =
        in_fetch_request | writeback_complete;

    // A read issued in one state appears during the following state. LDI,
    // LUI, and branches ignore RF data, so one broad immediate selector is
    // smaller than separately decoding only the immediate ALU operations.
    wire select_read_rd =
        immediate_class | (in_execute && store_op);
    wire select_read_rb = start_operand_load;
    wire [2:0] rf_read_register =
        select_read_rd ? rd : select_read_rb ? rb : ra;
    wire rf_read_system_bank =
        in_decode && system_group && !rb[0];

    wire [15:0] rf_read_data;
    wire [2:0] rf_write_register =
        compare_immediate ? 3'b000 : rd;
    // rf_we qualifies the state. Keeping MTS selected outside Execute and
    // selecting the JAL bank even when S0 suppresses its write maps smaller.
    wire rf_write_system_bank =
        mts_op | start_register_call;
    wire rf_we =
        (start_register_call && link_enabled) |
        writeback_complete;
    wire [15:0] rf_wdata = alu_result;

    riscc_rf #(
        .WIDTH(16),
        .ADDR_WIDTH(4)
    ) regs (
        .clk(clk),
        .raddr({rf_read_system_bank, rf_read_register}),
        .rdata(rf_read_data),
        .waddr({rf_write_system_bank, rf_write_register}),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Load formatting and shared ALU
    // ------------------------------------------------------------------
    wire [15:0] zero_extended_imm8 = {8'h00, instruction_q[7:0]};
    wire [15:0] upper_immediate = {instruction_q[7:0], 8'h00};
    wire [7:0] selected_load_byte =
        captured_bit_q ? mem_rdata[15:8] : mem_rdata[7:0];
    wire [15:0] load_result = byte_memory_op ?
        {{8{signed_byte_load && selected_load_byte[7]}},
         selected_load_byte} :
        mem_rdata;

    // Increment PC while the fetched word is captured. Decode then sees
    // pc_next, so JAL can write its link immediately without another state.
    wire alu_a_is_pc = in_instruction_capture | in_decode;
    wire alu_a_is_zero =
        (in_execute &&
         (immediate_load_group | immediate_logic |
          register_logic_op | single_step_shift_op)) |
        (in_mdr_writeback && !funnel_left_op) |
        in_compare_writeback;
    wire [15:0] alu_a =
        alu_a_is_pc ? {1'b0, pc_q} :
        alu_a_is_zero ? 16'h0000 :
        rf_read_data;

    wire alu_b_is_mdr =
        (in_execute && ordinary_rb_operand) | in_mdr_writeback;
    wire branch_taken =
        (rd[2] && !rd[1]) |
        (!rd[2] &&
         ((rd[1] ? r0_negative_q : r0_zero_q) ^ rd[0]));
    // Always form a branch target; the PC write enable decides whether it is
    // consumed. This keeps the flag result out of the wide ALU-input mux.
    wire alu_b_is_zero_extended_imm =
        (in_execute &&
         (load_immediate | immediate_arithmetic | immediate_memory)) |
        (in_decode && branch_op);
    wire alu_b_is_upper_imm =
        in_execute && load_upper_immediate;
    wire [15:0] normal_alu_b =
        in_compare_writeback ? {15'h0000, captured_bit_q} :
        alu_b_is_mdr ? mdr_q :
        alu_b_is_upper_imm ? upper_immediate :
        alu_b_is_zero_extended_imm ? zero_extended_imm8 :
        16'h0000;

    wire [15:0] logic_rhs =
        register_logic_op ? mdr_q : zero_extended_imm8;
    wire [1:0] logic_function =
        register_logic_op ? register_opcode[1:0] :
                            immediate_opcode[1:0];
    wire [15:0] logic_result =
        !logic_function[1] ?
            (logic_function[0] ? (rf_read_data | logic_rhs) :
                                 (rf_read_data & logic_rhs)) :
            (rf_read_data ^ logic_rhs);

    wire single_step_shift_input =
        funnel_right_op ? mdr_q[0] :
        (register_opcode[0] && rf_read_data[15]);
    wire [15:0] single_step_shift_result =
        {single_step_shift_input, rf_read_data[15:1]};
    wire [15:0] alu_b =
        (in_execute && (register_logic_op | immediate_logic)) ?
            logic_result :
        (in_execute && single_step_shift_op) ?
            single_step_shift_result :
        normal_alu_b;

    wire subtract_enable =
        in_execute &&
        (register_subtract_or_compare | compare_immediate);
    wire sign_extend_immediate =
        (in_execute && (immediate_arithmetic | immediate_memory)) |
        (in_decode && branch_op);
    wire fill_high_byte =
        sign_extend_immediate && instruction_q[7];
    // The XOR stage performs subtraction and immediate sign extension.
    wire [15:0] adjusted_alu_b =
        {alu_b[15:8] ^ {8{subtract_enable ^ fill_high_byte}},
         alu_b[7:0] ^ {8{subtract_enable}}};
    // FSL1's first pass stores ra + rb[15] in MDR. Writeback adds ra once
    // more, producing (ra << 1) | rb[15] without a carry register.
    wire alu_carry_in =
        in_instruction_capture | subtract_enable |
        (funnel_left_execute && mdr_q[15]);
    wire [16:0] alu_sum_ext =
        {1'b0, alu_a} + {1'b0, adjusted_alu_b} +
        {16'h0000, alu_carry_in};
    wire [15:0] alu_result = alu_sum_ext[15:0];

    wire subtract_overflow =
        (~(alu_a[15] ^ adjusted_alu_b[15])) &
        (alu_a[15] ^ alu_result[15]);
    wire signed_less = alu_result[15] ^ subtract_overflow;
    wire unsigned_less = !alu_sum_ext[16];
    wire compare_less =
        register_opcode[0] ? unsigned_less : signed_less;

    // ------------------------------------------------------------------
    // Unified memory port
    // ------------------------------------------------------------------
    wire memory_write_cycle = in_memory_access && store_op;
    assign mem_addr = in_memory_access ? mdr_q[15:1] : pc_q;
    assign mem_wdata = byte_memory_op ?
                       {rf_read_data[7:0], rf_read_data[7:0]} :
                       rf_read_data;
    assign mem_wmask = byte_memory_op ?
        (captured_bit_q ? 2'b10 : 2'b01) :
        2'b11;
    assign mem_we = memory_write_cycle;

    // ------------------------------------------------------------------
    // Sequential state and datapath updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state_q <= (10'b1 << (ST_FETCH_REQUEST - 1));
            pc_q <= RESET_PC[14:0];
            r0_zero_q <= 1'b1;
            r0_negative_q <= 1'b0;
        end else begin
            state_q[ST_INSTRUCTION_CAPTURE] <= start_fetch;
            state_q[ST_DECODE] <= in_instruction_capture;
            state_q[ST_OPERAND_LOAD] <= start_operand_load;
            state_q[ST_EXECUTE] <=
                start_direct_execute | in_operand_load;
            state_q[ST_FETCH_REQUEST] <=
                (in_decode && branch_op) |
                memory_write_cycle | in_jump_commit;
            state_q[ST_MEMORY_ACCESS] <= memory_address_ready;
            state_q[ST_LOAD_CAPTURE] <=
                in_memory_access && !store_op;
            state_q[ST_JUMP_COMMIT] <=
                start_register_call | (in_decode && return_op);
            state_q[ST_COMPARE_WRITEBACK] <=
                in_execute && register_compare;
            state_q[ST_MDR_WRITEBACK] <=
                in_load_capture | funnel_left_execute;

            if (in_instruction_capture)
                instruction_q <= mem_rdata;

            if (in_instruction_capture |
                (in_decode && branch_op && branch_taken) |
                in_jump_commit)
                pc_q <= alu_result[14:0];

            if (in_load_capture | update_mdr_from_alu)
                mdr_q <= in_load_capture ? load_result : alu_result;

            if (memory_address_ready ||
                (in_execute && register_compare))
                captured_bit_q <=
                    memory_address_ready ? alu_result[0] : compare_less;

            if (rf_we && !rf_write_system_bank &&
                !(|rf_write_register)) begin
                r0_zero_q <= (rf_wdata == 16'h0000);
                r0_negative_q <= rf_wdata[15];
            end
        end
    end

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = 16;
    wire tr_commit_i =
        writeback_complete | (in_decode && branch_op) |
        memory_write_cycle | in_jump_commit;
    wire [14:0] tr_pc_i = pc_q;
    wire [15:0] tr_ir_i = instruction_q;
    wire        tr_ie_i = 1'b0;
    wire        tr_rf_we_i = rf_we;
    wire        tr_rf_bank_i = rf_write_system_bank;
    wire [2:0]  tr_rf_reg_i = rf_write_register;
    wire [3:0]  tr_rf_lsb_i = 4'd0;
    wire [RISCC_TRACE_W-1:0] tr_rf_data_i = rf_wdata;
`include "riscc_trace_state.vh"
`endif

endmodule

`include "rtl/riscc_rf.vh"

`default_nettype wire
