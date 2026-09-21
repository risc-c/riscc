// riscc_cached.v : RC16/RC32 pipeline with internal instruction and data caches.
// The backing port uses 32-bit word addresses and Wishbone B4 handshakes.
// Cache hits do not use it; a miss owns it through its complete line fill.
`default_nettype none

module riscc_cached #(
    parameter integer XLEN = 16,
    // This byte-address bit selects uncached data outside the local SRAM.
    parameter integer DCACHE_UNCACHED_BIT = XLEN-1,
    // Optional low-address SRAM on the CPU ports, ahead of both caches.
    parameter integer SRAM_ADDR_BITS = 0,
    // Quartus uses a companion SRAM_HEX + ".mif" initialization file.
    parameter SRAM_HEX = "",
    // Register instruction decode when the local SRAM limits CPU frequency.
    parameter REGISTER_FETCH = 1'b0,
    parameter [XLEN-1:0] RESET_PC = 0
) (
    input wire clk,
    input wire rst,
    input wire irq,
    output wire [XLEN-3:0] mem_addr,
    input wire [31:0] mem_rdata,
    output wire [31:0] mem_wdata,
    output wire [3:0] mem_wmask,
    output wire mem_we,
    output wire mem_cyc,
    output wire mem_stb,
    input wire mem_stall,
    input wire mem_ack
);
    // Wider address tags favor fewer entries at the same cache capacity.
    localparam integer LINE_WORD_BITS = XLEN == 32 ? 4 : 3;
    initial begin
        if (DCACHE_UNCACHED_BIT < LINE_WORD_BITS+2 || DCACHE_UNCACHED_BIT >= XLEN)
            $error("riscc_cached: D-cache bypass bits must be above the line offset");
    end

    wire [XLEN-2:0] i_addr;
    wire [15:0] i_data;
    wire i_cyc, i_stb, i_stall, i_ack;
    wire [XLEN-3:0] d_addr;
    wire [31:0] d_rdata, d_wdata;
    wire [3:0] d_sel, d_rsel;
    wire d_we, d_cyc, d_stb, d_stall, d_ack;

    riscc_cached_pipe #(.XLEN(XLEN), .RESET_PC(RESET_PC),
                        .FETCH_RESPONSE_HELD(1),
                        .REGISTER_FETCH(REGISTER_FETCH)) cpu (
        .clk(clk), .rst(rst), .irq(irq),
        .imem_addr(i_addr), .imem_rdata(i_data),
        .imem_cyc(i_cyc), .imem_stb(i_stb), .imem_stall(i_stall), .imem_ack(i_ack),
        .dmem_addr(d_addr), .dmem_rdata(d_rdata), .dmem_wdata(d_wdata),
        .dmem_wmask(d_sel), .dmem_rsel(d_rsel), .dmem_we(d_we),
        .dmem_cyc(d_cyc), .dmem_stb(d_stb), .dmem_stall(d_stall), .dmem_ack(d_ack)
    );

    wire [15:0] cache_i_data;
    wire [31:0] cache_d_data;
    wire [3:0] cache_d_sel;
    wire cache_i_ack, cache_i_stall, cache_d_ack, cache_d_stall;
    wire i_local, d_local;

    generate if (SRAM_ADDR_BITS != 0) begin : g_sram
        localparam integer WORD_BITS = SRAM_ADDR_BITS - 2;
        initial begin
            if (SRAM_ADDR_BITS < 3 || SRAM_ADDR_BITS >= XLEN)
                $error("riscc_cached: invalid local SRAM size");
        end
        assign i_local = (i_addr >> (SRAM_ADDR_BITS-1)) == 0;
        assign d_local = (d_addr >> WORD_BITS) == 0;
        wire [WORD_BITS-1:0] i_word = i_addr[WORD_BITS:1];
        wire [WORD_BITS-1:0] d_word = d_addr[WORD_BITS-1:0];
        wire d_accept = d_cyc && d_stb && d_local && !d_stall && !rst;
        // Reading SRAM speculatively costs no transaction. Select its response
        // only for local requests; keep the full address decode off read enable.
        wire d_read = d_cyc && d_stb && !d_stall && !rst && !d_we;
        // Retry a fetch that overlaps a store to the same word. Keeping the
        // comparison out of STALL avoids a data-ALU-to-fetch combinational path.
        reg retry_q;
        reg [WORD_BITS-1:0] retry_addr_q;
        wire i_accept = i_cyc && i_stb && i_local && !i_stall && !rst;
        wire i_read = (i_cyc && i_stb && !i_stall && !rst) || retry_q;
        wire [WORD_BITS-1:0] read_word = retry_q ? retry_addr_q : i_word;
        wire instruction_collision = (i_accept || retry_q) && d_accept && d_we && read_word == d_word;
        reg i_local_q, d_local_q, i_ack_q, d_ack_q, i_half_q;
        wire [31:0] i_word_q, d_word_q;
        wire [15:0] i_sram_data = i_half_q ? i_word_q[31:16] : i_word_q[15:0];
        reg [3:0] d_sel_q;
`ifdef ALTERA_RESERVED_QIS
        // Quartus otherwise replicates this one-writer/two-reader memory.
        // Use both M20K ports explicitly, with one clock and independent reads.
        altera_syncram #(
            .init_file(SRAM_HEX == "" ? "UNUSED" : {SRAM_HEX, ".mif"}),
            .operation_mode("BIDIR_DUAL_PORT"), .ram_block_type("M20K"),
            .width_a(32), .widthad_a(WORD_BITS), .numwords_a(1 << WORD_BITS),
            .width_byteena_a(4),
            .width_b(32), .widthad_b(WORD_BITS), .numwords_b(1 << WORD_BITS),
            .width_byteena_b(4),
            .byte_size(8), .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
            .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"),
            .wrcontrol_wraddress_reg_b("CLOCK0"), .byteena_reg_b("CLOCK0"),
            .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
            .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
            .read_during_write_mode_mixed_ports("DONT_CARE")
        ) ram (
            .clock0(clk), .clocken0(1'b1), .clocken1(1'b1),
            .clocken2(1'b1), .clocken3(1'b1), .aclr0(1'b0), .aclr1(1'b0),
            .data_a(d_wdata), .address_a(d_word), .wren_a(d_we && d_accept),
            .rden_a(d_read), .byteena_a(d_sel), .q_a(d_word_q),
            .data_b(32'b0), .address_b(read_word), .wren_b(1'b0),
            .rden_b(i_read), .byteena_b(4'hf), .q_b(i_word_q)
        );
`else
        (* ram_style = "block", no_rw_check *) reg [31:0] ram [0:(1 << WORD_BITS)-1];
        initial if (SRAM_HEX != "") $readmemh(SRAM_HEX, ram);
        reg [31:0] i_read_q, d_read_q;
        assign i_word_q = i_read_q;
        assign d_word_q = d_read_q;
        always @(posedge clk) begin
            if (i_read) i_read_q <= ram[read_word];
            if (d_read) d_read_q <= ram[d_word];
        end
        integer lane;
        always @(posedge clk) begin
            if (d_accept && d_we)
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (d_sel[lane])
                        ram[d_word][lane*8 +: 8] <= d_wdata[lane*8 +: 8];
        end
`endif
        always @(posedge clk) begin
            if (i_accept) begin
                i_half_q <= i_addr[0];
                retry_addr_q <= i_word;
            end
            if (d_accept) d_sel_q <= d_sel;
        end
        always @(posedge clk) begin
            i_ack_q <= (i_accept || retry_q) && !instruction_collision;
            retry_q <= instruction_collision;
            d_ack_q <= d_accept;
            // Retain response ownership through stalls and across boundaries.
            if (i_cyc && i_stb && !i_stall) i_local_q <= i_local;
            if (d_cyc && d_stb && !d_stall) d_local_q <= d_local;
            if (rst) begin
                i_ack_q <= 0;
                retry_q <= 0;
                d_ack_q <= 0;
                i_local_q <= 0;
                d_local_q <= 0;
            end
        end
        assign i_data = i_local_q ? i_sram_data : cache_i_data;
        assign d_rdata = d_local_q ? d_word_q : cache_d_data;
        assign d_rsel = d_local_q ? d_sel_q : cache_d_sel;
        assign i_ack = i_ack_q || cache_i_ack;
        assign d_ack = d_ack_q || cache_d_ack;
        // Each CPU port has at most one pending request. A busy cache owns
        // that port; readiness need not wait for the new address decode.
        assign i_stall = retry_q || cache_i_stall;
        assign d_stall = cache_d_stall;
    end else begin : g_no_sram
        assign i_local = 1'b0;
        assign d_local = 1'b0;
        assign i_data = cache_i_data;
        assign d_rdata = cache_d_data;
        assign d_rsel = cache_d_sel;
        assign i_ack = cache_i_ack;
        assign d_ack = cache_d_ack;
        assign i_stall = cache_i_stall;
        assign d_stall = cache_d_stall;
    end endgenerate

    wire [XLEN-3:0] ib_addr, db_addr;
    wire [31:0] ib_wdata, db_wdata;
    wire [3:0] ib_sel, db_sel;
    wire ib_we, ib_cyc, ib_stb, ib_stall, ib_ack;
    wire db_we, db_cyc, db_stb, db_stall, db_ack;
    wire invalidate = mem_cyc && mem_stb && !mem_stall && mem_we;

    riscc_cached_cache #(.ADDR_BITS(XLEN-2), .READ_ONLY(1), .CPU_BITS(16),
                         .REGISTER_LOOKUP(SRAM_ADDR_BITS != 0),
                         .LOCAL_WORD_BITS(SRAM_ADDR_BITS != 0 ? SRAM_ADDR_BITS-2 : 0),
                         .LINE_WORD_BITS(LINE_WORD_BITS)) icache (
        .clk(clk), .rst(rst),
        .c_addr(i_addr[XLEN-2:1]), .c_wdata(16'b0),
        .c_sel(i_addr[0] ? 4'b1100 : 4'b0011), .c_we(1'b0),
        .c_rdata(cache_i_data), .c_rsel(), .c_cyc(i_cyc),
        .c_stb(i_stb), .c_stall(cache_i_stall), .c_ack(cache_i_ack),
        .m_addr(ib_addr), .m_wdata(ib_wdata), .m_sel(ib_sel), .m_we(ib_we),
        .m_rdata(mem_rdata), .m_cyc(ib_cyc), .m_stb(ib_stb), .m_stall(ib_stall), .m_ack(ib_ack),
        .inv_valid(invalidate), .inv_addr(mem_addr)
    );
    riscc_cached_cache #(.ADDR_BITS(XLEN-2),
                         .UNCACHED_BIT(DCACHE_UNCACHED_BIT-2), .READ_ONLY(0),
                         .LOCAL_WORD_BITS(SRAM_ADDR_BITS != 0 ? SRAM_ADDR_BITS-2 : 0),
                         .HOLD_PAYLOAD(1), .LINE_WORD_BITS(LINE_WORD_BITS)) dcache (
        .clk(clk), .rst(rst),
        .c_addr(d_addr), .c_wdata(d_wdata), .c_sel(d_sel), .c_we(d_we),
        .c_rdata(cache_d_data), .c_rsel(cache_d_sel), .c_cyc(d_cyc),
        .c_stb(d_stb), .c_stall(cache_d_stall), .c_ack(cache_d_ack),
        .m_addr(db_addr), .m_wdata(db_wdata), .m_sel(db_sel), .m_we(db_we),
        .m_rdata(mem_rdata), .m_cyc(db_cyc), .m_stb(db_stb), .m_stall(db_stall), .m_ack(db_ack),
        .inv_valid(1'b0), .inv_addr({(XLEN-2){1'b0}})
    );

    // Retain the owner across a refill. At a free boundary, data has priority.
    // Keeping fills indivisible also orders instruction invalidation after
    // any older fill, so a completed store cannot resurrect stale I-cache data.
    reg owner_q, locked_q;
    wire owner_active = owner_q ? db_cyc : ib_cyc;
    wire select_d = (locked_q && owner_active) ? owner_q : db_cyc;
    assign mem_addr = select_d ? db_addr : ib_addr;
    assign mem_wdata = select_d ? db_wdata : ib_wdata;
    assign mem_wmask = select_d ? db_sel : ib_sel;
    assign mem_we = select_d ? db_we : ib_we;
    assign mem_cyc = select_d ? db_cyc : ib_cyc;
    assign mem_stb = select_d ? db_stb : ib_stb;
    assign db_stall = !select_d || mem_stall;
    assign ib_stall = select_d || mem_stall;
    assign db_ack = select_d && mem_ack;
    assign ib_ack = !select_d && mem_ack;
    always @(posedge clk) begin
        if (rst) begin
            locked_q <= 0;
            owner_q <= 0;
        end else begin
            locked_q <= mem_cyc;
            owner_q <= select_d;
        end
    end
