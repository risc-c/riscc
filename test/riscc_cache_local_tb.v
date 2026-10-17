// Retained local classification, including idle captures and a stalled refill.
`default_nettype none
module riscc_cache_local_tb #(
    parameter integer REGISTER_LOOKUP = 0
);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg [29:0] c_addr = 4;
    reg c_cyc = 0, c_stb = 0;
    wire [31:0] c_rdata;
    wire [3:0] c_rsel;
    wire c_local, c_stall, c_ack;
    wire [29:0] m_addr;
    wire [3:0] m_sel;
    wire m_cyc, m_stb, m_we;
    reg m_stall = 1;
    wire m_ack = !rst && m_cyc && m_stb && !m_stall;
    wire [31:0] m_rdata = 32'h10000000 | {2'b0, m_addr};

    riscc_cached_cache #(
        .LOCAL_WORD_BITS(2), .REGISTER_LOOKUP(REGISTER_LOOKUP != 0)
    ) dut (
        .clk(clk), .rst(rst),
        .c_addr(c_addr), .c_wdata(32'b0), .c_sel(4'hf), .c_we(1'b0),
        .c_cyc(c_cyc), .c_stb(c_stb), .c_rdata(c_rdata), .c_rsel(c_rsel),
        .c_local(c_local), .c_stall(c_stall), .c_ack(c_ack), .store_posted(),
        .m_addr(m_addr), .m_wdata(), .m_sel(m_sel), .m_we(m_we),
        .m_cacheable(), .m_cyc(m_cyc), .m_stb(m_stb), .m_rdata(m_rdata),
        .m_stall(m_stall), .m_ack(m_ack), .inv_valid(1'b0), .inv_addr(30'b0)
    );

    reg metadata_known = 0;
    reg expected_local;
    integer idle_local = 0, idle_external = 0, held_changes = 0;
    integer local_requests = 0, responses = 0, backend_accepts = 0;
    integer epoch;

    // The classifier has no reset value. Only a non-reset free-slot capture
    // establishes an expectation, even when neither CYC nor STB is asserted.
    always @(posedge clk) begin
        if (rst) begin
            metadata_known = 0;
        end else begin
            if (!c_stall) begin
                expected_local = c_addr < 30'd4;
                metadata_known = 1;
                if (!c_cyc && !c_stb) begin
                    if (expected_local) idle_local = idle_local + 1;
                    else idle_external = idle_external + 1;
                end
                if (c_cyc && c_stb && c_addr == 3)
                    local_requests = local_requests + 1;
            end else if (metadata_known && expected_local != (c_addr < 30'd4)) begin
                held_changes = held_changes + 1;
            end
            if (c_ack) begin
                if (c_local !== 1'b0 || c_rdata !== 32'h10000004 || c_rsel !== 4'hf)
                    $fatal(1, "retained external response changed across local address input");
                responses = responses + 1;
            end
            if (m_ack) begin
                if (m_we || m_sel !== 4'hf ||
                    m_addr !== {27'b0, backend_accepts[2:0]})
                    $fatal(1, "refill command changed or extra backing request appeared");
                backend_accepts = backend_accepts + 1;
            end
        end
        #1;
        if (metadata_known && c_local !== expected_local)
            $fatal(1, "local classification capture/hold mismatch: got=%b expected=%b",
                   c_local, expected_local);
    end

    // Also catch a live-address classifier between capture edges.
    always @(negedge clk) begin
        #1;
        if (!rst && metadata_known && c_local !== expected_local)
            $fatal(1, "local classification followed live address before capture");
    end

    task automatic idle_capture(input [29:0] address);
        begin
            @(negedge clk);
            c_addr = address;
            c_cyc = 0;
            c_stb = 0;
            #2;
            if (c_stall) $fatal(1, "idle capture slot was not available");
            @(posedge clk); #2;
            if (c_local !== (address < 30'd4))
                $fatal(1, "idle payload was not classified");
            if (m_cyc || m_stb || c_ack)
                $fatal(1, "idle capture created a transaction");
        end
    endtask

    initial begin
        // The second reset starts with retained local metadata, then captures
        // an external idle address. Reset/CLEAR must not invent an expectation.
        for (epoch = 0; epoch < 2; epoch = epoch + 1) begin
            @(negedge clk);
            rst = 1;
            c_cyc = 0;
            c_stb = 0;
            c_addr = 4;
            m_stall = 1;
            repeat (3) @(negedge clk);
            rst = 0;
            while (c_stall) @(negedge clk);
            idle_capture(4);
            idle_capture(3);
            idle_capture(4);
            idle_capture(3);

            @(negedge clk);
            c_addr = 4;
            c_cyc = 1;
            c_stb = 1;
            #2;
            if (c_stall) $fatal(1, "external request was not accepted");
            @(posedge clk); #2;
            if (!c_stall || c_local !== 1'b0)
                $fatal(1, "cold external read did not retain a nonlocal request");

            @(negedge clk);
            c_addr = 3;
            c_cyc = 0;
            c_stb = 0;
            while (!(m_cyc && m_stb)) @(negedge clk);
            repeat (3) begin
                @(posedge clk); #2;
                if (!c_stall || c_local !== 1'b0 || !m_cyc || !m_stb)
                    $fatal(1, "local live address changed the stalled external request");
            end

            @(negedge clk);
            m_stall = 0;
            // Keep the local idle payload on the bus until the old response.
            while (!c_ack) @(negedge clk);
            if (c_stall || c_local !== 1'b0 || c_rdata !== 32'h10000004)
                $fatal(1, "refill did not return the retained external word");
            // Accept a local request on the external response edge. Its SRAM
            // response is outside this cache; it must not refill or cache-ACK.
            c_cyc = 1;
            c_stb = 1;
            @(posedge clk); #2;
            if (c_local !== 1'b1 || c_stall || c_ack || m_cyc || m_stb)
                $fatal(1, "local replacement was not captured after stall release");
            idle_capture(4);
            idle_capture(3);
        end
        if (idle_local < 6 || idle_external < 6 || held_changes < 6 ||
            local_requests != 2 || responses != 2 || backend_accepts != 16)
            $fatal(1, "missing coverage: idle=%0d/%0d held=%0d local=%0d replies=%0d beats=%0d",
                   idle_local, idle_external, held_changes, local_requests,
                   responses, backend_accepts);
        $display("PASS cache local classification REGISTER_LOOKUP=%0d idle_local=%0d idle_external=%0d held_changes=%0d local_requests=%0d responses=%0d beats=%0d resets=2",
                 REGISTER_LOOKUP, idle_local, idle_external, held_changes,
                 local_requests, responses, backend_accepts);
        $finish;
    end

    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "local classification test timeout");
    end
endmodule
`default_nettype wire
