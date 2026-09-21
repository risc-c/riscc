// Focused cache-hit timing checks for the public riscc_cached wrapper.
// The backing port returns ACK and read data one clock after acceptance. X
// completion is the accepted request; architectural writeback is observed in
// the following W edge.

`default_nettype none

module riscc_cached_hits_tb #(
    parameter integer XLEN = 16,
    parameter integer REGISTER_FETCH = 0
);
    localparam integer MEM_WORDS = 16384;
    localparam integer DATA_WORD = 32; // byte address 0x80
    localparam integer LAST_PC = 40;

    reg clk;
    reg rst;
    reg irq;
    wire [XLEN-3:0] mem_addr;
    wire [31:0] mem_rdata;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we;
    wire mem_cyc;
    wire mem_stb;
    wire mem_stall;
    wire mem_ack;

    reg [31:0] backing [0:MEM_WORDS-1];
    reg [31:0] response_data_q;
    reg response_pending_q;
    integer cycle_q;
    integer write_count;
    integer commit_count;
    integer iteration_count;
    integer gap_errors;
    integer result_errors;
    reg second_pass_q;
    reg done_q;
    reg failed_q;
    reg writeback_pending_q;
    reg [31:0] writeback_pc_q;
    integer i;

    // A pending response may complete while a refill offers its next beat.
    // Pass-through stores and loads keep STB low until the response arrives.
    wire request_accept = mem_cyc && mem_stb &&
                          (!response_pending_q || mem_ack);
    assign mem_ack = response_pending_q;
    assign mem_rdata = response_data_q;
    assign mem_stall = 1'b0;

    riscc_cached #(.XLEN(XLEN), .REGISTER_FETCH(REGISTER_FETCH != 0)) dut (
        .clk(clk), .rst(rst), .irq(irq),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb), .mem_stall(mem_stall),
        .mem_ack(mem_ack)
    );

    // Keep the backing RAM index and architectural monitor values explicit.
    // The public address is XLEN-2 bits wide, while this test only exercises
    // the low 16 KiB of the backing word address space.
    wire [13:0] backing_addr = mem_addr[13:0];
    wire [31:0] monitor_pc = {{(33-XLEN){1'b0}}, dut.cpu.x_pc_q};
    wire [31:0] monitor_wdata = {{(32-XLEN){1'b0}}, dut.cpu.rf_wdata};
    wire [3:0] monitor_waddr = dut.cpu.rf_waddr;
    wire monitor_commit = dut.cpu.commit_valid;
    wire monitor_rf_we = dut.cpu.rf_we;

    function automatic [15:0] enc_i(
        input [2:0] rd, input [2:0] op, input [7:0] imm);
        enc_i = {2'b10, rd, op, imm};
    endfunction

    function automatic [15:0] enc_mem(
        input store, input [2:0] rs, input [2:0] ra,
        input [7:0] disp);
        enc_mem = {2'b01, rs, ra, disp[7:1], store};
    endfunction

    function automatic [15:0] enc_r(
        input [2:0] rd, input [2:0] ra, input [4:0] func,
        input [2:0] rb);
        enc_r = {2'b11, rd, ra, func, rb};
    endfunction

    function automatic [15:0] enc_branch(
        input [2:0] cc, input signed [7:0] relative);
        reg [7:0] rotated;
        begin
            rotated = {relative[6:0], relative[7]};
            enc_branch = enc_i(cc, 3'b111, rotated);
        end
    endfunction

    task automatic put16(input integer address, input [15:0] value);
        begin
            if (address[0])
                backing[address >> 1][31:16] = value;
            else
                backing[address >> 1][15:0] = value;
        end
    endtask

    task automatic fail(input [8*96-1:0] message);
        begin
            if (!failed_q) begin
                failed_q = 1'b1;
                $display("FAIL XLEN=%0d: %0s", XLEN, message);
                $fatal(1, "XLEN=%0d: %0s", XLEN, message);
            end
        end
    endtask

    task automatic init_program;
        integer pc;
        begin
            // PC 0..40 occupies less than 0x80 bytes.  The data word is at
            // byte address 0x80, so its cache index cannot evict instruction
            // lines during the loop.
            pc = 0;
            put16(pc, enc_i(3'd7, 3'd0, 8'h80)); pc = pc + 1;
            put16(pc, enc_i(3'd0, 3'd0, 8'h00)); pc = pc + 1;
            for (i = 0; i < 32; i = i + 1) begin
                put16(pc, enc_i(3'd0, 3'd2, 8'h01));
                pc = pc + 1;
            end
            put16(pc, enc_mem(1'b0, 3'd1, 3'd7, 8'h00)); pc = pc + 1;
            put16(pc, enc_mem(1'b0, 3'd2, 3'd7, 8'h00)); pc = pc + 1;
            put16(pc, enc_r(3'd3, 3'd1, 5'h00, 3'd2)); pc = pc + 1;
            put16(pc, enc_mem(1'b1, 3'd3, 3'd7, 8'h00)); pc = pc + 1;
            put16(pc, enc_mem(1'b0, 3'd4, 3'd7, 8'h00)); pc = pc + 1;
            put16(pc, enc_r(3'd5, 3'd4, 5'h00, 3'd1)); pc = pc + 1;
            // rel8 is in bytes and is relative to the next instruction:
            // 82 + (-41 * 2) = 0.
            put16(pc, enc_branch(3'd4, -8'sd41));
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            response_pending_q <= 1'b0;
            response_data_q <= 32'b0;
            cycle_q <= 0;
            write_count <= 0;
        end else begin
            cycle_q <= cycle_q + 1;
            if (response_pending_q)
                response_pending_q <= 1'b0;
            if (request_accept) begin
                response_pending_q <= 1'b1;
                response_data_q <= backing[backing_addr];
                if (mem_we) begin
                    if (mem_wmask[0]) backing[backing_addr][7:0] <= mem_wdata[7:0];
                    if (mem_wmask[1]) backing[backing_addr][15:8] <= mem_wdata[15:8];
                    if (mem_wmask[2]) backing[backing_addr][23:16] <= mem_wdata[23:16];
                    if (mem_wmask[3]) backing[backing_addr][31:24] <= mem_wdata[31:24];
                    write_count <= write_count + 1;
                end
            end
        end
    end

    // Commit metadata is intentionally observed through the existing internal
    // monitor signals. X commit and W writeback are one edge apart, so the
    // writeback checks use the preceding committed PC.
    integer previous_commit_cycle;
    integer previous_commit_pc;
    reg previous_commit_valid;
    always @(posedge clk) begin
        if (rst) begin
            commit_count <= 0;
            iteration_count <= 0;
            previous_commit_cycle <= 0;
            previous_commit_pc <= 0;
            previous_commit_valid <= 1'b0;
            second_pass_q <= 1'b0;
            done_q <= 1'b0;
            gap_errors <= 0;
            result_errors <= 0;
            writeback_pending_q <= 1'b0;
            writeback_pc_q <= 0;
        end else begin
            // W may write back during the load-use bubble, when X has no
            // completion pulse. Keep the expectation live until rf_we: a
            // delayed load must not be hidden by a younger X completion.
            if (writeback_pending_q) begin
                if (monitor_rf_we) begin
                    if (second_pass_q) begin
                        if (writeback_pc_q >= 2 && writeback_pc_q <= 33) begin
                            if (monitor_waddr !== 0 ||
                                monitor_wdata !== writeback_pc_q - 1)
                                result_errors <= result_errors + 1;
                        end else if (writeback_pc_q == 34) begin
                            if (monitor_waddr !== 1 || monitor_wdata !== 32'd6)
                                result_errors <= result_errors + 1;
                        end else if (writeback_pc_q == 35) begin
                            if (monitor_waddr !== 2 || monitor_wdata !== 32'd6)
                                result_errors <= result_errors + 1;
                        end else if (writeback_pc_q == 36) begin
                            if (monitor_waddr !== 3 || monitor_wdata !== 32'd12)
                                result_errors <= result_errors + 1;
                        end else if (writeback_pc_q == 38) begin
                            if (monitor_waddr !== 4 || monitor_wdata !== 32'd12)
                                result_errors <= result_errors + 1;
                        end else if (writeback_pc_q == 39) begin
                            if (monitor_waddr !== 5 || monitor_wdata !== 32'd18)
                                result_errors <= result_errors + 1;
                        end
                    end
                    writeback_pending_q <= 1'b0;
                end else if (monitor_commit) begin
                    fail("younger X commit overwrote pending W writeback");
                end
            end

            if (monitor_commit) begin
                commit_count <= commit_count + 1;

                if (monitor_pc == LAST_PC) begin
                    iteration_count <= iteration_count + 1;
                    if (iteration_count == 1)
                        done_q <= 1'b1;
                    else if (iteration_count == 0)
                        second_pass_q <= 1'b1;
                end

                if (second_pass_q && previous_commit_valid) begin
                    if (monitor_pc == 2 && previous_commit_pc == 1 &&
                        cycle_q - previous_commit_cycle != 1) begin
                        gap_errors <= gap_errors + 1;
                    end
                    if ((monitor_pc == 34 || monitor_pc == 35 ||
                         monitor_pc == 38) &&
                        cycle_q - previous_commit_cycle != 1) begin
                        gap_errors <= gap_errors + 1;
                    end
                    if (monitor_pc == 36 &&
                        cycle_q - previous_commit_cycle != 2) begin
                        gap_errors <= gap_errors + 1;
                    end
                    // The store-to-same-word cache hit performs a relookup
                    // before its response, so its dependent ADD waits three
                    // X-completion edges while the load response is checked.
                    if (monitor_pc == 39 &&
                        cycle_q - previous_commit_cycle != 3) begin
                        gap_errors <= gap_errors + 1;
                    end
                    if (monitor_pc >= 2 && monitor_pc <= 33 &&
                        previous_commit_pc >= 2 && previous_commit_pc < 33 &&
                        cycle_q - previous_commit_cycle != 1) begin
                        gap_errors <= gap_errors + 1;
                    end
                end

                previous_commit_valid <= 1'b1;
                previous_commit_cycle <= cycle_q;
                previous_commit_pc <= monitor_pc;
                // Stores and control transfers have no architectural W
                // writeback expectation. Keep the prior expectation only
                // until its actual rf_we pulse above.
                if ((monitor_pc >= 2 && monitor_pc <= 36) ||
                    monitor_pc == 38 || monitor_pc == 39) begin
                    writeback_pending_q <= 1'b1;
                    writeback_pc_q <= monitor_pc;
                end
            end
        end
    end

    task automatic check_results;
        begin
            if (iteration_count != 2)
                fail("program did not complete two loop iterations");
            if (write_count != 2)
                fail("store was not accepted exactly twice");
            if (backing[DATA_WORD] !== (XLEN == 32 ? 32'd12 : 32'h0000_000c))
                fail("store then load did not preserve the updated value");
            if (gap_errors != 0)
                fail("cache-hit instruction or load timing mismatch");
            if (result_errors != 0)
                fail("dependent register result mismatch");
            $display("PASS Cached cache hits XLEN=%0d cycles=%0d commits=%0d writes=%0d",
                     XLEN, cycle_q, commit_count, write_count);
            $finish(0);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        irq = 1'b0;
        failed_q = 1'b0;
        response_pending_q = 1'b0;
        response_data_q = 32'b0;
        for (i = 0; i < MEM_WORDS; i = i + 1)
            backing[i] = 32'b0;
        backing[DATA_WORD] = 32'd3;
        init_program();
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        forever begin
            @(posedge clk);
            if (done_q)
                check_results();
            if (cycle_q > 20000)
                fail("watchdog expired");
        end
    end

    always #1 clk = ~clk;
endmodule

`default_nettype wire
