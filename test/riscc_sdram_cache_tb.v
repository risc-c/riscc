`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_cache_tb #(
    parameter integer DATA_BITS = 16,
    parameter integer LINE_WORD_BITS = 3,
    parameter integer CLK_MHZ = 50,
    parameter realtime CLOCK_PERIOD_NS = 1000.0 / CLK_MHZ,
    parameter integer INIT_CYCLES = 20,
    parameter integer REFRESH_CYCLES = 100,
    parameter integer CAS = 3,
    parameter integer TRCD = (20 * CLK_MHZ + 999) / 1000,
    parameter integer TRP = (20 * CLK_MHZ + 999) / 1000,
    parameter integer TRFC = (80 * CLK_MHZ + 999) / 1000,
    parameter integer TRAS = (45 * CLK_MHZ + 999) / 1000,
    parameter integer TWR = ((15 * CLK_MHZ + 999) / 1000 < 2) ?
                            2 : (15 * CLK_MHZ + 999) / 1000,
    parameter integer MAX_REFRESH_GAP = REFRESH_CYCLES + 32,
    parameter realtime T_AC = 6.0
);
    localparam integer ADDR_BITS = 24 - (DATA_BITS == 16 ? 1 : 0);
    reg clk = 0;
    always #(CLOCK_PERIOD_NS / 2.0) clk = ~clk;
    reg rst = 1;
    reg [ADDR_BITS-1:0] c_addr = 0;
    reg [31:0] c_wdata = 0;
    reg [3:0] c_sel = 15;
    reg c_we = 0, c_cyc = 0, c_stb = 0, inv_valid = 0;
    wire [31:0] c_rdata, m_wdata, m_rdata;
    wire [3:0] c_rsel, m_sel;
    wire c_ack, c_stall, m_we, m_cyc, m_stb, m_stall, m_ack, ready;
    wire [ADDR_BITS-1:0] m_addr;
    wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire [12:0] sd_addr;
    wire [1:0] sd_ba;
    wire [DATA_BITS/8-1:0] sd_dqm;
    wire [DATA_BITS-1:0] sd_dq_i, sd_dq_o;
    riscc_cached_cache #(.ADDR_BITS(ADDR_BITS), .LINE_WORD_BITS(LINE_WORD_BITS)) cache (
        .clk(clk), .rst(rst), .store_posted(), .c_addr(c_addr), .c_wdata(c_wdata), .c_sel(c_sel),
        .c_we(c_we), .c_cyc(c_cyc), .c_stb(c_stb), .c_rdata(c_rdata),
        .c_rsel(c_rsel), .c_ack(c_ack), .c_stall(c_stall),
        .m_cacheable(), .m_addr(m_addr), .m_wdata(m_wdata), .m_sel(m_sel), .m_we(m_we),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_stall(m_stall), .m_ack(m_ack),
        .m_rdata(m_rdata), .inv_valid(inv_valid), .inv_addr(c_addr)
    );
    riscc_sdram #(
        .DATA_BITS(DATA_BITS), .CLK_MHZ(CLK_MHZ),
        .INIT_CYCLES(INIT_CYCLES), .REFRESH_CYCLES(REFRESH_CYCLES),
        .CAS(CAS), .TRCD(TRCD), .TRP(TRP), .TRFC(TRFC), .TRAS(TRAS),
        .TWR(TWR)
    ) dut (
        .clk(clk), .rst(rst), .mem_addr(m_addr), .mem_wdata(m_wdata),
        .mem_wmask(m_sel), .mem_we(m_we), .mem_cyc(m_cyc), .mem_stb(m_stb),
        .mem_stall(m_stall), .mem_ack(m_ack), .mem_rdata(m_rdata), .ready(ready),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba),
        .sd_dqm(sd_dqm), .sd_dq_i(sd_dq_i), .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe)
    );
    riscc_sdram_model #(
        .DATA_BITS(DATA_BITS), .CAS(CAS), .INIT_CYCLES(INIT_CYCLES),
        .TRCD(TRCD), .TRP(TRP), .TRFC(TRFC), .TRAS(TRAS), .TWR(TWR),
        .T_AC(T_AC), .MAX_REFRESH_GAP(MAX_REFRESH_GAP)
    ) memory (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba),
        .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe(sd_dq_oe), .dq_o(sd_dq_i)
    );
    reg [31:0] expected [0:2047];
    reg [31:0] rng = 32'h932bbe11;
    integer cycles = 0, accesses = 0, backing_reads = 0, backing_writes = 0;
    integer index, mask, i, before_reads, before_writes;
    reg [31:0] data;
    reg [ADDR_BITS-1:0] address;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (m_cyc && m_stb && !m_stall) begin
            if (m_we) backing_writes <= backing_writes + 1;
            else backing_reads <= backing_reads + 1;
        end
        if (cycles > 1000000) $fatal(1, "cache SDRAM timeout");
    end
    function [31:0] random_next(input [31:0] x);
        reg [31:0] y;
        begin y=x^(x<<13); y=y^(y>>17); random_next=y^(y<<5); end
    endfunction
    task transaction(input bit write_op, input [ADDR_BITS-1:0] a,
                     input [31:0] value, input [3:0] lanes, input [31:0] want);
        reg accepted, answered;
        begin
            @(negedge clk);
            c_addr = a; c_wdata = value; c_sel = lanes;
            c_we = write_op; c_cyc = 1; c_stb = 1;
            accepted = 0; answered = 0;
            while (!answered) begin
                @(posedge clk);
                if (c_stb && !c_stall) accepted = 1;
                if (c_ack) begin
                    if (!accepted) $fatal(1, "cache ACK before acceptance");
                    if (!write_op && c_rdata !== want)
                        $fatal(1, "cache mismatch addr=%h got=%h expected=%h", a, c_rdata, want);
                    answered = 1;
                end
                @(negedge clk);
                if (accepted) c_stb = 0;
            end
            c_cyc = 0;
            accesses = accesses + 1;
        end
    endtask
    initial begin
        if (!$value$plusargs("SEED=%d", rng)) rng = 32'h932bbe11;
        for (i=0; i<2048; i=i+1) expected[i] = 0;
        repeat (4) @(negedge clk);
        rst = 0;
        wait (ready);
        // Populate SDRAM through write-through stores; these must not allocate.
        for (i=0; i<2048; i=i+1) begin
            expected[i] = 32'(i) * 32'h9e3779b9;
            transaction(1, ADDR_BITS'(i), expected[i], 15, 0);
        end
        before_reads = backing_reads;
        transaction(0, 0, 0, 15, expected[0]);
        if (backing_reads - before_reads != (1 << LINE_WORD_BITS))
            $fatal(1, "store miss allocated or incomplete cache refill");
        before_reads = backing_reads;
        transaction(0, 1, 0, 15, expected[1]);
        if (backing_reads != before_reads) $fatal(1, "warm cache read missed");
        // Store hit must both update the cached word and reach SDRAM once.
        before_writes = backing_writes;
        transaction(1, 1, 32'h11223344, 4'b0101, 0);
        expected[1] = (expected[1] & 32'hff00ff00) | 32'h00220044;
        transaction(0, 1, 0, 15, expected[1]);
        if (backing_reads != before_reads || backing_writes != before_writes + 1)
            $fatal(1, "write-through hit protocol failed");
        for (i=0; i<3000; i=i+1) begin
            rng = random_next(rng); index = int'(rng[10:0]);
            rng = random_next(rng); mask = int'(rng[3:0]); data = rng;
            address = ADDR_BITS'(index);
            if (rng[8]) begin
                transaction(1, address, data, 4'(mask), 0);
                for (integer lane=0; lane<4; lane=lane+1)
                    if ((mask & (1 << lane)) != 0) expected[index][lane*8 +: 8] = data[lane*8 +: 8];
            end else transaction(0, address, 0, 15, expected[index]);
        end
        // Invalidate each line before rereading: check external memory, not only cache hits.
        for (i=0; i<2048; i=i+1) begin
            if ((i & ((1 << LINE_WORD_BITS)-1)) == 0) begin
                @(negedge clk); c_addr = ADDR_BITS'(i); inv_valid = 1;
                @(negedge clk); inv_valid = 0;
            end
            transaction(0, ADDR_BITS'(i), 0, 15, expected[i]);
        end
        if (memory.refresh_count < 10) $fatal(1, "refresh coverage missing");
        $display("PASS SDRAM cache x%0d line=%0d accesses=%0d cycles=%0d reads=%0d writes=%0d refreshes=%0d",
            DATA_BITS, 4 << LINE_WORD_BITS, accesses, cycles, backing_reads, backing_writes, memory.refresh_count);
        $finish;
    end
endmodule
`default_nettype wire
