// Focused BTB checks for the RC16/RC32 DSP Cached pipeline.
`default_nettype none
module riscc_cached_btb_tb #(
    parameter integer CASE = 0,
    parameter integer XLEN = 32
);
    localparam integer HIGH_PC = XLEN == 32 ? 32'h7fff_fff8 : 32'h7ff8;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg irq = 0;
    wire iflush_req;
    integer iflush_wait = 0;
    integer iflush_commits = 0, irq_entries = 0;
    wire iflush_ack = CASE != 14 || iflush_wait >= 64;
    reg [15:0] mem [0:63];
    wire [XLEN-2:0] imem_addr;
    wire imem_cyc, imem_stb;
    reg imem_ack = 0;
    reg [15:0] imem_rdata = 0;
    reg [2:0] case5_delay_q = 0;
    reg case5_delay_used_q = 0;
    wire [XLEN-3:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0] dmem_wmask;
    wire dmem_cyc, dmem_stb, dmem_we;
    reg dmem_ack = 0;
    reg [31:0] dmem_rdata = 32'h1234_5678;

    riscc_cached_pipe #(.XLEN(XLEN),
            .RESET_PC(CASE == 3 && XLEN == 16 ? 16 : 0)) dut (
        .iflush_req(iflush_req), .iflush_ack(iflush_ack),
        .clk(clk), .rst(rst), .irq(irq),
        .imem_local(),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .imem_cyc(imem_cyc), .imem_stb(imem_stb),
        .imem_stall(1'b0), .imem_ack(imem_ack),
        .dmem_addr(dmem_addr), .dmem_rdata({dmem_rdata, 32'b0}),
        .dmem_local(1'b0),
        .dmem_wdata(dmem_wdata), .dmem_wmask(dmem_wmask),
        .dmem_we(dmem_we), .dmem_write_local(),
        .dmem_store_addr(),
        .dmem_cyc(dmem_cyc), .dmem_stb(dmem_stb),
        .dmem_stall(1'b0), .dmem_ack(dmem_ack)
    );

    function automatic [15:0] jump(input integer displacement);
        jump = {2'b10, 3'd4, 3'd7, displacement[6:0], displacement[7]};
    endfunction

    function automatic [15:0] branch(
        input [2:0] condition, input integer displacement);
        branch = {2'b10, condition, 3'd7,
                  displacement[6:0], displacement[7]};
    endfunction

    // Observe real pipeline updates: allocations start weak, and only a
    // subsequent taken hit earns the strongest prediction/replacement state.
    integer weak_allocations = 0, confirmed_entries = 0, aged_conflicts = 0;
    reg check_allocation = 0;
    integer allocated_index = 0;
    always @(posedge clk) begin
        check_allocation = 0;
        if (!rst && !dut.g_btb.clearing_q && dut.g_btb.update) begin
            if (!dut.x_hit_q && dut.x_count_q < 2) begin
                if (!dut.g_btb.replace_target || dut.g_btb.count_next != 2)
                    $fatal(1, "BTB allocation must start weakly taken");
                weak_allocations = weak_allocations + 1;
                allocated_index = int'(dut.g_btb.write_index);
                check_allocation = 1;
            end else if (!dut.x_hit_q) begin
                if (dut.g_btb.replace_target ||
                    dut.g_btb.count_next != dut.x_count_q - 2'd1)
                    $fatal(1, "BTB conflict must age a protected resident");
                aged_conflicts = aged_conflicts + 1;
            end else if (dut.g_btb.taken && dut.x_count_q == 2) begin
                if (dut.g_btb.count_next != 3)
                    $fatal(1, "BTB taken hit must confirm a weak entry");
                confirmed_entries = confirmed_entries + 1;
            end else if (!dut.g_btb.taken && dut.x_count_q == 2) begin
                if (dut.g_btb.count_next != 1)
                    $fatal(1, "BTB not-taken hit must weaken a new entry");
            end
        end
    end
    always @(negedge clk) begin
        if (check_allocation && dut.g_btb.count_mem[allocated_index] != 2)
            $fatal(1, "BTB weak allocation was not written to the counter RAM");
    end

    always @(posedge clk) begin
        if (!rst && imem_cyc && imem_stb)
            imem_rdata <= read_instr(imem_addr);
    end
    function automatic [15:0] movi(input [2:0] rd, input [7:0] value);
        movi = {2'b10, rd, 3'd0, value};
    endfunction
    function automatic [15:0] jall(input [2:0] rd, input integer target);
        integer encoded;
        begin
            encoded = 32'h0000_0034 | (rd * 32'd2048) |
                      (((target >> 16) & 31) * 64);
            jall = encoded[15:0];
        end
    endfunction
    function automatic [15:0] regop(
        input [2:0] rd, input [2:0] ra, input [4:0] op, input [2:0] rb
    );
        regop = {2'b11, rd, ra, op, rb};
    endfunction

    function automatic [15:0] store(
        input [2:0] rs, input [2:0] ra, input integer displacement);
        store = XLEN == 32 ? {2'b01, rs, ra, displacement[7:2], displacement[7], 1'b1} :
                             {2'b01, rs, ra, displacement[7:1], 1'b1};
    endfunction
    function automatic [15:0] load(
        input [2:0] rd, input [2:0] ra, input integer displacement);
        load = XLEN == 32 ? {2'b01, rd, ra, displacement[7:2], displacement[7], 1'b0} :
                            {2'b01, rd, ra, displacement[7:1], 1'b0};
    endfunction

    function automatic [15:0] read_instr(input [XLEN-2:0] halfword);
        integer address;
        begin
            address = int'(halfword);
            read_instr = 16'hffff;
            if (CASE < 2) begin
                read_instr = mem[halfword[5:0]];
            end else if (CASE == 2) begin
                case (address)
                    0:    read_instr = movi(3'd1, 8'd5);
                    1:    read_instr = jall(3'd1, 32'h0000_2000);
                    2:    read_instr = 16'h2000;
                    4096: read_instr = jump(1);
                    4098: read_instr = jall(3'd1, 32'h0000_0000);
                    4099: read_instr = 16'h0000;
                    default: read_instr = 16'hffff;
                endcase
            end else if (CASE == 3 && XLEN == 16) begin
                // Header at 0xfffe: payload wraps to zero and link wraps to 2.
                case (address)
                    16: read_instr = jall(1, 32'hfffe);
                    17: read_instr = 16'hfffe;
                    32767: read_instr = jall(1, 32'h0040);
                    0: read_instr = 16'h0040;
                    32: read_instr = regop(0, 1, 5'h1f, 0); // RET S1 -> PC1
                    1: read_instr = jump(14);              // PC1 -> PC16
                    default: read_instr = 16'hffff;
                endcase
            end else if (CASE == 3) begin
                case (address)
                    0:     read_instr = movi(3'd1, 8'd0);
                    1:     read_instr = jall(3'd1, 32'h0000_fffe);
                    2:     read_instr = 16'hfffe;
                    32767: read_instr = jall(3'd1, 32'h0001_0004);
                    32768: read_instr = 16'h0004;
                    32770: read_instr = regop(3'd1, 3'd1, 5'b11000, 3'd1);
                    default: read_instr = 16'hffff;
                endcase
            end else if (CASE == 16) begin
                case (address)
                    0: read_instr = movi(0, 0);
                    1: read_instr = load(1, 0, 0);
                    2: read_instr = regop(1, 1, 5'b11000, 1); // JALR S1,r1
                    3: read_instr = jump(-2);
                    HIGH_PC: read_instr = regop(0, 1, 5'b11000, 0); // RET S1
                    default: read_instr = 16'hffff;
                endcase
            end else if (CASE >= 6) begin
                read_instr = mem[halfword[5:0]];
            end else begin
                case (address)
                    0: read_instr = jall(3'd1, 32'h0000_0008);
                    1: read_instr = 16'h0008;
                    2: read_instr = jump(-3);
                    4: read_instr = regop(3'd0, 3'd1, 5'b11000, 3'd0);
                    default: read_instr = 16'hffff;
                endcase
            end
        end
    endfunction

    integer i, cycles = 0, commits = 0, previous = 0, errors = 0;
    integer expected_pc = CASE == 3 && XLEN == 16 ? 16 : 0;
    reg saw_case2_branch = 0, saw_case2_pc0 = 0;
    reg case3_link_seen = 0;
    reg case4_jall_seen = 0, case4_jall_hit = 0;
    reg case5_jall_seen = 0;
    integer case_target_issues = 0;
    integer case_store_count = 0;
    integer case_r3_writes = 0;
    reg case_branch_not_taken = 0;
    reg case9_fallthrough = 0;
    reg case15_jall33_seen = 0;
    reg case15_jall33_hit = 0;
    integer link_value;
    initial begin
        for (i = 0; i < 64; i = i + 1) mem[i] = 16'hffff;
        if (CASE == 0) begin
            // A tight taken JMP8 loop warms all four direct-mapped entries.
            mem[0] = jump(1);
            mem[2] = jump(1);
            mem[4] = jump(1);
            mem[6] = jump(-7);
        end else if (CASE == 1) begin
            // Exercise an indirect call and RET through the same target.
            mem[0] = movi(3'd1, 8'd8); // r1 = byte target 8
            mem[1] = regop(1, 1, 5'b11000, 1); // JALR S1,r1
            mem[2] = jump(-2);
            mem[4] = regop(0, 1, 5'b11000, 0); // RET S1
        end else if (CASE == 2) begin
            // An 8 KiB-separated JALL target and branch share the low
            // PC+1 XOR index.  Full tags must reject the stale row at PC0.
        end else if (CASE == 3) begin
            // RC32 checks the upper JALL target bit; RC16 wraps payload/link.
        end else if (CASE == 4) begin
            // The aligned JALL header and literal share one 32-bit fetch
            // word; 16-bit mode retains the crossing-payload path.
        end else if (CASE == 5) begin
            // Repeat the aligned JALL flow while delaying its first target
            // response.  The link must still reach the RET target.
        end else if (CASE == 6) begin
            // Train a conditional branch as taken.  Its second, not-taken
            // instance predicts the store target, which must issue and then
            // be squashed without a second data-side write.
            mem[0] = movi(3'd7, 8'h20);
            mem[1] = movi(3'd6, 8'd0);
            mem[2] = movi(3'd1, 8'd42);
            mem[3] = movi(3'd6, 8'd0);
            mem[4] = movi(3'd0, 8'd1);
            mem[5] = movi(3'd6, 8'd0);
            mem[6] = branch(3'd1, 3); // BNEZ -> 10
            mem[7] = movi(3'd6, 8'd0);
            mem[8] = jump(-1);         // safe not-taken loop
            mem[9] = movi(3'd6, 8'd0);
            mem[10] = store(3'd1, 3'd7, 0);
            mem[11] = movi(3'd6, 8'd0);
            mem[12] = movi(3'd0, 8'd0);
            mem[13] = movi(3'd6, 8'd0);
            mem[14] = jump(-9);        // return to branch at PC6
            mem[15] = movi(3'd6, 8'd0);
        end else if (CASE == 7) begin
            // The same trained branch predicts a younger MUL.  The first
            // target MUL is architectural; the second must issue but not
            // write r3 after deferred recovery.
            mem[0] = movi(3'd1, 8'd3);
            mem[1] = movi(3'd6, 8'd0);
            mem[2] = movi(3'd2, 8'd4);
            mem[3] = movi(3'd6, 8'd0);
            mem[4] = movi(3'd0, 8'd1);
            mem[5] = movi(3'd6, 8'd0);
            mem[6] = branch(3'd1, 3); // BNEZ -> 10
            mem[7] = movi(3'd6, 8'd0);
            mem[8] = jump(-1);
            mem[9] = movi(3'd6, 8'd0);
            mem[10] = regop(3'd3, 3'd1, 5'h07, 3'd2); // MUL r3,r1,r2
            mem[11] = movi(3'd6, 8'd0);
            mem[12] = movi(3'd0, 8'd0);
            mem[13] = movi(3'd6, 8'd0);
            mem[14] = jump(-9);
            mem[15] = movi(3'd6, 8'd0);
        end else if (CASE == 8) begin
            // STI is architectural on the first taken target, then CLI and
            // r0=0 prepare the second not-taken branch.  A predicted younger
            // STI must not re-enable interrupts after recovery.
            mem[0] = movi(3'd0, 8'd1);
            mem[1] = movi(3'd6, 8'd0);
            mem[2] = branch(3'd1, 3); // BNEZ -> 6
            mem[3] = movi(3'd6, 8'd0);
            mem[4] = jump(-1);
            mem[5] = movi(3'd6, 8'd0);
            mem[6] = regop(3'd7, 3'd0, 5'h1f, 3'd0); // STI
            mem[7] = movi(3'd6, 8'd0);
            mem[8] = regop(3'd2, 3'd0, 5'h1f, 3'd0); // CLI
            mem[9] = movi(3'd6, 8'd0);
            mem[10] = movi(3'd0, 8'd0);
            mem[11] = movi(3'd6, 8'd0);
            mem[12] = jump(-11);        // return to branch at PC2
            mem[13] = movi(3'd6, 8'd0);
        end else if (CASE == 9) begin
            // Reach a BEQZ with zero once to train its taken target.  The
            // target then makes r0 nonzero; on the second pass the branch is
            // not taken. A wrong-path XOR would toggle the flags back to zero.
            mem[0] = movi(3'd0, 8'd0);
            mem[1] = movi(3'd6, 8'd0);
            mem[2] = branch(3'd1, 3); // BNEZ -> 6, not taken first
            mem[3] = jump(2);         // route to PC6 with r0 still zero
            mem[4] = jump(-1);                        // safe terminal loop
            mem[6] = branch(3'd0, 3); // BEQZ -> 10, then not taken
            mem[7] = movi(3'd6, 8'd0);
            mem[8] = jump(-1);
            mem[9] = movi(3'd6, 8'd0);
            mem[10] = {2'b10, 3'd0, 3'b110, 8'd1}; // XORI r0,1
            mem[11] = movi(3'd6, 8'd0);
            mem[12] = jump(-11);        // return to branch at PC2
            mem[13] = movi(3'd6, 8'd0);
        end else if (CASE == 12) begin
            // Saturated self-branches must not lose predictions to RAM writes.
            mem[0] = jump(-1);
        end else if (CASE == 13) begin
            // Allocation redirects to the same row; avoid collision starvation.
            mem[0] = jall(3'd1, 0);
            mem[1] = 0;
        end else if (CASE == 14) begin
            // IRQ arrives while IFLUSH waits for the memory frontend. It
            // must enter after synchronization and return to the successor.
            mem[0] = jump(7);
            mem[2] = movi(3'd1, 8'd42);
            mem[3] = regop(3'd5, 3'd0, 5'h1f, 3'd0); // RETI S0
            mem[8] = regop(3'd7, 3'd0, 5'h1f, 3'd0); // STI
            mem[9] = regop(3'd3, 3'd0, 5'h1f, 3'd0); // IFLUSH
            mem[10] = movi(3'd3, 8'h55);
            mem[11] = jump(-1);
        end else if (CASE == 15) begin
            // PC0 and PC33 conflict in the direct-mapped XOR index.  The
            // second JALL must replace the old row even though the row is
            // already occupied, then hit after the return loop warms it.
            mem[0] = jall(3'd1, 96);       // target byte 96 -> PC48
            mem[1] = 96;
            mem[2] = jump(30);             // PC2 -> PC33
            mem[33] = jall(3'd1, 100);     // target byte 100 -> PC50
            mem[34] = 100;
            mem[35] = jump(-3);            // PC35 -> PC33
            mem[48] = regop(3'd0, 3'd1, 5'h1f, 3'd0); // RET S1
            mem[50] = regop(3'd0, 3'd1, 5'h1f, 3'd0); // RET S1
        end else if (CASE == 16) begin
            // Warm calls across the full address range must retain one IPC.
            dmem_rdata = 32'hffff_fff0;
        end else begin
            $fatal(1, "unsupported BTB test case %0d", CASE);
        end
        repeat (4) @(negedge clk);
        rst = 0;
    end

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (!rst && CASE == 14) begin
            if (iflush_req) begin
                iflush_wait <= iflush_wait + 1;
                if (iflush_wait == 4) irq <= 1;
                if (dut.take_irq) $fatal(1, "IRQ entered during IFLUSH");
            end
            if (dut.take_irq) begin
                if (iflush_commits != 1 || iflush_wait < 64)
                    $fatal(1, "IRQ preceded IFLUSH completion");
                if (dut.x_pc_q != 10 || dut.x_result != 20)
                    $fatal(1, "IRQ saved the wrong post-IFLUSH PC");
                irq_entries <= irq_entries + 1;
                irq <= 0;
            end
            if (dut.x_finish && dut.x_pc_q == 9)
                iflush_commits <= iflush_commits + 1;
        end
        if (rst) begin
            imem_ack <= 0;
            case5_delay_q <= 0;
            case5_delay_used_q <= 0;
        end else if (case5_delay_q != 0) begin
            case5_delay_q <= case5_delay_q - 1'b1;
            imem_ack <= case5_delay_q == 1;
        end else if (!case5_delay_used_q && CASE == 5 &&
                     imem_cyc && imem_stb && imem_addr == 4) begin
            // Hold this first target request for three clocks.  The response
            // data loaded by the SRAM model remains stable while waiting.
            case5_delay_q <= 3;
            case5_delay_used_q <= 1;
            imem_ack <= 0;
        end else begin
            imem_ack <= imem_cyc && imem_stb;
        end
        if (rst)
            dmem_ack <= 0;
        else if (CASE >= 6)
            dmem_ack <= dmem_cyc && dmem_stb;
        else
            dmem_ack <= 0;
        if (!rst && CASE < 6 && dmem_cyc && dmem_stb)
            $fatal(1, "wrong-path data operation");
        if (!rst && CASE >= 6 && dmem_cyc && dmem_stb && dmem_we)
            case_store_count = case_store_count + 1;
        if (!rst && CASE >= 6 && dut.rf_we && dut.w_dst_q == 3)
            case_r3_writes = case_r3_writes + 1;
        if (!rst && CASE >= 6 && dut.d_issue &&
            (((CASE == 6 || CASE == 7) && dut.f_pc_q == 10) ||
             (CASE == 8 && dut.f_pc_q == 6) ||
             (CASE == 9 && dut.f_pc_q == 10)))
            case_target_issues = case_target_issues + 1;
        if (!rst && CASE >= 6 && dut.x_finish && dut.x_branch_q &&
            !dut.x_branch_taken)
            case_branch_not_taken = 1;
        if (!rst && CASE == 9 && dut.x_finish && dut.x_pc_q == 6 &&
            dut.x_branch_q && !dut.x_branch_taken)
            case9_fallthrough = 1;
        if (!rst && dut.x_finish) begin
            if ((CASE < 6 || CASE >= 12) && int'(dut.x_pc_q) != expected_pc)
                $fatal(1, "PC sequence: expected %0d actual %0d", expected_pc, dut.x_pc_q);
            if (CASE == 0)
                expected_pc = expected_pc == 6 ? 0 : expected_pc + 2;
            else if (CASE == 1)
                expected_pc = expected_pc == 0 || expected_pc == 2 ? 1 :
                              expected_pc == 1 ? 4 : 2;
            else if (CASE == 2)
                expected_pc = expected_pc == 0 ? 1 :
                              expected_pc == 1 ? 4096 :
                              expected_pc == 4096 ? 4098 : 0;
            else if (CASE == 3 && XLEN == 16)
                expected_pc = expected_pc == 16 ? 32767 :
                              expected_pc == 32767 ? 32 :
                              expected_pc == 32 ? 1 : 16;
            else if (CASE == 3)
                expected_pc = expected_pc == 0 ? 1 :
                              expected_pc == 1 ? 32767 :
                              expected_pc == 32767 ? 32770 : 0;
            else if (CASE == 4 || CASE == 5)
                expected_pc = expected_pc == 0 ? 4 :
                              expected_pc == 4 ? 2 : 0;
            else if (CASE == 14)
                expected_pc = expected_pc == 0 ? 8 : expected_pc == 8 ? 9 :
                    expected_pc == 9 ? 2 : expected_pc == 2 ? 3 :
                    expected_pc == 3 ? 10 : 11;
            else if (CASE == 16)
                expected_pc = expected_pc < 2 ? expected_pc + 1 :
                              expected_pc == 2 ? HIGH_PC :
                              expected_pc == HIGH_PC ? 3 : 2;
            else if (CASE == 15)
                expected_pc = expected_pc == 0 ? 48 :
                              expected_pc == 48 ? 2 :
                              expected_pc == 2 ? 33 :
                              expected_pc == 33 ? 50 :
                              expected_pc == 50 ? 35 : 33;
            else
                expected_pc = 0;
            if (CASE == 2 && dut.x_pc_q == 4096)
                saw_case2_branch <= 1;
            if (CASE == 2 && dut.x_pc_q == 0 && saw_case2_branch) begin
                saw_case2_pc0 <= 1;
                if (dut.x_hit_q)
                    $fatal(1, "BTB false hit at PC0 after PC4096 training");
            end
            if (CASE == 3 && dut.x_pc_q == 32767) begin
                case3_link_seen <= 1;
                link_value = {{(32-XLEN){1'b0}}, dut.x_result};
                if (link_value != (XLEN == 32 ? 32'h0001_0002 : 32'h0000_0002))
                    $fatal(1, "JALL crossing link: XLEN=%0d actual=%h", XLEN, dut.x_result);
            end
            if (CASE == 4 && dut.x_pc_q == 0) begin
                link_value = {{(32-XLEN){1'b0}}, dut.x_result};
                if (link_value != 4)
                    $fatal(1, "aligned JALL link: expected 4 actual %0d", link_value);
                if (case4_jall_seen) begin
                    if (!dut.x_hit_q)
                        $fatal(1, "aligned JALL did not hit BTB after warmup");
                    case4_jall_hit <= 1;
                end
                case4_jall_seen <= 1;
            end
            if (CASE == 5 && dut.x_pc_q == 0 && !case5_jall_seen) begin
                link_value = {{(32-XLEN){1'b0}}, dut.x_result};
                if (link_value != 4)
                    $fatal(1, "delayed aligned JALL link: expected 4 actual %0d", link_value);
                case5_jall_seen <= 1;
            end
            if (CASE == 15 && dut.x_pc_q == 33) begin
                link_value = {{(32-XLEN){1'b0}}, dut.x_result};
                if (link_value != 70)
                    $fatal(1, "CASE15 JALL link: expected byte 70 actual %0d",
                           link_value);
                if (case15_jall33_seen && dut.x_hit_q)
                    case15_jall33_hit <= 1;
                case15_jall33_seen <= 1;
            end
            if ((CASE == 0 || CASE == 1 || CASE == 4 || CASE >= 12) && commits >= 24 &&
                cycles != previous + 1) begin
                $display("GAP case=%0d pc=%0d gap=%0d", CASE, dut.x_pc_q,
                         cycles - previous);
                errors <= errors + 1;
            end
            if (commits == 100) begin
                if (weak_allocations == 0)
                    $fatal(1, "BTB test did not exercise weak allocation");
                if (CASE == 0 && confirmed_entries == 0)
                    $fatal(1, "BTB test did not confirm a weak entry");
                if (CASE == 15 && aged_conflicts == 0)
                    $fatal(1, "BTB conflict test did not age a resident");
                if (CASE == 14 && (iflush_commits != 1 || irq_entries != 1 ||
                                   case_r3_writes != 1 || !dut.interrupt_enable_q))
                    $fatal(1, "IFLUSH/IRQ did not preserve successor or IE");
                if ((CASE == 0 || CASE == 1 || CASE == 4 || CASE >= 12) && errors != 0)
                    $fatal(1, "warm control transfers inserted bubbles");
                if (CASE == 2 && (!saw_case2_branch || !saw_case2_pc0))
                    $fatal(1, "CASE2 did not observe trained PC4096 then PC0");
                if (CASE == 3 && !case3_link_seen)
                    $fatal(1, "CASE3 did not observe the high JALL link");
                if (CASE == 4 && !case4_jall_hit)
                    $fatal(1, "CASE4 did not observe a warm aligned JALL hit");
                if (CASE == 5 && (!case5_jall_seen || !case5_delay_used_q))
                    $fatal(1, "CASE5 did not exercise delayed aligned JALL flow");
                if (CASE == 6 && (!case_branch_not_taken ||
                                  case_target_issues < 2 ||
                                  case_store_count != 1))
                    $fatal(1, "CASE6 target did not issue and squash its store");
                if (CASE == 7 && (!case_branch_not_taken ||
                                  case_target_issues < 2 ||
                                  case_r3_writes != 1))
                    $fatal(1, "CASE7 target did not issue and squash its MUL");
                if (CASE == 8 && (!case_branch_not_taken ||
                                  case_target_issues < 2 ||
                                  dut.interrupt_enable_q))
                    $fatal(1, "CASE8 target did not issue and squash its STI");
                if (CASE == 9 && (!case_branch_not_taken ||
                                  case_target_issues < 2 ||
                                  !case9_fallthrough || dut.r0_zero_q)) begin
                    $fatal(1, "CASE9 target did not issue and preserve flags");
                end
                if (CASE == 15 && (!case15_jall33_seen || !case15_jall33_hit))
                    $fatal(1, "CASE15 JALL conflict did not warm a BTB hit");
                if (CASE < 2)
                    $display("PASS BTB XLEN=%0d CASE=%0d warm consecutive commits=76", XLEN, CASE);
                else
                    $display("PASS BTB XLEN=%0d CASE=%0d directed PC sequence", XLEN, CASE);
                $finish;
            end
            commits <= commits + 1;
            previous <= cycles;
        end
        if (cycles > 2000)
            $fatal(1, "BTB test timeout");
    end
endmodule
`default_nettype wire
