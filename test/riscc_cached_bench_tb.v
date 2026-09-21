// Benchmark the core and cache hierarchy with one-clock, native-width SRAM.
`default_nettype none
module riscc_cached_bench_tb #(
    parameter integer XLEN = 16,
    parameter integer CACHED = 1
);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg [15:0] memory [0:32767];
    string image_path;
    integer n, cycles = 0, commits = 0, reads = 0, writes = 0;
    integer max_cycles;
    wire [XLEN-3:0] addr;
    wire [31:0] wdata;
    wire [3:0] sel;
    wire we, cyc, stb;
    reg ack = 0;
    reg [31:0] rdata = 0;
    reg [3:0] rsel = 0;
    wire commit, result_issued;
    reg result_issued_q = 0;
    wire [XLEN-2:0] i_addr;
    wire i_cyc, i_stb;
    reg i_ack = 0;
    reg [15:0] i_rdata = 0;
    generate if (CACHED != 0) begin : cached
        riscc_cached #(.XLEN(XLEN)) dut (
            .clk(clk), .rst(rst), .irq(1'b0),
            .mem_addr(addr), .mem_wdata(wdata), .mem_wmask(sel), .mem_we(we),
            .mem_rdata(rdata), .mem_cyc(cyc), .mem_stb(stb), .mem_stall(1'b0), .mem_ack(ack)
        );
        assign commit = dut.cpu.commit_valid;
        assign result_issued = dut.cpu.dmem_stb && !dut.cpu.dmem_stall &&
            dut.cpu.dmem_we && dut.cpu.dmem_addr[13:0] == 14'h3fff &&
            (&dut.cpu.dmem_wmask[3:2]);
        assign i_addr = 0;
        assign i_cyc = 0;
        assign i_stb = 0;
    end else begin : direct
        riscc_cached_pipe #(.XLEN(XLEN)) dut (
            .clk(clk), .rst(rst), .irq(1'b0),
            .imem_addr(i_addr), .imem_rdata(i_rdata), .imem_cyc(i_cyc),
            .imem_stb(i_stb), .imem_stall(1'b0), .imem_ack(i_ack),
            .dmem_addr(addr), .dmem_wdata(wdata), .dmem_wmask(sel), .dmem_rsel(rsel), .dmem_we(we),
            .dmem_rdata(rdata), .dmem_cyc(cyc), .dmem_stb(stb), .dmem_stall(1'b0), .dmem_ack(ack)
        );
        assign commit = dut.commit_valid;
        assign result_issued = cyc && stb && we && addr[13:0] == 14'h3fff &&
            (&sel[3:2]);
    end endgenerate
    initial begin
        for (n=0; n<32768; n=n+1) memory[n] = 0;
        if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "missing +IMAGE");
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100000;
        if (max_cycles <= 0) $fatal(1, "MAX_CYCLES must be positive");
        $readmemh(image_path, memory);
    end
    always @(negedge clk) if (cycles == 4) rst = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > max_cycles) begin
            $display("TIMEOUT after %0d cycles", cycles);
            $fatal(1, "benchmark timeout");
        end
        ack <= !rst && cyc && stb;
        i_ack <= !rst && i_cyc && i_stb;
        // Count the workload before its terminal result store and spin.
        if (!rst && result_issued) result_issued_q <= 1;
        if (!rst && commit && !result_issued_q && !result_issued) commits <= commits + 1;
        if (!rst && i_cyc && i_stb) i_rdata <= memory[i_addr & 32767];
        if (!rst && cyc && stb) begin
            rsel <= sel;
            rdata <= {memory[{addr[13:0], 1'b1}], memory[{addr[13:0], 1'b0}]};
            if (we) begin
                writes <= writes + 1;
                if (sel[0]) memory[{addr[13:0], 1'b0}][7:0] <= wdata[7:0];
                if (sel[1]) memory[{addr[13:0], 1'b0}][15:8] <= wdata[15:8];
                if (sel[2]) memory[{addr[13:0], 1'b1}][7:0] <= wdata[23:16];
                if (sel[3]) memory[{addr[13:0], 1'b1}][15:8] <= wdata[31:24];
                if (addr[13:0] == 14'h3fff && (&sel[3:2])) begin
                    if (wdata[31:16] != 16'h600d) $fatal(1, "benchmark failed: %h", wdata);
                    $display("PASS XLEN=%0d CACHED=%0d cycles=%0d commits=%0d backing_reads=%0d backing_writes=%0d", XLEN, CACHED, cycles, commits, reads, writes+1);
                    $finish;
                end
            end else reads <= reads + 1;
        end
    end
endmodule
`default_nettype wire