endmodule
`default_nettype wire

// Internal RC16/RC32 Full pipeline.
//
// The pipeline is IF, Decode/RF, Execute. Decode drives two replicated
// synchronous MLAB register files; their registered read outputs are the
// Execute operands. Both RF mappings provide a write-first architectural
// view so dependent instructions can issue without a pipeline bubble.
//
// Iterative shifts and MUL hold Execute until complete. The independent
// data port transfers a native RC32 word in one transaction. MUL uses a
// registered DSP by default; RISCC_FAST_SOFT_MUL selects an iterative fabric
// implementation. The instruction, destination, and operands remain owned by
// X until the operation commits. Instruction fetch uses a 16-bit port; the
// data port is 32 bits wide with byte enables. Both use Wishbone B4 handshakes.

`default_nettype none

module riscc_cached_pipe #(
    parameter integer XLEN = 16,
    // Internal caches retain read data until the next accepted request.
    // The raw SRAM timing test uses a separate holding word instead.
    parameter integer FETCH_RESPONSE_HELD = 0,
    parameter REGISTER_FETCH = 1'b0,
    parameter [XLEN-1:0] RESET_PC = 0  // halfword address
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq,        // level-sensitive; sampled between instructions

    output wire [XLEN-2:0] imem_addr, // halfword address
    input  wire [15:0] imem_rdata,
    output wire imem_cyc,
    output wire imem_stb,
    input  wire imem_stall,
    input  wire imem_ack,

    output wire [XLEN-3:0] dmem_addr, // word address
    input  wire [31:0] dmem_rdata,
    input  wire [3:0] dmem_rsel, // byte enables retained with the response
    output wire [31:0] dmem_wdata,
    output wire [3:0] dmem_wmask,
    output wire dmem_we,
    output wire dmem_cyc,
    output wire dmem_stb,
    input  wire dmem_stall,
    input  wire dmem_ack
);
    initial begin
        if (XLEN != 16 && XLEN != 32)
            $error("riscc_cached: XLEN must be 16 or 32");
    end

    // ------------------------------------------------------------------
    // Pipeline state and side-state control
    // ------------------------------------------------------------------
    localparam [2:0] ST_RUN   = 3'd0;
    localparam [2:0] ST_SHIFT = 3'd1;
    localparam [2:0] ST_MUL   = 3'd2;
