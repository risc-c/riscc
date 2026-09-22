// Focused test for riscc_cached's optional low-address synchronous SRAM.
// A deterministic pipeline stub drives both CPU ports so the test can
// exercise local SRAM and the cache/backing-port boundary directly.
`timescale 1ns/1ps
`default_nettype none

// The driver compiles the riscc_cached wrapper and cache modules without the
// production pipeline. This stub exposes deterministic two-port requests
// from the testbench while retaining the real TCM/cache routing logic.
module riscc_cached_pipe #(
    parameter integer XLEN = 32,
    parameter integer FETCH_RESPONSE_HELD = 0,
    parameter REGISTER_FETCH = 1'b0,
    parameter [XLEN-1:0] RESET_PC = 0
) (
    input wire clk, rst, irq,
    output wire [XLEN-2:0] imem_addr,
    input wire [15:0] imem_rdata,
    output wire imem_cyc, imem_stb,
    input wire imem_stall, imem_ack,
    output wire [XLEN-3:0] dmem_addr,
    input wire [31:0] dmem_rdata,
    output wire [31:0] dmem_wdata,
    output wire [3:0] dmem_wmask,
    output wire dmem_we, dmem_cyc, dmem_stb,
    input wire dmem_stall, dmem_ack
);
    assign imem_addr = riscc_cached_sram_tb.i_addr_q;
    assign imem_cyc = riscc_cached_sram_tb.i_cyc_q;
    assign imem_stb = riscc_cached_sram_tb.i_stb_q;
    assign dmem_addr = riscc_cached_sram_tb.d_addr_q;
    assign dmem_wdata = riscc_cached_sram_tb.d_wdata_q;
    assign dmem_wmask = riscc_cached_sram_tb.d_sel_q;
    assign dmem_we = riscc_cached_sram_tb.d_we_q;
    assign dmem_cyc = riscc_cached_sram_tb.d_cyc_q;
    assign dmem_stb = riscc_cached_sram_tb.d_stb_q;
endmodule

