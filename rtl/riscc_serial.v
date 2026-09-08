// Serial RISC-C: 16- or 32-bit registers, processed W bits per cycle.
// An instruction follows FETCH -> DECODE -> [STAGE] -> [PREPARE] -> EXECUTE.
// Loads and stores visit MEMORY/TRANSFER before EXECUTE. Full repeats EXECUTE
// for shifts and multiply; configurations with a shared adder add a PC pass.
//
// A pass processes the register slices from low to high. The RF reads the next
// slice while the current one is used; data_q, address_q and pc_q rotate by W.
// Memory transfers one halfword at a time and holds requests until mem_ready.

`default_nettype none

module riscc_serial #(
    parameter integer XLEN = 16,
    parameter integer W = 4,          // power of two, W < XLEN, W <= 16
    parameter integer PROFILE = 0,    // 0 = Min, 1 = Sys, 2 = Full
    parameter [XLEN-1:0] RESET_PC = 0  // byte address
) (
    input  wire clk,
    input  wire rst,
    input  wire irq,
    output wire [XLEN-2:0] mem_addr,  // halfword address
    input  wire [15:0] mem_rdata,
    output wire [15:0] mem_wdata,
    output wire [1:0] mem_wmask,
    output wire mem_we,
    output wire mem_valid,
    input  wire mem_ready
`ifdef RISCC_TRACE
    , output wire trace_valid,
    output wire [XLEN-1:0] trace_pc,
    output wire [15:0] trace_ir,
    output wire trace_ie,
    output wire [XLEN-1:0] trace_r0, trace_r1, trace_r2, trace_r3,
    output wire [XLEN-1:0] trace_r4, trace_r5, trace_r6, trace_r7,
    output wire [XLEN-1:0] trace_s0, trace_s1, trace_s2, trace_s3,
    output wire [XLEN-1:0] trace_s4, trace_s5, trace_s6, trace_s7
