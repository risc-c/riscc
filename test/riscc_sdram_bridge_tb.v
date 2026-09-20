// Clock-crossing test for the standalone SDRAM bring-up bridge.
//
// The host and memory clocks are intentionally unrelated.  The memory-side
// model applies deterministic pre-accept stalls and either same-cycle or
// delayed acknowledgements.  A sparse byte-addressed shadow checks every
// write and read, while the assertions below check the bridge handshake and
// payload stability directly.
`timescale 1ns/1ps
`default_nettype none

module riscc_sdram_bridge_tb #(
    parameter integer ADDR_BITS = 23,
    parameter realtime HOST_PERIOD_NS = 10.0,
    parameter realtime MEMORY_PERIOD_NS = 6.0,
    parameter integer READY_DELAY = 3,
    parameter integer REQUEST_COUNT = 96
);
    reg host_clk = 1'b0;
    reg memory_clk = 1'b0;
    always #(HOST_PERIOD_NS / 2.0) host_clk = ~host_clk;
    always #(MEMORY_PERIOD_NS / 2.0) memory_clk = ~memory_clk;

    reg reset_request = 1'b1;
    reg host_rst = 1'b1;
    reg memory_rst = 1'b1;
    always @(posedge host_clk) host_rst <= reset_request;
    always @(posedge memory_clk) memory_rst <= reset_request;

    reg [ADDR_BITS-1:0] host_addr = 0;
    reg [31:0] host_wdata = 0;
    reg [3:0] host_wmask = 0;
    reg host_we = 0, host_cyc = 0, host_stb = 0;
    wire host_stall, host_ready;
    wire host_ack;
    wire [31:0] host_rdata;

    wire [ADDR_BITS-1:0] memory_addr;
    wire [31:0] memory_wdata;
    wire [3:0] memory_wmask;
    wire memory_we, memory_cyc, memory_stb;
    wire memory_stall, memory_ack, memory_ready;
    wire [31:0] memory_rdata;

    riscc_sdram_bridge #(.ADDR_BITS(ADDR_BITS)) dut (
        .host_clk(host_clk), .host_rst(host_rst),
        .memory_clk(memory_clk), .memory_rst(memory_rst),
        .host_addr(host_addr), .host_wdata(host_wdata),
        .host_wmask(host_wmask), .host_we(host_we),
        .host_cyc(host_cyc), .host_stb(host_stb),
        .host_stall(host_stall), .host_ready(host_ready),
        .host_ack(host_ack), .host_rdata(host_rdata),
        .memory_addr(memory_addr), .memory_wdata(memory_wdata),
        .memory_wmask(memory_wmask), .memory_we(memory_we),
        .memory_cyc(memory_cyc), .memory_stb(memory_stb),
        .memory_stall(memory_stall), .memory_ack(memory_ack),
        .memory_ready(memory_ready), .memory_rdata(memory_rdata)
    );

    localparam integer SHADOW_WORDS = 256;
    reg [31:0] shadow_mem [0:SHADOW_WORDS-1];
    reg ready_q = 1'b0;
    integer ready_count_q = 0;
    reg memory_active_q = 1'b0;
    reg pre_stall_seen_q = 1'b0;
    integer pre_stall_left_q = 0;
    integer ack_wait_q = 0;
    reg [31:0] response_q = 0;
    reg [ADDR_BITS-1:0] active_addr_q = 0;
    reg [31:0] active_wdata_q = 0;
    reg [3:0] active_wmask_q = 0;
    reg active_we_q = 0;
    reg force_memory_stall = 1'b0;
    integer memory_cycle_count = 0;
    integer destination_accept_count = 0;
    integer destination_ack_count = 0;
    integer memory_stall_count = 0;
    integer payload_error_count = 0;
    integer lane;

    function automatic integer shadow_index(input [ADDR_BITS-1:0] address);
        shadow_index = address[9:2];
    endfunction

    function automatic [31:0] shadow_read(input [ADDR_BITS-1:0] address);
        shadow_read = shadow_mem[shadow_index(address)];
    endfunction

    function automatic [31:0] merged_write(
        input [31:0] old_value, input [31:0] write_value,
        input [3:0] byte_mask);
        reg [31:0] merged;
        integer byte_lane;
        begin
            merged = old_value;
            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                if (byte_mask[byte_lane])
                    merged[byte_lane*8 +: 8] = write_value[byte_lane*8 +: 8];
            merged_write = merged;
        end
    endfunction

    // Address bits select the stress mode.  These are stable while the
    // bridge holds memory_stb high, so the generated stall is repeatable.
    wire request_bus = memory_cyc && memory_stb;
    wire pre_stall_selected = (memory_addr[4:2] == 3'b001) ||
                              (memory_addr[4:2] == 3'b110);
    wire immediate_selected = memory_addr[7] || (memory_addr[5:3] == 3'b011);
    wire pre_stall_active = !memory_active_q && request_bus &&
                            pre_stall_selected &&
                            (!pre_stall_seen_q || pre_stall_left_q != 0);
    wire immediate_ack = !memory_active_q && request_bus &&
                         !force_memory_stall && !pre_stall_active &&
                         immediate_selected;
    assign memory_stall = !memory_rst &&
                          (force_memory_stall || pre_stall_active);
    assign memory_ack = !memory_rst &&
                        (immediate_ack ||
                         (memory_active_q && !memory_stb && ack_wait_q == 0));
    assign memory_ready = ready_q && !memory_rst;
    assign memory_rdata = immediate_ack ?
                          (memory_we ? 32'b0 : shadow_read(memory_addr)) :
                          response_q;

    // Memory-side transaction model.  The destination acceptance event is
    // the only point where writes become visible in the shadow memory.
    always @(posedge memory_clk) begin
        memory_cycle_count = memory_cycle_count + 1;
        if (memory_rst) begin
            ready_q <= 1'b0;
            ready_count_q <= 0;
            memory_active_q <= 1'b0;
            pre_stall_seen_q <= 1'b0;
            pre_stall_left_q <= 0;
            ack_wait_q <= 0;
            response_q <= 0;
        end else begin
            if (!ready_q) begin
                if (ready_count_q >= READY_DELAY)
                    ready_q <= 1'b1;
                else
                    ready_count_q <= ready_count_q + 1;
            end

            if (memory_stall)
                memory_stall_count = memory_stall_count + 1;

            if (!request_bus) begin
                pre_stall_seen_q <= 1'b0;
                pre_stall_left_q <= 0;
            end else if (!memory_active_q && pre_stall_selected) begin
                if (!pre_stall_seen_q) begin
                    pre_stall_seen_q <= 1'b1;
                    pre_stall_left_q <= 2;
                end else if (pre_stall_left_q != 0) begin
                    pre_stall_left_q <= pre_stall_left_q - 1;
                end
            end

            if (!memory_active_q && request_bus && !memory_stall) begin
                destination_accept_count = destination_accept_count + 1;
                active_addr_q <= memory_addr;
                active_wdata_q <= memory_wdata;
                active_wmask_q <= memory_wmask;
                active_we_q <= memory_we;
                if (memory_we)
                    shadow_mem[shadow_index(memory_addr)] <=
                        merged_write(shadow_read(memory_addr), memory_wdata,
                                     memory_wmask);
                response_q <= memory_we ? 32'b0 : shadow_read(memory_addr);
                if (immediate_ack) begin
                    destination_ack_count = destination_ack_count + 1;
                    memory_active_q <= 1'b0;
                    ack_wait_q <= 0;
                end else begin
                    memory_active_q <= 1'b1;
                    // Delayed acknowledgements cover one through four
                    // memory clocks, selected independently per request.
                    ack_wait_q <= 1 + memory_addr[6:5];
                end
            end else if (memory_active_q) begin
                if (memory_stb && memory_stall) begin
                    if (memory_addr !== active_addr_q ||
                        memory_wdata !== active_wdata_q ||
                        memory_wmask !== active_wmask_q ||
                        memory_we !== active_we_q) begin
                        payload_error_count = payload_error_count + 1;
                        $display("FAIL bridge payload changed while stalled");
                        $fatal(1, "memory payload was not stable");
                    end
                end
                if (ack_wait_q != 0)
                    ack_wait_q <= ack_wait_q - 1;
                if (memory_ack && (!memory_stb || !memory_stall)) begin
                    destination_ack_count = destination_ack_count + 1;
                    memory_active_q <= 1'b0;
                end
            end
        end
    end

    // Host-side protocol counters and payload stability checks.
    integer host_accept_count = 0;
    integer host_ack_count = 0;
    integer host_stall_count = 0;
    integer cancelled_request_count = 0;
    reg host_payload_held = 1'b0;
    reg [ADDR_BITS-1:0] held_addr;
    reg [31:0] held_wdata;
    reg [3:0] held_wmask;
    reg held_we;
    always @(posedge host_clk) begin
        if (!host_rst && host_cyc && host_stb && host_stall) begin
            host_stall_count = host_stall_count + 1;
            if (host_payload_held && (host_addr !== held_addr ||
                                       host_wdata !== held_wdata ||
                                       host_wmask !== held_wmask ||
                                       host_we !== held_we)) begin
                $display("FAIL bridge host payload changed while stalled");
                $fatal(1, "host payload was not stable");
            end
        end
        if (!host_rst && host_cyc && host_stb && !host_stall) begin
            host_accept_count = host_accept_count + 1;
            host_payload_held <= 1'b0;
        end
        if (!host_rst && host_ack)
            host_ack_count = host_ack_count + 1;
        if (host_rst)
            host_payload_held <= 1'b0;
        else if (!(host_cyc && host_stb))
            host_payload_held <= 1'b0;
        else if (host_cyc && host_stb && !host_payload_held) begin
            host_payload_held <= 1'b1;
            held_addr <= host_addr;
            held_wdata <= host_wdata;
            held_wmask <= host_wmask;
            held_we <= host_we;
        end
    end

    integer error_count = 0;
    integer request_number;
    reg [31:0] rng_state = 32'hc001d00d;
    reg [ADDR_BITS-1:0] request_addr;
    reg [31:0] request_data;
    reg [3:0] request_mask;
    reg request_write;
    reg [31:0] expected_data;
    reg [31:0] old_data;

    task automatic fail(input [8*160-1:0] message);
        begin
            error_count = error_count + 1;
            $display("FAIL BRIDGE cycle=%0d: %0s", memory_cycle_count, message);
            $fatal(1, "SDRAM bridge test failed");
        end
    endtask

    task automatic next_random(output [31:0] value_out);
        begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 17);
            rng_state = rng_state ^ (rng_state << 5);
            value_out = rng_state;
        end
    endtask

    task automatic wait_host_ready;
        integer guard;
        begin
            guard = 0;
            while (!host_ready) begin
                @(negedge host_clk);
                guard = guard + 1;
                if (guard > 1000) fail("host_ready timeout");
            end
        end
    endtask

    task automatic host_request(
        input [ADDR_BITS-1:0] address, input [31:0] write_value,
        input [3:0] byte_mask, input write_enable,
        input [31:0] expected_read, input check_read);
        integer guard;
        reg accepted;
        begin
            wait_host_ready();
            @(negedge host_clk);
            host_addr = address;
            host_wdata = write_value;
            host_wmask = byte_mask;
            host_we = write_enable;
            host_cyc = 1'b1;
            host_stb = 1'b1;
            accepted = 1'b0;
            guard = 0;
            while (!accepted) begin
                @(posedge host_clk);
                if (!host_stall)
                    accepted = 1'b1;
                guard = guard + 1;
                if (guard > 1000) fail("host request acceptance timeout");
            end
            @(negedge host_clk);
            host_stb = 1'b0;
            host_cyc = 1'b0;
            guard = 0;
            accepted = 1'b0;
            while (!accepted) begin
                if (host_ack) begin
                    if (check_read && host_rdata !== expected_read)
                        fail("host read data mismatch");
                    accepted = 1'b1;
                end
                guard = guard + 1;
                if (guard > 1000) fail("host acknowledgement timeout");
                if (!accepted) @(negedge host_clk);
            end
        end
    endtask

    task automatic cancel_pending_request;
        reg accepted;
        integer guard;
        integer destination_before;
        begin
            wait_host_ready();
            @(negedge host_clk);
            host_addr = 23'h104;
            host_wdata = 32'hcafe1234;
            host_wmask = 4'hf;
            host_we = 1'b0;
            host_cyc = 1'b1;
            host_stb = 1'b1;
            accepted = 1'b0;
            guard = 0;
            while (!accepted) begin
                @(posedge host_clk);
                if (!host_stall) accepted = 1'b1;
                guard = guard + 1;
                if (guard > 1000) fail("pending request acceptance timeout");
            end
            while (!(memory_cyc && memory_stb)) begin
                @(negedge memory_clk);
                guard = guard + 1;
                if (guard > 1000) fail("pending memory request timeout");
            end
            destination_before = destination_accept_count;
            force_memory_stall = 1'b1;
            repeat (2) @(posedge memory_clk);
            // Remove the host request before reset release so it cannot be
            // accepted again after the bridge state is reinitialized.
            @(negedge host_clk);
            host_cyc = 1'b0;
            host_stb = 1'b0;
            reset_request = 1'b1;
            repeat (4) @(posedge host_clk);
            repeat (4) @(posedge memory_clk);
            force_memory_stall = 1'b0;
            reset_request = 1'b0;
            repeat (6) @(posedge host_clk);
            if (host_ack)
                fail("cancelled request produced an acknowledgement");
            if (destination_accept_count != destination_before)
                fail("cancelled request reached the destination");
            cancelled_request_count = cancelled_request_count + 1;
        end
    endtask

    integer i;
    integer byte_index;
    initial begin
        if (!$value$plusargs("SEED=%d", rng_state))
            rng_state = 32'hc001d00d;
        for (i = 0; i < SHADOW_WORDS; i = i + 1)
            shadow_mem[i] = 32'b0;

        // Synchronous release in both domains after the initial reset.
        repeat (8) @(posedge host_clk);
        reset_request = 1'b0;
        wait_host_ready();

        for (request_number = 0; request_number < REQUEST_COUNT;
             request_number = request_number + 1) begin
            next_random(request_data);
            request_addr = (rng_state & 23'h000003fc);
            request_mask = rng_state[3:0];
            if ((request_number % 13) == 0) request_mask = 4'h0;
            if ((request_number % 17) == 0) request_mask = 4'hf;
            request_write = rng_state[8];
            old_data = shadow_read(request_addr);
            expected_data = old_data;
            if (request_write)
                expected_data = merged_write(old_data, request_data,
                                             request_mask);
            host_request(request_addr, request_data, request_mask,
                         request_write, old_data, !request_write);
            // Posted writes acknowledge before the destination sees them.
            while (dut.busy_q) @(negedge host_clk);
            // The memory-side model updates the shadow at destination
            // acceptance; verify the write became visible before continuing.
            if (request_write && shadow_read(request_addr) !== expected_data)
                fail("masked write did not update shadow memory");
        end

        cancel_pending_request();

        // Clean post-reset traffic proves that both toggle domains restart
        // from the same phase and that a cancelled request is not replayed.
        for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
            request_addr = 23'h200 + (byte_index << 2);
            request_data = 32'h13570000 | byte_index;
            request_mask = (byte_index[1:0] == 0) ? 4'hf : 4'b0101;
            old_data = shadow_read(request_addr);
            expected_data = merged_write(old_data, request_data, request_mask);
            host_request(request_addr, request_data, request_mask, 1'b1,
                         0, 1'b0);
            while (dut.busy_q) @(negedge host_clk);
            if (shadow_read(request_addr) !== expected_data)
                fail("post-reset write mismatch");
            host_request(request_addr, 0, 0, 1'b0, expected_data, 1'b1);
        end

        // The DUT drives host_ack with a nonblocking assignment on the host
        // edge.  Let the counter process observe the final one-cycle pulse
        // before checking the totals.
        @(posedge host_clk);
        @(negedge host_clk);
        if (host_accept_count != host_ack_count + cancelled_request_count) begin
            $display("BRIDGE COUNTS host_accept=%0d host_ack=%0d destination_accept=%0d destination_ack=%0d cancelled=%0d",
                     host_accept_count, host_ack_count, destination_accept_count,
                     destination_ack_count, cancelled_request_count);
            fail("host acceptance/acknowledgement count mismatch");
        end
        if (destination_accept_count != destination_ack_count)
            fail("destination acceptance/acknowledgement count mismatch");
        if (host_accept_count != destination_accept_count + cancelled_request_count)
            fail("host/destination request count mismatch");
        if (host_stall_count == 0 || memory_stall_count == 0)
            fail("stall coverage missing");
        if (payload_error_count != 0)
            fail("payload stability coverage failed");
        $display("PASS BRIDGE host_accept=%0d host_ack=%0d destination_accept=%0d destination_ack=%0d host_stalls=%0d memory_stalls=%0d cycles=%0d",
                 host_accept_count, host_ack_count, destination_accept_count,
                 destination_ack_count, host_stall_count, memory_stall_count,
                 memory_cycle_count);
        $finish;
    end
endmodule

`default_nettype wire