module riscc_cached_sram_tb #(
    parameter integer SRAM_ADDR_BITS = 14,
    parameter SRAM_HEX = ""
);
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    wire [29:0] mem_addr;
    wire [31:0] mem_rdata;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we, mem_cyc, mem_stb;
    reg forced_mem_stall = 1'b0;
    reg mem_ack = 1'b0;

    reg [30:0] i_addr_q = 0;
    reg i_cyc_q = 0, i_stb_q = 0;
    reg [29:0] d_addr_q = 0;
    reg [31:0] d_wdata_q = 0;
    reg [3:0] d_sel_q = 0;
    reg d_we_q = 0, d_cyc_q = 0, d_stb_q = 0;

    wire [15:0] i_data = dut.i_data;
    wire i_stall = dut.i_stall;
    wire i_ack = dut.i_ack;
    wire [31:0] d_rdata = dut.d_rdata;
    wire d_stall = dut.d_stall;
    wire d_ack = dut.d_ack;

    // Keep the actual wrapper and caches, using the stub pipeline above as a
    // deterministic two-port master for this test.
    riscc_cached #(
        .XLEN(32),
        .SRAM_ADDR_BITS(SRAM_ADDR_BITS),
        .SRAM_HEX(SRAM_HEX),
        .RESET_PC(0)
    ) dut (
        .clk(clk), .rst(rst), .irq(1'b0),
        .mem_cacheable(), .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb), .mem_stall(mem_stall),
        .mem_ack(mem_ack)
    );

    reg [31:0] backing [0:16383];
    reg backend_pending = 1'b0;
    reg [29:0] backend_addr_q = 0;
    integer backend_accepts = 0;
    integer backend_writes = 0;
    integer cycles = 0;
    integer guard;

    wire mem_stall = forced_mem_stall || backend_pending;
    wire backend_accept = mem_cyc && mem_stb && !mem_stall;
    assign mem_rdata = backing[backend_addr_q[13:0]];

    function automatic [31:0] merged_word(input [31:0] old_value,
                                           input [31:0] new_value,
                                           input [3:0] mask);
        integer lane;
        begin
            merged_word = old_value;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask[lane])
                    merged_word[lane*8 +: 8] = new_value[lane*8 +: 8];
        end
    endfunction

    // One-cycle registered backing responses.  A forced stall holds the
    // cache source while local SRAM requests remain independently usable.
    always @(posedge clk) begin
        cycles <= cycles + 1;
        mem_ack <= 1'b0;
        if (rst) begin
            backend_pending <= 1'b0;
        end else if (backend_pending) begin
            mem_ack <= 1'b1;
            backend_pending <= 1'b0;
        end else if (backend_accept) begin
            backend_pending <= 1'b1;
            backend_addr_q <= mem_addr;
            backend_accepts <= backend_accepts + 1;
            if (mem_we) begin
                backing[mem_addr[13:0]] <=
                    merged_word(backing[mem_addr[13:0]], mem_wdata, mem_wmask);
                backend_writes <= backend_writes + 1;
            end
        end
        if (cycles > 5000)
            $fatal(1, "TCM test timeout");
    end

    task automatic fail(input [1023:0] message);
        begin
            $display("FAIL Cached SRAM: %0s", message);
            $fatal(1, "Cached SRAM test failed");
        end
    endtask

    task automatic wait_guard(input integer guard);
        if (guard > 200)
            fail("request timeout");
    endtask

    task automatic i_read(input integer byte_addr, input [15:0] expected);
        integer guard;
        reg accept_preedge;
        reg got_ack;
        begin
            @(negedge clk);
            i_addr_q = byte_addr >> 1;
            i_cyc_q = 1'b1;
            i_stb_q = 1'b1;
            guard = 0; got_ack = 1'b0;
            while (1) begin
                // Capture the combinational stall state before the edge that
                // accepts the request. The strobe remains asserted until the
                // following negedge, so a one-cycle response is observable.
                accept_preedge = !i_stall;
                @(posedge clk);
                if (accept_preedge) begin
                    #1;
                    got_ack = i_ack;
                    @(negedge clk);
                    i_stb_q = 1'b0;
                    break;
                end
                #1;
                guard = guard + 1;
                wait_guard(guard);
            end
            guard = 0;
            while (!got_ack) begin
                @(posedge clk); #1;
                got_ack = i_ack;
                guard = guard + 1;
                wait_guard(guard);
            end
            if (i_data !== expected) begin
                $display("Cached SRAM instruction byte=%h got=%h expected=%h local=%b ack=%b",
                         byte_addr, i_data, expected, dut.g_sram.i_local_q, i_ack);
                fail("instruction halfword mismatch");
            end
            @(negedge clk);
            i_cyc_q = 1'b0;
        end
    endtask

    task automatic d_access(input integer byte_addr, input bit write,
                            input [3:0] mask, input [31:0] data,
                            input [31:0] expected);
        integer guard;
        reg accept_preedge;
        reg got_ack;
        begin
            @(negedge clk);
            d_addr_q = byte_addr >> 2;
            d_wdata_q = data;
            d_sel_q = mask;
            d_we_q = write;
            d_cyc_q = 1'b1;
            d_stb_q = 1'b1;
            guard = 0; got_ack = 1'b0;
            while (1) begin
                accept_preedge = !d_stall;
                @(posedge clk);
                if (accept_preedge) begin
                    #1;
                    got_ack = d_ack;
                    @(negedge clk);
                    d_stb_q = 1'b0;
                    break;
                end
                #1;
                guard = guard + 1;
                wait_guard(guard);
            end
            guard = 0;
            while (!got_ack) begin
                @(posedge clk); #1;
                got_ack = d_ack;
                guard = guard + 1;
                wait_guard(guard);
            end
            if (!write && d_rdata !== expected)
                fail("data word mismatch");
            @(negedge clk);
            d_cyc_q = 1'b0;
            d_we_q = 1'b0;
        end
    endtask

    task automatic concurrent_local(input integer i_byte_addr,
                                    input integer d_byte_addr,
                                    input [15:0] expected_i,
                                    input bit d_write,
                                    input [3:0] d_mask,
                                    input [31:0] d_data,
                                    input [31:0] expected_d);
        integer guard;
        reg got_i, got_d, accepted_i, accepted_d;
        reg accept_i_preedge, accept_d_preedge;
        begin
            @(negedge clk);
            i_addr_q = i_byte_addr >> 1;
            i_cyc_q = 1'b1; i_stb_q = 1'b1;
            d_addr_q = d_byte_addr >> 2;
            d_wdata_q = d_data;
            d_sel_q = d_mask; d_we_q = d_write;
            d_cyc_q = 1'b1; d_stb_q = 1'b1;
            guard = 0; got_i = 0; got_d = 0;
            accepted_i = 0; accepted_d = 0;
            while (!accepted_i || !accepted_d) begin
                accept_i_preedge = !i_stall && !accepted_i;
                accept_d_preedge = !d_stall && !accepted_d;
                @(posedge clk);
                if (accept_i_preedge) accepted_i = 1;
                if (accept_d_preedge) accepted_d = 1;
                #1;
                // Local responses are one-cycle pulses at the acceptance
                // edge, so capture them before dropping either strobe.
                if (i_ack) begin
                    got_i = 1;
                    if (i_data !== expected_i) fail("concurrent I data mismatch");
                end
                if (d_ack) begin
                    got_d = 1;
                    if (!d_write && d_rdata !== expected_d)
                        fail("concurrent D data mismatch");
                end
                guard = guard + 1;
                wait_guard(guard);
            end
            @(negedge clk);
            i_stb_q = 1'b0;
            d_stb_q = 1'b0;
            while (!got_i || !got_d) begin
                @(posedge clk); #1;
                if (i_ack) begin
                    got_i = 1;
                    if (i_data !== expected_i) fail("concurrent I data mismatch");
                end
                if (d_ack) begin
                    got_d = 1;
                    if (!d_write && d_rdata !== expected_d)
                        fail("concurrent D data mismatch");
                end
                guard = guard + 1;
                wait_guard(guard);
            end
            @(negedge clk);
            i_cyc_q = 1'b0; d_cyc_q = 1'b0;
        end
    endtask

    integer n;
    initial begin
        for (n = 0; n < 16384; n = n + 1)
            backing[n] = 32'h90000000 + n;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // SRAM_HEX supplies the first word; instruction reads select either
        // halfword, and data writes preserve masked lanes.
        i_read(0, 16'ha55a);
        i_read(2, 16'h5aa5);
        d_access(4, 1'b0, 4'hf, 0, 32'h11223344);
        d_access(4, 1'b1, 4'h1, 32'h000000ee, 0);
        d_access(4, 1'b1, 4'hc, 32'h55660000, 0);
        d_access(4, 1'b0, 4'hf, 0, 32'h556633ee);
        i_read(4, 16'h33ee);
        if (backend_accepts != 0)
            fail("local access reached backing port");

        // A local response retains its source after the address changes and
        // the request strobe drops while the registered instruction data is
        // being produced.
        @(negedge clk);
        i_addr_q = 0; i_cyc_q = 1'b1; i_stb_q = 1'b1;
        #1;
        if (i_stall)
            fail("local held-response request was stalled");
        @(posedge clk); #1;
        if (!i_ack || i_data !== 16'ha55a)
            fail("local instruction response was not available at acceptance");
        @(negedge clk);
        i_addr_q = 16'h4000; i_stb_q = 1'b0;
        #1;
        if (!i_ack || i_data !== 16'ha55a)
            fail("local response source was not retained across address change");
        @(posedge clk); #1;
        if (i_ack)
            fail("local response remained asserted after its held cycle");
        @(negedge clk); i_cyc_q = 1'b0;

        // Distinct simultaneous local requests, including a write, must
        // complete independently and preserve the instruction response.
        concurrent_local(0, 4, 16'ha55a, 1'b0, 4'hf, 0, 32'h556633ee);
        concurrent_local(0, 8, 16'ha55a, 1'b1, 4'hf, 32'hdeadbeef, 0);
        d_access(8, 1'b0, 4'hf, 0, 32'hdeadbeef);

        // The final local word is still local; the next aligned word reaches
        // the cached backing path. This catches the inclusive SRAM boundary.
        d_access(32'h3ffc, 1'b1, 4'hf, 32'hcafef00d, 0);
        d_access(32'h3ffc, 1'b0, 4'hf, 0, 32'hcafef00d);
        d_access(32'h4000, 1'b0, 4'hf, 0, backing[14'h1000]);

        // A same-word write accepts alongside the fetch, suppresses the
        // stale instruction response, and retries the retained address.
        @(negedge clk);
        i_addr_q = 4 >> 1; i_cyc_q = 1'b1; i_stb_q = 1'b1;
        d_addr_q = 4 >> 2; d_wdata_q = 32'h0000cafe; d_sel_q = 4'h3;
        d_we_q = 1'b1; d_cyc_q = 1'b1; d_stb_q = 1'b1;
        #1;
        if (i_stall || d_stall)
            fail("same-word collision was stalled before acceptance");
        // Both requests are accepted at this edge. The data response is
        // immediate, while the colliding instruction response is suppressed.
        @(posedge clk); #1;
        if (!d_ack || i_ack)
            fail("collision did not suppress the stale instruction response");
        if (!i_stall)
            fail("collision did not retain the instruction retry");
        // Keep a second same-word write active during the retry. This checks
        // that repeated conflicts continue to suppress stale fetch data.
        @(negedge clk);
        i_stb_q = 1'b0;
        d_wdata_q = 32'h0000beef;
        #1;
        if (!i_stall || d_stall)
            fail("repeated collision did not retain retry state");
        @(posedge clk); #1;
        if (!d_ack || i_ack)
            fail("repeated collision produced an early instruction response");
        @(negedge clk);
        d_stb_q = 1'b0;
        #1;
        if (!i_stall)
            fail("retry was released before its reread edge");
        @(posedge clk); #1;
        if (!i_ack || i_data !== 16'hbeef)
            fail("retry instruction response did not read the stored word");
        @(negedge clk);
        i_cyc_q = 1'b0; d_cyc_q = 1'b0; d_we_q = 1'b0;
        i_read(4, 16'hbeef);

        // Hold a cache refill at the backing port. A local data request must
        // still complete while the cache source is stalled, and the refill
        // must resume with its original source/data afterward.
        forced_mem_stall = 1'b1;
        @(negedge clk);
        i_addr_q = 16'h4000; // byte address 0x8000, outside local SRAM
        i_cyc_q = 1'b1; i_stb_q = 1'b1;
        #1;
        if (i_stall)
            fail("cache request was stalled before acceptance");
        // The CPU request is accepted here; the refill then owns the
        // response independently of the request strobe.
        @(posedge clk); #1;
        if (i_ack)
            fail("cache instruction response arrived before refill");
        @(negedge clk);
        // Change to a local address after acceptance and withdraw STB. The
        // eventual response must still select the retained cached source.
        i_addr_q = 0;
        i_stb_q = 1'b0;
        guard = 0;
        while (!mem_cyc || !mem_stb) begin
            @(posedge clk); #1;
            guard = guard + 1;
            wait_guard(guard);
        end
        if (!forced_mem_stall || !mem_stall)
            fail("cache refill did not expose backing stall");
        d_addr_q = 0; d_sel_q = 4'hf; d_we_q = 1'b0;
        d_cyc_q = 1'b1; d_stb_q = 1'b1;
        if (d_stall)
            fail("local response was advertised stalled during cache hold");
        @(posedge clk); #1;
        if (!d_ack || d_rdata !== 32'h5aa5a55a)
            fail("local response was lost during cache stall");
        @(negedge clk);
        d_stb_q = 1'b0;
        #1;
        if (!forced_mem_stall || !mem_stall)
            fail("cache stall was released by local response");
        @(negedge clk); d_cyc_q = 1'b0;
        forced_mem_stall = 1'b0;
        #1;
        if (!mem_cyc || !mem_stb || mem_stall)
            fail("backing request was not offered before acceptance");
        // The backing responder must advertise its one-cycle pending state
        // after this edge; otherwise a second request could be accepted and
        // silently discarded while the first response is outstanding.
        @(posedge clk); #1;
        if (!backend_pending || !mem_stall)
            fail("backing pending request was not advertised stalled");
        if (i_stb_q)
            fail("cache request strobe remained asserted during refill");
        guard = 0;
        while (!i_ack) begin
            @(posedge clk); #1;
            guard = guard + 1;
            wait_guard(guard);
        end
        if (dut.g_sram.i_local_q || i_data !== backing[14'h2000][15:0]) begin
            $display("Cached SRAM cache byte=%h got=%h expected=%h backend=%0d mem_addr=%h",
                     32'h8000, i_data, backing[14'h2000], backend_accepts, mem_addr);
            fail("cache response source/data mismatch");
        end
        @(negedge clk); i_cyc_q = 1'b0; i_stb_q = 1'b0;
        if (backend_accepts == 0)
            fail("cache refill did not reach backing port");

        // Registered external lookups also hit without backing traffic,
        // including when local fetches intervene. Stores invalidate that line.
        n = backend_accepts;
        i_read(32'h8002, 16'h9000);
        i_read(0, 16'ha55a);
        i_read(32'h8000, 16'h2000);
        if (backend_accepts != n) fail("warm instruction read missed");
        d_access(32'h8000, 1'b1, 4'hf, 32'h56781234, 0);
        i_read(32'h8000, 16'h1234);
        i_read(32'h8002, 16'h5678);
        if (backend_accepts != n + 17 || backend_writes != 1)
            fail("instruction invalidation did not refill exactly one line");

        $display("PASS Cached SRAM: init, masks, halfwords, dual-port, collision, cache stall (backing=%0d writes=%0d)",
                 backend_accepts, backend_writes);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Cached SRAM test timeout");
    end
endmodule

`default_nettype wire
