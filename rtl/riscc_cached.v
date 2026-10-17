// RC16/RC32 cached core: pipeline, local SRAM, and write-through I/D caches.
`default_nettype none

module riscc_cached #(
    parameter integer XLEN = 32,
    // Byte-address bit selecting uncached data outside local SRAM.
    parameter integer DCACHE_UNCACHED_BIT = XLEN-1,
    // Aligned cacheable region; other external reads bypass the caches.
    parameter integer CACHE_ADDR_BITS = XLEN,
    parameter [XLEN-1:0] CACHE_BASE = 0,
    parameter integer SRAM_ADDR_BITS = 0,
    // Quartus uses the companion SRAM_HEX + ".mif" file.
    parameter SRAM_HEX = "",
    parameter [XLEN-1:0] RESET_PC = 0
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   irq,
    output wire [XLEN-3:0]        mem_addr,
    input  wire [31:0]            mem_rdata,
    output wire [31:0]            mem_wdata,
    output wire [3:0]             mem_wmask,
    output wire                   mem_we,
    output wire                   mem_cacheable,
    output wire                   mem_cyc,
    output wire                   mem_stb,
    input  wire                   mem_stall,
    input  wire                   mem_ack
);
    // RC16 uses 32-byte lines; RC32 uses 64-byte lines.
    localparam integer LINE_WORD_BITS = XLEN == 32 ? 4 : 3;
    localparam [XLEN-1:0] CACHE_MASK =
        ~({XLEN{1'b1}} >> (XLEN-CACHE_ADDR_BITS));

    wire [XLEN-2:0] i_addr;
    wire [15:0] i_data;
    wire i_cyc, i_stb, i_stall, i_ack, i_local;
    wire [XLEN-3:0] d_addr;
    wire [63:0] d_rdata;
    wire [31:0] d_wdata;
    wire [3:0] d_sel;
    wire d_we, d_cyc, d_stb, d_stall, d_ack, d_store_local;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [XLEN-3:0] d_store_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire d_response_local;
    wire iflush_req, iflush_ack;

    wire [15:0] cache_i_data;
    wire [31:0] cache_d_data;
    wire cache_i_ack, cache_i_stall, cache_d_ack, cache_d_stall;
    wire [XLEN-3:0] ib_addr, db_addr;
    wire [31:0] db_wdata;
    wire [3:0] ib_sel, db_sel;
    wire ib_we, ib_cyc, ib_stb, ib_stall, ib_ack;
    wire db_we, db_cyc, db_stb, db_stall, db_ack;
    wire ib_cacheable, db_cacheable;

    reg iflush_active_q;
    reg instruction_owner_q;
    wire iflush_start = iflush_req && !iflush_active_q && !i_cyc && !ib_cyc;
    wire select_d = db_cyc && !instruction_owner_q;

    initial begin
        if (CACHE_ADDR_BITS < 12 || CACHE_ADDR_BITS > XLEN ||
            (CACHE_BASE & ~CACHE_MASK) != 0)
            $error("riscc_cached: invalid cacheable region");
        if (DCACHE_UNCACHED_BIT < LINE_WORD_BITS+2 || DCACHE_UNCACHED_BIT >= XLEN)
            $error("riscc_cached: D-cache bypass bits must be above the line offset");
    end

    riscc_cached_pipe #(
        .XLEN(XLEN),
        .RESET_PC(RESET_PC),
        .LOCAL_ADDR_BITS(SRAM_ADDR_BITS)
    ) cpu (
        .clk(clk),
        .rst(rst),
        .irq(irq),
        .iflush_req(iflush_req),
        .iflush_ack(iflush_ack),
        .imem_addr(i_addr),
        .imem_local(i_local),
        .imem_rdata(i_data),
        .imem_cyc(i_cyc),
        .imem_stb(i_stb),
        .imem_stall(i_stall),
        .imem_ack(i_ack),
        .dmem_addr(d_addr),
        .dmem_rdata(d_rdata),
        .dmem_local(d_response_local),
        .dmem_wdata(d_wdata),
        .dmem_wmask(d_sel),
        .dmem_we(d_we),
        .dmem_write_local(d_store_local),
        .dmem_store_addr(d_store_addr),
        .dmem_cyc(d_cyc),
        .dmem_stb(d_stb),
        .dmem_stall(d_stall),
        .dmem_ack(d_ack)
    );

    // A busy cache owns its CPU port, independent of the next address decode.
    assign i_stall = cache_i_stall;
    assign d_stall = cache_d_stall;

    generate
        if (SRAM_ADDR_BITS != 0) begin : g_sram
            localparam integer WORD_BITS = SRAM_ADDR_BITS - 2;
            reg i_local_q, i_ack_q, d_ack_q;
            wire [15:0] i_sram_data;
            wire [31:0] d_word_q;
            wire d_accept = d_cyc && d_stb && !d_stall && !rst;
            wire d_write = d_cyc && d_stb && d_we && d_store_local && !d_stall && !rst;
            // Speculative reads are independent of nonlocal cache backpressure.
            wire d_read = d_stb && !d_we;

            initial begin
                if (SRAM_ADDR_BITS < 3 || SRAM_ADDR_BITS >= XLEN)
                    $error("riscc_cached: invalid local SRAM size");
            end

            // Software must avoid instruction reads concurrent with writes
            // to the same word: mixed-port read/write data is undefined.
            riscc_cached_sram #(
                .WORD_BITS(WORD_BITS),
                .SRAM_HEX(SRAM_HEX)
            ) sram (
                .clk(clk),
                .i_addr(i_addr[WORD_BITS:0]),
                .i_en(i_stb),
                .i_data(i_sram_data),
                .d_addr(d_addr[WORD_BITS-1:0]),
                .d_en(d_read),
                .d_data(d_word_q),
                .store_addr(d_store_addr[WORD_BITS-1:0]),
                .write_data(d_wdata),
                .write_mask(d_sel),
                .write_en(d_write)
            );

            always @(posedge clk) begin
                i_ack_q <= i_cyc && i_stb && !i_stall && !rst;
                d_ack_q <= d_accept;
                // Retain response ownership through stalls and boundaries.
                if (i_cyc && i_stb && !i_stall)
                    i_local_q <= i_local;
                if (rst) begin
                    i_ack_q <= 0;
                    d_ack_q <= 0;
                    i_local_q <= 0;
                end
            end

            assign i_data = i_local_q ? i_sram_data : cache_i_data;
            assign d_rdata = {cache_d_data, d_word_q};
            assign i_ack = (i_ack_q && i_local_q) || cache_i_ack;
            assign d_ack = (d_ack_q && d_response_local) || cache_d_ack;
        end else begin : g_no_sram
            assign i_data = cache_i_data;
            assign d_rdata = {cache_d_data, 32'b0};
            assign i_ack = cache_i_ack;
            assign d_ack = cache_d_ack;
        end
    endgenerate

    // Drain old instruction requests before the reset sweep. Data traffic
    // continues independently: IFLUSH is not a store barrier.
    assign iflush_ack = iflush_active_q && !cache_i_stall;
    always @(posedge clk) begin
        if (rst || !iflush_req)
            iflush_active_q <= 0;
        else if (iflush_start)
            iflush_active_q <= 1;
    end

    riscc_cached_cache #(
        .ADDR_BITS(XLEN-2),
        .READ_ONLY(1),
        .CPU_BITS(16),
        .TAG_ADDR_BITS(CACHE_ADDR_BITS-2),
        .CACHE_BASE(CACHE_BASE[XLEN-1:2]),
        .REGISTER_LOOKUP(SRAM_ADDR_BITS != 0),
        .LOCAL_WORD_BITS(SRAM_ADDR_BITS != 0 ? SRAM_ADDR_BITS-2 : 0),
        .LINE_WORD_BITS(LINE_WORD_BITS)
    ) icache (
        .clk(clk),
        .rst(rst || iflush_start),
        .c_addr(i_addr[XLEN-2:1]),
        .c_wdata(16'b0),
        .c_sel(i_addr[0] ? 4'b1100 : 4'b0011),
        .c_we(1'b0),
        .c_rdata(cache_i_data),
        .c_rsel(),
        .c_local(),
        .c_cyc(i_cyc),
        .c_stb(i_stb),
        .c_stall(cache_i_stall),
        .c_ack(cache_i_ack),
        .store_posted(),
        .m_cacheable(ib_cacheable),
        .m_addr(ib_addr),
        .m_wdata(),
        .m_sel(ib_sel),
        .m_we(ib_we),
        .m_rdata(mem_rdata),
        .m_cyc(ib_cyc),
        .m_stb(ib_stb),
        .m_stall(ib_stall),
        .m_ack(ib_ack),
        .inv_valid(1'b0),
        .inv_addr({(XLEN-2){1'b0}})
    );

    riscc_cached_cache #(
        .ADDR_BITS(XLEN-2),
        .TAG_ADDR_BITS(CACHE_ADDR_BITS-2),
        .CACHE_BASE(CACHE_BASE[XLEN-1:2]),
        .UNCACHED_BIT(DCACHE_UNCACHED_BIT-2),
        .READ_ONLY(0),
        .LOCAL_WORD_BITS(SRAM_ADDR_BITS != 0 ? SRAM_ADDR_BITS-2 : 0),
        .LINE_WORD_BITS(LINE_WORD_BITS)
    ) dcache (
        .clk(clk),
        .rst(rst),
        .c_addr(d_addr),
        .c_wdata(d_wdata),
        .c_sel(d_sel),
        .c_we(d_we),
        .c_rdata(cache_d_data),
        .c_rsel(),
        .c_local(d_response_local),
        .c_cyc(d_cyc),
        .c_stb(d_stb),
        .c_stall(cache_d_stall),
        .c_ack(cache_d_ack),
        .store_posted(),
        .m_cacheable(db_cacheable),
        .m_addr(db_addr),
        .m_wdata(db_wdata),
        .m_sel(db_sel),
        .m_we(db_we),
        .m_rdata(mem_rdata),
        .m_cyc(db_cyc),
        .m_stb(db_stb),
        .m_stall(db_stall),
        .m_ack(db_ack),
        .inv_valid(1'b0),
        .inv_addr({(XLEN-2){1'b0}})
    );

    // Refills retain the backing port; data has priority between fills.
    // Registered ownership keeps fetch classification off the stall path.
    assign mem_cacheable = select_d ? db_cacheable : ib_cacheable;
    assign mem_addr = select_d ? db_addr : ib_addr;
    assign mem_wdata = db_wdata;
    assign mem_wmask = select_d ? db_sel : ib_sel;
    assign mem_we = select_d ? db_we : ib_we;
    assign mem_cyc = db_cyc || ib_cyc;
    assign mem_stb = select_d ? db_stb : ib_stb;
    assign db_stall = !select_d || mem_stall;
    assign ib_stall = select_d || mem_stall;
    assign db_ack = select_d && mem_ack;
    assign ib_ack = !select_d && mem_ack;

    always @(posedge clk) begin
        if (rst)
            instruction_owner_q <= 0;
        else
            instruction_owner_q <= ib_cyc && !select_d;
    end
endmodule

module riscc_cached_sram #(
    parameter integer WORD_BITS = 1,
    parameter SRAM_HEX = ""
) (
    input  wire                   clk,
    input  wire [WORD_BITS:0]     i_addr,
    input  wire                   i_en,
    output wire [15:0]            i_data,
    input  wire [WORD_BITS-1:0]   d_addr,
    input  wire                   d_en,
    output wire [31:0]            d_data,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [WORD_BITS-1:0]   store_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0]            write_data,
    input  wire [3:0]             write_mask,
    input  wire                   write_en
);
`ifdef ALTERA_RESERVED_QIS
    // Two native read ports share byte-enabled writes.
    altera_syncram #(
        .init_file(SRAM_HEX == "" ? "UNUSED" : {SRAM_HEX, ".mif"}),
        .operation_mode("DUAL_PORT"),
        .ram_block_type("M20K"),
        .width_a(32),
        .widthad_a(WORD_BITS),
        .numwords_a(1 << WORD_BITS),
        .width_byteena_a(4),
        .byte_size(8),
        .width_b(32),
        .widthad_b(WORD_BITS),
        .numwords_b(1 << WORD_BITS),
        .address_reg_b("CLOCK0"),
        .outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("DONT_CARE")
    ) data_sram (
        .clock0(clk),
        .clocken0(1'b1),
        .clocken1(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .aclr0(1'b0),
        .aclr1(1'b0),
        .address_a(store_addr),
        .data_a(write_data),
        .byteena_a(write_mask),
        .wren_a(write_en),
        .address_b(d_addr),
        .rden_b(d_en),
        .q_b(d_data)
    );

    altera_syncram #(
        .init_file(SRAM_HEX == "" ? "UNUSED" : {SRAM_HEX, ".mif"}),
        .operation_mode("DUAL_PORT"),
        .ram_block_type("M20K"),
        .width_a(32),
        .widthad_a(WORD_BITS),
        .numwords_a(1 << WORD_BITS),
        .width_byteena_a(4),
        .byte_size(8),
        .width_b(16),
        .widthad_b(WORD_BITS+1),
        .numwords_b(1 << (WORD_BITS+1)),
        .address_reg_b("CLOCK0"),
        .outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("DONT_CARE")
    ) instruction_sram (
        .clock0(clk),
        .clocken0(1'b1),
        .clocken1(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .aclr0(1'b0),
        .aclr1(1'b0),
        .address_a(store_addr),
        .data_a(write_data),
        .byteena_a(write_mask),
        .wren_a(write_en),
        .address_b(i_addr),
        .rden_b(i_en),
        .q_b(i_data)
    );
`else
    (* ram_style = "block", no_rw_check *) reg [31:0] ram [0:(1 << WORD_BITS)-1];
    reg i_half_q;
    reg [31:0] i_read_q, d_read_q;
    integer lane;

    initial begin
        if (SRAM_HEX != "")
            $readmemh(SRAM_HEX, ram);
    end

    always @(posedge clk) begin
        if (i_en)
            i_read_q <= ram[i_addr[WORD_BITS:1]];
        if (d_en)
            d_read_q <= ram[d_addr];
    end

    always @(posedge clk) begin
        if (write_en)
            for (lane = 0; lane < 4; lane = lane + 1)
                if (write_mask[lane])
                    ram[d_addr][lane*8 +: 8] <= write_data[lane*8 +: 8];
    end

    // Keep the selector aligned with speculative instruction reads.
    always @(posedge clk)
        if (i_en)
            i_half_q <= i_addr[0];

    assign i_data = i_half_q ? i_read_q[31:16] : i_read_q[15:0];
    assign d_data = d_read_q;
`endif
endmodule

// Four-stage RC16/RC32 pipeline: Fetch, Decode/RF, Execute, Writeback.
// f_/d_/x_/w_ identify stages; _q denotes registered state. PC values count
// halfwords. dmem_rdata carries cache data in [63:32] and SRAM data in [31:0].
// Each private port allows one pending request, replaceable on its reply edge.
// Requests may change before STB && !STALL; replies take at least one clock.
`default_nettype none

module riscc_cached_pipe #(
    parameter integer XLEN = 32,
    parameter integer LOCAL_ADDR_BITS = 0,
    parameter [XLEN-1:0] RESET_PC = 0  // halfword address
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   irq,        // level-sensitive; sampled between instructions
    output wire                   iflush_req, // held until the memory frontend has cleared
    input  wire                   iflush_ack, // direct SRAM without an I-cache may tie high

    output wire                   imem_local,
    output wire [XLEN-2:0]        imem_addr, // halfword address
    input  wire [15:0]            imem_rdata,
    output wire                   imem_cyc,
    output wire                   imem_stb,
    input  wire                   imem_stall,
    input  wire                   imem_ack,

    output wire [XLEN-3:0]        dmem_addr, // word address
    input  wire [63:0]            dmem_rdata,
    input  wire                   dmem_local,
    output wire [31:0]            dmem_wdata,
    output wire [3:0]             dmem_wmask,
    output wire                   dmem_we,
    output wire                   dmem_write_local,
    output wire [XLEN-3:0]        dmem_store_addr,
    output wire                   dmem_cyc,
    output wire                   dmem_stb,
    input  wire                   dmem_stall,
    input  wire                   dmem_ack
);

    // Pipeline state

    initial begin
        if (XLEN != 16 && XLEN != 32)
            $error("riscc_cached: XLEN must be 16 or 32");
    end

    // Execute states: ordinary instructions, multiplication, and IFLUSH.
    localparam [1:0] ST_RUN      = 2'd0;
    localparam [1:0] ST_MUL      = 2'd1;
    localparam [1:0] ST_MUL_CALC = 2'd2;
    localparam [1:0] ST_IFLUSH   = 2'd3;
    (* syn_encoding = "user" *) reg [1:0] state_q;
    wire in_run   = state_q == ST_RUN;
    wire in_mul   = state_q == ST_MUL;
    wire in_iflush = state_q == ST_IFLUSH;
    assign iflush_req = in_iflush;

    reg interrupt_enable_q;
    reg interrupt_request_q;

    // A held instruction keeps f_pc_q until issue. Prediction uses the
    // same response slot, without another PC register or instruction queue.
    reg recover_q;
    reg x_collision_q;
    reg [1:0] x_count_q;
    wire [1:0] btb_victim_count;
    reg x_hit_q;
    wire btb_taken, btb_clearing, btb_collision;
    wire [XLEN-2:0] btb_target;
    wire [1:0] btb_count;
    wire btb_hit;

    // Fetch and decode. Each memory port permits one pending request, which
    // can complete on the same edge that accepts its replacement.
    // The instruction port retains response data until the next request.
    reg [XLEN-2:0] f_pc_q;
    reg f_advance_q;
    // Execute retains the opcode PC for link values and precise IRQ entry.
    reg [XLEN-2:0] x_pc_q;
    reg i_pending_q, i_discard_q;
    reg data_pending_q;
    reg d_valid_q;
    // One completion slot shares the RF write port between ALU and loads.
    // Execute can replace it on the response edge; a miss holds younger work.
    reg w_we_q;
    reg [3:0] w_dst_q;
    reg [XLEN-1:0] w_result_q;
    reg w_native_q, w_byte_q;
    reg [3:0] w_sign_mask_q;
    reg w_upper_q, w_odd_q;
    wire core_advance = !data_pending_q || dmem_ack;
    wire fetch_reply = i_pending_q && imem_ack && !i_discard_q;
    wire d_valid = d_valid_q || fetch_reply;
    wire [15:0] d_instr = imem_rdata;
    reg x_jall_hit_q;
    reg x_valid_q, x_load_wait_q;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [13:0] x_instr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [3:0] x_dst_q;
    reg x_we_q;

    reg x_branch_q;
    reg x_imm_alu_q;
    reg x_multiply_q;
    // Immediate shifts complete in one Execute cycle.
    reg x_bitop_q;
    reg [2:0] x_shift_offset_q;
    reg x_shift_left_q;
    reg x_imm_sign_q, x_imm_bit0_q;
    reg x_alu_a_pc_q;
    reg x_alu_b_register_q, x_alu_b_imm_q;
    reg x_native_immediate_q, x_native_word_q;
    reg x_load_q, x_store_q;
    reg x_load_byte_q, x_signed_byte_q;
    reg x_indirect_q, x_jall_q;
    reg [2:0] x_logic_table_q;
    reg x_ie_write_q;
    reg x_iflush_q;
    reg x_run_short_imm_q;
    // Bit 1 selects subtraction; bit 0 selects an arithmetic result.
    // 00 bypass, 01 add, 11 subtract, 10 compare.
    reg [1:0] x_alu_kind_q;

    wire [2:0] x_ddd = x_dst_q[2:0];
    wire [1:0] x_aaa = x_instr_q[9:8];
    wire [2:0] x_f3 = x_instr_q[5:3];

    wire x_memory = x_load_q || x_store_q;

    wire [XLEN-1:0] rf_read_a, rf_read_b;
    reg x_forward_a_q, x_forward_b_q;
    wire [XLEN-1:0] rf_a = x_forward_a_q ? w_result_q : rf_read_a;
    wire [XLEN-1:0] rf_b = x_forward_b_q ? w_result_q : rf_read_b;
    wire [XLEN-1:0] alu_result;
    wire x_mul_start, data_accept, x_finish;

    // Interrupts wait for an older memory response before entering Execute.
    wire irq_waiting = interrupt_request_q && interrupt_enable_q;
    wire run_x = in_run && x_valid_q && !recover_q && !x_load_wait_q;
    // IRQ entry waits for an older load; ordinary work waits for its reply.
    wire take_irq = run_x && !data_pending_q && irq_waiting;
    wire normal_x = run_x && core_advance && !irq_waiting;
    reg r0_negative_q;
    // Per-byte reductions keep whole-word zero detection off the load path.
    localparam integer FLAG_BYTES = XLEN / 8;
    reg [FLAG_BYTES-1:0] r0_nonzero_q;
    wire r0_zero_q = !(|r0_nonzero_q);

    // Decode and operand selection

    // ddd is the destination; aaa/bbb select sources or sub-operations.
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
    wire d_shift_direction = d_f5[1] | (d_f5[4] & ~d_bbb[0]);
    // LDX uses ra+rb. Direct typed accesses use ra.
    wire d_native_load = d_reg_mem & ~d_f5[2] &
                         ~d_f5[1] & ~d_f5[0];
    wire d_direct_load = d_reg_mem & d_f5[1] & ~d_f5[0];
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
    // Decode the interrupt-enable update alongside the return operation.
    wire d_control_ie_value = d_ddd[2];
    wire d_iflush = d_control_plane & d_ddd[1] & d_ddd[0] & ~d_ddd[2];
    wire d_ie_write = d_control_plane &
                      (d_ddd[1] | d_control_ie_value) & ~d_iflush;
    // Defined byte and halfword selectors differ in bbb[1]. The remaining
    // selectors are reserved and need not enter the width-control cone.
    wire d_load_byte = (d_direct_load | d_reg_store) & ~d_bbb[1];
    wire d_cmpi = d_imm_alu & (d_aaa == 3'b011);

    // Compact funnels read old rd on A and ra on B before writing rd.
    wire d_src_a_is_ddd = d_class[1] &
        (~d_class[0] | (d_f5[4] & ~d_f5[3]));
    wire [3:0] d_src_a = {d_system & ~d_bbb[0],
        d_src_a_is_ddd ? d_ddd : d_aaa};
    // B is used by register ALU/LDX (bbb), stores (ddd), and funnels
    // (aaa). Other instructions ignore this port.
    wire d_src_b_is_ddd = ~d_class[1] | (d_f5[3] & d_f5[0]);
    wire d_src_b_is_aaa = d_f5[4];
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
    // Only logic/move/immediate-load instructions consume this truth table.
    // Decode their function fields directly; branches, memory and arithmetic
    // select another result and do not need full instruction classification here.
    wire [1:0] d_logic_op = d_class[0] ? d_f5[1:0] : d_aaa[1:0];
    wire d_logic_move = d_class[0] && d_f5[4];
    wire d_short_imm = !d_class[0] && !d_aaa[2] && !d_aaa[1];
    // Truth-table bits for (A,B) = (1,1), (1,0), (0,1).
    wire [2:0] d_logic_table = {
        d_logic_move || d_short_imm || !d_logic_op[1] || d_logic_op[0],
        d_logic_move || (!d_short_imm && (|d_logic_op)),
        !d_logic_move && (d_short_imm || (^d_logic_op))};
    wire d_alu_pc = d_branch | d_ldpc | d_return | d_link_jump;
    wire d_alu_immediate = d_branch | d_ldpc | d_imm_memory |
        (d_imm_alu & ~d_aaa[2] & d_aaa[1]);
    wire d_alu_rf_b = (d_reg_alu_group & ~d_f5[2]) | d_native_load;
    // An immediate load consumer issues normally, then waits in Execute
    // for a write-first RF read on the load response edge.
    // Compare source fields before the RF address mux. Loads only write
    // ordinary registers, so reads of system registers cannot conflict.
    wire d_reads_aaa = d_class[0] &&
        (!d_class[1] || !d_f5[4] || !d_f5[3] || d_bbb[0]);
    wire d_reads_ddd = d_store || d_funnel ||
        (d_immediate && (d_aaa[2] || d_aaa[1]) && !d_branch);
    wire d_reads_bbb = d_reg_alu_group || d_native_load;
    wire match_aaa = d_aaa == x_dst_q[2:0];
    wire match_ddd = d_ddd == x_dst_q[2:0];
    wire match_bbb = d_bbb == x_dst_q[2:0];
    wire load_use = x_valid_q && x_load_q &&
        ((d_reads_aaa && match_aaa) ||
         (d_reads_ddd && match_ddd) ||
         (d_reads_bbb && match_bbb) ||
         (d_branch && !(|x_dst_q)));
    wire d_issue = !rst && d_valid && x_slot_available && !redirect;
    // Share field comparisons with load-use detection. Compare before
    // the source-address mux so forwarding does not extend the RF path.
    wire match_a = d_system ? (match_aaa && x_dst_q[3] != d_bbb[0]) :
        (!x_dst_q[3] && (d_src_a_is_ddd ? match_ddd : match_aaa));
    wire match_b = !x_dst_q[3] &&
        (d_src_b_is_ddd ? match_ddd : d_src_b_is_aaa ? match_aaa : match_bbb);
    wire forward_a = x_valid_q && x_we_q && !x_load_q && match_a;
    wire forward_b = x_valid_q && x_we_q && !x_load_q && match_b;

    // Decode-to-Execute registers

    always @(posedge clk) begin
        if (!rst && x_slot_available) begin
            x_pc_q <= f_pc_q;
            x_count_q <= btb_victim_count;
            x_hit_q <= btb_hit;
            x_collision_q <= btb_collision;
        end
        if (d_issue) begin
            x_instr_q <= d_instr[13:0];
            x_jall_hit_q <= d_jall && btb_taken;
            x_dst_q <= d_dst;
            x_we_q <= d_we;
            x_branch_q <= d_branch;
            x_imm_alu_q <= d_imm_alu;
            x_multiply_q <= d_multiply;
            x_bitop_q <= d_shift | d_funnel;
            x_shift_offset_q <= (d_shift ? d_bbb : 3'b000) ^ {3{d_shift_direction}};
            x_shift_left_q <= d_shift_direction;
            x_imm_sign_q <= (d_branch || d_ldpc) ? d_instr[0] :
                (XLEN == 32 && d_imm_memory) ? d_instr[1] : d_instr[7];
            x_imm_bit0_q <= d_instr[0] &&
                !(d_branch || d_ldpc || (XLEN == 32 && d_imm_memory));
            x_native_immediate_q <= d_imm_memory;
            x_native_word_q <=
                (XLEN == 32) && (d_imm_memory || d_native_load || d_ldpc);
            x_load_q <= d_load;
            x_store_q <= d_store;
            x_load_byte_q <= d_load_byte;
            x_signed_byte_q <= d_f5[2] && (XLEN == 32 || d_load_byte);
            x_indirect_q <= d_return | d_jal;
            x_jall_q <= d_jall;
            x_logic_table_q <= d_logic_table;
            x_ie_write_q <= d_ie_write;
            x_iflush_q <= d_iflush;
            x_run_short_imm_q <= d_short_imm;
            x_alu_kind_q <= {
                (d_imm_alu & ~d_aaa[2] & d_aaa[1] & d_aaa[0]) |
                (d_reg_alu_group & ~d_f5[2] & (|d_f5[1:0])),
                (d_imm_alu & ~d_aaa[2] & d_aaa[1]) |
                (d_reg_alu_group & ~d_f5[2] & ~d_f5[1])
            };
        end
    end

    // These enables differ deliberately: operands may refresh in an empty
    // slot, while decoded controls only advance when an instruction issues.
    always @(posedge clk) begin
        if (rst) begin
            x_forward_a_q <= 0;
            x_forward_b_q <= 0;
        end else if (x_finish || !x_valid_q) begin
            x_forward_a_q <= forward_a;
            x_forward_b_q <= forward_b;
            x_alu_a_pc_q <= d_alu_pc;
            x_alu_b_register_q <= d_alu_rf_b;
            x_alu_b_imm_q <= !d_alu_rf_b && d_alu_immediate;
        end
    end

    always @(posedge clk) begin
        if (rst)
            x_load_wait_q <= 0;
        else if (core_advance)
            x_load_wait_q <= d_issue && load_use;

        // Recovery cancels younger work even while an older load is stalled.
        if (rst || recover_q)
            x_valid_q <= 0;
        else if (core_advance && (take_irq || x_slot_available))
            x_valid_q <= d_issue;
    end

    // Execute datapaths

    // Decode supplies the sign and scaling of immediate operands.
    wire [XLEN-1:0] x_imm_z = {{(XLEN-8){1'b0}}, x_instr_q[7:0]};
    wire [7:0] immediate_byte = (XLEN == 32 && x_native_immediate_q) ?
        {x_instr_q[7:2], 2'b00} : x_instr_q[7:0];
    wire [XLEN-1:0] x_imm_s = {{(XLEN-8){x_imm_sign_q}}, immediate_byte};
    wire [XLEN-1:0] x_imm_u = {{(XLEN-16){1'b0}}, x_instr_q[7:0], 8'h00};

    wire [XLEN-1:0] x_logic_immediate =
        (x_run_short_imm_q && x_aaa[0]) ? x_imm_u : x_imm_z;
    wire [XLEN-1:0] x_logic_rhs = x_imm_alu_q ? x_logic_immediate : rf_b;
    wire [XLEN-1:0] x_logic_result;
    genvar logic_bit;
    generate
        for (logic_bit = 0; logic_bit < XLEN; logic_bit = logic_bit + 1) begin : g_logic
            assign x_logic_result[logic_bit] = rf_a[logic_bit] ?
                (x_logic_rhs[logic_bit] ? x_logic_table_q[2] : x_logic_table_q[1]) :
                (x_logic_rhs[logic_bit] && x_logic_table_q[0]);
        end
    endgenerate

    wire [XLEN-1:0] x_shift_step;
    riscc_fast_shift #(.XLEN(XLEN)) shifter (
        .value(rf_a), .other(rf_b), .offset(x_shift_offset_q),
        .left(x_shift_left_q), .arithmetic(x_f3[0]),
        .funnel(x_instr_q[7]), .result(x_shift_step)
    );

    // Three Execute clocks: capture operands, multiply, and commit the sum.
    reg [XLEN-1:0] mul_a_q, mul_b_q;
    wire [XLEN-1:0] mul_write_data;
    always @(posedge clk) begin
        if (x_mul_start) begin
            mul_a_q <= rf_a;
            mul_b_q <= rf_b;
        end
    end
    generate
        if (XLEN == 32) begin : g_wide_multiply
            reg [31:0] low_q;
            reg [15:0] cross_a_q, cross_b_q;
            always @(posedge clk) begin
                if (state_q == ST_MUL_CALC) begin
                    low_q <= mul_a_q[15:0] * mul_b_q[15:0];
                    cross_a_q <= mul_a_q[31:16] * mul_b_q[15:0];
                    cross_b_q <= mul_a_q[15:0] * mul_b_q[31:16];
                end
            end
            assign mul_write_data = {low_q[31:16] + cross_a_q + cross_b_q,
                                     low_q[15:0]};
        end else begin : g_narrow_multiply
            reg [15:0] product_q;
            always @(posedge clk)
                if (state_q == ST_MUL_CALC)
                    product_q <= mul_a_q * mul_b_q;
            assign mul_write_data = product_q;
        end
    endgenerate

    // PC-relative operations have a separate halfword adder. Keeping PC and
    // interrupt selection out of the data ALU shortens its operand path.
    wire pc_write = x_indirect_q || x_jall_q;
    // An unaccepted private request has no side effects and can be canceled
    // by IRQ entry. Accepted memory operations finish first.
    wire irq_alu = interrupt_request_q && interrupt_enable_q &&
                   !data_pending_q;
    wire pc_relative = x_alu_b_imm_q && !irq_alu;
    wire pc_offset_sign = pc_relative && x_imm_sign_q;
    wire [7:0] pc_offset_byte =
        ({x_imm_sign_q, x_instr_q[7:1]} & {8{pc_relative}}) |
        {7'b0, x_jall_q && !irq_alu};
    wire [XLEN-2:0] pc_sum = x_pc_q +
        {{(XLEN-9){pc_offset_sign}}, pc_offset_byte} +
        {{(XLEN-2){1'b0}}, !irq_alu};
    wire [XLEN-1:0] pc_result = {pc_sum, 1'b0};
    wire [XLEN-1:0] address_result = (irq_alu || x_alu_a_pc_q) ?
        pc_result : alu_result;

    wire [XLEN-1:0] run_result = x_bitop_q ? x_shift_step : x_logic_result;
    // Decode supplies the two arithmetic operand selects. Logical, move
    // and shift results do not pass through this mux or the carry chain.
    // Branch/LDPC immediates encode their sign in bit 0. Clear it before
    // operand selection so register arithmetic needs no low-bit masking.
    wire [XLEN-1:0] arithmetic_imm =
        {x_imm_s[XLEN-1:1], x_imm_bit0_q};
    wire alu_b_rf = x_alu_b_register_q && !x_forward_b_q;
    wire alu_b_forward = x_alu_b_register_q && x_forward_b_q;
    wire [XLEN-1:0] alu_b =
        (rf_read_b & {XLEN{alu_b_rf}}) |
        (w_result_q & {XLEN{alu_b_forward}}) |
        (arithmetic_imm & {XLEN{x_alu_b_imm_q}});

    wire [XLEN-1:0] adjusted_alu_b = alu_b ^ {XLEN{x_alu_kind_q[1]}};
    wire [XLEN:0] alu_sum = {1'b0, rf_a} +
                          {1'b0, adjusted_alu_b} +
                          {{XLEN{1'b0}}, x_alu_kind_q[1]};
    assign alu_result = alu_sum[XLEN-1:0];
    wire unsigned_less = ~alu_sum[XLEN];
    wire x_compare = x_alu_kind_q[1] && !x_alu_kind_q[0];

    // Completion and control transfers

    // Branches inspect the latest R0 value, cached at its producer.
    wire x_branch_taken =
        x_ddd[2] | ((x_ddd[1] ? r0_negative_q : r0_zero_q) ^ x_ddd[0]);

    assign x_mul_start = normal_x & x_multiply_q;
    wire iflush_start = normal_x && x_iflush_q;
    wire iflush_done = in_iflush && iflush_ack && !btb_clearing &&
        !i_pending_q && !data_pending_q;
    wire run_ready = run_x && !irq_waiting && !x_iflush_q && !x_multiply_q &&
        (!x_memory || (!rst && !dmem_stall)) &&
        (!x_jall_q || x_jall_hit_q || d_valid);
    wire run_commit = core_advance && run_ready;
    wire x_ready = run_ready || in_mul || iflush_done;
    // On a prediction miss, JALL consumes its second halfword.
    // A full-tag BTB hit supplies its authoritative cached target until IFLUSH.
    wire [31:0] x_long_target = {11'b0, x_instr_q[10:6], d_instr};
    wire younger_present = d_valid_q || i_pending_q;
    // Fixed targets are valid until IFLUSH. Only indirect jumps need a
    // full successor comparison; branches check their predicted direction.
    // Compare both sources in parallel; forwarding selects one bit rather
    // than preceding the full-width comparison on the redirect path.
    wire successor_wrong = x_forward_a_q ?
        (w_result_q[XLEN-1:1] != f_pc_q) : (rf_read_a[XLEN-1:1] != f_pc_q);
    // Consume a separately fetched JALL payload through the existing flush
    // path. No payload instruction may issue, and no BTB recovery is needed.
    wire jall_payload_done = normal_x && x_jall_q && !x_jall_hit_q && d_valid;
    // Branches and indirect jumps need no data request or multiplier result.
    // Resolve them without routing memory-request readiness through this path.
    wire predicted_taken = x_hit_q && x_count_q[1];
    wire taken_branch_miss = normal_x && x_branch_q &&
        x_branch_taken && !predicted_taken;
    wire indirect_miss = normal_x && x_indirect_q &&
        (!younger_present || successor_wrong);
    // Fallthrough recovery reuses Fetch's saved PC and incrementer.
    wire deferred_recovery = normal_x && x_branch_q &&
        !x_branch_taken && predicted_taken;
    wire resolved_redirect =
        taken_branch_miss || indirect_miss || jall_payload_done;
    wire redirect = take_irq | iflush_start | iflush_done |
        recover_q | resolved_redirect;
    wire i_accept;
    assign x_finish = core_advance && x_ready;
    wire x_slot_available = core_advance && (!x_valid_q || x_ready);

    // Multiply: operand capture -> DSP product -> sum/writeback.
    always @(posedge clk) begin
        if (rst) begin
            state_q <= ST_RUN;
        end else if (core_advance) begin
            if (iflush_start)
                state_q <= ST_IFLUSH;
            else if (redirect)
                state_q <= ST_RUN;
            else if (x_mul_start)
                state_q <= ST_MUL_CALC;
            else if (state_q == ST_MUL_CALC)
                state_q <= ST_MUL;
            else if (x_finish || !x_valid_q)
                state_q <= ST_RUN;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            interrupt_request_q <= 0;
            interrupt_enable_q <= 0;
        end else begin
            interrupt_request_q <= irq;
            if (core_advance) begin
                if (take_irq)
                    interrupt_enable_q <= 0;
                else if (run_commit && x_ie_write_q)
                    interrupt_enable_q <= x_ddd[2];
            end
        end
    end

    // Writeback and register file

    wire load_byte = !w_native_q && w_byte_q;
    function [31:0] format_load;
        input [31:0] value;
        input native_word, byte_load, sign_value, upper, odd;
        reg [15:0] half;
        reg [7:0] byte_value;
        begin
            half = upper ? value[31:16] : value[15:0];
            byte_value = odd ? half[15:8] : half[7:0];
            format_load = {native_word ? value[31:16] : {16{sign_value}},
                byte_load ? {8{sign_value}} : half[15:8], byte_value};
        end
    endfunction
    wire local_load_sign = |(w_sign_mask_q &
        {dmem_rdata[31], dmem_rdata[23], dmem_rdata[15], dmem_rdata[7]});
    wire cached_load_sign = |(w_sign_mask_q &
        {dmem_rdata[63], dmem_rdata[55], dmem_rdata[47], dmem_rdata[39]});
    wire [31:0] local_load = format_load(dmem_rdata[31:0], w_native_q,
        load_byte, local_load_sign, w_upper_q, w_odd_q);
    wire [31:0] cached_load = format_load(dmem_rdata[63:32], w_native_q,
        load_byte, cached_load_sign, w_upper_q, w_odd_q);
    wire [XLEN-1:0] accepted_load_value = dmem_local ?
        local_load[XLEN-1:0] : cached_load[XLEN-1:0];
    wire [31:0] dmem_word = dmem_local ? dmem_rdata[31:0] : dmem_rdata[63:32];
    // Reduce each memory byte before lane selection. Zero needs no data
    // alignment or sign extension, keeping those wide muxes off the flag path.
    wire [3:0] load_nonzero_bytes = {
        |dmem_word[31:24], |dmem_word[23:16],
        |dmem_word[15:8], |dmem_word[7:0]};
    wire [3:0] load_flag_mask = w_native_q ? 4'b1111 :
        load_byte ? (4'b0001 << {w_upper_q, w_odd_q}) :
        w_upper_q ? 4'b1100 : 4'b0011;
    wire [3:0] load_nonzero_lanes = load_nonzero_bytes & load_flag_mask;
    wire rf_we = !rst && core_advance && w_we_q;
    wire write_local = data_pending_q && dmem_local;
    wire write_cached = data_pending_q && !dmem_local;
    // A load leaves zero in the ALU completion slot. The memory and ALU
    // sources can therefore share an OR at the RF input.
    wire load_extension = (write_local && local_load_sign) ||
        (write_cached && cached_load_sign);
    wire local_native = write_local && w_native_q;
    wire cached_native = write_cached && w_native_q;
    wire [31:0] memory_write_data = {
        (dmem_rdata[31:16] & {16{local_native}}) |
        (dmem_rdata[63:48] & {16{cached_native}}) | {16{load_extension}},
        (local_load[15:0] & {16{write_local}}) |
        (cached_load[15:0] & {16{write_cached}})};
    wire [XLEN-1:0] rf_wdata = w_result_q | memory_write_data[XLEN-1:0];
    // Execute completion and IRQ entry are the only writeback producers.
    wire w_push = x_finish || take_irq;
    wire x_write = take_irq || x_we_q;
    // Signed comparison adjusts the subtraction carry for operand signs.
    wire compare_value = unsigned_less ^
        (!x_f3[0] && (rf_a[XLEN-1] ^ alu_b[XLEN-1]));
    wire write_arithmetic = pc_write || x_alu_kind_q[0];
    // Acceptance gates writeback; the data mux only needs the RUN IRQ condition.
    wire result_alu = (in_run && irq_alu) || write_arithmetic;
    // Encode four sources with two shared selects so adjacent result bits
    // can share the selector inputs of a fractured LUT.
    wire result_zero = x_load_q && !irq_alu;
    wire result_high = result_zero || (!result_alu && !in_mul);
    wire result_low = !result_zero && !result_alu && (in_mul || !x_compare);
    wire [XLEN-1:0] x_result = result_high ?
        (result_low ? run_result :
            {{(XLEN-1){1'b0}}, compare_value && !result_zero}) :
        (result_low ? mul_write_data : address_result);

    always @(posedge clk) begin
        if (rst) begin
            w_we_q <= 0;
        end else begin
            if (core_advance) begin
                w_we_q <= w_push && x_write;
                w_dst_q <= take_irq ? 4'h8 : x_dst_q;
                w_native_q <= x_native_word_q;
                w_byte_q <= x_load_byte_q;
                w_sign_mask_q <= (x_signed_byte_q && !x_native_word_q) ?
                    (4'b0001 << {x_load_byte_q ? rf_a[1] : alu_result[1],
                                 !x_load_byte_q || rf_a[0]}) : 4'b0000;
                // Retain alignment with the load's destination and format.
                // The cache need only return data, not repeat its byte mask.
                w_upper_q <= !x_native_word_q &&
                    (x_load_byte_q ? rf_a[1] : alu_result[1]);
                w_odd_q <= x_load_byte_q && rf_a[0];
            end
            if (w_push)
                w_result_q <= x_result;
        end
    end

    // Cache R0 properties for branches, not architectural flags. A younger
    // Execute result overrides load writeback on the same edge.
    wire flags_from_execute = x_finish && x_we_q && !x_memory && !(|x_dst_q);
    always @(posedge clk) begin
        if (rf_we && data_pending_q && !(|w_dst_q)) begin
            r0_negative_q <= accepted_load_value[XLEN-1];
        end
        if (flags_from_execute) begin
            r0_negative_q <= x_result[XLEN-1];
        end
    end

    genvar flag_byte;
    generate
        for (flag_byte = 0; flag_byte < FLAG_BYTES; flag_byte = flag_byte + 1) begin : g_r0_flags
            wire load_nonzero = load_nonzero_lanes[flag_byte] |
                ((XLEN == 16) && load_nonzero_lanes[flag_byte + (XLEN == 16 ? 2 : 0)]);
            always @(posedge clk) begin
                if (rf_we && data_pending_q && !(|w_dst_q))
                    r0_nonzero_q[flag_byte] <= load_nonzero;
                if (flags_from_execute)
                    r0_nonzero_q[flag_byte] <= |x_result[flag_byte*8 +: 8];
            end
        end
    endgenerate

    // Capture source addresses when Execute is available; the distributed
    // RF is read in Execute. Unissued reads have no side effects.
    riscc_cached_rf #(.XLEN(XLEN)) regs (
        .clk(clk), .read_en(x_slot_available),
        .raddr_a(d_src_a), .rdata_a(rf_read_a),
        .raddr_b(d_src_b), .rdata_b(rf_read_b),
        .waddr(w_dst_q), .wdata(rf_wdata), .we(rf_we)
    );

    // Data port

    // Execute releases a request at acceptance. The completion slot retains
    // its destination and format until the response, allowing replacement.
    assign dmem_stb = !rst && normal_x && x_memory;
    assign dmem_cyc = !rst && (data_pending_q || dmem_stb);
    assign data_accept = dmem_stb && !dmem_stall;
    assign dmem_addr = address_result[XLEN-1:2];
    // Stores use a base plus an eight-bit signed displacement, or the base
    // alone. Check the upper region in parallel with the low address sum.
    // Both directions across zero, including address wraparound, are exact.
    generate
        if (LOCAL_ADDR_BITS != 0) begin : g_store_region
            localparam LOW_BITS = LOCAL_ADDR_BITS < 8 ? 8 : LOCAL_ADDR_BITS;
            wire [LOW_BITS:0] low_sum = {1'b0, rf_a[LOW_BITS-1:0]} +
                {1'b0, arithmetic_imm[LOW_BITS-1:0] & {LOW_BITS{x_alu_b_imm_q}}};
            assign dmem_store_addr = {{(XLEN-LOW_BITS){1'b0}}, low_sum[LOW_BITS-1:2]};
            wire negative = x_alu_b_imm_q && x_imm_sign_q;
            // The displacement is only eight bits. Classify its carry into
            // the region in parallel with the remaining address bits.
            wire [8:0] byte_sum = {1'b0, rf_a[7:0]} +
                {1'b0, arithmetic_imm[7:0] & {8{x_alu_b_imm_q}}};
            wire [LOW_BITS-1:0] middle = rf_a[LOW_BITS-1:0] >> 8;
            wire middle_last = middle == ((1 << (LOW_BITS-8))-1);
            wire upper_zero = !(|rf_a[XLEN-1:LOW_BITS]);
            wire upper_one = rf_a[XLEN-1:LOW_BITS] == 1;
            wire upper_last = &rf_a[XLEN-1:LOW_BITS];
            // Resolve both carry outcomes alongside the byte adder. Only this
            // final selector follows its carry, including crossings through zero.
            wire local_without_carry = negative ?
                ((upper_zero && (|middle)) || (upper_one && !(|middle))) : upper_zero;
            wire local_with_carry = negative ? upper_zero :
                ((upper_zero && !middle_last) || (upper_last && middle_last));
            assign dmem_write_local = ((low_sum[LOW_BITS-1:0] >> LOCAL_ADDR_BITS) == 0) &&
                (byte_sum[8] ? local_with_carry : local_without_carry);
        end else begin : g_no_store_region
            assign dmem_write_local = 0;
            assign dmem_store_addr = 0;
        end
    endgenerate
    assign dmem_we = x_store_q;
    assign dmem_wdata = x_load_byte_q ? {4{rf_b[7:0]}} :
        x_native_word_q ? {{(32-XLEN){1'b0}}, rf_b} : {2{rf_b[15:0]}};
    // RC32 halfword accesses are base-only; native words enable every lane.
    wire halfword_upper = XLEN == 32 ? rf_a[1] : alu_result[1];
    assign dmem_wmask = x_load_byte_q ? (4'b0001 << rf_a[1:0]) :
        x_native_word_q ? 4'b1111 : (halfword_upper ? 4'b1100 : 4'b0011);

    always @(posedge clk) begin
        if (rst)
            data_pending_q <= 0;
        else if (core_advance)
            data_pending_q <= data_accept;
    end

    // Fetch

    wire i_ready = !i_pending_q || imem_ack;
    // A retiring control transfer opens the Execute slot whether or not
    // its prediction was correct. Fetch readiness need not compare targets.
    wire fetch_space = !d_valid || x_slot_available;
    wire fetch_ready = !rst && !btb_clearing && !iflush_start &&
        (!in_iflush || iflush_done) && i_ready;
    assign imem_stb = fetch_ready && (take_irq || recover_q || fetch_space);
    assign imem_cyc = !rst && (i_pending_q || imem_stb);
    // Increment before redirect selection, keeping another carry chain
    // out of the prediction-to-fetch path.
    wire [XLEN-2:0] sequential_fetch_pc =
        f_pc_q + {{(XLEN-2){1'b0}}, f_advance_q};
    // A full-tag taken hit skips the JALL payload.
    // A miss fetches the payload and redirects directly on its response.
    wire predict_btb = !in_iflush && f_advance_q && btb_taken;
    // Recovery and cold JALL targets share the BTB write-data selector.
    // Fallthrough recovery reuses the saved PC and Fetch incrementer.
    wire [XLEN-2:0] resolved_target = x_jall_q ? x_long_target[XLEN-1:1] :
        x_indirect_q ? rf_a[XLEN-1:1] : pc_sum;
    // The mutually exclusive selects serve both address and region selection.
    wire fetch_predicted = !take_irq && !recover_q && !resolved_redirect && predict_btb;
    wire fetch_sequential = !take_irq && !resolved_redirect && (recover_q || !predict_btb);
    assign imem_addr =
        ({{(XLEN-3){1'b0}}, 2'b10} & {(XLEN-1){take_irq}}) |
        (resolved_target & {(XLEN-1){resolved_redirect}}) |
        (btb_target & {(XLEN-1){fetch_predicted}}) |
        (sequential_fetch_pc & {(XLEN-1){fetch_sequential}});
    // Classify candidates before selection to keep the wide region decode
    // off the selected fetch-address path.
    wire target_local =
        x_jall_q ? (({x_long_target[XLEN-1:1], 1'b0} >> LOCAL_ADDR_BITS) == 0) :
        x_indirect_q ? ((rf_a >> LOCAL_ADDR_BITS) == 0) :
        (({pc_sum, 1'b0} >> LOCAL_ADDR_BITS) == 0);
    assign imem_local = LOCAL_ADDR_BITS != 0 &&
        (take_irq || (resolved_redirect && target_local) ||
         (fetch_predicted && (({btb_target, 1'b0} >> LOCAL_ADDR_BITS) == 0)) ||
         (fetch_sequential && (({sequential_fetch_pc, 1'b0} >> LOCAL_ADDR_BITS) == 0)));
    assign i_accept = imem_stb && !imem_stall;
    wire fetch_capture = !redirect && fetch_reply && (d_valid_q || !d_issue);

    always @(posedge clk) begin
        if (rst) begin
            recover_q <= 0;
            f_pc_q <= RESET_PC[XLEN-2:0];
            f_advance_q <= 0;
            i_pending_q <= 0;
            i_discard_q <= 0;
            d_valid_q <= 0;
        end else begin
            recover_q <= deferred_recovery;
            if (i_ready) begin
                i_pending_q <= i_accept;
                i_discard_q <= 0;
            end else if (redirect)
                i_discard_q <= 1;
            if (deferred_recovery || iflush_start) begin
                f_pc_q <= x_pc_q;
                f_advance_q <= 1;
            end else if (redirect || d_issue ||
                         (!d_valid && fetch_ready && !imem_stall)) begin
                // If issue outruns fetch acceptance, hold the proposed next
                // PC with advance clear. A later BTB write cannot change an
                // already issued instruction's selected path during a stall.
                f_pc_q <= imem_addr;
                f_advance_q <= i_accept;
            end
            if (redirect || d_issue)
                d_valid_q <= 0;
            if (fetch_capture)
                d_valid_q <= 1;
        end
    end

    // Branch target buffer

    // Read prediction alongside the instruction request. Its registered
    // address waits with the response, without another PC queue.
    generate
        begin : g_btb
`ifdef RISCC_ECP5
            localparam INDEX_BITS = 4;
`else
            localparam INDEX_BITS = 5;
`endif
            localparam PC_BITS = XLEN-1;
            localparam TAG_BITS = PC_BITS-INDEX_BITS;
            localparam ROW_BITS = TAG_BITS+PC_BITS+2;
            (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
            reg [ROW_BITS-3:0] target_mem [0:(1 << INDEX_BITS)-1];
            (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
            reg [1:0] count_mem [0:(1 << INDEX_BITS)-1];
            reg [INDEX_BITS-1:0] clear_q;
            reg clearing_q;
            reg [INDEX_BITS-1:0] read_index_q;
            wire [ROW_BITS-1:0] row_q =
                {target_mem[read_index_q], count_mem[read_index_q]};
            reg target_write_q;
            reg [INDEX_BITS-1:0] target_write_index_q;
            wire collision_q = target_write_q && (read_index_q == target_write_index_q);
            wire [TAG_BITS-1:0] write_tag = x_pc_q[PC_BITS-1:INDEX_BITS];
            wire [INDEX_BITS-1:0] write_index =
                x_pc_q[INDEX_BITS-1:0] ^ x_pc_q[2*INDEX_BITS-1:INDEX_BITS];
            // Read the predictor and instruction memory using the same fetch PC.
            // Full tags distinguish addresses sharing this folded index.
            wire [INDEX_BITS-1:0] read_index =
                imem_addr[INDEX_BITS-1:0] ^ imem_addr[2*INDEX_BITS-1:INDEX_BITS];
            wire tag_match =
                row_q[ROW_BITS-1:PC_BITS+2] == f_pc_q[PC_BITS-1:INDEX_BITS];
            assign btb_count =
                !clearing_q && !collision_q && tag_match ? row_q[1:0] : 2'b00;
            assign btb_hit = |btb_count;
            assign btb_taken = btb_count[1];
            assign btb_collision = collision_q;
            assign btb_target = row_q[PC_BITS+1:2];
            assign btb_victim_count = row_q[1:0];
            assign btb_clearing = clearing_q;
            // All transfers use the same replacement policy. A conflicting
            // miss ages the resident counter; replace when it reaches zero.
            wire taken = (x_branch_q && x_branch_taken) || x_indirect_q || x_jall_q;
            wire conditional = x_branch_q && !x_ddd[2];
            // Fixed targets cannot change before IFLUSH. Counter-only writes
            // leave the target readable; only allocations or changed indirect
            // targets need the mixed-port collision guard.
            wire update = x_finish && !take_irq && !x_iflush_q && !x_collision_q &&
                (taken || (x_hit_q && x_branch_q));
            wire replace_target = update && taken && (x_hit_q || !x_count_q[1]) &&
                (!x_hit_q || (x_indirect_q && successor_wrong));
            // Tag and target change only on allocation or an indirect-target change.
            wire [PC_BITS-1:0] write_target = resolved_target;
            wire [1:0] count_next = !x_hit_q && x_count_q[1] ?
                x_count_q - 1'b1 : (!conditional || !x_hit_q) ? 2'b11 : taken ?
                    (&x_count_q ? x_count_q : x_count_q + 1'b1) :
                    (|x_count_q ? x_count_q - 1'b1 : x_count_q);
            // A counter collision changes only the prediction strength. Target
            // writes invalidate the simultaneous lookup, so no wide bypass is needed.
            always @(posedge clk) begin
                target_write_q <= replace_target && !clearing_q && !rst && !iflush_start;
                target_write_index_q <= write_index;
                if (i_accept) begin
                    read_index_q <= read_index;
                end
                if (rst || iflush_start) begin
                    clearing_q <= 1;
                    clear_q <= 0;
                end else if (clearing_q) begin
                    count_mem[clear_q] <= 0;
                    clear_q <= clear_q + 1'b1;
                    if (&clear_q)
                        clearing_q <= 0;
                end else if (update) begin
                    count_mem[write_index] <= count_next;
                    if (replace_target)
                        target_mem[write_index] <= {write_tag, write_target};
                end
            end
        end
    endgenerate
endmodule

module riscc_cached_cache #(
    // Register the address before RAM lookup when sharing a fast local port.
    parameter REGISTER_LOOKUP = 1'b0,
    // Local SRAM requests bypass cache transactions, but may read RAM.
    parameter integer LOCAL_WORD_BITS = 0,
    parameter integer ADDR_BITS = 30,
    parameter integer TAG_ADDR_BITS = ADDR_BITS,
    parameter [ADDR_BITS-1:0] CACHE_BASE = 0,
    parameter integer LINE_WORD_BITS = 3,
    // Word-address bit selecting uncached data; ignored by instruction cache.
    parameter integer UNCACHED_BIT = ADDR_BITS-1,
    parameter integer READ_ONLY = 0,
    parameter integer CPU_BITS = 32
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
    output wire                   store_posted,
    output wire                   c_local,

    output wire [ADDR_BITS-1:0]   m_addr,
    output wire [31:0]            m_wdata,
    output wire [3:0]             m_sel,
    output wire                   m_we,
    output wire                   m_cacheable,
    output wire                   m_cyc,
    output wire                   m_stb,
    input  wire [31:0]            m_rdata,
    input  wire                   m_stall,
    input  wire                   m_ack,

    input  wire                   inv_valid,
    input  wire [ADDR_BITS-1:0]   inv_addr
);
    localparam [ADDR_BITS-1:0] CACHE_MASK =
        ~({ADDR_BITS{1'b1}} >> (ADDR_BITS-TAG_ADDR_BITS));
    localparam integer TAG_BITS = TAG_ADDR_BITS - 9;
    localparam integer INDEX_BITS = 9 - LINE_WORD_BITS;
    localparam integer LINE_COUNT = 1 << INDEX_BITS;
    localparam [LINE_WORD_BITS-1:0] LAST_BEAT = {LINE_WORD_BITS{1'b1}};

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_LOOKUP   = 3'd1;
    localparam [2:0] ST_REFILL   = 3'd2;
    localparam [2:0] ST_RELOOK   = 3'd3;
    localparam [2:0] ST_PASS     = 3'd4;
    localparam [2:0] ST_REPLY    = 3'd5;
    localparam [2:0] ST_CLEAR    = 3'd6;
    localparam [2:0] ST_UNCACHED = 3'd7;

    reg [2:0] state_q;
    reg [ADDR_BITS-1:0] req_addr_q;
    reg [CPU_BITS-1:0] req_wdata_q;
    reg [3:0] req_sel_q;
    reg req_we_q, req_cacheable_q, req_local_q;
    reg [LINE_WORD_BITS-1:0] refill_beat_q;
    reg pending_q, refill_invalidated_q;
    // Writes reside in the backing pipeline; retain ownership until drained.
    reg [1:0] writes_pending_q;
    reg [TAG_BITS:0] tag_word;
    reg tag_invalidated_q, tag_hit_q, refill_relook_q;

`ifndef ALTERA_RESERVED_QIS
    (* ram_style = "block" *) reg [7:0] data_mem [0:2047];
    reg [CPU_BITS-1:0] read_data_q;
    integer read_lane, lane;
`endif
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [TAG_BITS:0] tag_mem [0:LINE_COUNT-1];

    wire [INDEX_BITS-1:0] c_index = c_addr[8:LINE_WORD_BITS];
    wire [8:0] c_data_index = c_addr[8:0];
    wire [INDEX_BITS-1:0] req_index = req_addr_q[8:LINE_WORD_BITS];
    wire [8:0] req_data_index = req_addr_q[8:0];
    wire [INDEX_BITS-1:0] inv_index = inv_addr[8:LINE_WORD_BITS];
    wire [TAG_BITS-1:0] req_tag;
    genvar tag_bit;

    wire lookup_valid_q = tag_word[TAG_BITS] && !tag_invalidated_q;
    wire read_only = (READ_ONLY != 0);
    wire c_in_region = (c_addr & CACHE_MASK) == CACHE_BASE;

    wire cpu_request = c_cyc && c_stb && !c_stall;
    wire tag_matches = lookup_valid_q && (tag_word[TAG_BITS-1:0] == req_tag);
    wire lookup_hit = !req_local_q && req_cacheable_q &&
        (REGISTER_LOOKUP ? tag_hit_q : tag_matches) &&
        !(inv_valid && (inv_index == req_index));
    wire lookup_read_hit = lookup_hit && !req_we_q;

    // A refill reply can be replaced by the next word request on the same edge.
    wire refill_response = (state_q == ST_REFILL) && pending_q && m_ack;
    wire refill_offer_next = (state_q == ST_REFILL) && pending_q &&
        m_ack && (refill_beat_q != LAST_BEAT);
    wire refill_accept = (state_q == ST_REFILL) && m_cyc && m_stb && !m_stall;
    wire refill_immediate = (state_q == ST_REFILL) && !pending_q &&
        refill_accept && m_ack;
    wire refill_response_event = refill_response || refill_immediate;
    wire refill_last_response = refill_response_event && (refill_beat_q == LAST_BEAT);
    wire [LINE_WORD_BITS-1:0] refill_addr_beat = refill_beat_q +
        {{(LINE_WORD_BITS-1){1'b0}}, pending_q && m_ack};

    // Stores/uncached reads issue in LOOKUP, then wait in PASS if necessary.
    wire pass_active = (state_q == ST_PASS) ||
        ((state_q == ST_LOOKUP) && (REGISTER_LOOKUP || !req_local_q) &&
         (!req_cacheable_q || req_we_q));
    wire pass_ready = req_we_q ? (!(&writes_pending_q) || m_ack) : !(|writes_pending_q);
    wire pass_accept = pass_active && m_cyc && m_stb && !m_stall;
    wire write_accept = pass_accept && req_we_q;
    wire write_response = m_ack && ((|writes_pending_q) || write_accept);
    wire pass_response = pass_active && !req_we_q && !(|writes_pending_q) &&
        ((pending_q && m_ack) ||
         (!pending_q && pass_accept && m_ack));

    // Uncached replies use the refill write port, then read back in ST_UNCACHED.
    wire relook = (state_q == ST_RELOOK) || (state_q == ST_UNCACHED);
    wire [8:0] ram_read_addr =
        (REGISTER_LOOKUP || relook) ? req_data_index : c_data_index;
    wire ram_read_en = (!REGISTER_LOOKUP && cpu_request) || relook;
    wire ram_read_half = (REGISTER_LOOKUP || relook) ? req_sel_q[3] : c_sel[3];
    wire store_hit = (state_q == ST_LOOKUP) && lookup_hit && req_we_q && !read_only;
    wire pass_read_reply = pass_response && !req_we_q;
    wire backing_read_reply = refill_response_event || pass_read_reply;
    wire [8:0] ram_write_addr = refill_response_event ?
        {req_index, refill_beat_q} : req_data_index;
    wire [31:0] ram_write_data =
        req_we_q ? {{(32-CPU_BITS){1'b0}}, req_wdata_q} : m_rdata;
    wire [3:0] ram_write_mask = backing_read_reply ? 4'b1111 :
        (req_sel_q & {4{store_hit}});

    wire [INDEX_BITS-1:0] tag_read_addr =
        (!REGISTER_LOOKUP && relook) ? req_index : c_index;
    wire clearing = state_q == ST_CLEAR;
    wire clear_reply_tag = state_q == ST_UNCACHED;
    wire tag_write_en = clearing || inv_valid || clear_reply_tag ||
        (refill_last_response && !refill_invalidated_q);
    wire [INDEX_BITS-1:0] tag_write_addr =
        (inv_valid && !clearing) ? inv_index : req_index;
    wire [TAG_BITS:0] tag_write_data = {
        !(clearing || inv_valid || clear_reply_tag), req_tag};

    // A store/read collision requires a second RAM read.
    wire [2:0] request_state = (REGISTER_LOOKUP ||
        (!c_we && store_hit && c_data_index == req_data_index)) ? ST_RELOOK : ST_LOOKUP;
    wire [2:0] idle_or_request = (c_cyc && c_stb) ? request_state : ST_IDLE;

`ifdef ALTERA_RESERVED_QIS
    localparam integer READ_ADDR_BITS = CPU_BITS == 16 ? 10 : 9;
    wire [READ_ADDR_BITS-1:0] read_address = CPU_BITS == 16 ?
        {ram_read_addr, ram_read_half} : ram_read_addr;
`endif

    initial begin
        if (TAG_ADDR_BITS < 10 || TAG_ADDR_BITS > ADDR_BITS ||
            (CACHE_BASE & ~CACHE_MASK) != 0)
            $error("riscc_cached_cache: invalid cacheable region");
        if (LINE_WORD_BITS < 3 || LINE_WORD_BITS > 4)
            $error("riscc_cached_cache: line size must be 32 or 64 bytes");
        if (UNCACHED_BIT < LINE_WORD_BITS || UNCACHED_BIT >= ADDR_BITS)
            $error("riscc_cached_cache: bypass bits must be above the line offset");
    end

    // Allocated data lines have the bypass bit clear; omit it from the tag.
    generate
        for (tag_bit = 0; tag_bit < TAG_BITS; tag_bit = tag_bit + 1) begin : g_tag
            assign req_tag[tag_bit] = (READ_ONLY == 0 && tag_bit+9 == UNCACHED_BIT) ?
                1'b0 : req_addr_q[tag_bit+9];
        end
    endgenerate

    // ACK belongs to the retained request, not the next CYC/STB.
    assign store_posted = (state_q == ST_LOOKUP) && !req_local_q && req_we_q;
    assign c_ack = ((state_q == ST_LOOKUP) && lookup_read_hit) ||
        store_posted || (state_q == ST_REPLY);
    // Hits and accepted stores release the request slot immediately.
    assign c_stall =
        ((state_q == ST_IDLE) || (state_q == ST_REPLY) ||
         (req_local_q && (state_q == ST_LOOKUP ||
                         (REGISTER_LOOKUP && state_q == ST_RELOOK)))) ? 1'b0 :
        (state_q == ST_LOOKUP && lookup_read_hit) ? 1'b0 :
        write_accept ? 1'b0 : 1'b1;
    assign c_rsel = req_sel_q;
    assign c_local = req_local_q;

    assign m_cyc = pass_active || (state_q == ST_REFILL) || (|writes_pending_q);
    assign m_stb = pass_active ? (!pending_q && pass_ready) :
        (state_q == ST_REFILL) ? (!pending_q || refill_offer_next) : 1'b0;
    assign m_addr = pass_active ? req_addr_q :
        {req_addr_q[ADDR_BITS-1:LINE_WORD_BITS], refill_addr_beat};
    assign m_wdata = read_only ? 32'b0 : {{(32-CPU_BITS){1'b0}}, req_wdata_q};
    assign m_sel = pass_active ? req_sel_q : 4'b1111;
    assign m_we = req_we_q;
    assign m_cacheable = req_cacheable_q;

    // Registered lookup reads tags speculatively, then captures the hit with
    // the data read. Invalidation poisons a concurrent tag read explicitly.
    always @(posedge clk) begin
        if (!rst && (REGISTER_LOOKUP || cpu_request || relook)) begin
            tag_word <= tag_mem[tag_read_addr];
            tag_invalidated_q <= inv_valid && (inv_index == tag_read_addr);
        end
    end

`ifdef ALTERA_RESERVED_QIS
    // Mixed-width ports keep instruction halfword selection inside the RAM.
    altera_syncram #(
        .operation_mode("DUAL_PORT"),
        .ram_block_type("M20K"),
        .width_a(32),
        .widthad_a(9),
        .numwords_a(512),
        .width_byteena_a(4),
        .byte_size(8),
        .width_b(CPU_BITS),
        .widthad_b(READ_ADDR_BITS),
        .numwords_b(1 << READ_ADDR_BITS),
        .address_reg_b("CLOCK0"),
        .outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("DONT_CARE")
    ) data_ram (
        .clock0(clk),
        .clocken0(1'b1),
        .clocken1(1'b1),
        .clocken2(1'b1),
        .clocken3(1'b1),
        .aclr0(1'b0),
        .aclr1(1'b0),
        .address_a(ram_write_addr),
        .data_a(ram_write_data),
        .byteena_a(ram_write_mask),
        .wren_a(!rst && |ram_write_mask),
        .address_b(read_address),
        .rden_b(!rst && ram_read_en),
        .q_b(c_rdata)
    );
`else
    assign c_rdata = read_data_q;

    always @(posedge clk) begin
        if (!rst && ram_read_en)
            for (read_lane = 0; read_lane < CPU_BITS/8; read_lane = read_lane + 1)
                if (CPU_BITS == 16)
                    read_data_q[read_lane*8 +: 8] <=
                        data_mem[{ram_read_addr, ram_read_half, read_lane[0]}];
                else
                    read_data_q[read_lane*8 +: 8] <=
                        data_mem[{ram_read_addr, read_lane[1:0]}];
        if (!rst)
            for (lane = 0; lane < 4; lane = lane + 1)
                if (ram_write_mask[lane])
                    data_mem[{ram_write_addr, lane[1:0]}] <= ram_write_data[lane*8 +: 8];
    end
`endif

    // Reset sweeps tags using req_index. Uncached replies invalidate their
    // overwritten line; external invalidation has priority outside the sweep.
    always @(posedge clk) begin
        if (!rst && tag_write_en)
            tag_mem[tag_write_addr] <= tag_write_data;
    end

    // Forward a completed refill's hit across the tag RAM write.
    // Invalidation overrides the hit; reset overrides both retained results.
    always @(posedge clk) begin
        if (cpu_request)
            refill_relook_q <= 0;
        if (refill_last_response) begin
            refill_relook_q <= 1;
            tag_hit_q <= !refill_invalidated_q && !inv_valid;
        end else if (relook) begin
            refill_relook_q <= 0;
            if (!refill_relook_q)
                tag_hit_q <= tag_matches;
        end
        if (inv_valid && inv_index == req_index)
            tag_hit_q <= 0;
        if (rst) begin
            tag_hit_q <= 0;
            refill_relook_q <= 0;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state_q <= ST_CLEAR;
            req_addr_q[8:LINE_WORD_BITS] <= 0;
            pending_q <= 1'b0;
            writes_pending_q <= 0;
            refill_beat_q <= 0;
            refill_invalidated_q <= 1'b0;
        end else begin
            case ({write_accept, write_response})
                2'b10: writes_pending_q <= writes_pending_q + 1'b1;
                2'b01: writes_pending_q <= writes_pending_q - 1'b1;
                default: begin end
            endcase

            // Free slots capture even unowned payloads; do not gate on CYC/STB.
            if (!c_stall) begin
                req_addr_q <= c_addr;
                req_cacheable_q <= c_in_region && (read_only || !c_addr[UNCACHED_BIT]);
                req_local_q <= LOCAL_WORD_BITS != 0 && (c_addr >> LOCAL_WORD_BITS) == 0;
                req_wdata_q <= c_wdata;
                req_sel_q <= c_sel;
                req_we_q <= c_we;
            end
            if (cpu_request)
                pending_q <= 1'b0;

            case (state_q)
                ST_CLEAR: begin
                    if (&req_index)
                        state_q <= ST_IDLE;
                    else
                        req_addr_q[8:LINE_WORD_BITS] <= req_index + 1'b1;
                end
                ST_IDLE: state_q <= idle_or_request;

                ST_LOOKUP: begin
                    if (req_local_q || lookup_read_hit) begin
                        state_q <= idle_or_request;
                    end else if (pass_active) begin
                        if (write_accept)
                            state_q <= idle_or_request;
                        else if (pass_response)
                            state_q <= ST_UNCACHED;
                        else
                            state_q <= ST_PASS;
                    end else if (!(|writes_pending_q)) begin
                        // Publish the replacement tag only after the full line.
                        refill_beat_q <= 0;
                        pending_q <= 1'b0;
                        refill_invalidated_q <= inv_valid && (inv_index == req_index);
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
                            // An immediate ACK leaves no pending request; an
                            // older reply can accept its replacement here.
                            pending_q <= refill_accept && (pending_q || !m_ack);
                        end
                    end else if (!pending_q && refill_accept) begin
                        pending_q <= 1'b1;
                    end
                end

                ST_RELOOK: begin
                    // Read after the final RAM write, avoiding mixed-port collision.
                    state_q <= (REGISTER_LOOKUP && req_local_q) ? idle_or_request : ST_LOOKUP;
                end
                ST_UNCACHED: begin
                    // Retry if another index needed the tag write port.
                    if (!inv_valid || inv_index == req_index)
                        state_q <= ST_REPLY;
                end
                ST_PASS: begin
                    if (write_accept)
                        state_q <= idle_or_request;
                    else if (pass_response)
                        state_q <= ST_UNCACHED;
                end
                ST_REPLY: state_q <= idle_or_request;

                default: begin
                    state_q <= ST_IDLE;
                    pending_q <= 1'b0;
                end
            endcase

            // Pass-read progress overrides the request-capture pending clear.
            if (pass_active && !req_we_q) begin
                if (pass_response) begin
                    pending_q <= 0;
                end else if (pass_accept)
                    pending_q <= 1;
            end
        end
    end
endmodule

module riscc_cached_rf #(
    parameter integer XLEN = 32
) (
    input  wire                   clk,
    input  wire                   read_en,
    input  wire [3:0]             raddr_a,
    input  wire [3:0]             raddr_b,
    input  wire [3:0]             waddr,
    input  wire [XLEN-1:0]        wdata,
    input  wire                   we,
    output wire [XLEN-1:0]        rdata_a,
    output wire [XLEN-1:0]        rdata_b
);
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [XLEN-1:0] mem_a [0:15];
    (* ram_style = "distributed", ramstyle = "MLAB, no_rw_check" *)
    reg [XLEN-1:0] mem_b [0:15];
    reg [3:0] addr_a_q, addr_b_q;

    always @(posedge clk) begin
        if (read_en) begin
            addr_a_q <= raddr_a;
            addr_b_q <= raddr_b;
        end
        if (we) begin
            mem_a[waddr] <= wdata;
            mem_b[waddr] <= wdata;
        end
    end

    assign rdata_a = mem_a[addr_a_q];
    assign rdata_b = mem_b[addr_b_q];
endmodule

`default_nettype wire
