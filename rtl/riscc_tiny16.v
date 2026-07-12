// riscc_tiny16.v : RISC-C W=16 (single-cycle datapath) core.
//
// The non-serial family member: doc/HARDWARE.md 'Implementation family' (one 17-bit
// adder/result path, one memory-data staging register, no store staging,
// constant-vector IRQ path, and a shared iteration loop for shifts/MUL).
// Every tiny profile has SLT and LDBS.  sys adds variable shifts; full adds
// MUL.

`default_nettype none

module riscc_tiny16 #(
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

`ifndef RISCC_SYS
    /* verilator lint_off UNUSED */
    wire unused_irq = irq;
    /* verilator lint_on UNUSED */
`endif

    // ------------------------------------------------------------------
    // One-hot sequencer and stored datapath state
    // ------------------------------------------------------------------
    localparam ST_DECODE                    = 1;
    localparam ST_OPERAND_LOAD              = 2;
    localparam ST_EXECUTE                   = 3;
    localparam ST_FETCH_REQUEST             = 4;
    localparam ST_MEMORY_ACCESS             = 5;  // read issue/store commit
    localparam ST_LOAD_CAPTURE              = 6;
    localparam ST_LINK_WRITEBACK            = 7;
    localparam ST_JUMP_COMMIT               = 8;
    localparam ST_COMPARE_WRITEBACK         = 9;
    localparam ST_INSTRUCTION_CAPTURE       = 10;
    localparam ST_IRQ_ENTRY                 = 11; // EPC <- PC, IE <- 0, PC <- 2

`ifdef RISCC_SYS
    localparam ST_ITERATION_OPERAND_LOAD     = 12; // shift/MUL operand staging
    localparam ST_ITERATE                    = 13; // one shift/MUL iteration
    localparam ST_MDR_WRITEBACK              = 14; // load/MUL result through ALU

    (* fsm_encoding = "none" *) reg [14:1] state_q;
`else
    localparam ST_MDR_WRITEBACK              = 12; // load result through ALU
    (* fsm_encoding = "none" *) reg [12:1] state_q;
`endif

    reg [15:0] instruction_q;
    reg [14:0] pc_q;        // 15-bit word address
    reg [15:0] mdr_q;
    // Shared because its lifetimes do not overlap: byte lane during memory
    // access, or less-than result while entering compare writeback.
`ifndef RISCC_FULL
    reg        captured_bit_q;
`endif
    reg        interrupt_enable_q;
    reg        r0_zero_q;       // branch-condition shadows for r0
    reg        r0_negative_q;

    wire in_decode              = state_q[ST_DECODE];
    wire in_operand_load        = state_q[ST_OPERAND_LOAD];
    wire in_execute             = state_q[ST_EXECUTE];
    wire in_fetch_request       = state_q[ST_FETCH_REQUEST];
    wire in_memory_access       = state_q[ST_MEMORY_ACCESS];
    wire in_load_capture        = state_q[ST_LOAD_CAPTURE];
    wire in_link_writeback      = state_q[ST_LINK_WRITEBACK];
    wire in_jump_commit         = state_q[ST_JUMP_COMMIT];
    wire in_compare_writeback   = state_q[ST_COMPARE_WRITEBACK];
    wire in_instruction_capture = state_q[ST_INSTRUCTION_CAPTURE];
    wire in_irq_entry           = state_q[ST_IRQ_ENTRY];
    wire in_mdr_writeback       = state_q[ST_MDR_WRITEBACK];
