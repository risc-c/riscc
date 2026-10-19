// CoreMark fixture: native-width, one-clock SRAM plus always-ready console
// and a coherent 64-bit cycle counter. Standard 32-entry BTB with synchronous
// block register file; no changes to the CPU or ISA.
`default_nettype none
module riscc_coremark_tb #(
    parameter integer CACHED = 0
);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg [15:0] memory [0:32767];
    string image_path;
    integer n;
    reg [63:0] cycles = 0, cycle_base = 0, snapshot = 0;
    reg [63:0] max_cycles;
    wire [63:0] counter = cycle_base + cycles;
    wire [29:0] addr;
    wire [31:0] wdata;
    wire [3:0] sel;
    wire we, cyc, stb;
    reg ack = 0;
    reg [31:0] rdata = 0;
    wire [30:0] i_addr;
    wire i_cyc, i_stb;
    reg i_ack = 0;
    reg [15:0] i_rdata = 0;

    generate if (CACHED != 0) begin : cached
        riscc_cached #(.XLEN(32)) dut (
            .clk(clk), .rst(rst), .irq(1'b0),
            .mem_cacheable(), .mem_addr(addr), .mem_wdata(wdata),
            .mem_wmask(sel), .mem_we(we), .mem_rdata(rdata),
            .mem_cyc(cyc), .mem_stb(stb), .mem_stall(1'b0), .mem_ack(ack)
        );
        initial begin
            if ($size(dut.cpu.g_btb.target_mem) != 32)
                $fatal(1, "CoreMark requires a 32-entry BTB");
            $display("COREMARK_CONFIG cached=1 btb_entries=%0d",
                     $size(dut.cpu.g_btb.target_mem));
        end
        assign i_addr = 0;
        assign i_cyc = 0;
        assign i_stb = 0;
    end else begin : direct
        riscc_cached_pipe #(.XLEN(32)) dut (
            .clk(clk), .rst(rst), .irq(1'b0),
            .iflush_req(), .iflush_ack(1'b1), .imem_local(),
            .imem_addr(i_addr), .imem_rdata(i_rdata),
            .imem_cyc(i_cyc), .imem_stb(i_stb),
            .imem_stall(1'b0), .imem_ack(i_ack),
            .dmem_addr(addr), .dmem_wdata(wdata), .dmem_wmask(sel),
            .dmem_we(we), .dmem_write_local(), .dmem_store_addr(),
            .dmem_rdata({rdata, 32'b0}), .dmem_local(1'b0),
            .dmem_cyc(cyc), .dmem_stb(stb),
            .dmem_stall(1'b0), .dmem_ack(ack)
        );
        initial begin
            if ($size(dut.g_btb.target_mem) != 32)
                $fatal(1, "CoreMark requires a 32-entry BTB");
            $display("COREMARK_CONFIG cached=0 btb_entries=%0d",
                     $size(dut.g_btb.target_mem));
        end
    end endgenerate

    initial begin
        for (n = 0; n < 32768; n = n + 1) memory[n] = 0;
        if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "missing +IMAGE");
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000000;
        if (!$value$plusargs("CYCLE_BASE=%d", cycle_base)) cycle_base = 0;
        if (max_cycles == 0) $fatal(1, "MAX_CYCLES must be positive");
        $readmemh(image_path, memory);
    end

    always @(negedge clk) if (cycles == 4) rst = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > max_cycles) $fatal(1, "CoreMark timeout after %0d cycles", cycles);
        ack <= !rst && cyc && stb;
        i_ack <= !rst && i_cyc && i_stb;
        if (!rst && i_cyc && i_stb) begin
            if (i_addr >= 32768) $fatal(1, "instruction address outside SRAM");
            i_rdata <= memory[i_addr[14:0]];
        end
        if (!rst && cyc && stb) begin
            if (addr >= 16384 && !(!we &&
                    (addr == 30'h3ffffff8 || addr == 30'h3ffffff9)))
                $fatal(1, "data address outside SRAM/MMIO");
            rdata <= {memory[{addr[13:0], 1'b1}], memory[{addr[13:0], 1'b0}]};
            if (!we) begin
                if (addr == 30'h3ffffff8) begin // 0xffffffe0: snapshot low
                    snapshot <= counter;
                    rdata <= counter[31:0];
                end else if (addr == 30'h3ffffff9) // 0xffffffe4: snapshot high
                    rdata <= snapshot[63:32];
                else if (addr == 30'h3ffc) // 0xfff0/2: UART TX always ready
                    rdata <= 32'h00010000;
            end else begin
                if (addr == 30'h3ffc && sel[0]) $write("%c", wdata[7:0]);
                if (addr == 30'h3fff && (&sel[3:2])) begin
                    if (wdata[31:16] != 16'h600d)
                        $fatal(1, "CoreMark port detected errors: %h", wdata[31:16]);
                    $display("COREMARK_DONE cached=%0d cycles=%0d", CACHED, cycles);
                    $finish;
                end
                if (sel[0]) memory[{addr[13:0], 1'b0}][7:0] <= wdata[7:0];
                if (sel[1]) memory[{addr[13:0], 1'b0}][15:8] <= wdata[15:8];
                if (sel[2]) memory[{addr[13:0], 1'b1}][7:0] <= wdata[23:16];
                if (sel[3]) memory[{addr[13:0], 1'b1}][15:8] <= wdata[31:24];
            end
        end
    end
endmodule
`default_nettype wire
