`default_nettype none

module riscc_cache_tb #(
    parameter integer CACHE_READ_ONLY = 0,
    parameter integer CPU_BITS = 32,
    parameter integer HOLD_PAYLOAD = 0,
    parameter integer UNCACHED_BIT = 13,
    parameter integer LINE_WORD_BITS = 3
);
    localparam integer ADDR_BITS = 30;
    localparam integer MEM_WORDS = 16384;
    localparam integer LINE_WORDS = 1 << LINE_WORD_BITS;
    localparam [29:0] LAST_WORD_ADDR = (30'd1 << LINE_WORD_BITS) - 30'd1;
    localparam [31:0] LAST_WORD_VALUE =
        32'h10000000 + {2'b0, LAST_WORD_ADDR};
    localparam [31:0] LAST_WORD_HIGH = {16'b0, LAST_WORD_VALUE[31:16]};

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [ADDR_BITS-1:0] c_addr;
    reg [CPU_BITS-1:0] c_wdata;
    reg [3:0] c_sel;
    reg c_we, c_cyc, c_stb;
    wire [CPU_BITS-1:0] c_rdata;
    wire [3:0] c_rsel;
    wire c_stall, c_ack;

    wire [ADDR_BITS-1:0] m_addr;
    wire [31:0] m_wdata;
    wire [3:0] m_sel;
    wire m_we, m_cyc, m_stb;
    reg [31:0] m_rdata;
    reg m_stall, m_ack;
    reg inv_valid;
    reg [ADDR_BITS-1:0] inv_addr;

    reg [31:0] memory [0:MEM_WORDS-1];
    reg backend_pending;
    integer backend_delay;
    reg [ADDR_BITS-1:0] backend_addr;
    integer backend_accepts;
    integer backend_writes;
    integer expected_writes;
    integer cycle_count;
    integer stall_count;
    integer ack_stall_count;
    integer stall_release_count;
    reg stalled_last;
    reg [ADDR_BITS-1:0] stalled_addr;
    reg [31:0] stalled_wdata;
    reg [3:0] stalled_sel;
    reg stalled_we;
    reg stalled_cyc;
    reg stalled_stb;
    reg immediate_mode;
    reg rdata_hold_valid;
    reg [CPU_BITS-1:0] rdata_hold;
    reg uncached_check_pending;
    reg [ADDR_BITS-1:0] uncached_check_addr;
    reg [3:0] uncached_check_sel;
    reg uncached_check_we;
    reg [31:0] uncached_check_wdata;

    riscc_cached_cache #(.ADDR_BITS(ADDR_BITS),
                         .LINE_WORD_BITS(LINE_WORD_BITS),
                         .UNCACHED_BIT(UNCACHED_BIT),
                         .READ_ONLY(CACHE_READ_ONLY), .CPU_BITS(CPU_BITS),
                         .HOLD_PAYLOAD(HOLD_PAYLOAD)) dut (
        .clk(clk), .rst(rst),
        .c_addr(c_addr), .c_wdata(c_wdata), .c_sel(c_sel), .c_we(c_we),
        .c_cyc(c_cyc), .c_stb(c_stb), .c_rdata(c_rdata),
        .c_rsel(c_rsel), .c_stall(c_stall), .c_ack(c_ack),
        .m_addr(m_addr), .m_wdata(m_wdata), .m_sel(m_sel), .m_we(m_we),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_rdata(m_rdata),
        .m_stall(m_stall), .m_ack(m_ack),
        .inv_valid(inv_valid), .inv_addr(inv_addr)
    );

    wire m_accept = m_cyc && m_stb && !m_stall;
    wire c_accept = c_cyc && c_stb && !c_stall;
    reg c_response_pending;
    reg [3:0] c_response_sel;

    // c_rsel belongs to the oldest accepted CPU request.  Check it before
    // replacing that request on an ACK+accept edge; this catches accidental
    // use of the live c_sel input after a generic master changes its payload.
    always @(posedge clk) begin
        if (rst) begin
            c_response_pending <= 1'b0;
            c_response_sel <= 4'b0;
        end else begin
            if (c_response_pending && c_ack && c_rsel !== c_response_sel)
                $fatal(1, "response select changed: got %b expected %b",
                       c_rsel, c_response_sel);
            if (c_response_pending && c_ack)
                c_response_pending <= 1'b0;
            if (c_accept) begin
                c_response_pending <= 1'b1;
                c_response_sel <= c_sel;
            end
        end
    end
    wire c_uncached = (CACHE_READ_ONLY == 0) && (UNCACHED_BIT >= 0) &&
                      c_addr[UNCACHED_BIT];
    localparam [ADDR_BITS-1:0] POLICY_UNCACHED_ADDR =
        (UNCACHED_BIT >= 0) ? (30'd1 << UNCACHED_BIT) : 30'h00002000;
    localparam [ADDR_BITS-1:0] POLICY_CACHED_ADDR =
        (UNCACHED_BIT >= 0) ? ((30'd1 << UNCACHED_BIT) - 1'b1) : 30'h00001fff;
    localparam [ADDR_BITS-1:0] UNCACHED_ALIAS_ADDR =
        POLICY_UNCACHED_ADDR | 30'd3;
    localparam [ADDR_BITS-1:0] HIGH_TAG_ADDR =
        {1'b0, 1'b1, {(ADDR_BITS-2){1'b0}}};
    localparam [ADDR_BITS-1:0] HIGHEST_TAG_ADDR =
        {1'b1, {(ADDR_BITS-1){1'b0}}};
    localparam [31:0] HIGH_TAG_DATA = 32'hb17ecafe;

    function automatic [31:0] backend_word(input [ADDR_BITS-1:0] address);
        begin
            // Give the high cacheable byte address a distinct backing value
            // as well as a distinct full-width tag, so a truncated tag fails
            // both the traffic and data checks. The bit-31 byte address is
            // separately exercised through POLICY_UNCACHED_ADDR when the
            // actual default bypass bit is selected.
            if (address == UNCACHED_ALIAS_ADDR)
                backend_word = 32'hcafe5a3c;
            else if (address[ADDR_BITS-1] || address[ADDR_BITS-2])
                backend_word = HIGH_TAG_DATA;
            else
                backend_word = memory[address[13:0]];
        end
    endfunction
    integer i;
    always @* begin
        m_ack = backend_pending ||
                (immediate_mode && m_cyc && m_stb && !m_stall);
        m_rdata = immediate_mode ? backend_word(m_addr) :
                  backend_word(backend_addr);
        // Deterministic target backpressure exercises held refill commands.
        m_stall = (cycle_count > 40) && ((cycle_count % 7) == 2);
    end

    always @(posedge clk) begin
        // An accepted uncached command must be offered to the backing port
        // during the immediately following clock, even if the target stalls.
        // Capture the CPU command before generic-mode masters change their
        // payload after acceptance; read payloads are intentionally ignored.
        if (rst) begin
            uncached_check_pending <= 1'b0;
        end else begin
            if (uncached_check_pending) begin
                if (!m_cyc || !m_stb || m_addr !== uncached_check_addr ||
                    m_sel !== uncached_check_sel ||
                    m_we !== uncached_check_we ||
                    (uncached_check_we && (CACHE_READ_ONLY == 0) &&
                     m_wdata !== uncached_check_wdata))
                    $fatal(1, "uncached backend offer mismatch");
                uncached_check_pending <= 1'b0;
            end
            if (c_cyc && c_stb && !c_stall &&
                (c_uncached ||
                 (CACHE_READ_ONLY != 0 && c_we))) begin
                uncached_check_pending <= 1'b1;
                uncached_check_addr <= c_addr;
                uncached_check_sel <= c_sel;
                uncached_check_we <= c_we;
                uncached_check_wdata <= {{(32-CPU_BITS){1'b0}}, c_wdata};
            end
        end
        // Once a response has been presented, the cache keeps its data bus
        // stable while the master finishes the cycle.  Check that contract
        // until the next accepted CPU command.
        if (rst) begin
            rdata_hold_valid <= 1'b0;
        end else begin
            if (rdata_hold_valid && !(c_cyc && c_stb && !c_stall) &&
                c_rdata !== rdata_hold) begin
                $fatal(1, "CPU read data changed before next acceptance");
            end
            if (c_cyc && c_stb && !c_stall)
                rdata_hold_valid <= 1'b0;
            else if (c_ack) begin
                rdata_hold_valid <= 1'b1;
                rdata_hold <= c_rdata;
            end
        end
        cycle_count <= cycle_count + 1;
        // Compare against the command captured on the preceding stalled
        // cycle before looking at this cycle's STALL.  This also checks the
        // edge where STALL drops and the held command is accepted.
        if (stalled_last &&
            (m_addr != stalled_addr || m_wdata != stalled_wdata ||
             m_sel != stalled_sel || m_we != stalled_we ||
             !m_cyc || !m_stb))
            $fatal(1, "backend command changed while stalled");
        if (!immediate_mode && backend_delay != 0 && m_accept)
            $fatal(1, "backend accepted a second request while delayed");
        if (stalled_last && !(m_cyc && m_stb && m_stall))
            stall_release_count <= stall_release_count + 1;
        if (m_ack && m_stall)
            ack_stall_count <= ack_stall_count + 1;
        if (m_cyc && m_stb && m_stall) begin
            stalled_last <= 1'b1;
            stalled_addr <= m_addr;
            stalled_wdata <= m_wdata;
            stalled_sel <= m_sel;
            stalled_we <= m_we;
            stalled_cyc <= m_cyc;
            stalled_stb <= m_stb;
            stall_count <= stall_count + 1;
        end else begin
            stalled_last <= 1'b0;
        end

        if (immediate_mode) begin
            backend_pending <= 1'b0;
            if (m_accept) begin
                backend_addr <= m_addr;
                backend_accepts <= backend_accepts + 1;
                if (m_we) begin
                    if (m_sel[0]) memory[m_addr[13:0]][7:0] <= m_wdata[7:0];
                    if (m_sel[1]) memory[m_addr[13:0]][15:8] <= m_wdata[15:8];
                    if (m_sel[2]) memory[m_addr[13:0]][23:16] <= m_wdata[23:16];
                    if (m_sel[3]) memory[m_addr[13:0]][31:24] <= m_wdata[31:24];
                    backend_writes <= backend_writes + 1;
                end
            end
        end else if (backend_pending) begin
            backend_pending <= 1'b0;
            if (m_accept) begin
                // Leave a real response gap after a replacement acceptance.
                // This exercises the cache's one-outstanding-request state
                // independently of target STALL.
                backend_delay <= 2;
                backend_addr <= m_addr;
                backend_accepts <= backend_accepts + 1;
                if (m_we) begin
                    if (m_sel[0]) memory[m_addr[13:0]][7:0] <= m_wdata[7:0];
                    if (m_sel[1]) memory[m_addr[13:0]][15:8] <= m_wdata[15:8];
                    if (m_sel[2]) memory[m_addr[13:0]][23:16] <= m_wdata[23:16];
                    if (m_sel[3]) memory[m_addr[13:0]][31:24] <= m_wdata[31:24];
                    backend_writes <= backend_writes + 1;
                end
            end
        end else if (backend_delay != 0) begin
            if (backend_delay == 1) begin
                backend_pending <= 1'b1;
                backend_delay <= 0;
            end else
                backend_delay <= backend_delay - 1;
        end else if (m_accept) begin
            backend_delay <= 2;
            backend_addr <= m_addr;
            backend_accepts <= backend_accepts + 1;
            if (m_we) begin
                if (m_sel[0]) memory[m_addr[13:0]][7:0] <= m_wdata[7:0];
                if (m_sel[1]) memory[m_addr[13:0]][15:8] <= m_wdata[15:8];
                if (m_sel[2]) memory[m_addr[13:0]][23:16] <= m_wdata[23:16];
                if (m_sel[3]) memory[m_addr[13:0]][31:24] <= m_wdata[31:24];
                backend_writes <= backend_writes + 1;
            end
        end
    end

    task automatic cpu_read_sel(input [ADDR_BITS-1:0] address,
                                input [CPU_BITS-1:0] expected,
                                input [3:0] sel);
        integer accepted, accepts, responses, timeout;
        reg done;
        reg accept_now, ack_now;
        reg [CPU_BITS-1:0] ack_data;
        begin
            @(negedge clk);
            c_addr = address; c_wdata = 0; c_sel = sel; c_we = 0;
            c_cyc = 1; c_stb = 1;
            accepted = 0; accepts = 0; responses = 0; timeout = 0; done = 0;
            while (!done) begin
                // Sample handshake signals during the cycle before the edge.
                // In particular, do not sample STALL after the edge: reset
                // clear may have just exposed IDLE at that edge.
                accept_now = (accepted == 0) && !c_stall;
                ack_now = (accepted != 0) && c_ack;
                if (ack_now) ack_data = c_rdata;
                @(posedge clk); #1;
                timeout = timeout + 1;
                if (accept_now) begin
                    accepted = 1; accepts = accepts + 1; c_stb = 0;
                    // A generic pipelined master can change accepted payload.
                    // The private Execute port instead holds it through ACK.
                    if (HOLD_PAYLOAD == 0) begin
                        c_wdata = ~c_wdata;
                        c_we = !c_we;
                    end
                end
                if (ack_now) begin
                    responses = responses + 1;
                    if (ack_data !== expected)
                        $fatal(1, "read %h got %h expected %h", address,
                               ack_data, expected);
                    done = 1;
                end
                if (timeout > 500) $fatal(1, "read timeout at %h", address);
                if (!done) @(negedge clk);
            end
            if (accepts != 1 || responses != 1)
                $fatal(1, "read %h accepts=%0d responses=%0d", address,
                       accepts, responses);
            @(negedge clk); c_cyc = 0; c_stb = 0;
        end
    endtask

    task automatic cpu_read(input [ADDR_BITS-1:0] address,
                            input [31:0] expected);
        begin
            cpu_read_sel(address, expected[CPU_BITS-1:0],
                         (CPU_BITS == 16) ? 4'b0011 : 4'b1111);
        end
    endtask

    task automatic cpu_read_memory(input [ADDR_BITS-1:0] address);
        begin
            cpu_read(address, memory[address[13:0]]);
        end
    endtask

    task automatic cpu_read_backend(input [ADDR_BITS-1:0] address);
        begin
            cpu_read(address, backend_word(address));
        end
    endtask

    task automatic cpu_read_half(input [ADDR_BITS-1:0] address,
                                  input high_half,
                                  input [31:0] expected);
        begin
            cpu_read_sel(address, expected[CPU_BITS-1:0],
                         high_half ? 4'b1100 : 4'b0011);
        end
    endtask

    // Keep the tag write port busy at a different index while an uncached
    // reply aliases data RAM.  Release it on a fixed timer, independently of
    // the CPU response, so this also covers delayed backend replies.
    task automatic cpu_read_with_invalidation(input [ADDR_BITS-1:0] address,
                                              input [31:0] expected,
                                              input [3:0] sel);
        begin
            @(negedge clk);
            inv_addr = 30'd1 << LINE_WORD_BITS;
            inv_valid = 1;
            fork
                cpu_read_sel(address, expected[CPU_BITS-1:0], sel);
                begin
                    repeat (8) @(posedge clk);
                    @(negedge clk); inv_valid = 0;
                end
            join
        end
    endtask

    task automatic cpu_write(input [ADDR_BITS-1:0] address,
                             input [31:0] value, input [3:0] sel);
        integer accepted, accepts, responses, timeout;
        reg done;
        reg accept_now, ack_now;
        begin
            @(negedge clk);
            c_addr = address; c_wdata = value[CPU_BITS-1:0]; c_sel = sel;
            c_we = 1; c_cyc = 1; c_stb = 1;
            accepted = 0; accepts = 0; responses = 0; timeout = 0; done = 0;
            while (!done) begin
                accept_now = (accepted == 0) && !c_stall;
                ack_now = (accepted != 0) && c_ack;
                @(posedge clk); #1;
                timeout = timeout + 1;
                if (accept_now) begin
                    accepted = 1; accepts = accepts + 1; c_stb = 0;
                    // A generic pipelined master can change accepted payload.
                    // The private Execute port instead holds it through ACK.
                    if (HOLD_PAYLOAD == 0) begin
                        c_wdata = ~c_wdata;
                        c_we = !c_we;
                    end
                end
                if (ack_now) begin
                    responses = responses + 1; done = 1;
                end
                if (timeout > 500) $fatal(1, "write timeout at %h", address);
                if (!done) @(negedge clk);
            end
            if (accepts != 1 || responses != 1)
                $fatal(1, "write %h accepts=%0d responses=%0d", address,
                       accepts, responses);
            @(negedge clk); c_cyc = 0; c_stb = 0;
        end
    endtask

    task automatic cpu_read_burst;
        integer accepted, responses, timeout, burst_edges;
        integer max_edges;
        reg done;
        reg accept_now, ack_now;
        reg [CPU_BITS-1:0] ack_data;
        reg [31:0] expected_word;
        begin
            @(negedge clk);
            c_addr = 0; c_wdata = 0;
            c_sel = (CPU_BITS == 16) ? 4'b0011 : 4'b1111;
            c_we = 0; c_cyc = 1; c_stb = 1;
            accepted = 0; responses = 0; timeout = 0;
            burst_edges = 0; done = 0;
            max_edges = (CACHE_READ_ONLY != 0) ? 9 : 16;
            while (!done) begin
                accept_now = (accepted < 8) && c_stb && !c_stall;
                ack_now = (responses < 8) && c_ack;
                if (ack_now) ack_data = c_rdata;
                @(posedge clk); #1;
                timeout = timeout + 1;
                burst_edges = burst_edges + 1;
                if (burst_edges > max_edges)
                    $fatal(1, "hit burst exceeded %0d edges", max_edges);
                if (CACHE_READ_ONLY != 0) begin
                    if (burst_edges <= 8 && !accept_now)
                        $fatal(1, "I hit burst acceptance gap at edge %0d", burst_edges);
                    if (burst_edges >= 2 && !ack_now)
                        $fatal(1, "I hit burst response gap at edge %0d", burst_edges);
                    if (burst_edges == 1 && ack_now)
                        $fatal(1, "I hit burst responded before first acceptance");
                    if (burst_edges == 9 && accept_now)
                        $fatal(1, "I hit burst accepted after eighth command");
                end else begin
                    // RW data cache lookup keeps c_stall asserted while its
                    // one-cycle hit ACK is presented.  The master therefore
                    // alternates acceptance and response: 16 edges for eight
                    // requests, with no simultaneous replacement.
                    if ((burst_edges & 1) != 0) begin
                        if (!accept_now || ack_now)
                            $fatal(1, "D hit burst expected accept at edge %0d", burst_edges);
                    end else if (!ack_now || accept_now) begin
                        $fatal(1, "D hit burst expected response at edge %0d", burst_edges);
                    end
                end
                if (accept_now) begin
                    accepted = accepted + 1;
                    if (CACHE_READ_ONLY != 0) begin
                        if (accepted < 8) begin
                            c_addr = accepted[ADDR_BITS-1:0];
                            c_stb = 1;
                        end else c_stb = 0;
                    end else begin
                        c_stb = 0;
                    end
                end
                if (ack_now) begin
                    expected_word = (CPU_BITS == 16) ?
                                    {16'b0, responses[15:0]} :
                                    (32'h10000000 + responses);
                    if (ack_data !== expected_word[CPU_BITS-1:0])
                        $fatal(1, "burst word %0d got %h", responses, ack_data);
                    responses = responses + 1;
                    if (CACHE_READ_ONLY == 0 && accepted < 8) begin
                        c_addr = accepted[ADDR_BITS-1:0];
                        c_stb = 1;
                    end
                end
                if (accepted == 8 && responses == 8) done = 1;
                if (timeout > 500) $fatal(1, "burst timeout");
                if (!done) @(negedge clk);
            end
            @(negedge clk); c_cyc = 0; c_stb = 0;
        end
    endtask

    task automatic check_address_policy;
        integer prior_accepts;
        begin
            // A selected address bit makes a data request uncached. The
            // fixture uses word bit 13 (byte addresses 0x8000..0xffff),
            // while the actual default uses word bit 29 (byte bit 31).
            // Read-only caches always take the all-cached path.
            if (CACHE_READ_ONLY != 0) begin
                prior_accepts = backend_accepts;
                cpu_read_backend(POLICY_UNCACHED_ADDR);
                if (backend_accepts != prior_accepts + LINE_WORDS)
                    $fatal(1, "read-only address did not fill cache");
                prior_accepts = backend_accepts;
                cpu_read_backend(POLICY_UNCACHED_ADDR);
                if (backend_accepts != prior_accepts)
                    $fatal(1, "read-only address missed after fill");
            end else begin
                prior_accepts = backend_accepts;
                cpu_read_backend(POLICY_UNCACHED_ADDR);
                if (backend_accepts != prior_accepts + 1)
                    $fatal(1, "configured uncached address allocated");
                prior_accepts = backend_accepts;
                cpu_read_backend(POLICY_UNCACHED_ADDR);
                if (backend_accepts != prior_accepts + 1)
                    $fatal(1, "configured uncached address was cached");
            end

            prior_accepts = backend_accepts;
            cpu_read_backend(POLICY_CACHED_ADDR);
            if (backend_accepts != prior_accepts + LINE_WORDS)
                $fatal(1, "address with bypass bit clear did not fill");
            prior_accepts = backend_accepts;
            cpu_read_backend(POLICY_CACHED_ADDR);
            if (backend_accepts != prior_accepts)
                $fatal(1, "address with bypass bit clear was not cached");

            // A high cacheable byte address maps to the same index as address
            // zero but must not alias its full-width tag.
            prior_accepts = backend_accepts;
            cpu_read(HIGH_TAG_ADDR, HIGH_TAG_DATA);
            if (backend_accepts != prior_accepts + LINE_WORDS)
                $fatal(1, "high-address tag aliased low address");
            prior_accepts = backend_accepts;
            cpu_read_memory(0);
            if (backend_accepts != prior_accepts + LINE_WORDS)
                $fatal(1, "low address retained high-address tag");

            // Read-only instruction caches also cache the top byte-address
            // bit, which is the RW data-cache bypass bit in the default build.
            if (CACHE_READ_ONLY != 0) begin
                prior_accepts = backend_accepts;
                cpu_read(HIGHEST_TAG_ADDR, HIGH_TAG_DATA);
                if (backend_accepts != prior_accepts + LINE_WORDS)
                    $fatal(1, "top address tag aliased low address");
                prior_accepts = backend_accepts;
                cpu_read_memory(0);
                if (backend_accepts != prior_accepts + LINE_WORDS)
                    $fatal(1, "low address retained top address tag");
            end
        end
    endtask

    initial begin
        c_addr = 0; c_wdata = 0; c_sel = 0; c_we = 0; c_cyc = 0; c_stb = 0;
        inv_valid = 0; inv_addr = 0; backend_pending = 0; backend_delay = 0;
        backend_addr = 0;
        backend_accepts = 0; backend_writes = 0; expected_writes = 0;
        cycle_count = 0; stall_count = 0; ack_stall_count = 0;
        stall_release_count = 0; stalled_last = 0;
        rdata_hold_valid = 0; rdata_hold = 0;
        uncached_check_pending = 0; uncached_check_addr = 0;
        uncached_check_sel = 0; uncached_check_we = 0;
        uncached_check_wdata = 0;
        immediate_mode = $test$plusargs("IMMEDIATE");
        for (i = 0; i < MEM_WORDS; i = i + 1) memory[i] = 32'h10000000 + i;
        // Both halves contain distinct values for 16-bit read checks.
        repeat (3) @(posedge clk);
        rst = 0;
        if (CPU_BITS == 16) begin
            // The instruction-cache specialization returns either half of a
            // 32-bit backing word, selected by the Wishbone byte lanes.
            cpu_read_half(30'd0, 0, 32'h00000000);
            if (backend_accepts != LINE_WORDS) $fatal(1, "rc16 fill accepted %0d beats", backend_accepts);
            i = backend_accepts;
            cpu_read_half(LAST_WORD_ADDR, 0, LAST_WORD_VALUE);
            cpu_read_half(LAST_WORD_ADDR, 1, LAST_WORD_HIGH);
            if (backend_accepts != i) $fatal(1, "rc16 last-word hit accessed backing memory");
            cpu_read_half(30'd0, 1, 32'h00001000);
            if (backend_accepts != LINE_WORDS) $fatal(1, "rc16 high hit accessed backing memory");
            cpu_read_half(30'd1, 0, 32'h00000001);
            cpu_read_half(30'd1, 1, 32'h00001000);

            // An uncached word can alias a currently valid cached data-RAM
            // entry.  Check both returned halves, then all words around the
            // aliased cached entry, regardless of whether the line is kept.
            if ((CACHE_READ_ONLY == 0) && (UNCACHED_BIT >= 0)) begin
                cpu_read_with_invalidation(UNCACHED_ALIAS_ADDR, 32'h00005a3c, 4'b0011);
                cpu_read_with_invalidation(UNCACHED_ALIAS_ADDR, 32'h0000cafe, 4'b1100);
            end
            cpu_read_half(30'd3, 0, 32'h00000003);
            cpu_read_half(30'd3, 1, 32'h00001000);
            cpu_read_half(30'd0, 0, 32'h00000000);
            cpu_read_half(30'd7, 1, 32'h00001000);

            rst = 1; repeat (2) @(posedge clk); rst = 0;
            i = backend_accepts;
            cpu_read_half(30'd0, 1, 32'h00001000);
            if (backend_accepts != i + LINE_WORDS) $fatal(1, "rc16 reset retained line");
            i = backend_accepts;
            cpu_read(30'd512, 32'h00000200);
            if (backend_accepts != i + LINE_WORDS) $fatal(1, "rc16 conflict fill missing");
        end else begin
            // First access misses and fills LINE_WORDS words.  Subsequent
            // words in the line must hit without any backing request.
            cpu_read(30'd0, 32'h10000000);
            if (backend_accepts != LINE_WORDS) $fatal(1, "fill accepted %0d beats", backend_accepts);
            i = backend_accepts;
            cpu_read(LAST_WORD_ADDR, LAST_WORD_VALUE);
            if (backend_accepts != i) $fatal(1, "last-word hit accessed backing memory");
            cpu_read(30'd1, 32'h10000001);
            if (backend_accepts != LINE_WORDS) $fatal(1, "hit accessed backing memory");
            cpu_read(30'd7, 32'h10000007);

            // Reset must invalidate the line.  Read-only I-cache hits issue
            // one word per response edge; RW D-cache hits alternate acceptance
            // and response, with no backing accesses in either case.
            rst = 1; repeat (2) @(posedge clk); rst = 0;
            i = backend_accepts;
            cpu_read(30'd0, 32'h10000000);
            if (backend_accepts != i + LINE_WORDS) $fatal(1, "reset retained cache line");
            i = backend_accepts;
            cpu_read_burst();
            if (backend_accepts != i) $fatal(1, "hit burst used backing memory");

            // An uncached word aliases data-RAM entry three while line zero
            // is valid.  Preserve correctness whether that line is kept or
            // invalidated by the uncached response.
            if ((CACHE_READ_ONLY == 0) && (UNCACHED_BIT >= 0))
                cpu_read_with_invalidation(UNCACHED_ALIAS_ADDR, 32'hcafe5a3c, 4'b1111);
            cpu_read(30'd3, memory[3]);
            cpu_read(30'd0, memory[0]);
            cpu_read(30'd7, memory[7]);

            // Lines 0 and 512 map to the same direct-mapped index.
            i = backend_accepts;
            cpu_read(30'd512, memory[512]);
            if (backend_accepts != i + LINE_WORDS) $fatal(1, "conflict fill missing");
            i = backend_accepts;
            cpu_read(30'd0, memory[0]);
            if (backend_accepts != i + LINE_WORDS) $fatal(1, "conflict eviction missing");

            // Invalidate the active line during refill.  The sticky
            // invalidate guard forces a retry before the line is usable.
            i = backend_accepts;
            fork
                cpu_read(30'd1024, memory[1024]);
                begin
                    wait (backend_accepts >= i + 1);
                    @(negedge clk); inv_addr = 30'd1024; inv_valid = 1;
                    @(negedge clk); inv_valid = 0;
                end
            join
            if (backend_accepts < i + (2 * LINE_WORDS))
                $fatal(1, "invalidation during refill revived line");

            // Partial write hit updates the cache and backing word exactly once.
            if (CACHE_READ_ONLY == 0) begin
                cpu_write(30'd1, 32'hdeadbeef, 4'b0010);
                if (backend_writes != 1) $fatal(1, "write-through count %0d", backend_writes);
                cpu_read(30'd1, 32'h1000be01);
                if (memory[1] !== 32'h1000be01) $fatal(1, "write-through data mismatch");
            end

            // Store miss bypasses without allocating; a subsequent read refills.
            if (CACHE_READ_ONLY == 0) begin
                cpu_write(30'd16, 32'hcafebabe, 4'b1111);
                if (backend_writes != 2) $fatal(1, "store miss did not bypass");
                cpu_read(30'd16, 32'hcafebabe);
                if (backend_accepts < (2 * LINE_WORDS + 2)) $fatal(1, "store miss allocated unexpectedly");
            end

        end
        check_address_policy();
        if (stall_count == 0) $fatal(1, "no delayed backend stalls exercised");
        if (!immediate_mode && ack_stall_count == 0)
            $fatal(1, "registered backend never produced ACK+STALL");
        if (stall_release_count == 0)
            $fatal(1, "backend STALL never released a held command");
        $display("PASS riscc_cache accepts=%0d writes=%0d stalls=%0d ack_stall=%0d stall_release=%0d",
                 backend_accepts, backend_writes, stall_count,
                 ack_stall_count, stall_release_count);
        $finish;
    end
endmodule

`default_nettype wire
