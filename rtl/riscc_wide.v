// Full-width, multicycle RISC-C. PROFILE: 0 = Min, 1 = Sys, 2 = Full.
// MDU: 0 = base instructions, 1 = MULHU, 2 = MULHU and DIVU (Full only).
// XLEN is 16 or 32. The memory port always transfers 16 bits.
`default_nettype none

module riscc_wide #(
    parameter integer XLEN = 16,
    parameter integer PROFILE = 0,
    parameter integer MDU = 0,
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
    localparam HAS_MULH = MDU >= 1;
    localparam HAS_DIV = MDU == 2;
    localparam integer COUNT_BITS = $clog2(XLEN);

    initial begin
        if ((XLEN != 16 && XLEN != 32) || PROFILE < 0 || PROFILE > 2 ||
            MDU < 0 || MDU > 2 || (MDU != 0 && !HAS_FULL))
            $error("riscc_wide: invalid XLEN, PROFILE or MDU");
    end

    // DECODE advances PC and issues the first RF read. Two-source operations
    // use OPERAND to save one source, then read the other for EXECUTE.
    // Completed operations can fetch the next instruction during writeback.
    localparam [3:0] FETCH = 0, DECODE = 1, OPERAND = 2, EXECUTE = 3,
        MEMORY = 4, MEMORY_HIGH = 5, WRITEBACK = 6, LINK = 7, JUMP = 8,
        COMPARE = 9, IRQ_ENTRY = 10, ITER_READ = 11, ITERATE = 12;
    (* syn_encoding = "one-hot" *) reg [3:0] state_q;
    reg [3:0] state_d;
    wire decoding = state_q == DECODE;
    wire staging = state_q == OPERAND;
    wire executing = state_q == EXECUTE;
    wire memory_high = (XLEN == 32) && state_q == MEMORY_HIGH;
    wire accessing = state_q == MEMORY || memory_high;
    wire writing = state_q == WRITEBACK;
    wire linking = HAS_SYSTEM && state_q == LINK;
    wire jumping = state_q == JUMP;
    wire comparing = state_q == COMPARE;
    wire trapping = HAS_SYSTEM && state_q == IRQ_ENTRY;
    wire iter_read = HAS_FULL && state_q == ITER_READ;
    wire iterating = HAS_FULL && state_q == ITERATE;

    reg [15:0] instr_q;
    reg [XLEN-2:0] pc_q;
    reg [XLEN-1:0] data_q;
    reg ie_q, negative_q;
    // RC32 saves one zero flag per nibble to shorten the path after the
    // carry chain. RC16 keeps a single flag.
    localparam integer ZERO_GROUP_BITS = XLEN == 32 ? 4 : 16;
    reg [XLEN/ZERO_GROUP_BITS-1:0] zero_groups_q;
    wire zero_q = &zero_groups_q;
    integer zero_group;
    // data_q holds an operand, address or product low word.
    // scratch_q holds the memory response or product high word. For RC32
    // loads, its low half stays in place while the second halfword arrives.
    reg [XLEN-1:0] scratch_q;
    reg [COUNT_BITS-1:0] count_q;
    reg boundary_q, dividend_bit_q;
    localparam [1:0] PASS_B = 0, AND_B = 1, OR_B = 2, XOR_B = 3;
    reg [1:0] logic_mode_q;
    // Comparison and division save their decision until writeback.
    wire saved_bit = boundary_q;

    wire [2:0] rd = instr_q[13:11];
    wire [2:0] ra = instr_q[10:8];
    wire [2:0] rb = instr_q[2:0];
    wire [1:0] group = instr_q[7:6];
    wire [2:0] op = instr_q[5:3];
    wire immediate = instr_q[15] && !instr_q[14];
    wire native_immediate = !instr_q[15] && (instr_q[14] || !HAS_SYSTEM);
    wire register_op = instr_q[15] && instr_q[14];
    wire long_jump = HAS_SYSTEM && !instr_q[15] && !instr_q[14];
    wire branch = immediate && (&ra);
    wire load_constant = immediate && !ra[2] && !ra[1];
    wire ldi = load_constant && !ra[0];
    wire lui = (XLEN == 16) && load_constant && ra[0];
    wire ldpc = (XLEN == 32) && load_constant && ra[0];
    wire immediate_arithmetic = immediate && !ra[2] && ra[1];
    wire compare_immediate = immediate_arithmetic && ra[0];
    wire immediate_logic = immediate && ra[2] && !(&ra[1:0]);

    wire alu_group = register_op && group == 0;
    wire memory_group = register_op && group == 1;
    wire extension_group = register_op && group == 2;
    wire system_group = register_op && group == 3;
    wire compare = alu_group && !op[2] && op[1];
    wire register_subtract = alu_group && !op[2] && (op[1] || op[0]);
    wire register_logic = alu_group && op[2] && !(&op[1:0]);
    wire multiply = HAS_FULL && alu_group && (&op);
    wire funnel = extension_group && (!HAS_MULH || op[0]);
    wire funnel_right = funnel && rb[0];
    wire funnel_left = funnel && !rb[0];
    wire mulhu = HAS_MULH && extension_group && !op[0] && op[2];
    wire divide = HAS_DIV && extension_group && !op[0] && !op[2];
    wire product = multiply || mulhu;

    wire indexed_load = memory_group && !op[2] && !op[1];
    wire direct_load = memory_group && op[1] && !op[0];
    wire direct_store = memory_group && !op[2] && op[1] && op[0];
    wire right_shift = memory_group && op[2] && !op[1];
    wire left_shift = HAS_FULL && memory_group && (&op);
    wire shift = right_shift || left_shift;
    wire memory_op = native_immediate || indexed_load || direct_load ||
                     direct_store || ldpc;
    wire store = (native_immediate && instr_q[0]) || direct_store;
    wire typed_memory = direct_load || direct_store;
    wire byte_access = typed_memory && ((XLEN == 16) || !rb[1]);
    wire native_word = !typed_memory;

    wire control = system_group && !rb[1] && !rb[0];
    wire return_op = control && (!HAS_SYSTEM || !rd[1]);
    wire set_ie = HAS_SYSTEM && control && rd[1];
    wire register_call = system_group && !rb[1] && rb[0];
    wire system_move = system_group && rb[1];
    wire mts = system_move && rb[0];
    wire has_link = |rd;
    wire branch_taken = branch && (rd[2] ||
        ((rd[1] ? negative_q : zero_q) ^ rd[0]));
    wire stage_rb = alu_group || indexed_load || mulhu || divide;
    wire needs_operand = stage_rb || funnel || (HAS_FULL && shift);
    wire counted_op = product || divide || (HAS_FULL && shift);

    // MUL adds the multiplicand when data_q[0] is set, then shifts the product.
    // DIV keeps quotient in ra, remainder in rd, and divisor in data_q:
    //   ITER_READ: shift quotient; save its outgoing bit.
    //   ITERATE:   test (remainder << 1 | saved bit) - divisor.
    //   WRITEBACK: repeat that sum, or just shift if subtraction failed.
    // The decision is registered, so RF write-enable never waits for the adder.
    // DIVU requires distinct ra, rb and rd, with initial remainder < divisor.
    wire count_done = (product || divide) ? !(|count_q) : !(|count_q[2:0]);
    wire product_step = iterating && product;
    wire shift_step = iterating && shift;
    wire quotient_step = divide && (iter_read || executing);
    wire remainder_step = divide && iterating;
    wire divide_shift = quotient_step;
    wire divide_commit = divide && writing;
    wire mulhu_high = mulhu && writing;
    wire mulhu_low = mulhu && executing;
    wire address_ready = executing && memory_op;
    // Division needs a left-shifted ALU input; FSL1 and SLLI reuse it.
    // Otherwise FSL1 uses two sums: rd + endpoint, then rd + that result.
    wire two_pass_funnel = funnel_left && !HAS_DIV;
    wire funnel_first = executing && two_pass_funnel;
    wire execute_done = executing && !memory_op && !compare && !two_pass_funnel;
    wire writeback_done = writing && !mulhu && !divide;
    wire shift_done = shift_step && count_done;
    wire fetch_request = state_q == FETCH || execute_done || writeback_done ||
                         comparing || shift_done;
    wire take_irq = HAS_SYSTEM && fetch_request && mem_ready && irq && ie_q;
    wire memory_done = accessing && mem_ready &&
                       (!(XLEN == 32 && native_word) || memory_high);
    wire store_done = memory_done && store;

    // The RF read address selects the operand needed in the NEXT cycle.
    // In particular, stores keep reading rd throughout a stalled request.
    wire read_rd = immediate || executing || (accessing && store) ||
        (iter_read && shift) || (staging && funnel) || quotient_step ||
        (iterating && divide);
    wire read_rb = decoding && needs_operand && stage_rb;
    wire [2:0] read_reg = read_rd ? rd : read_rb ? rb : ra;
    wire read_system = decoding && system_group && !rb[0];
    wire write_aux = quotient_step || mulhu_high;
    wire write_system = mts || trapping || linking || (decoding && register_call);
    wire [2:0] write_reg = write_aux ? ra :
                          (trapping || compare_immediate) ? 3'b0 : rd;
    wire rf_we = execute_done || writeback_done || comparing || trapping ||
        shift_step || divide_shift || divide_commit || mulhu_high ||
        ((linking || (decoding && register_call)) && has_link);
    wire [XLEN-1:0] rf_rdata, result;
    riscc_rf #(.WIDTH(XLEN), .ADDR_WIDTH(4)) regs (
        .clk(clk), .raddr({read_system, read_reg}), .rdata(rf_rdata),
        .waddr({write_system, write_reg}), .wdata(result), .we(rf_we)
    );

    // The immediate selector shares the encoded low byte. PC arithmetic
    // supplies bit zero separately; native memory ignores its alignment bits.
    wire pc_relative = (decoding && branch_taken) || (executing && ldpc);
    wire immediate_sign = pc_relative ? instr_q[0] :
        native_immediate ? ((XLEN == 32) ? instr_q[1] : instr_q[7]) :
        (immediate_arithmetic && instr_q[7]);
    wire [7:0] immediate_byte = {instr_q[7:2],
        instr_q[1] && !(XLEN == 32 && native_immediate),
        instr_q[0] && !pc_relative};
    wire [XLEN-1:0] immediate_value = {{(XLEN-8){1'b0}}, immediate_byte};
    wire [XLEN-1:0] upper_value = {{(XLEN-16){1'b0}}, instr_q[7:0], 8'b0};
    wire right_step = (executing && (funnel_right || right_shift)) ||
                      (shift_step && !left_shift);
    wire right_bit = funnel_right ? data_q[0] : op[0] && rf_rdata[XLEN-1];
    wire [XLEN-1:0] right_result = {right_bit, rf_rdata[XLEN-1:1]};
    wire shift_a = HAS_DIV && (divide_shift || remainder_step || divide_commit ||
                   (shift_step && left_shift) || (executing && funnel_left));
    wire logic_step = |logic_mode_q;
    wire subtract = (executing && (register_subtract || compare_immediate)) ||
                    remainder_step || (divide_commit && boundary_q);
    wire pc_step = decoding || linking;

    // One adder serves PC, address, ALU and MDU operations. Logic and right
    // shift put their result on B and clear A, so RF writeback has one source.
    wire a_pc = decoding || linking || trapping || (executing && ldpc);
    wire a_zero = (executing && (ldi || lui || logic_step || right_step || mulhu_low)) ||
        (writing && !divide && !two_pass_funnel) || comparing || (jumping && long_jump) ||
        (product_step && !data_q[0]) || (shift_step && !left_shift);
    wire [XLEN-1:0] shifted_a = {rf_rdata[XLEN-2:0],
        (remainder_step || divide_commit) && dividend_bit_q};
    wire [XLEN-1:0] register_a = shift_a ? shifted_a : rf_rdata;
    wire [XLEN-1:0] alu_a = a_pc ? {pc_q, pc_step} :
        a_zero ? {XLEN{1'b0}} : register_a;
    // B selects the staged operand, memory response/product high, or an
    // immediate. The remaining states need zero (operand copy, shift, jump).
    reg b_data, b_immediate, b_scratch, b_upper;
    always @* begin
        b_data = 1'b0;
        b_immediate = 1'b0;
        b_scratch = 1'b0;
        b_upper = 1'b0;
        case (state_q)
            DECODE: b_immediate = branch_taken;
            EXECUTE: begin
                b_data = alu_group || indexed_load || mulhu_low;
                b_immediate = ldi || immediate_arithmetic || immediate_logic ||
                              native_immediate || ldpc;
                b_upper = lui;
            end
            WRITEBACK: begin
                b_data = !memory_op && !mulhu_high && (!divide || boundary_q);
                b_scratch = memory_op || mulhu_high;
            end
            JUMP: b_scratch = long_jump;
            ITERATE: if (HAS_FULL) begin
                b_data = divide || (left_shift && !HAS_DIV);
                b_scratch = product;
            end
            default: ;
        endcase
    end
    wire [XLEN-1:0] normal_b;
    generate
        if (XLEN == 16) begin : g_b16
            // The extra LUI source is smaller with a priority selector.
            assign normal_b = comparing ? {{(XLEN-1){1'b0}}, saved_bit} :
                b_scratch ? scratch_q : b_data ? data_q :
                b_upper ? upper_value : b_immediate ? immediate_value : 0;
        end else begin : g_b32
            // RC32 has three sources, selected by mutually exclusive states.
            assign normal_b = (scratch_q & {XLEN{b_scratch}}) |
                (data_q & {XLEN{b_data}}) |
                (immediate_value & {XLEN{b_immediate}}) |
                {{(XLEN-1){1'b0}}, comparing && saved_bit};
        end
    endgenerate
    wire [1:0] logic_select = register_logic ? op[1:0] : ra[1:0];
    wire [1:0] next_logic_mode = !(register_logic || immediate_logic) ? PASS_B :
        logic_select[1] ? XOR_B : logic_select[0] ? OR_B : AND_B;
    // Decode before Execute. Two control bits select each bit's Boolean
    // function; other cycles pass B through to the shared adder.
    always @(posedge clk) begin
        if (rst) logic_mode_q <= PASS_B;
        else if (staging || (decoding && !needs_operand))
            logic_mode_q <= next_logic_mode;
        else logic_mode_q <= PASS_B;
    end
    reg [XLEN-1:0] logic_result;
    always @* begin
        case (logic_mode_q)
            AND_B: logic_result = rf_rdata & normal_b;
            OR_B:  logic_result = rf_rdata | normal_b;
            XOR_B: logic_result = rf_rdata ^ normal_b;
            default: logic_result = normal_b;
        endcase
    end
    wire [XLEN-1:0] alu_b = right_step ? right_result : logic_result;
    // PC's low bit and carry both supply 1 during a step: aligned PC + 2.
    // Sign extension shares the XOR gates used to complement a subtrahend.
    wire carry_in = pc_step || subtract ||
        (executing && funnel_left && data_q[XLEN-1]) || (divide_shift && boundary_q);
    wire sign_fill = b_immediate && immediate_sign;
    wire [XLEN-1:0] adjusted_b = {
        alu_b[XLEN-1:8] ^ {(XLEN-8){subtract ^ sign_fill}},
        alu_b[7:0] ^ {8{subtract}}};
    wire [XLEN:0] sum = {1'b0, alu_a} + {1'b0, adjusted_b} +
                        {{XLEN{1'b0}}, carry_in};
    assign result = sum[XLEN-1:0];
    // Signed and unsigned order differ only when the operand signs differ.
    wire opposite_signs = rf_rdata[XLEN-1] ^ data_q[XLEN-1];
    wire less_than = !sum[XLEN] ^ (opposite_signs && !op[0]);

    // Address and write data stay parked while memory waits. Aligned RC32
    // words use the next halfword address for their second beat.
    assign mem_addr = accessing ?
        (data_q[XLEN-1:1] | {{(XLEN-2){1'b0}}, memory_high}) : pc_q;
    wire [31:0] store_word = {{(32-XLEN){1'b0}}, rf_rdata};
    wire [15:0] store_half = memory_high ? store_word[31:16] : store_word[15:0];
    assign mem_wdata = byte_access ? {2{rf_rdata[7:0]}} : store_half;
    assign mem_wmask = (accessing && byte_access) ? {data_q[0], !data_q[0]} : 2'b11;
    assign mem_valid = fetch_request || accessing || linking;
    assign mem_we = accessing && store;
    wire [7:0] load_byte = (byte_access && data_q[0]) ? mem_rdata[15:8] : mem_rdata[7:0];
    wire load_sign = op[2] && (byte_access ? load_byte[7] : mem_rdata[15]);
    // Assemble the memory response in scratch_q. MEMORY_HIGH preserves the
    // first halfword; JALL supplies the five high bits of its target address.
    wire [15:0] response_low = memory_high ? scratch_q[15:0] :
        {byte_access ? {8{load_sign}} : mem_rdata[15:8], load_byte};
    wire [15:0] response_high = linking ? {11'b0, instr_q[10:6]} :
        memory_high ? mem_rdata : {16{load_sign}};
    wire [31:0] response_word = {response_high, response_low};

    always @* begin
        state_d = state_q;
        case (state_q)
            FETCH: begin
                if (!mem_ready) state_d = FETCH;
                else if (HAS_SYSTEM && irq && ie_q) state_d = IRQ_ENTRY;
                else state_d = DECODE;
            end
            DECODE: begin
                if (branch || set_ie) state_d = FETCH;
                else if (long_jump) state_d = LINK;
                else if (return_op || register_call) state_d = JUMP;
                else if (needs_operand) state_d = OPERAND;
                else state_d = EXECUTE;
            end
            OPERAND: state_d = divide ? ITER_READ :
                               (product || (HAS_FULL && shift)) ? ITERATE : EXECUTE;
            EXECUTE: begin
                if (memory_op) state_d = MEMORY;
                else if (compare) state_d = COMPARE;
                else if (two_pass_funnel) state_d = WRITEBACK;
                else if (!mem_ready) state_d = FETCH;
                else if (HAS_SYSTEM && irq && ie_q) state_d = IRQ_ENTRY;
                else state_d = DECODE;
            end
            MEMORY: if (mem_ready)
                state_d = (XLEN == 32 && native_word) ? MEMORY_HIGH :
                          store ? FETCH : WRITEBACK;
            MEMORY_HIGH: if (XLEN == 32 && mem_ready) state_d = store ? FETCH : WRITEBACK;
            WRITEBACK: begin
                if (mulhu) state_d = EXECUTE;
                else if (divide) state_d = count_done ? EXECUTE : ITER_READ;
                else if (!mem_ready) state_d = FETCH;
                else if (HAS_SYSTEM && irq && ie_q) state_d = IRQ_ENTRY;
                else state_d = DECODE;
            end
            LINK: if (HAS_SYSTEM && mem_ready) state_d = JUMP;
            JUMP, IRQ_ENTRY: state_d = FETCH;
            COMPARE: begin
                if (!mem_ready) state_d = FETCH;
                else if (HAS_SYSTEM && irq && ie_q) state_d = IRQ_ENTRY;
                else state_d = DECODE;
            end
            ITER_READ: if (HAS_FULL) state_d = ITERATE;
            ITERATE: if (HAS_FULL) begin
                if (divide) state_d = WRITEBACK;
                else if (product) state_d = count_done ? WRITEBACK : ITERATE;
                else if (!count_done) state_d = ITER_READ;
                else if (!mem_ready) state_d = FETCH;
                else if (HAS_SYSTEM && irq && ie_q) state_d = IRQ_ENTRY;
                else state_d = DECODE;
            end
            default: state_d = FETCH;
        endcase
    end

    always @(posedge clk) begin
        if (rst) state_q <= FETCH;
        else state_q <= state_d;
    end

    // These temporaries are written before use; they need no reset gating.
    always @(posedge clk) begin
        if (staging || address_ready || funnel_first ||
            (shift_step && left_shift && !count_done && !HAS_DIV))
            data_q <= result;
        else if (product_step)
            data_q <= {sum[0], data_q[XLEN-1:1]};

        // Outside MUL this is the memory input register. WRITEBACK/JUMP uses
        // the sample from the accepted request; intervening samples are unused.
        if (staging && product)
            scratch_q <= 0;
        else if (product_step)
            scratch_q <= sum[XLEN:1];
        else
            scratch_q <= response_word[XLEN-1:0];

        if (staging && counted_op)
            count_q <= (product || divide) ? {COUNT_BITS{1'b1}} :
                                            {{(COUNT_BITS-3){1'b0}}, rb};
        else if (product_step || (shift_step && !count_done) || (divide_commit && !count_done))
            count_q <= count_q - 1'b1;
        if (executing && compare)
            boundary_q <= less_than;
        if (staging && divide)
            boundary_q <= 1'b0;
        else if (remainder_step)
            boundary_q <= rf_rdata[XLEN-1] || sum[XLEN];
        if (quotient_step)
            dividend_bit_q <= rf_rdata[XLEN-1];
    end

    always @(posedge clk) begin
        if (rst) begin
            pc_q <= RESET_PC[XLEN-1:1];
            ie_q <= 1'b0;
            zero_groups_q <= {XLEN/ZERO_GROUP_BITS{1'b1}};
            negative_q <= 1'b0;
        end else begin
            if (fetch_request && mem_ready && !take_irq)
                instr_q <= mem_rdata;
            if (decoding || jumping)
                pc_q <= result[XLEN-1:1];
            if (trapping)
                pc_q <= 2; // interrupt vector: byte address 4

            if (rf_we && !write_system && !(|write_reg)) begin
                for (zero_group = 0; zero_group < XLEN/ZERO_GROUP_BITS;
                     zero_group = zero_group + 1)
                    zero_groups_q[zero_group] <=
                        !(|result[zero_group*ZERO_GROUP_BITS +: ZERO_GROUP_BITS]);
                negative_q <= result[XLEN-1];
            end
            if (HAS_SYSTEM && decoding && (set_ie || (return_op && rd[0])))
                ie_q <= rd[0];
            if (trapping)
                ie_q <= 1'b0;
        end
    end

`ifdef RISCC_TRACE
    // Simulation only. Snapshot after the retiring write, before the next
    // instruction's early link write. RC16 reports next PC in halfwords;
    // RC32 reports the retiring instruction's byte PC.
    reg [XLEN-1:0] trace_regs [0:15];
    reg [XLEN-1:0] trace_snapshot [0:15];
    reg [XLEN-1:0] trace_fetch_pc_q, trace_pc_q;
    reg [15:0] trace_irq_ir_q, trace_ir_q;
    reg trace_valid_q, trace_ie_q;
    integer trace_i;
    wire retire = execute_done || writeback_done || comparing || shift_done ||
        (decoding && (branch || set_ie)) || store_done || jumping || trapping;
    always @(posedge clk) begin
        trace_valid_q <= 1'b0;
        if (rst) begin
            for (trace_i = 0; trace_i < 16; trace_i = trace_i + 1) begin
                trace_regs[trace_i] <= 0;
                trace_snapshot[trace_i] <= 0;
            end
        end else begin
            if (fetch_request && mem_ready) begin
                trace_fetch_pc_q <= {pc_q, 1'b0};
                trace_irq_ir_q <= mem_rdata;
            end
            if (rf_we)
                trace_regs[{write_system, write_reg}] <= result;
            if (retire) begin
                trace_valid_q <= 1'b1;
                trace_ir_q <= trapping ? trace_irq_ir_q : instr_q;
                trace_pc_q <= (XLEN == 32) ? trace_fetch_pc_q :
                    trapping ? 2 : (decoding || jumping) ? (result >> 1) : {{1'b0}, pc_q};
                trace_ie_q <= HAS_SYSTEM && !trapping &&
                    ((decoding && (set_ie || (return_op && rd[0]))) ? rd[0] : ie_q);
                for (trace_i = 0; trace_i < 16; trace_i = trace_i + 1)
                    trace_snapshot[trace_i] <=
                        (rf_we && {write_system, write_reg} == trace_i[3:0]) ? result : trace_regs[trace_i];
            end
        end
    end
    assign trace_valid = trace_valid_q;
    assign trace_pc = trace_pc_q;
    assign trace_ir = trace_ir_q;
    assign trace_ie = trace_ie_q;
    assign trace_r0 = trace_snapshot[0];
    assign trace_r1 = trace_snapshot[1];
    assign trace_r2 = trace_snapshot[2];
    assign trace_r3 = trace_snapshot[3];
    assign trace_r4 = trace_snapshot[4];
    assign trace_r5 = trace_snapshot[5];
    assign trace_r6 = trace_snapshot[6];
    assign trace_r7 = trace_snapshot[7];
    assign trace_s0 = trace_snapshot[8];
    assign trace_s1 = trace_snapshot[9];
    assign trace_s2 = trace_snapshot[10];
    assign trace_s3 = trace_snapshot[11];
    assign trace_s4 = trace_snapshot[12];
    assign trace_s5 = trace_snapshot[13];
    assign trace_s6 = trace_snapshot[14];
    assign trace_s7 = trace_snapshot[15];
`endif
endmodule

`include "rtl/riscc_rf.vh"
`default_nettype wire