`ifndef RISCC_FAST_SOFT_MUL
    localparam [2:0] ST_MUL_CALC = 3'd3;
    localparam [2:0] ST_MUL_PIPE = 3'd4;
`endif
    (* syn_encoding = "user" *) reg [2:0] state_q;
    wire in_run   = state_q == ST_RUN;
    wire in_shift = state_q == ST_SHIFT;
    wire in_mul   = state_q == ST_MUL;

    reg interrupt_enable_q;
    reg interrupt_request_q;

    // ------------------------------------------------------------------
    // IF and Decode/RF stages
    // ------------------------------------------------------------------
    // Each port permits one accepted request and completion/replacement.
    // The I-cache output feeds Decode and remains stable while Execute is
    // occupied. Raw SRAM tests retain a response in the optional holding word.
    reg [XLEN-2:0] f_pc_q;
    reg [XLEN-2:0] x_pc_next_q;
    reg i_pending_q, i_discard_q, i_stalled_q;
    reg data_pending_q, data_stalled_q;
    reg d_valid_q;
    reg fetch_held_q;
    reg [15:0] d_instr_q;
    wire core_advance = 1'b1;
    wire data_pending = data_pending_q;
    wire fetch_pending = i_pending_q;
    wire fetch_reply = i_pending_q && imem_ack && !i_discard_q;
    wire d_valid = d_valid_q || (!REGISTER_FETCH && fetch_reply);
    wire [15:0] d_instr = REGISTER_FETCH ? d_instr_q :
        (FETCH_RESPONSE_HELD != 0) ? imem_rdata :
        d_valid_q ? d_instr_q : imem_rdata;

    // ISA notation: ddd is the destination, aaa and bbb are source fields,
    // and f5 is the five-bit register-operation field. Prefixes identify the
    // Decode (d_) and Execute (x_) stages.
    wire [1:0] d_class = d_instr[15:14];
    wire [2:0] d_ddd = d_instr[13:11];
    wire [2:0] d_aaa = d_instr[10:8];
    wire [4:0] d_f5 = d_instr[7:3];
    wire [2:0] d_bbb = d_instr[2:0];

    wire d_imm_memory = ~d_class[1] & d_class[0];
    wire d_imm_store = d_imm_memory & d_instr[0];
    wire d_immediate = d_class[1] & ~d_class[0];
    wire d_register = &d_class;
    wire d_branch = d_immediate & (d_aaa == 3'b111);
    wire d_ldpc = (XLEN == 32) && d_immediate && d_aaa == 1;
    wire d_imm_alu = d_immediate & ~d_branch & ~d_ldpc;
    wire d_reg_alu_group = d_register & (d_f5[4:3] == 2'b00);
    wire d_reg_mem = d_register & (d_f5[4:3] == 2'b01);
    wire d_system = d_register & d_f5[4] & d_f5[3];
    wire d_reg_store = d_reg_mem & ~d_f5[2] & d_f5[1] & d_f5[0];
    wire d_multiply = d_reg_alu_group & (&d_f5[2:0]);
    wire d_reg_alu = d_reg_alu_group & ~d_multiply;
    // FSL1/FSR1 use f5=10_001 with ooo[0] selecting right versus left.
    // Reserved functions in the group-10 plane may alias the same paths.
    wire d_funnel = d_register & d_f5[4] & ~d_f5[3];
    wire d_shift_right = d_reg_mem & d_f5[2] & ~d_f5[1];
    wire d_shift_left = d_reg_mem & (&d_f5[2:0]);
    wire d_shift = d_shift_right | d_shift_left;
    // LDX uses ra+rb. Direct typed accesses use ra.
    wire d_native_load = d_reg_mem & ~d_f5[2] &
                         ~d_f5[1] & ~d_f5[0];
    wire d_direct_load = d_reg_mem & d_f5[1] & ~d_f5[0];
    wire d_indexed_memory = d_native_load;
    wire d_reg_memory = d_native_load | d_direct_load | d_reg_store;
    wire d_memory = d_imm_memory | d_reg_memory | d_ldpc;
    wire d_store = d_imm_store | d_reg_store;
    wire d_load = d_memory & ~d_store;
    wire d_jal = d_system & ~d_bbb[2] & ~d_bbb[1] & d_bbb[0];
    wire d_control_plane = d_system & ~d_bbb[1] & ~d_bbb[0];
    // JALL is the only defined quadrant-00 instruction at either width.
    // Other encodings in this quadrant are undefined in the base ISA.
    wire d_jall = ~|d_class;
    wire d_link_jump = d_jal | d_jall;
    // RET/RETI and CLI/STI share bbb=000. ddd[1] selects a return versus a
    // direct IE operation; ddd[2] and ddd[0] duplicate the selected IE value.
    wire d_return = d_control_plane & ~d_ddd[1];
    wire d_move = d_system & ~d_bbb[2] & d_bbb[1];
    // Both final controls are predecoded to keep the packed selector off the
    // Execute instruction fanout.
    wire d_control_ie_value = d_ddd[2];
    wire d_ie_write = d_control_plane &
                      (d_ddd[1] | d_control_ie_value);
    // Defined byte and halfword selectors differ in bbb[1]. The remaining
    // selectors are reserved and need not enter the width-control cone.
    wire d_load_byte = (d_direct_load | d_reg_store) & ~d_bbb[1];
    wire d_signed_byte = d_load_byte & d_f5[2];
    wire d_cmpi = d_imm_alu & (d_aaa == 3'b011);

    // Compact funnels read old rd on A and ra on B before writing rd.
    wire d_src_a_is_ddd = d_class[1] & (~d_class[0] | d_f5[4]);
    wire [3:0] d_src_a = d_system ? {~d_bbb[0], d_aaa} :
        d_src_a_is_ddd ? {1'b0, d_ddd} : {1'b0, d_aaa};
    wire d_src_b_is_ddd = d_class[0] &
        (~d_class[1] | (d_f5[3] & d_f5[0]));
    wire d_src_b_is_aaa = (d_class[1] & d_f5[4]) |
        (d_class[0] & ~d_f5[4] & d_f5[3] & d_f5[1]);
    wire [3:0] d_src_b = {1'b0,
        d_src_b_is_ddd ? d_ddd :
        d_src_b_is_aaa ? d_aaa : d_bbb};

    wire d_result_we = d_imm_alu | d_shift | d_funnel |
                       d_reg_alu | d_multiply |
                       d_move | (d_link_jump & (|d_ddd));
    wire d_we = d_load | d_result_we;
    wire d_result_system = (d_system & d_bbb[0]) | d_jall;
    wire [3:0] d_dst = {
        d_result_system,
        d_ddd & {3{~d_cmpi}}
    };

    // ------------------------------------------------------------------
    // Execute stage and factored instruction decode
    // ------------------------------------------------------------------
    reg        x_valid_q;
    // The Decode head is also the executing instruction's sequential PC.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [XLEN-2:0] x_pc_q = x_pc_next_q - 1'b1;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */
    reg [13:0] x_instr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [3:0]  x_dst_q;
    reg        x_we_q;

    // Factored D-stage controls. Registering these removes raw major-opcode
    // decode from the Execute adder/result path without introducing a broad
    // 32-way operation selector.
    reg x_branch_q;
    reg x_imm_alu_q;
    reg x_multiply_q;
    // Predecode one-step bit operations and variable-shift continuation.
    reg x_bitop_q;
    reg x_shift_nonzero_q;
    reg x_shift_left_q;
    reg x_ldpc_q, x_native_immediate_q, x_native_word_q;
    reg x_memory_q;
    reg x_store_q;
    reg x_load_byte_q;
    reg x_signed_byte_q;
    reg x_indirect_q;
    reg x_jall_q;
    reg x_move_q;
    reg x_ie_write_q;
    // Decode also registers the result and arithmetic operand selects.
    reg x_run_imm_s_q;
    reg x_run_rf_b_q;
    reg x_run_short_imm_q;
    // Bit 1 selects subtraction; bit 0 selects an arithmetic result.
    // 00 bypass, 01 add, 11 subtract, 10 compare. No extra control state.
    reg [1:0] x_alu_kind_q;

`ifdef RISCC_FAST_SOFT_MUL
    wire [2:0] x_ddd = x_instr_q[13:11];
`else
    wire [2:0] x_ddd = x_dst_q[2:0];
`endif
    wire [1:0] x_aaa = x_instr_q[9:8];
    wire [2:0] x_f3 = x_instr_q[5:3];
    wire [2:0] x_bbb = x_instr_q[2:0];

    wire x_branch = x_branch_q;
    wire x_imm_alu = x_imm_alu_q;
    wire x_multiply = x_multiply_q;
    wire x_bitop = x_bitop_q;
    // Registering direction keeps ooo decode out of the Execute shifter and
    // improves both DSP and fabric timing.
    wire x_shift_left = x_shift_left_q;
    wire x_memory = x_memory_q;
    wire x_store = x_store_q;
    wire x_load_byte = x_load_byte_q;
    wire x_signed_byte = x_signed_byte_q;
    wire x_indirect = x_indirect_q;
    wire x_jall = x_jall_q;
    wire x_move = x_move_q;
    wire x_ie_write = x_ie_write_q;

    wire [XLEN-1:0] rf_a;
    wire [XLEN-1:0] rf_b;
    wire [XLEN-1:0] alu_result;
    wire x_mul_start, data_accept, x_finish;

    wire run_x = in_run & x_valid_q;
    // IRQ enters before a RUN instruction starts, never between data beats.
    // Waiting for an ACK also holds the architectural instruction boundary.
    wire take_irq = run_x && !data_pending && !data_stalled_q &&
                    interrupt_request_q && interrupt_enable_q;
    wire normal_x = run_x & ~take_irq;

    // Branches, LDPC, and arithmetic share the byte-addressed ALU. Keep the
    // instruction unchanged between D and X; branch displacement decoding
    // does not need a second mux on the Execute instruction register.
    wire [XLEN-1:0] x_imm_z = {{(XLEN-8){1'b0}}, x_instr_q[7:0]};
    wire x_imm_sign = x_ldpc_q ? x_instr_q[0] :
        ((XLEN == 32) && x_native_immediate_q) ? x_instr_q[1] :
        x_branch ? x_instr_q[0] : x_instr_q[7];
    wire [7:0] immediate_byte = ((XLEN == 32) && x_native_immediate_q) ?
        {x_instr_q[7:2], 2'b00} : x_instr_q[7:0];
    wire [XLEN-1:0] x_imm_s = {{(XLEN-8){x_imm_sign}}, immediate_byte};
    wire [XLEN-1:0] x_imm_u = {{(XLEN-16){1'b0}}, x_instr_q[7:0], 8'h00};
    reg [XLEN-1:0] side_data_q;

    wire [1:0] x_logic_op = x_move ? 2'b11 :
        x_imm_alu ? x_aaa[1:0] : x_f3[1:0];
    wire [XLEN-1:0] x_logic_rhs = x_imm_alu ? x_imm_z : rf_b;
    wire [XLEN-1:0] x_logic_result = !x_logic_op[1] ?
        (x_logic_op[0] ? (rf_a | x_logic_rhs) :
                         (rf_a & x_logic_rhs)) :
        (x_logic_op[0] ? rf_a : (rf_a ^ x_logic_rhs));

    // One-bit shift hardware is shared by the initial X step and ST_SHIFT.
    `ifdef RISCC_FAST_SOFT_MUL
    localparam integer COUNT_BITS = $clog2(XLEN/2);
`else
    localparam integer COUNT_BITS = 3;
`endif
`ifdef RISCC_FAST_SOFT_MUL
    // The multiplier's digit counter stays separate from instruction decode.
    reg [COUNT_BITS-1:0] side_count_q;
`else
    // With DSP multiplication only shifts count; their source index is dead.
    wire [COUNT_BITS-1:0] side_count_q = x_instr_q[2:0];
`endif

    // Shifts reuse the destination RF register as their accumulator. IRQs
    // remain deferred until the final step; both RAM mappings forward each write.
    wire [XLEN-1:0] side_shift_source = rf_a;
    wire side_shift_left = x_shift_left;
    wire side_shift_endpoint = x_instr_q[7] ? rf_b[0] :
                               (x_f3[0] & side_shift_source[XLEN-1]);
    wire [XLEN-1:0] side_shift_step = side_shift_left ?
        {side_shift_source[XLEN-2:0], x_instr_q[7] & rf_b[XLEN-1]} :
        {side_shift_endpoint, side_shift_source[XLEN-1:1]};
    wire [XLEN-1:0] x_shift_step = side_shift_step;
    wire [XLEN-1:0] shift_step = side_shift_step;
    wire shift_finish = in_shift & (side_count_q == 1);

`ifdef RISCC_FAST_SOFT_MUL
    // MUL visits XLEN/2 radix-4 Booth digits, from high to low. Each step
    // doubles the accumulator twice and adds 0, +/-ra, or +/-2*ra. Only
    // the low XLEN bits matter. X selects the first digit; each multiply
    // cycle selects the next, keeping that decode off the carry path.
    wire [COUNT_BITS-1:0] next_mul_digit = in_mul ? side_count_q - 1'b1 : {COUNT_BITS{1'b1}};
    wire [XLEN:0] multiplier_bits = {rf_b, 1'b0};
    wire [2:0] next_booth = multiplier_bits[{1'b0, next_mul_digit, 1'b0} +: 3];
    reg booth_one_q, booth_two_q, booth_negative_q;
    always @(posedge clk)
        if (!rst && core_advance) begin
            booth_one_q <= next_booth[1] ^ next_booth[0];
            booth_two_q <= (next_booth == 3'b011) || (next_booth == 3'b100);
            booth_negative_q <= next_booth[2];
        end
    wire [XLEN-1:0] mul_magnitude = booth_two_q ? {rf_a[XLEN-2:0], 1'b0} : rf_a;
    wire [XLEN-1:0] mul_addend = mul_magnitude & {XLEN{booth_one_q || booth_two_q}};
    wire [XLEN-1:0] mul_step = alu_result;
    wire mul_finish = in_mul && !(|side_count_q);
`else
    // Four Execute clocks: capture operands, pipeline the low product,
    // retain it for writeback, and commit. Other operations are unchanged.
    reg [XLEN-1:0] mul_a_q, mul_b_q, mul_product_q;
    wire [XLEN-1:0] x_mul_result = mul_a_q * mul_b_q;
    wire [XLEN-1:0] mul_write_data = side_data_q;
    always @(posedge clk) begin
        if (x_mul_start) begin
            mul_a_q <= rf_a;
            mul_b_q <= rf_b;
        end
        if (state_q == ST_MUL_CALC) mul_product_q <= x_mul_result;
        if (state_q == ST_MUL_PIPE) side_data_q <= mul_product_q;
    end
`endif

    // Arithmetic and addresses use the adder; other results bypass it.

    // Calls share the ordinary PC operand path with branches and LDPC.
    // IRQ shares the ALU; its operand select does not wait for RUN arbitration.
    wire pc_write = x_indirect || x_jall;
    // Pending loads do not use the ALU. A stalled command still owns its
    // address, so defer IRQ operand selection until it has been accepted.
    wire irq_alu = interrupt_request_q && interrupt_enable_q && !data_stalled_q;
    wire alu_a_is_pc = x_branch || x_ldpc_q || pc_write || irq_alu;
    // Non-arithmetic instructions do not consume the ALU result. Keeping
    // ra as the default removes a full-width zeroing gate on the input.
    wire [XLEN-1:0] ordinary_alu_a = alu_a_is_pc ? {x_pc_next_q, 1'b0} : rf_a;

    wire [XLEN-1:0] immediate_result = x_aaa[0] ? x_imm_u : x_imm_z;
    wire run_short_imm = x_run_short_imm_q;
    // These instruction classes are mutually exclusive. Arithmetic operands
    // never select this bypass path, including in the soft multiplier build.
    wire run_shift = x_bitop;
    wire [XLEN-1:0] run_result = run_short_imm ? immediate_result :
        run_shift ? x_shift_step : x_logic_result;
    // Decode supplies the two arithmetic operand selects. Logical, move
    // and shift results do not pass through this mux or the carry chain.
    // Branch/LDPC immediates encode their sign in bit 0. Clear it before
    // operand selection so register arithmetic needs no low-bit masking.
    wire [XLEN-1:0] arithmetic_imm =
        {x_imm_s[XLEN-1:1], x_imm_s[0] && !(x_branch || x_ldpc_q)};
    wire [XLEN-1:0] ordinary_alu_b =
        (rf_b & {XLEN{x_run_rf_b_q && !irq_alu}}) |
        (arithmetic_imm & {XLEN{x_run_imm_s_q && !irq_alu}}) |
        {{(XLEN-2){1'b0}}, x_jall || irq_alu, 1'b0};

    wire ordinary_subtract = irq_alu || x_alu_kind_q[1];
`ifdef RISCC_FAST_SOFT_MUL
    // MUL shares the adder, selecting its accumulator and digit only
    // during the iterative steps. Other instructions use the ordinary ALU.
    wire [XLEN-1:0] alu_a = in_mul ?
        {side_data_q[XLEN-3:0], 2'b00} : ordinary_alu_a;
    wire [XLEN-1:0] alu_b = in_mul ? mul_addend : ordinary_alu_b;
    wire alu_subtract = in_mul ? booth_negative_q : ordinary_subtract;
`else
    wire [XLEN-1:0] alu_a = ordinary_alu_a;
    wire [XLEN-1:0] alu_b = ordinary_alu_b;
    wire alu_subtract = ordinary_subtract;
`endif
    wire alu_carry_in = alu_subtract;
    wire [XLEN-1:0] adjusted_alu_b = alu_b ^ {XLEN{alu_subtract}};
    wire [XLEN:0] alu_sum = {1'b0, alu_a} +
                          {1'b0, adjusted_alu_b} +
                          {{XLEN{1'b0}}, alu_carry_in};
    assign alu_result = alu_sum[XLEN-1:0];
    wire alu_carry_out = alu_sum[XLEN];
    wire alu_overflow = (alu_a[XLEN-1] ^ alu_b[XLEN-1]) &
                        (alu_result[XLEN-1] ^ alu_a[XLEN-1]);
    wire signed_less = alu_result[XLEN-1] ^ alu_overflow;
    wire unsigned_less = ~alu_carry_out;
    wire x_compare = x_alu_kind_q[1] && !x_alu_kind_q[0];

    reg r0_negative_q, r0_zero_q;
    wire x_branch_taken = x_ddd[2] |
        ((x_ddd[1] ? r0_negative_q : r0_zero_q) ^ x_ddd[0]);

    // ------------------------------------------------------------------
    // X side-state starts, completion, redirects, and Decode issue
    // ------------------------------------------------------------------
    wire x_shift_start = normal_x & x_shift_nonzero_q;
    assign x_mul_start = normal_x & x_multiply;
    wire x_side_start = x_shift_start | x_mul_start;
    wire data_complete = dmem_ack && (data_pending_q || data_accept);
    wire run_commit = normal_x && !x_side_start &&
        (!x_memory || data_complete) && (!x_jall || d_valid);
`ifdef RISCC_FAST_SOFT_MUL
    wire mul_commit = mul_finish;
`else
    wire mul_commit = in_mul;
`endif
    wire x_complete = run_commit | shift_finish | mul_commit;
    wire commit_valid = x_finish;
    // Control transfers are RUN instructions with no side state or data
    // transaction. Their redirect does not depend on memory completion logic.
    wire x_redirect = normal_x &&
        ((x_branch && x_branch_taken) || x_indirect || (x_jall && d_valid));
    wire [31:0] x_long_target = {11'b0, x_instr_q[10:6], d_instr};
    wire [XLEN-2:0] x_redirect_pc = x_jall ? x_long_target[XLEN-1:1] :
        x_branch ? alu_result[XLEN-1:1] : rf_a[XLEN-1:1];
    wire redirect = take_irq | x_redirect;
    wire i_accept;
    wire frontend_flush = redirect && (!i_stalled_q || i_accept);
    // The compact frontend shares its target mux with the fetch port.
    // Registered fetch uses a separate parallel selector to shorten the
    // Execute-to-memory path without adding another redirect cycle.
    wire target_long = !take_irq && x_jall;
    wire target_branch = !take_irq && !x_jall && x_branch;
    wire target_register = !take_irq && !x_jall && !x_branch;
    wire [XLEN-2:0] compact_redirect_pc =
        ({{(XLEN-3){1'b0}}, 2'b10} & {(XLEN-1){take_irq}}) |
        (x_long_target[XLEN-1:1] & {(XLEN-1){target_long}}) |
        (alu_result[XLEN-1:1] & {(XLEN-1){target_branch}}) |
        (rf_a[XLEN-1:1] & {(XLEN-1){target_register}});
    wire [XLEN-2:0] frontend_redirect_pc = REGISTER_FETCH ?
        (take_irq ? 2 : x_redirect_pc) : compact_redirect_pc;

    // A previously offered fetch must remain stable until accepted. Hold a
    // redirect in Execute while that command drains, then discard its reply.
    assign x_finish = x_complete && (!redirect || frontend_flush);
    wire x_slot_available = !x_valid_q || x_complete;
    wire d_issue = !rst && d_valid && x_slot_available && !redirect;

    // ------------------------------------------------------------------
    // Load response and architectural writeback
    // ------------------------------------------------------------------
    wire [15:0] load_half = (|dmem_rsel[3:2]) ? dmem_rdata[31:16] : dmem_rdata[15:0];
    wire [7:0] accepted_load_byte = (dmem_rsel[3] || dmem_rsel[1]) ? load_half[15:8] : load_half[7:0];
    wire load_sign = x_signed_byte &&
        (x_load_byte ? accepted_load_byte[7] : load_half[15]);
    wire [XLEN-1:0] accepted_load_value = x_native_word_q ?
        dmem_rdata[XLEN-1:0] : x_load_byte ?
        {{(XLEN-8){load_sign}}, accepted_load_byte} :
        {{(XLEN-16){load_sign}}, load_half};
`ifdef RISCC_FAST_SOFT_MUL
    wire [XLEN-1:0] mul_write_data = mul_step;
`endif
    // ACK controls state enables, not the operand/result selectors. Their
    // values are immaterial while the pipeline and RF write port are held.
    wire rf_we = !rst && core_advance &&
                 ((take_irq && frontend_flush) || (x_finish && x_we_q) ||
                  x_shift_start || in_shift);
    wire [3:0] rf_waddr = take_irq ? 4'h8 : x_dst_q;
    // IRQ saves the interrupted PC. Calls and arithmetic share the ALU;
    // short and long calls save PC+1 and PC+2 halfwords respectively.
    wire compare_value = x_f3[0] ? unsigned_less : signed_less;
    wire write_arithmetic = pc_write || x_alu_kind_q[0];
    wire [XLEN-1:0] rf_wdata = (take_irq || write_arithmetic) ? alu_result :
        in_mul ? mul_write_data :
        x_memory ? accepted_load_value :
        x_compare ? {{(XLEN-1){1'b0}}, compare_value} : run_result;

    // Branch conditions observe the last architectural write to r0.
    // Updating alongside RF writeback forwards directly to a following branch.
    always @(posedge clk)
        if (rf_we && !(|rf_waddr)) begin
            r0_negative_q <= rf_wdata[XLEN-1];
            r0_zero_q <= !(|rf_wdata);
        end

    // Only unfinished shifts need their destination read back. The final
    // step can read Decode's operands; if Decode is empty no X operand is
    // consumed. Keep late cache completion out of the RF address selector.
    wire shift_feedback = core_advance &&
        (x_shift_start || (in_shift && !shift_finish));
    riscc_fast_rf #(.XLEN(XLEN)) regs (
        .clk(clk),
        .read_en_a((d_issue || shift_feedback) && !rst),
        .read_en_b(d_issue && !rst),
        .raddr_a(shift_feedback ? x_dst_q : d_src_a),
        .rdata_a(rf_a),
        .raddr_b(d_src_b),
        .rdata_b(rf_b),
        .waddr(rf_waddr),
        .wdata(rf_wdata),
        .we(rf_we)
    );

    // ------------------------------------------------------------------
    // Independent instruction and data handshakes
    // ------------------------------------------------------------------
    // A data request retains Execute and both RF outputs through ACK. The
    // instruction port continues independently during cache misses and loads.
    assign dmem_stb = !rst && normal_x && x_memory && !data_pending_q;
    assign dmem_cyc = !rst && (data_pending_q || dmem_stb);
    assign data_accept = dmem_stb && !dmem_stall;
    assign dmem_addr = alu_result[XLEN-1:2];
    assign dmem_we = x_store;
    wire [31:0] store_word = {{(32-XLEN){1'b0}}, rf_b};
    assign dmem_wdata = x_load_byte ? {4{rf_b[7:0]}} :
        x_native_word_q ? store_word : {2{rf_b[15:0]}};
    assign dmem_wmask = x_load_byte ? (4'b0001 << rf_a[1:0]) :
        x_native_word_q ? 4'b1111 : (alu_result[1] ? 4'b1100 : 4'b0011);

    wire i_ready = !i_pending_q || imem_ack;
    // A registered Decode stage can retain one instruction while the
    // memory port holds the following response during an Execute stall.
    wire decode_space = !d_valid_q || d_issue;
    // Drain a held response before requesting another: a zero-wait memory
    // may replace its data combinationally as soon as the next STB is offered.
    wire fetch_space = REGISTER_FETCH ?
        (!fetch_held_q && (decode_space || !fetch_reply)) : !d_valid || d_issue;
    wire redirect_fetch = redirect && !i_stalled_q;
    assign imem_stb = !rst && i_ready &&
        (i_stalled_q || redirect_fetch || (fetch_space && (!REGISTER_FETCH || !redirect)));
    assign imem_cyc = !rst && (i_pending_q || imem_stb);
    // Select fetch sources in parallel; a taken branch need not traverse
    // the call, interrupt, and sequential-PC priority muxes.
    wire fetch_irq = redirect_fetch && take_irq;
    wire fetch_long = redirect_fetch && !take_irq && x_jall;
    wire fetch_branch = redirect_fetch && !take_irq && !x_jall && x_branch;
    wire fetch_register = redirect_fetch && !take_irq && !x_jall && !x_branch;
    assign imem_addr = !REGISTER_FETCH ?
        (redirect_fetch ? frontend_redirect_pc : f_pc_q) :
        (f_pc_q & {(XLEN-1){!redirect_fetch}}) |
        ({{(XLEN-3){1'b0}}, 2'b10} & {(XLEN-1){fetch_irq}}) |
        (x_long_target[XLEN-1:1] & {(XLEN-1){fetch_long}}) |
        (alu_result[XLEN-1:1] & {(XLEN-1){fetch_branch}}) |
        (rf_a[XLEN-1:1] & {(XLEN-1){fetch_register}});
    assign i_accept = imem_stb && !imem_stall;
    wire early_fetch_reply = !i_pending_q && i_accept && imem_ack;
    wire fetch_capture = REGISTER_FETCH ?
        ((early_fetch_reply && redirect_fetch) ||
         ((fetch_held_q || fetch_reply || early_fetch_reply) && decode_space && !frontend_flush)) :
        (early_fetch_reply && (!frontend_flush || redirect_fetch)) ||
        (!frontend_flush && fetch_reply && (d_valid_q || !d_issue));

    always @(posedge clk) begin
        if (rst) begin
            f_pc_q <= RESET_PC[XLEN-2:0];
            x_pc_next_q <= RESET_PC[XLEN-2:0];
            i_pending_q <= 0;
            i_discard_q <= 0;
            i_stalled_q <= 0;
            data_pending_q <= 0;
            data_stalled_q <= 0;
            interrupt_request_q <= 0;
            d_valid_q <= 0;
            fetch_held_q <= 0;
        end else begin
            interrupt_request_q <= irq;
            data_stalled_q <= dmem_stb && dmem_stall;
            if (data_complete) data_pending_q <= 0;
            else if (data_accept) data_pending_q <= 1;
            i_stalled_q <= imem_stb && imem_stall;
            if (i_ready) begin
                i_pending_q <= i_accept && (i_pending_q || !imem_ack);
                i_discard_q <= frontend_flush && !redirect_fetch;
            end else if (frontend_flush) i_discard_q <= 1;
            if (frontend_flush) begin
                f_pc_q <= frontend_redirect_pc + {{(XLEN-2){1'b0}}, i_accept && redirect_fetch};
                x_pc_next_q <= frontend_redirect_pc;
            end else begin
                if (i_accept) f_pc_q <= f_pc_q + 1'b1;
                if (d_issue) x_pc_next_q <= x_pc_next_q + 1'b1;
            end
            if (REGISTER_FETCH) begin
                if (fetch_reply || early_fetch_reply) fetch_held_q <= 1;
                if (fetch_capture || frontend_flush) fetch_held_q <= 0;
            end
            if (frontend_flush || d_issue) d_valid_q <= 0;
            if (fetch_capture) begin
                d_instr_q <= imem_rdata;
                d_valid_q <= 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Pipeline and side-state updates
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst && core_advance) begin
            // D/RF -> X. The RF module samples the same decoded addresses on
            // this edge; its registered outputs and these controls stay aligned.
            if (d_issue) begin
                x_instr_q <= d_instr[13:0];
                x_dst_q <= d_dst;
                x_we_q <= d_we;
                x_branch_q <= d_branch;
                x_imm_alu_q <= d_imm_alu;
                x_multiply_q <= d_multiply;
                x_bitop_q <= d_shift | d_funnel;
                x_shift_nonzero_q <= d_shift & (|d_bbb);
                x_shift_left_q <= d_f5[1] | (d_f5[4] & ~d_bbb[0]);
                x_ldpc_q <= d_ldpc;
                x_native_immediate_q <= d_imm_memory;
                x_native_word_q <= (XLEN == 32) && (d_imm_memory || d_native_load || d_ldpc);
                x_memory_q <= d_memory;
                x_store_q <= d_store;
                x_load_byte_q <= d_load_byte;
                x_signed_byte_q <= (XLEN == 32) ? d_f5[2] : d_signed_byte;
                x_indirect_q <= d_return | d_jal;
                x_jall_q <= d_jall;
                x_move_q <= d_move;
                x_ie_write_q <= d_ie_write;
                x_run_imm_s_q <= d_branch | d_ldpc | d_imm_memory |
                                 (d_imm_alu & ~d_aaa[2] & d_aaa[1]);
                x_run_rf_b_q <= (d_reg_alu_group & ~d_f5[2]) |
                                d_indexed_memory;
                x_run_short_imm_q <= d_imm_alu & ~d_aaa[2] & ~d_aaa[1];
                x_alu_kind_q <= {
                    (d_imm_alu & ~d_aaa[2] & d_aaa[1] & d_aaa[0]) |
                    (d_reg_alu_group & ~d_f5[2] & (|d_f5[1:0])),
                    (d_imm_alu & ~d_aaa[2] & d_aaa[1]) |
                    (d_reg_alu_group & ~d_f5[2] & ~d_f5[1])
                };
            end

            if (frontend_flush) begin
                state_q <= ST_RUN;
                x_valid_q <= 1'b0;
            end else if (x_shift_start) begin
                state_q <= ST_SHIFT;
`ifdef RISCC_FAST_SOFT_MUL
                side_count_q <= {{(COUNT_BITS-3){1'b0}}, x_bbb};
`endif
            end else if (x_mul_start) begin
`ifdef RISCC_FAST_SOFT_MUL
                state_q <= ST_MUL;
                side_data_q <= 0;
                side_count_q <= {COUNT_BITS{1'b1}};
`else
                state_q <= ST_MUL_CALC;
            end else if (state_q == ST_MUL_CALC) begin
                state_q <= ST_MUL_PIPE;
            end else if (state_q == ST_MUL_PIPE) begin
                state_q <= ST_MUL;
`endif
`ifdef RISCC_FAST_SOFT_MUL
            end else if (in_mul & ~mul_finish) begin
                side_data_q <= mul_step;
                side_count_q <= side_count_q - 1'b1;
`endif
            end else if (in_shift & ~shift_finish) begin
`ifdef RISCC_FAST_SOFT_MUL
                side_count_q <= side_count_q - 1'b1;
`else
                x_instr_q[2:0] <= side_count_q - 1'b1;
`endif
            end else if (x_finish | ~x_valid_q) begin
                state_q <= ST_RUN;
                x_valid_q <= d_issue;
            end

            // Architectural IE changes only at completed instruction boundaries.
            if (frontend_flush && take_irq)
                interrupt_enable_q <= 1'b0;
            else if (x_finish && run_commit && x_ie_write)
                interrupt_enable_q <= x_ddd[2];

        end
        if (rst) begin
            state_q <= ST_RUN;
            interrupt_enable_q <= 0;
            x_valid_q <= 0;
        end
    end

endmodule


// Internal blocking direct-mapped cache. Addresses count 32-bit words.
// Each cache holds 2 KiB in lines of eight or sixteen words. Data RAM is synchronous;
// Tags and valid bits use MLABs, with reads registered alongside cache data.
// Reads miss by fetching a complete line.  Stores are write-through and do
// not allocate on a miss. One address bit selects uncached data;
// instruction fetches use full-address tags without a cacheability check.

`default_nettype none

module riscc_cached_cache #(
    // Capture the address before RAM lookup when sharing a fast local port.
    parameter REGISTER_LOOKUP = 1'b0,
    // Broadcast CPU requests also reach local SRAM. Ignore its address range
    // when accepting a cache transaction, but allow speculative RAM reads.
    parameter integer LOCAL_WORD_BITS = 0,
    parameter integer ADDR_BITS = 30,
    parameter integer LINE_WORD_BITS = 3,
    // Word-address bit selecting uncached data; ignored by instruction cache.
    parameter integer UNCACHED_BIT = ADDR_BITS-1,
    parameter integer READ_ONLY = 0,
    parameter integer CPU_BITS = 32,
    // Execute retains write data and direction until ACK on the data port.
    parameter integer HOLD_PAYLOAD = 0
) (
    input  wire                   clk,
    input  wire                   rst,

    input  wire [ADDR_BITS-1:0]   c_addr,
    input  wire [CPU_BITS-1:0]    c_wdata,
    input  wire [3:0]             c_sel,
    input  wire                   c_we,
    input  wire                   c_cyc,
    input  wire                   c_stb,
    output wire [CPU_BITS-1:0]    c_rdata,
    output wire [3:0]             c_rsel,
    output wire                   c_stall,
    output wire                   c_ack,

    output wire [ADDR_BITS-1:0]   m_addr,
    output wire [31:0]            m_wdata,
    output wire [3:0]             m_sel,
    output wire                   m_we,
    output wire                   m_cyc,
    output wire                   m_stb,
    input  wire [31:0]            m_rdata,
    input  wire                   m_stall,
    input  wire                   m_ack,

    input  wire                   inv_valid,
    input  wire [ADDR_BITS-1:0]   inv_addr
);
    localparam integer TAG_BITS = ADDR_BITS - 9;
    localparam integer INDEX_BITS = 9 - LINE_WORD_BITS;
    localparam integer LINE_COUNT = 1 << INDEX_BITS;
    localparam [LINE_WORD_BITS-1:0] LAST_BEAT = {LINE_WORD_BITS{1'b1}};

    initial begin
        if (LINE_WORD_BITS < 3 || LINE_WORD_BITS > 4)
            $error("riscc_cached_cache: line size must be 32 or 64 bytes");
        if (UNCACHED_BIT < LINE_WORD_BITS || UNCACHED_BIT >= ADDR_BITS)
            $error("riscc_cached_cache: bypass bits must be above the line offset");
    end

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_LOOKUP  = 3'd1;
    localparam [2:0] ST_REFILL  = 3'd2;
    localparam [2:0] ST_RELOOK  = 3'd3;
    localparam [2:0] ST_PASS    = 3'd4;
    localparam [2:0] ST_REPLY   = 3'd5;
    localparam [2:0] ST_CLEAR   = 3'd6;
    localparam [2:0] ST_UNCACHED = 3'd7;
    reg [2:0]        state_q;

    // The data RAM is deliberately not reset.  Valid bits provide reset and
    // replacement state, while this shape is inferred as one 512x32 M20K.
    (* ram_style = "block", ramstyle = "M20K, no_rw_check" *)
    reg [31:0] data_mem [0:511];
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [TAG_BITS:0] tag_mem [0:LINE_COUNT-1];

    reg [ADDR_BITS-1:0] req_addr_q;
    reg [CPU_BITS-1:0]  req_wdata_q;
    reg [3:0]           req_sel_q;
    reg                 captured_we_q;
    wire req_we_q = (HOLD_PAYLOAD != 0) ? c_we : captured_we_q;
    reg [31:0]          data_rdata_q;
    wire [TAG_BITS-1:0] tag_rdata_q;
    wire                lookup_valid_q;

    reg [LINE_WORD_BITS-1:0] refill_beat_q;
    reg                 pending_q;
    reg                 refill_invalidated_q;

    wire [INDEX_BITS-1:0] c_index = c_addr[8:LINE_WORD_BITS];
    wire [8:0] c_data_index = c_addr[8:0];
    wire [INDEX_BITS-1:0] req_index = req_addr_q[8:LINE_WORD_BITS];
    wire [8:0] req_data_index = req_addr_q[8:0];
    wire [INDEX_BITS-1:0] inv_index = inv_addr[8:LINE_WORD_BITS];
    // Tags and data are read together at request acceptance. The
    // response clock only compares the registered tag. A concurrent
    // invalidation poisons this lookup regardless of RAM RDW mode.
    reg [TAG_BITS:0] tag_word;
    reg tag_invalidated_q;
    assign tag_rdata_q = tag_word[TAG_BITS-1:0];
    assign lookup_valid_q = tag_word[TAG_BITS] && !tag_invalidated_q;
    wire read_only = (READ_ONLY != 0);

    wire req_cacheable = read_only || !req_addr_q[UNCACHED_BIT];

    // Allocated data lines have the bypass bit clear; do not store that bit.
    wire [TAG_BITS-1:0] req_tag;
    genvar tag_bit;
    generate for (tag_bit=0; tag_bit<TAG_BITS; tag_bit=tag_bit+1) begin : g_tag
        assign req_tag[tag_bit] = (READ_ONLY == 0 && tag_bit+9 == UNCACHED_BIT) ?
                                 1'b0 : req_addr_q[tag_bit+9];
    end endgenerate

    wire cpu_request = c_cyc && c_stb && !c_stall;
    wire local_request = LOCAL_WORD_BITS != 0 && (c_addr >> LOCAL_WORD_BITS) == 0;
    wire cpu_idle_accept = cpu_request && !local_request;
    wire lookup_hit = req_cacheable && lookup_valid_q && (tag_rdata_q == req_tag) &&
                      !(inv_valid && (inv_index == req_index));
    wire lookup_read_hit = lookup_hit && !req_we_q;

    // Backend refill command generation.  A pending request is replaced on
    // the same edge as its ACK whenever the target is able to accept the next
    // beat.  If STALL is asserted, the replacement command remains stable.
    wire refill_response = (state_q == ST_REFILL) && pending_q && m_ack;
    wire refill_offer_next = (state_q == ST_REFILL) && pending_q &&
                             m_ack && (refill_beat_q != LAST_BEAT);
    wire refill_accept = (state_q == ST_REFILL) && m_cyc && m_stb && !m_stall;
    wire refill_immediate = (state_q == ST_REFILL) && !pending_q &&
                            refill_accept && m_ack;
    wire refill_response_event = refill_response || refill_immediate;
    wire refill_last_response = refill_response_event &&
                                (refill_beat_q == LAST_BEAT);

    // Uncached commands reach the backing port during their first lookup
    // clock. Checking the retained address keeps the bypass bit test
    // off the incoming address path without delaying the backing request.
    // Pass-through requests have one backend command and no refill data.
    // An ACK on an accepted command is an immediate response; otherwise the
    // command is held as an outstanding request until ACK arrives.
    wire pass_active = (state_q == ST_PASS) ||
        ((state_q == ST_LOOKUP) && (!req_cacheable || (read_only && req_we_q)));
    wire pass_accept = pass_active && m_cyc && m_stb && !m_stall;
    wire pass_response = pass_active &&
        ((pending_q && m_ack) ||
         (!pending_q && pass_accept && m_ack));
    // ACK describes the retained transaction, so it remains asserted after
    // STB drops while CYC is held through completion.  It must not be gated
    // by the current CYC/STB inputs: doing so feeds a combinational response
    // loop into masters that derive their next CYC from ACK.
    assign c_ack = ((state_q == ST_LOOKUP) && lookup_read_hit) ||
                   (pass_response && req_we_q) || (state_q == ST_REPLY);
    // Only instruction fetch replaces a hit on its response edge. Execute
    // holds each data operation through ACK and offers its next request on
    // the following clock, so data readiness need not depend on the tag.
    assign c_stall =
        ((state_q == ST_IDLE) || (state_q == ST_REPLY)) ? 1'b0 :
        (READ_ONLY != 0 && state_q == ST_LOOKUP) ? !lookup_read_hit :
        1'b1;
    // Every read response comes from the data RAM output. Uncached replies
    // use the refill write port, then read back the word in ST_UNCACHED.
    wire [31:0] cpu_read_word = (CPU_BITS == 16 && req_sel_q[3]) ?
        {16'b0, data_rdata_q[31:16]} : data_rdata_q;
    assign c_rdata = cpu_read_word[CPU_BITS-1:0];
    assign c_rsel = req_sel_q;

    assign m_cyc = pass_active || (state_q == ST_REFILL);
    assign m_stb = pass_active ? !pending_q :
                   (state_q == ST_REFILL) ?
                       (!pending_q || refill_offer_next) : 1'b0;
    wire [LINE_WORD_BITS-1:0] refill_addr_beat = refill_beat_q +
        {{(LINE_WORD_BITS-1){1'b0}}, pending_q && m_ack};
    assign m_addr = pass_active ? req_addr_q :
                    {req_addr_q[ADDR_BITS-1:LINE_WORD_BITS], refill_addr_beat};
    wire [CPU_BITS-1:0] store_data = (HOLD_PAYLOAD != 0) ? c_wdata : req_wdata_q;
    assign m_wdata = read_only ? 32'b0 : {{(32-CPU_BITS){1'b0}}, store_data};
    assign m_sel = pass_active ? req_sel_q : 4'b1111;
    assign m_we = req_we_q;

    // One read address and one byte-enabled write address infer a simple
    // dual-port RAM. Select addresses before indexing the arrays.
    wire relook = (state_q == ST_RELOOK) || (state_q == ST_UNCACHED);
    wire [8:0] ram_read_addr = (REGISTER_LOOKUP || relook) ? req_data_index : c_data_index;
    // Reading an uncached request's RAM index is harmless; its data cannot
    // be acknowledged as a hit. Every accepted address uses the same enable.
    wire ram_read_en = (!REGISTER_LOOKUP && cpu_request) || relook;
    wire [INDEX_BITS-1:0] tag_read_addr = (REGISTER_LOOKUP || relook) ? req_index : c_index;
    always @(posedge clk)
        if (!rst && ram_read_en) begin
            tag_word <= tag_mem[tag_read_addr];
            tag_invalidated_q <= inv_valid && (inv_index == tag_read_addr);
        end
    wire store_hit = (state_q == ST_LOOKUP) && lookup_hit && req_we_q && !read_only;
    wire pass_read_reply = pass_response && !req_we_q;
    wire backing_read_reply = refill_response_event || pass_read_reply;
    wire [8:0] ram_write_addr = refill_response_event ?
        {req_index, refill_beat_q} : req_data_index;
    wire [31:0] ram_write_data = backing_read_reply ? m_rdata : {{(32-CPU_BITS){1'b0}}, store_data};
    wire [3:0] ram_write_mask = backing_read_reply ? 4'b1111 :
        (req_sel_q & {4{store_hit}});
    integer lane;
    always @(posedge clk) begin
        if (!rst && ram_read_en) begin
            data_rdata_q <= data_mem[ram_read_addr];
        end
        if (!rst)
            for (lane=0; lane<4; lane=lane+1)
                if (ram_write_mask[lane])
                    data_mem[ram_write_addr][lane*8 +: 8] <= ram_write_data[lane*8 +: 8];
    end

    // Valid lives with the tag in MLAB/LUT RAM. Reset clears one entry per
    // clock, using the otherwise idle request index as the sweep counter.
    // Both caches clear in parallel; normal hits retain their one-clock path.
    wire clearing = state_q == ST_CLEAR;
    // An uncached reply overwrites a RAM word without installing a tag.
    // Clear its line before acknowledging it; external invalidation has
    // priority on the shared tag write port.
    wire clear_reply_tag = state_q == ST_UNCACHED;
    wire tag_write_en = clearing || inv_valid || clear_reply_tag ||
        (refill_last_response && !refill_invalidated_q);
    wire [INDEX_BITS-1:0] tag_write_addr = (inv_valid && !clearing) ? inv_index : req_index;
    wire [TAG_BITS:0] tag_write_data = (clearing || inv_valid || clear_reply_tag) ?
        {(TAG_BITS+1){1'b0}} : {1'b1, req_tag};
    always @(posedge clk)
        if (!rst && tag_write_en) tag_mem[tag_write_addr] <= tag_write_data;

    always @(posedge clk) begin
        if (rst) begin
            state_q <= ST_CLEAR;
            req_addr_q[8:LINE_WORD_BITS] <= 0;
            pending_q <= 1'b0;
            refill_beat_q <= 0;
            refill_invalidated_q <= 1'b0;
        end else begin
            // An idle address has no owner; payload must retain the last reply
            // until a new request. Region selection only controls cache state.
            if (!c_stall) req_addr_q <= c_addr;
            if (cpu_request) begin
                if (HOLD_PAYLOAD == 0) req_wdata_q <= c_wdata;
                req_sel_q <= c_sel;
                if (HOLD_PAYLOAD == 0) captured_we_q <= c_we;
            end
            if (cpu_idle_accept) begin
                pending_q <= 1'b0;
                state_q <= REGISTER_LOOKUP ? ST_RELOOK : ST_LOOKUP;
            end else case (state_q)
                ST_CLEAR: begin
                    if (&req_index) state_q <= ST_IDLE;
                    else req_addr_q[8:LINE_WORD_BITS] <= req_index + 1'b1;
                end
                ST_IDLE: begin end
                ST_LOOKUP: begin
                    if (pass_active) begin
                        state_q <= ST_PASS;
                    end else if (lookup_read_hit) begin
                        state_q <= ST_IDLE;
                    end else if (req_we_q) begin
                        // Both store hits and misses await the backing write.
                        // Only a hit updates data RAM; misses do not allocate.
                        pending_q <= 1'b0;
                        state_q <= ST_PASS;
                    end else begin
                        // Read miss. Publish the replacement tag only after
                        // the entire line has arrived.
                        refill_beat_q <= 0;
                        pending_q <= 1'b0;
                        refill_invalidated_q <= inv_valid &&
                            (inv_index == req_index);
                        state_q <= ST_REFILL;
                    end
                end

                ST_REFILL: begin
                    if (inv_valid && (inv_index == req_index))
                        refill_invalidated_q <= 1'b1;
                    if (refill_response_event) begin
                        if (refill_last_response) begin
                            pending_q <= 1'b0;
                            state_q <= ST_RELOOK;
                        end else begin
                            refill_beat_q <= refill_beat_q + 1'b1;
                            // A response and replacement acceptance may
                            // occupy the same clock edge.
                            // With no old pending request, an accepted ACK
                            // completed immediately and needs no pending bit.
                            pending_q <= refill_accept &&
                                (pending_q || !m_ack);
                        end
                    end else if (!pending_q && refill_accept) begin
                        pending_q <= 1'b1;
                    end
                end

                ST_RELOOK: begin
                    // Read after the final write, avoiding mixed-port RAM
                    // read-during-write behavior at the requested address.
                    state_q <= ST_LOOKUP;
                end
                ST_UNCACHED: begin
                    // Retry if another index needed the tag write port.
                    if (!inv_valid || inv_index == req_index) state_q <= ST_REPLY;
                end

                ST_PASS: begin
                    // Backend completion is handled below.
                end
                ST_REPLY: state_q <= ST_IDLE;

                default: begin
                    state_q <= ST_IDLE;
                    pending_q <= 1'b0;
                end
            endcase

            if (pass_active) begin
                if (pass_response) begin
                    pending_q <= 0;
                    state_q <= req_we_q ? ST_IDLE : ST_UNCACHED;
                end else if (pass_accept) pending_q <= 1;
            end
        end
    end

endmodule

`default_nettype wire
