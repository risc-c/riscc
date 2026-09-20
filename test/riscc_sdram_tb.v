// Command-level SDRAM controller integration and protocol test.
//
// The SDRAM model runs from the inverted controller clock.  The bus driver
// deliberately keeps requests queued while the controller is busy, then
// drops STB before the response for single requests so that responses cannot
// be mistaken for a second acceptance.
`timescale 1ns/1ps
`default_nettype none

module riscc_sdram_tb #(
    parameter integer DATA_BITS = 16,
    parameter integer ROW_BITS = 13,
    parameter integer COL_BITS = 9,
    parameter integer CLK_MHZ = 50,
    // Keep the integer clock rate for the controller's cycle-based timing
    // calculations, while allowing simulation to use the exact board period
    // (for example 6.0 ns for a 166.667 MHz clock).
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
    // Model a native SDRAM output register between the controller and the
    // package pins.  The register samples the controller outputs on the
    // same rising edge, so the external pins see the preceding cycle's
    // values, matching an additional positive-edge I/O stage in hardware.
    parameter integer PIN_PIPELINE = 0,
    parameter integer FIFO_BITS = 3,
    parameter integer MAX_REFRESH_GAP = REFRESH_CYCLES + 32,
    parameter realtime T_AC = 6.0,
    // Device-clock rising edge after the controller's rising edge.  The
    // default is the existing inverted-clock relationship (180 degrees).
    // A fractional value models the forwarded-clock phase and board delay.
    parameter realtime DEVICE_CLK_PHASE_NS = CLOCK_PERIOD_NS / 2.0
);
    localparam integer HALF = DATA_BITS == 16 ? 1 : 0;
    localparam integer ADDR_BITS = ROW_BITS + COL_BITS + 2 - HALF;
    localparam integer BYTE_BITS = DATA_BITS / 8;
    localparam integer SHADOW_SLOTS = 2048;
    localparam integer MAX_RESPONSES = 8192;
    localparam integer MAX_BURST = 128;

    reg clk = 1'b0;
    reg rst = 1'b1;
    // The model observes a device clock whose rising edge is phase-shifted
    // from the controller edge.  The default reproduces ~clk exactly; a
    // fractional phase models the PLL/forwarded-clock relationship used by
    // the board-level SDRAM interface.
    always #(CLOCK_PERIOD_NS / 2.0) clk = ~clk;
    reg sd_clk = 1'b0;
    initial begin
        #(CLOCK_PERIOD_NS / 2.0 + DEVICE_CLK_PHASE_NS);
        sd_clk = 1'b1;
        forever begin
            #(CLOCK_PERIOD_NS / 2.0);
            sd_clk = ~sd_clk;
        end
    end

    reg [ADDR_BITS-1:0] mem_addr = 0;
    reg [31:0] mem_wdata = 0;
    reg [3:0] mem_wmask = 0;
    reg mem_we = 0, mem_cyc = 0, mem_stb = 0;
    wire mem_stall, mem_ack;
    wire [31:0] mem_rdata;
    wire ready;

    wire dut_sd_cke, dut_sd_cs_n, dut_sd_ras_n, dut_sd_cas_n, dut_sd_we_n;
    wire [12:0] dut_sd_addr;
    wire [1:0] dut_sd_ba;
    wire [BYTE_BITS-1:0] dut_sd_dqm;
    wire [DATA_BITS-1:0] dut_sd_dq_o;
    wire [DATA_BITS-1:0] sd_dq_i;
    wire dut_sd_dq_oe;
    wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_addr;
    wire [1:0] sd_ba;
    wire [BYTE_BITS-1:0] sd_dqm;
    wire [DATA_BITS-1:0] sd_dq_o;
    wire sd_dq_oe;

    riscc_sdram #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .CLK_MHZ(CLK_MHZ), .INIT_CYCLES(INIT_CYCLES),
        .REFRESH_CYCLES(REFRESH_CYCLES), .CAS(CAS), .TRCD(TRCD),
        .TRP(TRP), .TRFC(TRFC), .TRAS(TRAS), .TWR(TWR),
        .PIN_PIPELINE(PIN_PIPELINE),
        .FIFO_BITS(FIFO_BITS)
    ) dut (
        .clk(clk), .rst(rst), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask), .mem_we(mem_we), .mem_cyc(mem_cyc),
        .mem_stb(mem_stb), .mem_stall(mem_stall), .mem_ack(mem_ack),
        .mem_rdata(mem_rdata), .ready(ready), .sd_cke(dut_sd_cke),
        .sd_cs_n(dut_sd_cs_n), .sd_ras_n(dut_sd_ras_n),
        .sd_cas_n(dut_sd_cas_n), .sd_we_n(dut_sd_we_n),
        .sd_addr(dut_sd_addr), .sd_ba(dut_sd_ba), .sd_dqm(dut_sd_dqm),
        .sd_dq_i(sd_dq_i), .sd_dq_o(dut_sd_dq_o), .sd_dq_oe(dut_sd_dq_oe)
    );

    generate
        if (PIN_PIPELINE != 0) begin : g_pin_pipeline
            reg pin_sd_cke, pin_sd_cs_n, pin_sd_ras_n, pin_sd_cas_n;
            reg pin_sd_we_n;
            reg [12:0] pin_sd_addr;
            reg [1:0] pin_sd_ba;
            reg [BYTE_BITS-1:0] pin_sd_dqm;
            reg [DATA_BITS-1:0] pin_sd_dq_o;
            reg pin_sd_dq_oe;

            always @(posedge clk) begin
                pin_sd_cke <= dut_sd_cke;
                pin_sd_cs_n <= dut_sd_cs_n;
                pin_sd_ras_n <= dut_sd_ras_n;
                pin_sd_cas_n <= dut_sd_cas_n;
                pin_sd_we_n <= dut_sd_we_n;
                pin_sd_addr <= dut_sd_addr;
                pin_sd_ba <= dut_sd_ba;
                pin_sd_dqm <= dut_sd_dqm;
                pin_sd_dq_o <= dut_sd_dq_o;
                pin_sd_dq_oe <= dut_sd_dq_oe;
            end

            assign sd_cke = pin_sd_cke;
            assign sd_cs_n = pin_sd_cs_n;
            assign sd_ras_n = pin_sd_ras_n;
            assign sd_cas_n = pin_sd_cas_n;
            assign sd_we_n = pin_sd_we_n;
            assign sd_addr = pin_sd_addr;
            assign sd_ba = pin_sd_ba;
            assign sd_dqm = pin_sd_dqm;
            assign sd_dq_o = pin_sd_dq_o;
            assign sd_dq_oe = pin_sd_dq_oe;
        end else begin : g_direct_pins
            assign sd_cke = dut_sd_cke;
            assign sd_cs_n = dut_sd_cs_n;
            assign sd_ras_n = dut_sd_ras_n;
            assign sd_cas_n = dut_sd_cas_n;
            assign sd_we_n = dut_sd_we_n;
            assign sd_addr = dut_sd_addr;
            assign sd_ba = dut_sd_ba;
            assign sd_dqm = dut_sd_dqm;
            assign sd_dq_o = dut_sd_dq_o;
            assign sd_dq_oe = dut_sd_dq_oe;
        end
    endgenerate

    riscc_sdram_model #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .CAS(CAS), .INIT_CYCLES(INIT_CYCLES), .TRCD(TRCD), .TRP(TRP),
        .TRFC(TRFC), .TRAS(TRAS), .TWR(TWR),
        .MAX_REFRESH_GAP(MAX_REFRESH_GAP), .T_AC(T_AC)
    ) model (
        .clk(sd_clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq_i(sd_dq_o),
        .dq_oe(sd_dq_oe), .dq_o(sd_dq_i)
    );

    wire accept = mem_cyc && mem_stb && !mem_stall;
    integer cycle_count = 0;
    integer accepted_count = 0;
    integer response_count = 0;
    integer error_count = 0;
    integer stalled_cycles = 0, simultaneous_cycles = 0;
    integer perf_first = 0, perf_last = 0, perf_count = 0;
    reg measuring = 0;
    reg require_dropped_ack = 1'b0;
    integer shadow_count = 0;
    integer rsp_head = 0, rsp_tail = 0;
    reg [ADDR_BITS-1:0] shadow_addr [0:SHADOW_SLOTS-1];
    reg [31:0] shadow_data [0:SHADOW_SLOTS-1];
    reg shadow_valid [0:SHADOW_SLOTS-1];
    reg [31:0] rsp_data [0:MAX_RESPONSES-1];
    reg rsp_is_write [0:MAX_RESPONSES-1];

    integer i;
    integer n;
    reg [31:0] old_value;
    reg [31:0] new_value;
    reg [31:0] expected_value;

    function automatic [31:0] shadow_get(input [ADDR_BITS-1:0] address);
        integer p;
        begin
            shadow_get = 32'b0;
            for (p = 0; p < SHADOW_SLOTS; p = p + 1)
                if (shadow_valid[p] && shadow_addr[p] == address)
                    shadow_get = shadow_data[p];
        end
    endfunction

    task automatic shadow_put(
        input [ADDR_BITS-1:0] address, input [31:0] value_in);
        integer p;
        reg found;
        begin
            found = 1'b0;
            for (p = 0; p < SHADOW_SLOTS; p = p + 1)
                if (shadow_valid[p] && shadow_addr[p] == address) begin
                    shadow_data[p] = value_in;
                    found = 1'b1;
                end
            if (!found) begin
                if (shadow_count >= SHADOW_SLOTS)
                    $fatal(1, "shadow memory full");
                shadow_valid[shadow_count] = 1'b1;
                shadow_addr[shadow_count] = address;
                shadow_data[shadow_count] = value_in;
                shadow_count = shadow_count + 1;
            end
        end
    endtask

    // Keep a write run and a read run in one queued transaction.  The
    // controller must drain the write pipeline before changing direction,
    // while the bus side continues presenting requests without an idle gap.
    task automatic mixed_burst_requests(
        input integer count, input integer write_count_in,
        input [ADDR_BITS-1:0] base_address);
        integer b;
        integer start_cycle;
        integer finish_cycle;
        reg [31:0] data_value;
        reg [31:0] random_value;
        reg [31:0] next_address;
        begin
            if (write_count_in >= count || count > MAX_BURST)
                fail("invalid mixed burst lengths");
            start_cycle = cycle_count;
            mem_cyc = 1'b1;
            mem_stb = 1'b1;
            for (b = 0; b < count; b = b + 1) begin
                next_random(random_value);
                data_value = request_data(b) ^ random_value;
                next_address = {{(32-ADDR_BITS){1'b0}}, base_address} + (b % write_count_in);
                mem_addr = next_address[ADDR_BITS-1:0];
                mem_wdata = data_value;
                if (b < write_count_in) begin
                    mem_we = 1'b1;
                    mem_wmask = 4'hf;
                end else begin
                    mem_we = 1'b0;
                    mem_wmask = 0;
                end
                wait_accept();
            end
            finish_cycle = cycle_count;
            mem_stb = 1'b0;
            wait_responses();
            repeat (4) @(negedge clk);
            mem_cyc = 1'b0;
            $display("SDRAM MIXED DATA_BITS=%0d words=%0d writes=%0d cycles=%0d",
                     DATA_BITS, count, write_count_in,
                     finish_cycle - start_cycle);
        end
    endtask

    task automatic fail(input [8*160-1:0] message);
        begin
            error_count = error_count + 1;
            $display("FAIL SDRAM DATA_BITS=%0d cycle=%0d: %0s",
                     DATA_BITS, cycle_count, message);
            $fatal(1, "SDRAM test failed");
        end
    endtask

    // The expected memory is updated at bus acceptance.  Since requests and
    // responses are in order, this also models a read following a queued
    // partial write before that write reaches the SDRAM pins.
    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (cycle_count > 1000000) fail("simulation watchdog");
        if (!rst && mem_cyc && mem_stb && mem_stall) stalled_cycles = stalled_cycles + 1;
        if (!rst && accept && dut.issue) simultaneous_cycles = simultaneous_cycles + 1;
        if (rst) begin
            rsp_head = 0;
            rsp_tail = 0;
        end else if (accept) begin
            accepted_count = accepted_count + 1;
            if (rsp_tail >= MAX_RESPONSES)
                fail("response scoreboard overflow");
            rsp_is_write[rsp_tail] = mem_we;
            rsp_data[rsp_tail] = shadow_get(mem_addr);
            rsp_tail = rsp_tail + 1;
            if (mem_we) begin
                old_value = shadow_get(mem_addr);
                new_value = old_value;
                for (n = 0; n < 4; n = n + 1)
                    if (mem_wmask[n])
                        new_value[n*8 +: 8] = mem_wdata[n*8 +: 8];
                shadow_put(mem_addr, new_value);
            end
        end
    end

    // Responses are registered at the controller's rising edge.  Inspect
    // them on the following falling edge, when mem_rdata is stable and the
    // scoreboard has already recorded the acceptance edge.
    always @(negedge clk) begin
        if (!rst && mem_ack) begin
            if (measuring) begin
                if (perf_count == 0) perf_first = cycle_count;
                perf_last = cycle_count;
                perf_count = perf_count + 1;
            end
            if (rsp_head >= rsp_tail)
                fail("unexpected extra acknowledgement");
            if (require_dropped_ack && mem_stb)
                fail("acknowledgement arrived before STB dropped");
            if (rsp_is_write[rsp_head] == 1'b0) begin
                expected_value = rsp_data[rsp_head];
                if (mem_rdata !== expected_value)
                    fail("read data mismatch");
            end
            rsp_head = rsp_head + 1;
            response_count = response_count + 1;
        end
    end

    task automatic wait_accept;
        begin
            while (1) begin
                @(posedge clk);
                // mem_stall is sampled before the controller's state update
                // at this edge, which is exactly the acceptance condition.
                if (!mem_stall) begin
                    @(negedge clk);
                    break;
                end
            end
        end
    endtask

    task automatic wait_responses;
        integer guard;
        begin
            guard = 0;
            while (rsp_head != rsp_tail) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 100000)
                    fail("response timeout");
            end
        end
    endtask

    task automatic quiet_bus;
        begin
            mem_stb = 1'b0;
            mem_we = 1'b0;
            wait_responses();
            repeat (4) @(negedge clk);
            mem_cyc = 1'b0;
        end
    endtask

    task automatic single_request(
        input [ADDR_BITS-1:0] address, input [31:0] write_data,
        input [3:0] write_mask, input write_enable,
        input [31:0] expected_read, input check_read);
        begin
            mem_cyc = 1'b1;
            mem_stb = 1'b1;
            mem_addr = address;
            mem_wdata = write_data;
            mem_wmask = write_mask;
            mem_we = write_enable;
            wait_accept();
            // This is intentionally before the SDRAM transaction completes.
            // It exercises an acknowledgement after STB has fallen.
            mem_stb = 1'b0;
            require_dropped_ack = 1'b1;
            wait_responses();
            require_dropped_ack = 1'b0;
            if (check_read && expected_value !== expected_read)
                fail("single read expected value mismatch");
            repeat (3) @(negedge clk);
            mem_cyc = 1'b0;
        end
    endtask

    reg [31:0] rng_state = 32'hc001d00d;
    task automatic next_random(output [31:0] value_out);
        begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 17);
            rng_state = rng_state ^ (rng_state << 5);
            value_out = rng_state;
        end
    endtask

    function automatic [ADDR_BITS-1:0] geometry_address(
        input integer row_number, input integer bank_number,
        input integer column_number);
        reg [31:0] physical;
        reg [31:0] shifted;
        begin
            physical = (row_number << (COL_BITS + 2)) |
                       (bank_number << COL_BITS) | column_number;
            // x16 bus words cover two SDRAM columns; x32 words map one
            // column because the controller's physical address is already
            // expressed in native SDRAM beats.
            shifted = physical >> (DATA_BITS == 16 ? 1 : 0);
            geometry_address = shifted[ADDR_BITS-1:0];
        end
    endfunction

    function automatic [31:0] request_data(input integer index);
        request_data = 32'h53000000 ^ (index * 32'h001f1237) ^
                       (DATA_BITS * 32'h00010001);
    endfunction

    task automatic burst_requests(
        input integer count, input [ADDR_BITS-1:0] base_address,
        input integer write_enable, input integer random_masks,
        input integer measure_perf);
        integer b;
        integer start_cycle;
        integer finish_cycle;
        reg [3:0] mask_value;
        reg [31:0] next_address;
        reg [31:0] data_value;
        reg [31:0] random_value;
        begin
            if (count > MAX_BURST)
                fail("burst exceeds test limit");
            start_cycle = cycle_count;
            measuring = measure_perf != 0;
            perf_count = 0;
            mem_cyc = 1'b1;
            mem_stb = 1'b1;
            for (b = 0; b < count; b = b + 1) begin
                next_random(random_value);
                data_value = request_data(b) ^ random_value;
                if (write_enable != 0) begin
                    if (random_masks != 0) begin
                        mask_value = random_value[3:0];
                        if ((b % 11) == 0) mask_value = 0;
                        if ((b % 13) == 0) mask_value = 4'hf;
                    end else
                        mask_value = 4'hf;
                    mem_we = 1'b1;
                    mem_wmask = mask_value[3:0];
                end else begin
                    mem_we = 1'b0;
                    mem_wmask = 0;
                end
                next_address = {{(32-ADDR_BITS){1'b0}}, base_address} + b;
                mem_addr = next_address[ADDR_BITS-1:0];
                mem_wdata = data_value;
                wait_accept();
            end
            mem_stb = 1'b0;
            wait_responses();
            repeat (4) @(negedge clk);
            finish_cycle = cycle_count;
            measuring = 0;
            mem_cyc = 1'b0;
            if (measure_perf != 0) begin
                $display("SDRAM PERF x%0d %s responses=%0d span=%0d clocks_per_word=%0f total=%0d",
                         DATA_BITS, write_enable != 0 ? "write" : "read", perf_count,
                         perf_last - perf_first, (perf_last - perf_first) * 1.0 / (count - 1),
                         finish_cycle - start_cycle);
                if (perf_count != count) fail("burst response count mismatch");
                if (REFRESH_CYCLES > 1000 && perf_last - perf_first != (count - 1) * (HALF + 1))
                    fail("same-row burst did not sustain physical data rate");
            end
        end
    endtask

    integer r;
    integer b;
    integer c;
    reg [31:0] random_value;
    reg [ADDR_BITS-1:0] address_value;
    reg [3:0] random_mask;
    integer column_value;
    integer canceled_tail;

    initial begin
        if (!$value$plusargs("SEED=%d", rng_state)) rng_state = 32'hc001d00d;
        for (i = 0; i < SHADOW_SLOTS; i = i + 1)
            shadow_valid[i] = 1'b0;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        // The model and controller must both complete initialization before
        // any bus request is accepted.
        r = 0;
        while (!ready) begin
            @(negedge clk);
            r = r + 1;
            if (r > INIT_CYCLES + 1000) fail("controller initialization timeout");
        end

        // Exercise all banks, a row transition, and full/partial/zero masks.
        for (b = 0; b < 4; b = b + 1) begin
            address_value = geometry_address(3, b, 0);
            single_request(address_value, 32'h11000000 | b, 4'hf, 1'b1,
                           0, 1'b0);
            single_request(address_value, 32'h00000000, 0, 1'b0,
                           0, 1'b0);
            single_request(address_value, 32'h22000000 | (b << 8),
                           4'b0101, 1'b1, 0, 1'b0);
            single_request(address_value, 32'h00000000, 0, 1'b0,
                           0, 1'b0);
        end

        // Same-row pipelining at the intended steady-state rate.  The first
        // burst also fills the controller FIFO, making acceptance and issue
        // overlap; the second crosses a row boundary.
        address_value = geometry_address(10, 1, 32);
        burst_requests(8, address_value, 1, 1, 0);
        burst_requests(16, address_value, 0, 0, 0);
        burst_requests(64, address_value, 1, 1, 1);
        burst_requests(64, address_value, 0, 0, 1);
        mixed_burst_requests(64, 32, geometry_address(10, 1, 256));
        address_value = geometry_address(10, 3, 508);
        burst_requests(16, address_value, 0, 0, 0);

        // Initialize a larger deterministic region, then use randomized
        // masked stores and reads against it.
        address_value = geometry_address(12, 2, 64);
        burst_requests(64, address_value, 1, 0, 0);
        for (c = 0; c < 1024; c = c + 1) begin
            next_random(random_value);
            r = int'(random_value[15:13]);
            b = int'(random_value[12:11]);
            column_value = random_value % 32'd512;
            column_value = column_value & 32'h1fc;
            address_value = geometry_address(12 + r, b,
                                             column_value);
            next_random(random_value);
            random_mask = random_value[3:0];
            if ((c % 17) == 0) random_mask = 0;
            single_request(address_value, random_value ^ c, random_mask,
                           1'b1, 0, 1'b0);
            single_request(address_value, 0, 0, 1'b0, 0, 1'b0);
        end

        // Queue mixed random accesses without draining responses between commands.
        mem_cyc = 1;
        mem_stb = 1;
        for (c = 0; c < 256; c = c + 1) begin
            next_random(random_value);
            if (random_value[10])
                mem_addr = geometry_address(3, int'(random_value[9:8]), 0);
            else
                mem_addr = geometry_address(12, 2, 64) + ADDR_BITS'(random_value[5:0]);
            mem_we = random_value[11];
            mem_wmask = random_value[15:12];
            mem_wdata = random_value;
            wait_accept();
        end
        quiet_bus();

        for (b = 0; b < 4; b = b + 1) begin
            address_value = geometry_address((1 << ROW_BITS) - 1, b, 510);
            single_request(address_value, 32'hdead0000 | b, 15, 1, 0, 0);
            single_request(address_value, 0, 0, 0, 0, 0);
        end

        // Accepted reads in the FIFO must be discarded by reset.  These
        // addresses are deliberately row misses, so they cannot alter the
        // retained memory before reset arrives.
        mem_cyc = 1'b1;
        mem_stb = 1'b1;
        mem_we = 1'b0;
        for (c = 0; c < 8; c = c + 1) begin
            mem_addr = geometry_address(30 + c, 3, 0);
            mem_wdata = 0;
            mem_wmask = 0;
            wait_accept();
        end
        canceled_tail = rsp_tail;
        mem_stb = 0;
        @(negedge clk);
        rst = 1'b1;
        repeat (4) @(negedge clk);
        if (rsp_head != rsp_tail)
            fail("reset did not cancel pending bus responses");
        mem_cyc = 1'b0;
        mem_stb = 1'b0;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        r = 0;
        while (!ready) begin
            @(negedge clk);
            r = r + 1;
            if (r > INIT_CYCLES + 1000) fail("controller reinitialization timeout");
        end
        address_value = geometry_address(12, 2, 64);
        single_request(address_value, 0, 0, 1'b0, 0, 1'b0);

        repeat (8) @(negedge clk);
        if (rsp_head != rsp_tail)
            fail("response queue not empty at end of test");
        if (stalled_cycles == 0 || simultaneous_cycles == 0)
            fail("FIFO backpressure or simultaneous enqueue/dequeue not exercised");
        if (model.refresh_count < 16) fail("refresh coverage missing");
        $display("PASS SDRAM DATA_BITS=%0d accepted=%0d responses=%0d cycles=%0d",
                 DATA_BITS, accepted_count, response_count, cycle_count);
        $finish;
    end
endmodule

`default_nettype wire