`endif
);
    localparam HAS_SYSTEM = PROFILE >= 1;
    localparam HAS_FULL = PROFILE == 2;
    // Sharing the ALU saves area at W >= 8 but adds a PC pass.
    // RC16 Full keeps its separate PC adder to avoid that cycle cost.
    localparam SHARE_PC_ADDER = W >= 8 && !(XLEN == 16 && HAS_FULL);
    localparam integer SLICES = XLEN / W;
    localparam integer SLICE_BITS = $clog2(SLICES);
    localparam integer BIT_INDEX_BITS = $clog2(XLEN);
    localparam integer RF_ADDR_BITS = 4 + SLICE_BITS;
    localparam integer LAST_HALFWORD_BIT = 16 - W;
    localparam integer BYTE_SLICES = 8 / W;
    localparam integer SLICE_BIT_MASK = W - 1;
    localparam integer MULT_INDEX_BITS = (W == 1) ? 1 : $clog2(W);

    initial begin
        if ((XLEN != 16 && XLEN != 32) || W < 1 || W > 16 ||
            W >= XLEN || (W & (W-1)) != 0 || PROFILE < 0 || PROFILE > 2)
            $error("riscc_serial: invalid XLEN, W or PROFILE");
    end

    // State bit 2 enables the slice counter.
    localparam [2:0]
        FETCH    = 0,  // wait for instruction
        DECODE   = 1,  // select operands, check IRQ
        MEMORY   = 2,  // wait for data or jump literal
        STAGE    = 4,  // read operand into data_q
        PREPARE  = 5,  // form address, compare, or initialize MUL
        TRANSFER = 6,  // move data between RF and memory buffers
        EXECUTE  = 7;  // write result and update PC

    reg [2:0] state_q;
    reg [SLICE_BITS-1:0] slice_q;
    reg pc_phase_q;

    wire fetching = state_q == FETCH;
    wire decoding = state_q == DECODE;
    wire waiting = state_q == MEMORY;
    wire preparing = state_q == PREPARE;
    wire transferring = state_q == TRANSFER;
    wire executing = state_q == EXECUTE;

    // A shared adder writes the data result and PC in separate passes.
    wire result_pass = executing && (!SHARE_PC_ADDER || !pc_phase_q);
    wire pc_pass = executing && (!SHARE_PC_ADDER || pc_phase_q);

    wire counted = state_q[2];
    wire first_slice = ~|slice_q;
    wire last_slice = &slice_q;
    wire [SLICE_BITS-1:0] next_slice = slice_q + 1'b1;
    wire [BIT_INDEX_BITS-1:0] bit_offset = {slice_q, {$clog2(W){1'b0}}};
    wire [3:0] half_offset = bit_offset[3:0];
    wire half_end = half_offset == LAST_HALFWORD_BIT[3:0];
    wire upper_half = (XLEN == 32) && bit_offset[BIT_INDEX_BITS-1];
    // RC32 resumes at the upper halfword after a memory wait.
    wire [SLICE_BITS-1:0] resume_slice = (XLEN == 32) ? slice_q : 0;

    reg [15:0] instr_q;
    reg [XLEN-1:0] pc_q;
    reg [XLEN-1:0] address_q;
    reg [XLEN-1:0] data_q;
    reg [15:0] response_q;
    reg ie_q, trap_q, literal_q;
    wire trap = HAS_SYSTEM && trap_q;
    wire take_irq = HAS_SYSTEM && ie_q && irq;
    wire literal = HAS_SYSTEM && literal_q;

    // ISA fields; immediate and system formats reuse the register fields.
    wire [2:0] ddd = instr_q[13:11];  // destination / branch condition
    wire [2:0] aaa = instr_q[10:8];   // source A / immediate opcode
    wire [4:0] fn = instr_q[7:3];    // register opcode
    wire [2:0] bbb = instr_q[2:0];   // source B / shift count / sub-op

    // Instruction decode
    wire immediate = instr_q[15:14] == 2'b10;
    // Min's unused long-instruction plane aliases native memory.
    wire memory_immediate = !instr_q[15] && (instr_q[14] || !HAS_SYSTEM);
    wire register_op = instr_q[15] && instr_q[14];
    wire long_jump = HAS_SYSTEM && (instr_q[15:14] == 2'b00);

    wire branch = immediate && (&aaa);
    wire ldpc = (XLEN == 32) && immediate && aaa == 1;
    // LDPC uses PC to form the load address, then subtracts the offset afterward.
    wire prepare_ldpc = preparing && ldpc;
    wire restore_ldpc = executing && ldpc && !trap;
    wire lui = (XLEN == 16) && immediate && aaa == 1;
    wire immediate_alu = immediate && !branch && !ldpc;
    // Branches share CMPI's decode but do not write a result.
    wire compare_immediate = immediate && aaa[1] && aaa[0];

    // Arithmetic and funnel operations share the buffered ALU operand.
    wire alu_group = register_op && !fn[3];
    wire arithmetic = alu_group && !fn[4];
    wire multiply = HAS_FULL && arithmetic && (fn[2:0] == 3'b111);
    wire ordinary_alu = arithmetic && !multiply;
    wire funnel = alu_group && fn[4];
    wire compare = arithmetic && (fn[2:1] == 2'b01);
    wire signed_compare = !fn[0];

    wire memory_plane = register_op && (fn[4:3] == 2'b01);
    wire indexed_load = memory_plane && (fn[2:1] == 2'b00);
    wire direct_load = memory_plane && fn[1] && !fn[0];
    wire direct_store = memory_plane && (fn[2:0] == 3'b011);
    wire right_shift = memory_plane && (fn[2:1] == 2'b10);
    wire left_shift = HAS_FULL && memory_plane && (fn[2:0] == 3'b111);
    wire shift = right_shift || left_shift;
    wire funnel_right = funnel && bbb[0];

    wire system_op = register_op && (fn[4:3] == 2'b11);
    wire control = system_op && (bbb[1:0] == 2'b00);
    wire register_jump = system_op && !bbb[1] &&
                         (bbb[0] || !HAS_SYSTEM || !ddd[1]);
    wire register_link = system_op && !bbb[1] && bbb[0];
    wire system_move = system_op && bbb[1];
    wire link = register_link || literal;

    wire load_op = (memory_immediate && !instr_q[0]) ||
                   indexed_load || direct_load || ldpc;
    wire store_op = (memory_immediate && instr_q[0]) || direct_store;
    wire memory_op = load_op || store_op;
    wire byte_access = (direct_load || direct_store) &&
                       ((XLEN == 16) || !bbb[1]);
    wire native_load = (memory_immediate && !instr_q[0]) || indexed_load || ldpc;
    wire native_store = memory_immediate && instr_q[0];
    wire signed_load = fn[2];

    wire data_operand = alu_group || indexed_load;
    wire needs_stage = data_operand || shift || register_jump;
    wire needs_prepare = memory_op || compare || funnel || multiply;

    // Repeated shifts and MUL (Full only).
    // MUL accumulates in rd, shifts ra in data_q, and holds rb in address_q.
    reg [BIT_INDEX_BITS-1:0] pass_q;
    reg left_carry_q, low_bit_q;
    wire repeat_execute = HAS_FULL && (shift || multiply) && !trap &&
                          result_pass && !(&pass_q);
    // Only MUL starts at pass zero; other instructions start in the last eight.
    wire clear_product = HAS_FULL && result_pass && !(|pass_q);
    wire refill_multiplier = (pass_q & SLICE_BIT_MASK[BIT_INDEX_BITS-1:0]) ==
                              SLICE_BIT_MASK[BIT_INDEX_BITS-1:0];
    // Read the next multiplier bit before PC updates overwrite address_q.
    reg multiplier_bit_q;
    // Bits 1..W are the next bits to use, including the next slice's bit 0.
    // PREPARE selects bit W, which becomes rb[0] after its final rotation.
    wire [W-1:0] next_multiplier_bits = address_q[W:1];
    wire [MULT_INDEX_BITS-1:0] multiplier_index =
        (pass_q[MULT_INDEX_BITS-1:0] | {MULT_INDEX_BITS{preparing}}) &
        SLICE_BIT_MASK[MULT_INDEX_BITS-1:0];

    // RF read schedule. The last cycle of a pass requests the next operand.
    // Normal ALU: stage rb, then read ra. Funnel: stage ra, then read rd.
    // MUL: stage ra, prepare rb, then read/write the rd accumulator.
    reg read_staged, read_multiplier, read_rd;
    always @* begin
        read_staged = 1'b0;
        read_multiplier = 1'b0;
        read_rd = 1'b0;
        case (state_q)
            DECODE:
                read_staged = 1'b1;
            STAGE: begin
                read_staged = !last_slice;
                read_multiplier = last_slice;
            end
            PREPARE: begin
                read_multiplier = !last_slice;
                read_rd = (store_op || multiply) && last_slice;
            end
            MEMORY:
                // RC32 stores prefetch rd for the next memory beat.
                read_rd = XLEN == 32;
            TRANSFER:
                read_rd = 1'b1;
            EXECUTE:
                read_rd = multiply;
            default: ;
        endcase
    end
    wire read_rb = multiply ? read_multiplier : (data_operand && read_staged);
    wire read_dest = read_rd || immediate || funnel;
    wire [2:0] read_index = read_rb ? (funnel ? aaa : bbb) :
                            read_dest ? ddd : aaa;
    // MFS and RET/RETI read the system bank; ALU operands use GPRs.
    wire [3:0] read_reg = {system_op && !bbb[0], read_index};
    // Trap entry writes S0; CMPI writes R0. Other writes use ddd.
    wire write_system = trap || (system_op && bbb[0]) || literal;
    wire write_zero = trap || compare_immediate;
    wire [3:0] write_reg = {write_system, write_zero ? 3'b000 : ddd};
    wire [SLICE_BITS-1:0] read_slice =
        counted ? next_slice :
        (waiting && !(direct_store && mem_ready)) ?
            resume_slice : {SLICE_BITS{1'b0}};
    // Byte accesses rotate the RF address to match the memory lane.
    // At W=16 both bytes are in one slice; the data mux handles the lane.
    wire rotate_store = (W <= 8) && direct_store && read_rd && low_bit_q;
    wire [SLICE_BITS-1:0] store_rotation =
        {SLICE_BITS{rotate_store}} & BYTE_SLICES[SLICE_BITS-1:0];
    wire rotate_load = (W > 1 && W <= 8) && transferring && load_op &&
                       byte_access && low_bit_q;
    wire [SLICE_BITS-1:0] write_slice = slice_q ^
        ({SLICE_BITS{rotate_load}} & BYTE_SLICES[SLICE_BITS-1:0]);
    wire [BIT_INDEX_BITS-1:0] write_bit = {write_slice, {$clog2(W){1'b0}}};
    wire writes_result = immediate_alu || arithmetic || funnel || shift || system_move;
    wire write_alu = result_pass && writes_result && !trap;
    wire write_link = pc_pass && (trap || ((|ddd) && link));
    wire write_load = transferring && load_op;
    wire rf_we = write_alu || write_link || write_load;
    wire [W-1:0] rf_rdata, rf_wdata;
    riscc_rf #(.WIDTH(W), .ADDR_WIDTH(RF_ADDR_BITS)) regs (
        .clk   (clk),
        .raddr ({read_reg, read_slice ^ store_rotation}),
        .rdata (rf_rdata),
        .waddr ({write_reg, write_slice}),
        .wdata (rf_wdata),
        .we    (rf_we)
    );

    // Immediate operand. Address bit 0 is ignored by memory and forced to 1
    // for PC arithmetic. RC32 native memory also clears bit 1 for alignment.
    wire memory_sign = memory_immediate &&
                       ((XLEN == 32) ? instr_q[1] : instr_q[7]);
    wire relative_sign = (branch || ldpc) && instr_q[0];
    wire arithmetic_sign = !memory_immediate && !aaa[2] && aaa[1] && instr_q[7];
    wire immediate_sign = memory_sign || relative_sign || arithmetic_sign;
    wire [7:0] immediate_byte = {instr_q[7:2],
        instr_q[1] && !((XLEN == 32) && memory_immediate), instr_q[0]};
    wire [XLEN-1:0] immediate_word =
        {{(XLEN-8){immediate_sign}}, immediate_byte};
    // LUI swaps bytes by changing the slice index.
    wire [BIT_INDEX_BITS-1:0] immediate_bit = bit_offset ^
        {{(BIT_INDEX_BITS-4){1'b0}}, lui, 3'b0};
    wire [W-1:0] immediate_slice = immediate_word[immediate_bit +: W];
    wire [W-1:0] step_slice = {{(W-1){1'b0}}, first_slice};

    // ALU. SLT leaves its one-bit result in carry after PREPARE, then writes
    // it with both operands zero. LDI/LUI and the first MUL pass also clear A.
    wire subtract = (ordinary_alu && (fn[1] || fn[0])) || compare_immediate;
    wire compare_result = compare && result_pass;
    wire zero_a = (immediate && !aaa[2] && !aaa[1]) ||
                  compare_result || clear_product;
    wire zero_b = system_op || (memory_plane && fn[1]) || compare_result ||
                  (multiply && !(executing && multiplier_bit_q));
    wire use_pc_adder = SHARE_PC_ADDER && (pc_pass || prepare_ldpc);
    wire b_from_data = data_operand && !use_pc_adder;
    wire enable_b = use_pc_adder ? ((branch_taken || ldpc) && !trap) : !zero_b;
    wire [W-1:0] alu_a = rf_rdata & {W{!zero_a}};
    wire [W-1:0] operand_b = b_from_data ? data_q[W-1:0] : immediate_slice;
    wire [W-1:0] alu_b_raw = operand_b & {W{enable_b}};
    wire invert_b = use_pc_adder ? restore_ldpc : subtract && !compare_result;
    wire [W-1:0] alu_b = (alu_b_raw ^ {W{invert_b}}) |
                        (step_slice & {W{use_pc_adder && !trap}});
    reg alu_carry_q;
    reg pc_carry_q;
    wire [W-1:0] sum_a = use_pc_adder ? pc_q[W-1:0] : alu_a;
    wire sum_carry = use_pc_adder ? pc_carry_q : alu_carry_q;
    wire [W:0] sum = {1'b0, sum_a} + {1'b0, alu_b} + {{W{1'b0}}, sum_carry};
    // Signed comparison reverses unsigned order when the operand signs differ.
    wire opposite_signs = rf_rdata[W-1] != alu_b_raw[W-1];
    wire borrow = !sum[W];
    wire less_than = borrow ^ (signed_compare && opposite_signs);
    always @(posedge clk) begin
        if (preparing && last_slice && !multiply) begin
            // FSL starts with ra's high bit; SLT starts with its comparison bit.
            if (funnel)
                alu_carry_q <= data_q[W-1];
            else
                alu_carry_q <= less_than;
        end else if (preparing || result_pass) begin
            // Each repeated shift/MUL pass starts with carry zero.
            if (HAS_FULL && last_slice)
                alu_carry_q <= 1'b0;
            else
                alu_carry_q <= sum[W];
        end else begin
            // A - B is A + ~B + 1.
            alu_carry_q <= subtract;
        end
    end

    // Branches also have aaa[2] set, but never write an ALU result.
    wire logic_op = (immediate && aaa[2]) || (ordinary_alu && fn[2]);
    wire [1:0] logic_select = immediate ? aaa[1:0] : fn[1:0];
    reg [W-1:0] logic_result;
    always @* begin
        if (logic_select[1])
            logic_result = rf_rdata ^ alu_b_raw;
        else if (logic_select[0])
            logic_result = rf_rdata | alu_b_raw;
        else
            logic_result = rf_rdata & alu_b_raw;
    end

    // Shifter
    // Interior slices take their incoming bit from the adjacent slice.
    // At the word boundary, right shifts use zero, sign, or the funnel bit.
    wire right_fill = funnel ? low_bit_q : (fn[0] && data_q[W-1]);
    wire right_input = last_slice ? right_fill : data_q[W];
    wire left_input = !first_slice && left_carry_q;
    wire [W:0] right_bits = {right_input, data_q[W-1:0]};
    wire [W:0] left_bits = {data_q[W-1:0], left_input};
    wire [W-1:0] right_result = right_bits[W:1];
    wire [W-1:0] left_result = left_bits[W-1:0];
    // SLLI and MUL use low function bits 11; right shifts use 00/01.
    wire [W-1:0] shift_result =
        (HAS_FULL && fn[1] && fn[0]) ? left_result : right_result;

    // Load result: select the memory lane, then zero- or sign-extend it.
    wire [7:0] addressed_byte = low_bit_q ? response_q[15:8] : response_q[7:0];
    wire fill_bit = signed_load &&
                    (byte_access ? addressed_byte[7] : response_q[15]);
    wire [W-1:0] load_slice;
    generate
        if (W == 1) begin : g_load_bit
            // Select the byte in the bit address; RF writes stay in order.
            wire [3:0] load_bit = {
                byte_access ? low_bit_q : half_offset[3], half_offset[2:0]};
            wire fill_slice = !native_load &&
                (byte_access ? (|bit_offset[BIT_INDEX_BITS-1:3]) : upper_half);
            assign load_slice = fill_slice ? fill_bit : response_q[load_bit];
        end else if (W <= 8) begin : g_load_slices
            // write_slice already accounts for the byte lane.
            wire fill_slice = !native_load &&
                (byte_access ? (|write_bit[BIT_INDEX_BITS-1:3]) : upper_half);
            assign load_slice =
                fill_slice ? {W{fill_bit}} : response_q[half_offset +: W];
        end else begin : g_load_halfword
            // In a 16-bit slice, extend each byte once. Typed loads fill the
            // upper halfword; byte loads also fill the upper byte of the low half.
            wire fill_low = direct_load && upper_half;
            wire fill_high = fill_low || byte_access;
            wire [7:0] low_byte = byte_access ? addressed_byte : response_q[7:0];
            assign load_slice = {
                fill_high ? {8{fill_bit}} : response_q[15:8],
                fill_low ? {8{fill_bit}} : low_byte
            };
        end
    endgenerate

    // Operand and memory buffers
    wire [31:0] literal_address = {11'b0, instr_q[10:6], response_q};
    wire [XLEN-1:0] literal_word = literal_address[XLEN-1:0];
    wire [W-1:0] data_input =
        (transferring && literal) ? literal_word[bit_offset +: W] :
        (HAS_FULL && result_pass && (shift || multiply)) ? shift_result : rf_rdata;
    always @(posedge clk) begin
        if (mem_valid)
            response_q <= mem_rdata;
        if (counted && !(preparing && multiply))
            data_q <= {data_input, data_q[XLEN-1:W]};
        // Capture ra[0] as it leaves the RF: STAGE for funnels, PREPARE for memory.
        if (first_slice && (read_rb || (preparing && !funnel)))
            low_bit_q <= rf_rdata[0];
        left_carry_q <= data_q[W-1];

        // Count up to all ones: MUL takes XLEN passes, shifts take bbb+1.
        if (decoding)
            pass_q <= multiply ? 0 : ~{{(BIT_INDEX_BITS-3){1'b0}}, bbb};
        else if (result_pass && last_slice && repeat_execute)
            pass_q <= pass_q + 1'b1;
        if (last_slice)
            multiplier_bit_q <= next_multiplier_bits[multiplier_index];
    end

    // Update branch flags as R0 is written, without a separate RF read.
    reg zero_q, negative_q;
    wire write_r0 = rf_we && !write_system && (compare_immediate || ddd == 0);
    always @(posedge clk)
        if (write_r0) begin
            zero_q <= !(|rf_wdata) && (first_slice || zero_q);
            if (W == 1 || &write_slice)
                negative_q <= rf_wdata[W-1];
        end
    // BEQZ/BNEZ test zero; BLTZ/BGEZ test the sign. Bit 0 inverts the test.
    wire branch_flag = ddd[1] ? negative_q : zero_q;
    wire branch_condition = branch_flag != ddd[0];
    // Bit 2 selects the unconditional JMP8 family.
    wire branch_taken = branch && (ddd[2] || branch_condition);

    // PC and address registers
    // Aligned PC + (offset | 1) + carry=1 gives PC+2+offset.
    // Trap entry uses no offset and carry=0 to save the unmodified PC.
    wire [W-1:0] pc_displacement = restore_ldpc ? ~immediate_slice : immediate_slice;
    wire [W-1:0] pc_offset =
        (pc_displacement & {W{(branch_taken || ldpc) && !trap}}) |
        (step_slice & {W{!trap}});
    wire [W:0] separate_pc_sum = {1'b0, pc_q[W-1:0]} + {1'b0, pc_offset} +
                                {{W{1'b0}}, pc_carry_q};
    wire [W:0] pc_sum = SHARE_PC_ADDER ? sum : separate_pc_sum;
    wire [XLEN-1:0] vector_word = {{(XLEN-3){1'b0}}, 3'b100};
    wire [W-1:0] next_pc =
        trap ? vector_word[bit_offset +: W] :
        (register_jump || literal) ? data_q[W-1:0] : pc_sum[W-1:0];
    wire advance_pc = pc_pass && !repeat_execute;
    wire repeating_multiply = multiply && repeat_execute;
    wire rotate_multiplier = repeating_multiply && last_slice && refill_multiplier;
    // LDPC takes the PC result; other addresses take the ALU result.
    // A shared adder sends both through next_pc. MUL rotates its saved rb.
    wire [W-1:0] address_input =
        (preparing && !SHARE_PC_ADDER && !ldpc) ? sum[W-1:0] :
        repeating_multiply ? address_q[W-1:0] : next_pc;
    always @(posedge clk) begin
        pc_carry_q <= (advance_pc || prepare_ldpc) ? pc_sum[W] :
                                                  !(decoding && take_irq);
        if (rst)
            pc_q <= RESET_PC;
        else if (advance_pc || prepare_ldpc)
            pc_q <= {next_pc, pc_q[XLEN-1:W]};

        if (rst)
            address_q <= RESET_PC;
        else if (preparing || advance_pc || rotate_multiplier)
            address_q <= {address_input, address_q[XLEN-1:W]};
    end

    // Register writeback
    wire pc_result = trap || link;
    // A shared PC pass writes the adder result; data passes select the ALU op.
    wire select_shift = (shift || funnel_right) && !(SHARE_PC_ADDER && pc_pass);
    wire select_logic = logic_op && !(SHARE_PC_ADDER && pc_pass);
    wire [W-1:0] data_result =
        transferring ? load_slice :
        select_shift ? shift_result :
        select_logic ? logic_result : sum[W-1:0];
    assign rf_wdata = (!SHARE_PC_ADDER && pc_result) ? pc_sum[W-1:0] : data_result;

    // Memory port. During a wait, store slices point past the current
    // halfword; load slices point to the start of the requested halfword.
    wire store_request = waiting && store_op;
    // Only native loads reach a second read beat. Stores buffer a beat
    // before waiting, so their counter points to the following halfword.
    wire high_request = (XLEN == 32) && waiting &&
        (store_op ? (native_store && !upper_half) : upper_half);
    wire [15:0] store_half = data_q[XLEN-1 -: 16];
    assign mem_addr = address_q[XLEN-1:1] | {{(XLEN-2){1'b0}}, high_request};
    assign mem_valid = fetching || waiting;
    assign mem_we = store_request;
    assign mem_wdata = (W == 16 && byte_access) ? {2{store_half[7:0]}} : store_half;
    assign mem_wmask = (store_request && byte_access) ?
        {low_bit_q, !low_bit_q} : 2'b11;

    // Direct stores finish after one beat. A native RC32 store finishes
    // after its second beat, when the slice counter has wrapped to zero.
    wire store_done = direct_store || (native_store && !upper_half);

    // Controller
    always @(posedge clk) begin
        case (state_q)
            FETCH:
                if (mem_ready)
                    state_q <= DECODE;

            DECODE:
                state_q <= take_irq ? EXECUTE :
                           needs_stage ? STAGE :
                           needs_prepare ? PREPARE : EXECUTE;

            STAGE:
                if (last_slice)
                    state_q <= needs_prepare ? PREPARE : EXECUTE;

            PREPARE:
                if (last_slice)
                    state_q <= store_op ? TRANSFER :
                               load_op ? MEMORY : EXECUTE;

            MEMORY:
                if (mem_ready)
                    state_q <= store_done ? EXECUTE : TRANSFER;

            TRANSFER: begin
                if (half_end && store_op)
                    state_q <= MEMORY;
                else if (last_slice)
                    state_q <= EXECUTE;
                else if (half_end && native_load)
                    state_q <= MEMORY;
            end

            EXECUTE:
                if (last_slice && advance_pc)
                    state_q <= (long_jump && !literal && !trap) ? MEMORY : FETCH;

            default:
                state_q <= FETCH;
        endcase
        if (rst)
            state_q <= FETCH;
        slice_q <= read_slice;

        // Only the value captured with mem_ready is used by DECODE.
        if (fetching)
            instr_q <= mem_rdata;
        if (advance_pc && last_slice)
            literal_q <= long_jump && !literal && !trap;
        if (decoding)
            trap_q <= take_irq;

        if (advance_pc && last_slice) begin
            if (trap)
                ie_q <= 1'b0;
            else if (control)
                ie_q <= ddd[2] || (!ddd[1] && ie_q);
        end
        if (decoding)
            pc_phase_q <= take_irq || !writes_result;
        else if (executing && last_slice && !repeat_execute)
            pc_phase_q <= 1'b1;

        if (rst) begin
            pc_phase_q <= 1'b0;
            ie_q <= 1'b0;
            trap_q <= 1'b0;
            literal_q <= 1'b0;
        end
    end

`ifdef RISCC_TRACE
    // Reconstruct RF slice writes and report after the final write settles.
    // RC16 reports the next PC in halfwords;
    // RC32 reports the retiring instruction's byte address.
    reg [XLEN-1:0] trace_regs [0:15];
    reg [XLEN-1:0] trace_fetch_pc_q, trace_pc_q;
    reg [15:0] trace_ir_q;
    reg trace_pending_q, trace_valid_q, trace_ie_q;
    integer trace_i;
    wire retire = advance_pc && last_slice &&
                  !(long_jump && !literal && !trap);
    always @(posedge clk) begin
        trace_valid_q <= 1'b0;
        if (rst) begin
            trace_pending_q <= 1'b0;
            for (trace_i = 0; trace_i < 16; trace_i = trace_i + 1)
                trace_regs[trace_i] <= 0;
        end else begin
            if (fetching && mem_ready)
                trace_fetch_pc_q <= address_q;
            if (rf_we)
                trace_regs[write_reg][write_bit +: W] <= rf_wdata;
            if (trace_pending_q) begin
                trace_valid_q <= 1'b1;
                trace_pending_q <= 1'b0;
                trace_ie_q <= HAS_SYSTEM && ie_q;
                trace_pc_q <= XLEN == 16 ? (pc_q >> 1) : trace_fetch_pc_q;
            end
            if (retire) begin
                trace_ir_q <= instr_q;
                trace_pending_q <= 1'b1;
            end
        end
    end
    assign trace_valid = trace_valid_q;
    assign trace_pc = trace_pc_q;
    assign trace_ir = trace_ir_q;
    assign trace_ie = trace_ie_q;
    assign trace_r0 = trace_regs[0];
    assign trace_r1 = trace_regs[1];
    assign trace_r2 = trace_regs[2];
    assign trace_r3 = trace_regs[3];
    assign trace_r4 = trace_regs[4];
    assign trace_r5 = trace_regs[5];
    assign trace_r6 = trace_regs[6];
    assign trace_r7 = trace_regs[7];
    assign trace_s0 = trace_regs[8];
    assign trace_s1 = trace_regs[9];
    assign trace_s2 = trace_regs[10];
    assign trace_s3 = trace_regs[11];
    assign trace_s4 = trace_regs[12];
    assign trace_s5 = trace_regs[13];
    assign trace_s6 = trace_regs[14];
    assign trace_s7 = trace_regs[15];
`endif
endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