`ifdef RISCC_SYS
    wire in_iteration_operand_load = state_q[ST_ITERATION_OPERAND_LOAD];
    wire in_iterate = state_q[ST_ITERATE];
`endif

    // ------------------------------------------------------------------
    // Instruction fields and immediate decode
    // ------------------------------------------------------------------
    // ST_INSTRUCTION_CAPTURE latches the instruction; ST_DECODE consumes it.
    // The extra state avoids a mem_rdata/instruction mux across the decoder.
    wire immediate_store_word = !instruction_q[15] && instruction_q[14];
    wire immediate_class = instruction_q[15] && !instruction_q[14];
    wire register_class  = instruction_q[15] && instruction_q[14];
    wire immediate_memory = !instruction_q[15];

    wire [2:0] rd = instruction_q[13:11];
    wire [2:0] ra = instruction_q[10:8];
    wire [2:0] immediate_opcode = instruction_q[10:8];
    wire [1:0] register_group  = instruction_q[7:6];
    wire [2:0] register_opcode = instruction_q[5:3];
    wire [2:0] rb = instruction_q[2:0];

    wire immediate_load_group = immediate_class &&
                                !immediate_opcode[2] && !immediate_opcode[1];
    wire load_immediate       = immediate_load_group && !immediate_opcode[0];
    wire load_upper_immediate = immediate_load_group && immediate_opcode[0];
    wire immediate_arithmetic = immediate_class &&
                                !immediate_opcode[2] && immediate_opcode[1];
    wire compare_immediate    = immediate_arithmetic & immediate_opcode[0];
    // JAL16 Sd (register-indirect group, bbb=101): two words, second word
    // is the target.  Sd == S0 writes no link (JMP16 = JAL16 S0).
`ifndef RISCC_SYS
    wire jal16_op = 1'b0;
`else
    wire jal16_op = system_group && rb[2] && !rb[1] && rb[0];
`endif
    wire link_enabled = |rd;    // Sd == S0: no link written (plain jump)
    wire immediate_logic = immediate_class && immediate_opcode[2] &&
                           !(immediate_opcode[1] && immediate_opcode[0]);
    wire branch_op = immediate_class && immediate_opcode[2] &&
                              immediate_opcode[1] && immediate_opcode[0];

    // ------------------------------------------------------------------
    // Register and system decode
    // ------------------------------------------------------------------
    wire register_alu_group = register_class &&
                              !register_group[1] && !register_group[0];
    wire register_memory_group = register_class &&
                                 !register_group[1] && register_group[0];
    // 01_000/010/110 are LDWX/LDB/LDBS; 01_011 is direct STB. Profile-local
    // loose decodes let reserved slots alias existing paths where that avoids
    // a wider exact decoder; defined encodings retain their ISA behavior.
`ifndef RISCC_SYS
    wire register_memory_decode = register_memory_group &&
        (!register_opcode[2] ||
         (register_opcode[1] && !register_opcode[0]));
`elsif RISCC_FULL
    wire register_memory_decode = register_memory_group &&
        (!register_opcode[2] ||
         (register_opcode[1] && !register_opcode[0]));
`else
    // Shift control makes the loose memory-plane aliases unobserved in sys.
    wire register_memory_decode = register_memory_group;
`endif
    wire indexed_byte_load = register_memory_decode &&
                             register_opcode[1] && !register_opcode[0];
`ifndef RISCC_SYS
    wire register_store_group = register_memory_group &&
                                register_opcode[1] && register_opcode[0];
`elsif RISCC_FULL
    wire register_store_group = register_memory_decode && register_opcode[0];
`else
    wire register_store_group = register_memory_decode && register_opcode[0];
`endif
    wire register_subtract = register_alu_group && !register_opcode[2] &&
                             !register_opcode[1] && register_opcode[0];
    wire register_compare = register_alu_group &&
                            !register_opcode[2] && register_opcode[1];
    wire signed_byte_load = register_opcode[2];
    wire right_shift_slot = register_memory_group &&
                            register_opcode[2] && !register_opcode[1];
`ifndef RISCC_SYS
    // min: sys-only slot 101 aliases as JAL
    wire jal_register_op = system_group && !rb[1] && rb[0];
`else
    wire jal_register_op = system_group && ~rb[2] && ~rb[1] && rb[0];
`endif

    // ------------------------------------------------------------------
    // Variable-shift and multiply iteration loop
    // ------------------------------------------------------------------
`ifdef RISCC_SYS
    // SHLI is 01_111; SHRI/SARI use right_shift_slot above.
    wire shift_left_immediate = register_memory_group &&
                                (&register_opcode);
    wire immediate_shift_op = right_shift_slot | shift_left_immediate;
`ifdef RISCC_FULL
    // Full profile: sys immediate shifts plus MUL.  Shifts repeat the existing
    // one-bit path for bbb+1 cycles; MUL runs 16 add/shift steps through
    // {multiply_accumulator_q, mdr_q}, reusing the one adder.  It adds ra to
    // the accumulator when the current multiplier bit mdr_q[0] is set.
    wire multiply_slot = register_alu_group && (&register_opcode);
    wire multiply_op = multiply_slot;
    wire iterative_op = immediate_shift_op | multiply_op;
    reg  [4:0]  iteration_count_q;
    // Outside the iteration states, the counter LSB holds the byte lane or
    // less-than result instead of adding a separate full-profile flip-flop.
    wire captured_bit_q = iteration_count_q[0];
    reg  [15:0] multiply_accumulator_q;
    wire iteration_done = multiply_op ? (iteration_count_q == 5'd0) :
                                        (iteration_count_q[2:0] == 3'd0);
    wire shift_iteration = in_iterate && immediate_shift_op;
    wire shift_right_iteration = shift_iteration && !shift_left_immediate;
    wire shift_left_iteration = shift_iteration && shift_left_immediate;
    wire shift_complete = shift_iteration && iteration_done;
    wire shift_has_more = shift_iteration && !iteration_done;
    wire multiply_complete = in_iterate && multiply_op && iteration_done;
`else
    // Sys profile: immediate shifts only.  MUL is left to software sequences;
    // the shift loop only adds a 3-bit counter and two control states.
    wire iterative_op = immediate_shift_op;
    reg  [2:0]  iteration_count_q;
    wire iteration_done = (iteration_count_q == 3'd0);
    wire shift_iteration = in_iterate;
    wire shift_right_iteration = shift_iteration && !shift_left_immediate;
    wire shift_left_iteration = shift_iteration && shift_left_immediate;
    wire shift_complete = in_iterate && iteration_done;
    wire shift_has_more = in_iterate && !iteration_done;
`endif
`endif

    // Logical register-indirect group 11_111, mandatory ops in the
    // bbb[2]=0 plane:
    //   000 RET Sa   001 JAL Sd, ra   010 MFS rd, Sa   011 MTS Sd, ra
    //   100 RETI Sa  101 JAL16 Sd     110 CLI          111 STI
    // bbb[0]=1 ops write S[ddd]; bbb[0]=0 ops read S[aaa]; RETI = RET+bbb[2].
    wire system_group = register_class && (&register_group);
`ifndef RISCC_SYS
    wire interrupt_enable_op = 1'b0;
`else
    wire interrupt_enable_op = system_group && rb[2] && rb[1];          // CLI/STI: IE <- rb[0]
`endif
    wire return_op = system_group && ~rb[1] && ~rb[0];
    wire mfs_op = system_group && ~rb[2] && rb[1] && ~rb[0];
    wire mts_op = system_group && ~rb[2] && rb[1] && rb[0];

`ifdef RISCC_FULL
    wire register_logic_op = register_alu_group && register_opcode[2] &&
                             !(register_opcode[1] && register_opcode[0]);
`else
    wire register_logic_op = register_alu_group && register_opcode[2];
`endif
`ifndef RISCC_SYS
    wire single_step_shift_op = right_shift_slot;
`else
    wire single_step_shift_op = 1'b0;
`endif
    wire register_memory_or_store = register_memory_decode |
                                    register_store_group;
    wire direct_address_op = immediate_memory | register_store_group;
`ifndef RISCC_SYS
    wire memory_op = direct_address_op | register_memory_decode;
`else
    wire memory_op = immediate_memory | register_memory_or_store;
`endif
    wire store_op = immediate_store_word | register_store_group;
`ifdef RISCC_FULL
    wire byte_memory_op = register_memory_decode && register_opcode[1];
`else
    wire byte_memory_op = register_memory_group && register_opcode[1];
`endif

    wire immediate_alu_op = immediate_arithmetic | immediate_logic;
    wire executes_directly =
        immediate_load_group | immediate_alu_op |
`ifndef RISCC_SYS
        direct_address_op |
`elsif RISCC_FULL
        direct_address_op |
`else
        immediate_memory |
`endif
        single_step_shift_op | mfs_op | mts_op;

    // STB has no rb operand. Min/full issue its ra address directly; sys uses
    // the existing operand-load control as a delay while ignoring encoded
    // bbb=0. The rs value is read later for the memory write.
`ifdef RISCC_FULL
    wire needs_rb_operand = register_alu_group |
                            (register_memory_decode & ~register_opcode[0]);
`elsif RISCC_MIN
    wire needs_rb_operand = register_alu_group |
                            (register_memory_decode & ~register_store_group);
`else
    wire needs_rb_operand = register_alu_group |
                            (register_memory_decode & ~iterative_op);
`endif
`ifndef RISCC_SYS
    wire alu_b_uses_mdr = needs_rb_operand;
`elsif RISCC_FULL
    wire alu_b_uses_mdr = needs_rb_operand;
`else
    wire alu_b_uses_mdr = needs_rb_operand & ~register_store_group;
`endif

    wire start_register_call = in_decode && jal_register_op;
    wire start_direct_execute = in_decode && executes_directly;
`ifndef RISCC_SYS
    wire start_operand_load = in_decode && needs_rb_operand;
`elsif RISCC_FULL
    wire start_operand_load = in_decode &&
                              (needs_rb_operand | iterative_op);
`else
    wire start_operand_load = in_decode &&
                              (needs_rb_operand | iterative_op);
`endif

    // ------------------------------------------------------------------
    // Sequencer control
    // ------------------------------------------------------------------
    wire memory_address_ready = in_execute && memory_op;

    // States that keep the external memory port pointed at PC can begin a
    // fetch; ST_INSTRUCTION_CAPTURE then latches it before ST_DECODE.
    wire execute_complete = (in_execute && !memory_op && !register_compare) |
                            in_mdr_writeback;
`ifndef RISCC_SYS
    wire start_fetch = in_fetch_request | execute_complete | in_compare_writeback;
`else
    wire start_fetch = in_fetch_request | execute_complete | in_compare_writeback | shift_complete;
`endif
`ifndef RISCC_SYS
    wire take_interrupt = 1'b0;
`else
    wire take_interrupt = start_fetch && irq && interrupt_enable_q;
`endif

    // ------------------------------------------------------------------
    // Synchronous register-file schedule
    // ------------------------------------------------------------------
    // A read issued in one state appears during the following state.  The
    // selector priority is rd, then ra, then rb.
`ifdef RISCC_FULL
    wire select_read_rd = immediate_alu_op |
                          (memory_address_ready && store_op) |
                          (in_iteration_operand_load && immediate_shift_op);
`elsif RISCC_MIN
    wire select_read_rd = immediate_alu_op |
                          (memory_address_ready && store_op);
`else
    wire select_read_rd = immediate_alu_op |
                          (memory_address_ready && store_op) | in_iteration_operand_load;
`endif
    wire select_read_rb = in_decode && needs_rb_operand;
    wire [2:0] rf_read_register = select_read_rd ? rd :
                                  select_read_rb ? rb : ra;
    // Upper (system) bank: bbb[0]=0 group ops read S[aaa] (RET/RETI/MFS).
    wire rf_read_system_bank = in_decode && system_group && ~rb[0];

    wire [15:0] rf_read_data;
    // JAL/JAL16 link into S[ddd] -- the same write address as MTS.
    wire [2:0] rf_write_register =
        (in_irq_entry | compare_immediate) ? 3'b000 : rd;
    wire rf_write_system_bank = (in_execute && mts_op) | in_irq_entry |
                                (in_link_writeback && link_enabled);
    wire rf_we =
        (in_link_writeback && link_enabled) | in_compare_writeback |
        in_irq_entry | execute_complete
`ifdef RISCC_SYS
        | (in_iterate && immediate_shift_op)
`endif
        ;
`ifndef RISCC_SYS
    wire [15:0] rf_wdata =
        {in_irq_entry ? interrupt_enable_q : alu_result[15], alu_result[14:0]};
`else
    wire [15:0] rf_wdata = alu_result;
`endif

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

    wire [15:0] zero_extended_imm8 = {8'h00, instruction_q[7:0]};
    wire [15:0] upper_immediate = {instruction_q[7:0], 8'h00};

    // ------------------------------------------------------------------
    // Load formatting and shared ALU
    // ------------------------------------------------------------------
    wire [7:0] selected_load_byte = captured_bit_q ?
                                    mem_rdata[15:8] : mem_rdata[7:0];
    wire [15:0] load_result = byte_memory_op ?
        {{8{signed_byte_load && selected_load_byte[7]}}, selected_load_byte} :
        mem_rdata;

    // One adder/result path.  Logical and shift results are formed as B with A
    // forced to zero.  SLT/SLTU first reuse the subtract path and then write a
    // 0/1 result in ST_COMPARE_WRITEBACK.
    wire alu_a_is_pc = in_decode | in_link_writeback | in_irq_entry;
`ifdef RISCC_FULL
    wire alu_a_is_zero =
        (in_execute && (immediate_load_group | immediate_logic |
                        register_logic_op | single_step_shift_op)) |
        in_mdr_writeback |
        in_compare_writeback | (in_jump_commit && jal16_op) |
        (in_iterate && multiply_op && !mdr_q[0]) | shift_right_iteration;
`elsif RISCC_MIN
    wire alu_a_is_zero =
        (in_execute && (immediate_load_group | immediate_logic |
                        register_logic_op | single_step_shift_op)) |
        in_mdr_writeback |
        in_compare_writeback | (in_jump_commit && jal16_op);
`else
    wire alu_a_is_zero =
        (in_execute && (immediate_load_group | immediate_logic |
                        register_logic_op | single_step_shift_op)) |
        in_mdr_writeback |
        in_compare_writeback | (in_jump_commit && jal16_op) | shift_right_iteration;
`endif
    wire [15:0] alu_a =
        alu_a_is_pc ? {1'b0, pc_q} :
        alu_a_is_zero ? 16'h0000 :
        rf_read_data;

    wire alu_b_is_mdr =
        (in_execute && alu_b_uses_mdr) | in_mdr_writeback |
        (in_jump_commit && jal16_op)
`ifdef RISCC_SYS
        | shift_left_iteration
`endif
        ;
    wire alu_b_is_zero_extended_imm =
        (in_execute && (load_immediate | immediate_arithmetic | immediate_memory)) |
        (in_decode && branch_op && branch_taken);
    wire alu_b_is_upper_imm = in_execute && load_upper_immediate;
    wire [15:0] normal_alu_b =
`ifdef RISCC_FULL
        (in_iterate && multiply_op) ? multiply_accumulator_q :
`endif
        in_compare_writeback ? {15'h0000, captured_bit_q} :
        alu_b_is_mdr ? mdr_q :
        alu_b_is_upper_imm ? upper_immediate :
        alu_b_is_zero_extended_imm ? zero_extended_imm8 : 16'h0000;

    wire [15:0] logic_rhs = register_logic_op ? mdr_q : zero_extended_imm8;
    wire [1:0] logic_function = register_logic_op ?
                                register_opcode[1:0] : immediate_opcode[1:0];
    wire [15:0] logic_result =
        !logic_function[1] ? (logic_function[0] ? (rf_read_data | logic_rhs) :
                                                    (rf_read_data & logic_rhs)) :
                               (rf_read_data ^ logic_rhs);
`ifndef RISCC_SYS
    wire [15:0] single_step_shift_result = register_opcode[0] ?
        {rf_read_data[15], rf_read_data[15:1]} :
        {1'b0, rf_read_data[15:1]};
`endif
`ifdef RISCC_SYS
    wire alu_b_is_shift_result = (in_execute && single_step_shift_op) |
                                 shift_right_iteration;
    wire arithmetic_right_shift =
        (in_execute && single_step_shift_op && register_opcode[0]) |
        (shift_iteration && !shift_left_immediate && register_opcode[0]);
    wire [15:0] iterative_shift_result =
        {arithmetic_right_shift && rf_read_data[15], rf_read_data[15:1]};
`endif
    wire [15:0] alu_b =
        (in_execute && (register_logic_op | immediate_logic)) ? logic_result :
`ifdef RISCC_SYS
        alu_b_is_shift_result ? iterative_shift_result :
`else
        (in_execute && single_step_shift_op) ? single_step_shift_result :
`endif
        normal_alu_b;

    wire subtract_enable = in_execute &&
                           (register_subtract | register_compare |
                            compare_immediate);
    wire sign_extend_immediate =
        (in_execute && (immediate_arithmetic | immediate_memory)) |
        (in_decode && branch_op && branch_taken);
    wire fill_high_byte = sign_extend_immediate && instruction_q[7];
    // The same XOR stage performs subtraction and high-byte sign extension;
    // alu_carry_in supplies the matching +1 for subtraction and PC updates.
    wire [15:0] adjusted_alu_b =
        {alu_b[15:8] ^ {8{subtract_enable ^ fill_high_byte}},
         alu_b[7:0] ^ {8{subtract_enable}}};
    wire alu_carry_in = in_decode | subtract_enable | (in_link_writeback && jal16_op);
    wire [16:0] alu_sum_ext = {1'b0, alu_a} + {1'b0, adjusted_alu_b} +
                              {16'h0000, alu_carry_in};
    wire [15:0] alu_result = alu_sum_ext[15:0];

    wire subtract_overflow = (~(alu_a[15] ^ adjusted_alu_b[15])) &
                             (alu_a[15] ^ alu_result[15]);
    wire signed_less = alu_result[15] ^ subtract_overflow;
    wire unsigned_less = !alu_sum_ext[16];
    wire compare_less = register_opcode[0] ? unsigned_less : signed_less;

    wire branch_taken = (rd[2] && !(rd[1] ^ rd[0])) |
                       (!rd[2] && ((rd[1] ? r0_negative_q : r0_zero_q) ^ rd[0]));

    // ------------------------------------------------------------------
    // Unified external memory port
    // ------------------------------------------------------------------
    wire memory_write_cycle = in_memory_access && store_op;
    assign mem_addr = in_memory_access ? mdr_q[15:1] : pc_q;
    assign mem_wdata = byte_memory_op ?
                       {rf_read_data[7:0], rf_read_data[7:0]} : rf_read_data;
    assign mem_wmask = {2{memory_write_cycle}} &
                       (byte_memory_op ?
                        (captured_bit_q ? 2'b10 : 2'b01) : 2'b11);
    assign mem_we = memory_write_cycle;

    // ------------------------------------------------------------------
    // Sequential state and datapath updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state_q <= (11'b1 << (ST_FETCH_REQUEST - 1));
            pc_q <= RESET_PC[14:0];
            r0_zero_q <= 1'b1;
            r0_negative_q <= 1'b0;
            interrupt_enable_q <= 1'b0;
        end else begin
            // One-hot next-state equations.
            state_q[ST_INSTRUCTION_CAPTURE] <= start_fetch && !take_interrupt;
            state_q[ST_DECODE] <= in_instruction_capture;
            state_q[ST_OPERAND_LOAD] <= start_operand_load;
`ifdef RISCC_FULL
            state_q[ST_EXECUTE] <=
                start_direct_execute | (in_operand_load && !iterative_op);
`elsif RISCC_MIN
            state_q[ST_EXECUTE] <= start_direct_execute | in_operand_load;
`else
            state_q[ST_EXECUTE] <=
                start_direct_execute | (in_operand_load && !iterative_op);
`endif
`ifdef RISCC_SYS
`ifdef RISCC_FULL
            state_q[ST_ITERATION_OPERAND_LOAD] <=
                (in_operand_load && multiply_op) | shift_has_more;
            state_q[ST_ITERATE] <=
                (in_operand_load && immediate_shift_op) | in_iteration_operand_load |
                (in_iterate && multiply_op && !iteration_done);
`else
            state_q[ST_ITERATION_OPERAND_LOAD] <= shift_has_more;
            state_q[ST_ITERATE] <=
                (in_operand_load && iterative_op) | in_iteration_operand_load;
`endif
`endif
            state_q[ST_FETCH_REQUEST] <=
                (in_decode && (branch_op | interrupt_enable_op)) |
                memory_write_cycle | in_jump_commit | in_irq_entry;
            state_q[ST_MEMORY_ACCESS] <= memory_address_ready;
            state_q[ST_LOAD_CAPTURE] <=
                (in_memory_access && !store_op) |
                (in_link_writeback && jal16_op);
            state_q[ST_LINK_WRITEBACK] <=
                start_register_call | (in_decode && jal16_op);
            state_q[ST_JUMP_COMMIT] <=
                (in_link_writeback && !jal16_op) |
                (in_load_capture && jal16_op) | (in_decode && return_op);
            state_q[ST_COMPARE_WRITEBACK] <= in_execute && register_compare;
            state_q[ST_IRQ_ENTRY] <= take_interrupt;
            state_q[ST_MDR_WRITEBACK] <= (in_load_capture && !jal16_op)
`ifdef RISCC_FULL
                                          | multiply_complete
`endif
                                          ;

            // Capture the next instruction after its synchronous read.
            if (in_instruction_capture) begin
                instruction_q <= mem_rdata;
            end

            // PC updates are deliberately separate: IRQ entry has priority.
            if (in_decode | in_jump_commit) begin
                pc_q <= alu_result[14:0];
            end
            if (in_irq_entry) begin
                pc_q <= 15'h0002;
            end

            // Base MDR updates.  The iteration block below may override them
            // later in this process.
            if (in_operand_load | memory_address_ready) begin
                mdr_q <= alu_result;
            end else if (in_load_capture) begin
                mdr_q <= load_result;
            end

`ifdef RISCC_SYS
`ifdef RISCC_FULL
            if (in_operand_load && iterative_op) begin
                iteration_count_q <= multiply_op ? 5'd16 : {2'b00, rb};
                multiply_accumulator_q <= 16'h0000;
            end
            if (in_iterate && !iteration_done) begin
                mdr_q <= multiply_op ? {alu_sum_ext[0], mdr_q[15:1]} :
                         shift_left_iteration ? alu_result : mdr_q;
                multiply_accumulator_q <= multiply_op ?
                                          alu_sum_ext[16:1] :
                                          multiply_accumulator_q;
                iteration_count_q <= iteration_count_q - 5'd1;
            end
`else
            if (in_operand_load && iterative_op) begin
                iteration_count_q <= rb;
            end
            if (shift_iteration && !iteration_done) begin
                iteration_count_q <= iteration_count_q - 3'd1;
            end
            if (shift_left_iteration && !iteration_done) begin
                mdr_q <= alu_result;
            end
`endif
`endif

            // Save either the memory byte lane or the less-than result.
            if (memory_address_ready ||
                (in_execute && register_compare)) begin
`ifdef RISCC_FULL
                iteration_count_q[0] <= register_compare ?
                                        compare_less : alu_result[0];
`else
                captured_bit_q <= register_compare ?
                                  compare_less : alu_result[0];
`endif
            end

            // Branch-condition shadows avoid a separate r0 read.
            if (rf_we && !rf_write_system_bank &&
                (rf_write_register == 3'b000)) begin
                r0_zero_q <= (rf_wdata == 16'h0000);
                r0_negative_q <= rf_wdata[15];
            end

`ifdef RISCC_SYS
            // These independent assignments intentionally establish priority.
            if (in_decode && interrupt_enable_op) begin
                interrupt_enable_q <= rb[0];
            end
            if (in_irq_entry) begin
                interrupt_enable_q <= 1'b0;
            end
            if (in_jump_commit && return_op && rb[2]) begin
                interrupt_enable_q <= 1'b1;  // RETI; RET leaves IE unchanged
            end
`endif
        end
    end

`ifdef RISCC_TRACE
    localparam integer RISCC_TRACE_W = 16;
`ifdef RISCC_SYS
    wire        tr_op_done_i = shift_complete;
`else
    wire        tr_op_done_i = 1'b0;
`endif
    wire        tr_commit_i = execute_complete | in_compare_writeback | tr_op_done_i |
                              (in_decode && (branch_op | interrupt_enable_op)) |
                              memory_write_cycle | in_jump_commit | in_irq_entry;
    wire [14:0] tr_pc_i = pc_q;
    wire [15:0] tr_ir_i = in_irq_entry ? mem_rdata : instruction_q;
    wire        tr_ie_i = interrupt_enable_q;
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
