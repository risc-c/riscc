// Integration test for the queued SDRAM/cache traffic benchmark.
//
// This fixture runs the benchmark engine against the same command-level SDR
// model used by the controller tests.  The x16 configuration instantiates
// the actual IcePi wrapper, including its registered I/O and forwarded clock,
// so every benchmark phase exercises the complete controller path.
`timescale 1ns/1ps
`default_nettype none

module riscc_sdram_bench_tb #(
    parameter integer CLK_MHZ = 167,
    parameter realtime CLOCK_PERIOD_NS = 6.0,
    // The 166 MHz IcePi test uses the PLL's 292.5-degree pin phase.  The
    // 5.875 ns model phase includes the registered-pin delay abstraction.
    parameter realtime DEVICE_CLK_PHASE_NS = 5.875,
    parameter realtime T_AC = 5.0,
    parameter integer INIT_CYCLES = 20,
    parameter integer REFRESH_CYCLES = 100,
    parameter integer MAX_REFRESH_GAP = REFRESH_CYCLES + 32,
    parameter integer DATA_BITS = 16,
    parameter integer FULL_BITS = 10,
    parameter integer RANDOM_BITS = 8,
    parameter integer FIFO_BITS = 3,
    parameter integer READ_DELAY = 1,
    parameter integer DIRECT_CAPTURE = 0,
    parameter integer IO_CAPTURE = 0,
    parameter integer CAPTURE_RETIME = 0,
    parameter realtime CAPTURE_PHASE_NS = 0.0,
    parameter integer AGILEX_WRAPPER = 0,
    parameter realtime FORWARD_PHASE_NS = 0.0,
    parameter integer CORRUPT_READ = 0,
    parameter integer CORRUPT_INDEX = 1025
);
    localparam integer ROW_BITS = 13;
    localparam integer COL_BITS = 9;
    localparam integer ADDR_BITS = ROW_BITS + COL_BITS + 2 -
                                   (DATA_BITS == 16 ? 1 : 0);
    localparam integer BYTE_BITS = DATA_BITS / 8;
    localparam integer MAX_RESPONSES = (1 << (FULL_BITS + 1)) +
                                       (5 << RANDOM_BITS) + 64;

    reg clk = 1'b0;
    reg sd_clk_phase = 1'b0;
    reg forward_clk_phase = 1'b0;
    reg rst = 1'b1;
    reg capture_clk_phase = 1'b0;
    initial begin
        #(CLOCK_PERIOD_NS / 2.0 + CAPTURE_PHASE_NS);
        capture_clk_phase = 1'b1;
        forever #(CLOCK_PERIOD_NS / 2.0) capture_clk_phase = ~capture_clk_phase;
    end
    always #(CLOCK_PERIOD_NS / 2.0) clk = ~clk;
    initial begin
        #(CLOCK_PERIOD_NS / 2.0 + DEVICE_CLK_PHASE_NS);
        sd_clk_phase = 1'b1;
        forever begin
            #(CLOCK_PERIOD_NS / 2.0);
            sd_clk_phase = ~sd_clk_phase;
        end
    end
    // IcePi presents a separately phased SDRAM clock. The Agilex x32 wrapper
    // forwards the complement of the controller clock through its SDRAM pin
    // when IO_CAPTURE is disabled. A separate phase parameter models the
    // board PLL's forwarded clock phase for registered I/O cases.
    initial begin
        #(CLOCK_PERIOD_NS / 2.0 + FORWARD_PHASE_NS);
        forward_clk_phase = 1'b1;
        forever begin
            #(CLOCK_PERIOD_NS / 2.0);
            forward_clk_phase = ~forward_clk_phase;
        end
    end
    wire sd_clk = DATA_BITS == 16 ? sd_clk_phase : ~clk;

    wire [ADDR_BITS-1:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we, mem_cyc, mem_stb;
    wire mem_stall, mem_ack;
    wire [31:0] dut_mem_rdata;
    wire [31:0] mem_rdata = dut_mem_rdata ^
        ((CORRUPT_READ != 0 && mem_ack && ack_head == CORRUPT_INDEX) ?
         32'h00000001 : 32'h00000000);
    wire ready;

    wire dut_sd_cke, dut_sd_cs_n, dut_sd_ras_n, dut_sd_cas_n, dut_sd_we_n;
    wire dut_sd_clk;
    wire [12:0] dut_sd_addr;
    wire [1:0] dut_sd_ba;
    wire [BYTE_BITS-1:0] dut_sd_dqm;
    wire [DATA_BITS-1:0] dut_sd_dq_o;
    wire dut_sd_dq_oe;
    wire [DATA_BITS-1:0] model_dq_i;
    wire [DATA_BITS-1:0] model_dq_o;
    wire model_dq_oe;
    // The wrapper owns the pin-side tri-state enable. During a read the
    // model drives this bus; during a write the wrapper drives it and the
    // model samples the resulting value.
    wire [15:0] icepi_dq_bus;
    wire icepi_dq_oe;

    // The x16 case instantiates the actual IcePi wrapper; AGILEX_WRAPPER
    // selects the actual Agilex x32 wrapper for either raw or registered I/O.
    wire [31:0] atum_dq_out;
    wire atum_dq_oe;
    generate if (DATA_BITS == 16) begin : g_icepi_wrapper
        // The IcePi output DQ/tristate registers add one cycle after the
        // controller's dq_oe.  The model must use the actual pin enable.
        assign icepi_dq_oe = !icepi_wrapper.dq_tristate[0];
        assign icepi_dq_bus = icepi_dq_oe ? icepi_wrapper.dq_pin : model_dq_o;
        icepi_sdram #(
            .CLK_MHZ(CLK_MHZ),
            .INIT_CYCLES(INIT_CYCLES), .REFRESH_CYCLES(REFRESH_CYCLES),
            .READ_DELAY(READ_DELAY)
        ) icepi_wrapper (
            .clk(clk), .rst(rst), .pin_clk(sd_clk_phase),
            .mem_addr(mem_addr), .mem_wdata(mem_wdata),
            .mem_wmask(mem_wmask), .mem_we(mem_we), .mem_cyc(mem_cyc),
            .mem_stb(mem_stb), .mem_stall(mem_stall), .mem_ack(mem_ack),
            .mem_rdata(dut_mem_rdata), .ready(ready), .sd_clk(dut_sd_clk),
            .sd_cke(dut_sd_cke), .sd_cs_n(dut_sd_cs_n),
            .sd_ras_n(dut_sd_ras_n), .sd_cas_n(dut_sd_cas_n),
            .sd_we_n(dut_sd_we_n), .sd_addr(dut_sd_addr), .sd_ba(dut_sd_ba),
            .sd_dqm(dut_sd_dqm), .sd_dq(icepi_dq_bus)
        );
    end else if (IO_CAPTURE != 0 || AGILEX_WRAPPER != 0) begin : g_agilex_wrapper
        wire [31:0] atum_sd_dq;
        assign atum_dq_out = agilex_wrapper.dq_out;
        assign atum_dq_oe = agilex_wrapper.dq_oe;
        assign atum_sd_dq = atum_dq_oe ? atum_dq_out : model_dq_o;
        agilex3_sdram #(
            .CLK_MHZ(CLK_MHZ), .READ_DELAY(READ_DELAY),
            .IO_CAPTURE(IO_CAPTURE), .CAPTURE_RETIME(CAPTURE_RETIME),
            .INIT_CYCLES(INIT_CYCLES)
        ) agilex_wrapper (
            .clk(clk), .rst(rst), .capture_clk(capture_clk_phase),
            .forward_clk(forward_clk_phase),
            .mem_addr(mem_addr), .mem_wdata(mem_wdata),
            .mem_wmask(mem_wmask), .mem_we(mem_we), .mem_cyc(mem_cyc),
            .mem_stb(mem_stb), .mem_stall(mem_stall), .mem_ack(mem_ack),
            .mem_rdata(dut_mem_rdata), .ready(ready), .sd_clk(dut_sd_clk),
            .sd_cke(dut_sd_cke), .sd_cs_n(dut_sd_cs_n),
            .sd_ras_n(dut_sd_ras_n), .sd_cas_n(dut_sd_cas_n),
            .sd_we_n(dut_sd_we_n), .sd_addr(dut_sd_addr), .sd_ba(dut_sd_ba),
            .sd_dqm(dut_sd_dqm), .sd_dq(atum_sd_dq)
        );
    end else begin : g_controller
        assign dut_sd_clk = 1'b0;
        assign atum_dq_out = {32{1'b0}};
        assign atum_dq_oe = 1'b0;
        riscc_sdram #(
            .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
            .CLK_MHZ(CLK_MHZ), .INIT_CYCLES(INIT_CYCLES),
            .REFRESH_CYCLES(REFRESH_CYCLES),
            .PIN_PIPELINE(0),
            .INPUT_REGISTERED(DIRECT_CAPTURE != 0 ? 1 : 0),
            .READ_DELAY(READ_DELAY), .FIFO_BITS(FIFO_BITS)
        ) controller (
            .clk(clk), .rst(rst), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
            .mem_wmask(mem_wmask), .mem_we(mem_we), .mem_cyc(mem_cyc),
            .mem_stb(mem_stb), .mem_stall(mem_stall), .mem_ack(mem_ack),
            .mem_rdata(dut_mem_rdata), .ready(ready), .sd_cke(dut_sd_cke),
            .sd_cs_n(dut_sd_cs_n), .sd_ras_n(dut_sd_ras_n),
            .sd_cas_n(dut_sd_cas_n), .sd_we_n(dut_sd_we_n),
            .sd_addr(dut_sd_addr), .sd_ba(dut_sd_ba), .sd_dqm(dut_sd_dqm),
            .sd_dq_i(model_dq_o), .sd_dq_o(dut_sd_dq_o),
            .sd_dq_oe(dut_sd_dq_oe)
        );
    end endgenerate

    generate
        if (DATA_BITS == 16) begin : g_icepi_model_bus
            assign model_dq_i = icepi_dq_bus;
            assign model_dq_oe = icepi_dq_oe;
        end else if (IO_CAPTURE != 0 || AGILEX_WRAPPER != 0) begin : g_agilex_model_bus
            assign model_dq_i = atum_dq_out;
            assign model_dq_oe = atum_dq_oe;
        end else begin : g_controller_model_bus
            assign model_dq_i = dut_sd_dq_o;
            assign model_dq_oe = dut_sd_dq_oe;
        end
    endgenerate
    wire model_sd_clk = DATA_BITS == 16 || IO_CAPTURE != 0 ||
                        AGILEX_WRAPPER != 0 ? dut_sd_clk : sd_clk;

    riscc_sdram_model #(
        .DATA_BITS(DATA_BITS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS),
        .CAS(3), .INIT_CYCLES(INIT_CYCLES),
        .TRCD((20 * CLK_MHZ + 999) / 1000),
        .TRP((20 * CLK_MHZ + 999) / 1000),
        .TRFC((80 * CLK_MHZ + 999) / 1000),
        .TRAS((45 * CLK_MHZ + 999) / 1000),
        .TWR(((15 * CLK_MHZ + 999) / 1000 < 2) ? 2 :
             (15 * CLK_MHZ + 999) / 1000),
        .MAX_REFRESH_GAP(MAX_REFRESH_GAP), .T_AC(T_AC)
    ) memory (
        .clk(model_sd_clk), .rst(rst),
        .cke(dut_sd_cke), .cs_n(dut_sd_cs_n), .ras_n(dut_sd_ras_n),
        .cas_n(dut_sd_cas_n), .we_n(dut_sd_we_n), .addr(dut_sd_addr),
        .ba(dut_sd_ba), .dqm(dut_sd_dqm),
        .dq_i(model_dq_i), .dq_oe(model_dq_oe),
        .dq_o(model_dq_o)
    );

    wire result_toggle, terminal;
    reg reply_toggle = 1'b0;
    wire [3:0] phase;
    wire [31:0] words, cycles, errors, error_address, expected, actual;
    wire done, failed;

    riscc_sdram_bench #(
        .ADDR_BITS(ADDR_BITS), .FULL_BITS(FULL_BITS), .RANDOM_BITS(RANDOM_BITS)
    ) engine (
        .clk(clk), .rst(rst), .ready(ready), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb), .mem_stall(mem_stall),
        .mem_ack(mem_ack), .mem_rdata(mem_rdata),
        .result_toggle(result_toggle), .reply_toggle(reply_toggle),
        .phase(phase), .words(words), .cycles(cycles), .errors(errors),
        .address(error_address), .expected(expected), .actual(actual),
        .terminal(terminal), .done(done), .failed(failed)
    );

    integer accepted_count = 0;
    integer response_count = 0;
    integer pending_count = 0;
    integer max_pending = 0;
    integer write_count = 0;
    integer read_count = 0;
    integer phase_accept_count [0:5];
    integer phase_read_count [0:5];
    integer phase_write_count [0:5];
    integer phase_cycle_count [0:5];
    integer mask_count [0:15];
    integer nonsequential_count [0:5];
    integer max_consecutive = 0;
    integer consecutive = 0;
    integer ack_head = 0;
    reg [31:0] response_expected [0:MAX_RESPONSES-1];
    reg response_is_write [0:MAX_RESPONSES-1];
    reg [31:0] shadow [0:(1 << FULL_BITS)-1];
    reg [3:0] previous_phase;
    reg [ADDR_BITS-1:0] previous_address;
    integer i;
    integer lane;
    integer phase_index;
    reg [31:0] shadow_value;
    wire accept = mem_cyc && mem_stb && !mem_stall;

    // Independent bus scoreboard.  It checks every read response, including
    // responses after masked writes and while the benchmark keeps requests
    // queued, instead of relying only on the engine's internal checker.
    always @(posedge clk) begin
        if (rst) begin
            accepted_count = 0;
            response_count = 0;
            pending_count = 0;
            max_pending = 0;
            write_count = 0;
            read_count = 0;
            ack_head = 0;
            consecutive = 0;
            previous_phase = 0;
            previous_address = 0;
            for (phase_index = 0; phase_index < 6; phase_index = phase_index + 1)
                phase_cycle_count[phase_index] = 0;
        end else begin
            if (engine.counting)
                phase_cycle_count[int'(phase)] = phase_cycle_count[int'(phase)] + 1;
            if (accept) begin
                phase_index = int'(phase);
                if (phase_index < 0 || phase_index > 5)
                    $fatal(1, "invalid benchmark phase %0d", phase_index);
                if (accepted_count >= MAX_RESPONSES)
                    $fatal(1, "benchmark response queue overflow");
                response_is_write[accepted_count] = mem_we;
                response_expected[accepted_count] = shadow[mem_addr[FULL_BITS-1:0]];
                shadow_value = shadow[mem_addr[FULL_BITS-1:0]];
                if (mem_we) begin
                    write_count = write_count + 1;
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (mem_wmask[lane])
                            shadow_value[lane*8 +: 8] = mem_wdata[lane*8 +: 8];
                    shadow[mem_addr[FULL_BITS-1:0]] = shadow_value;
                end else
                    read_count = read_count + 1;
                phase_accept_count[phase_index] = phase_accept_count[phase_index] + 1;
                if (mem_we) phase_write_count[phase_index] = phase_write_count[phase_index] + 1;
                else phase_read_count[phase_index] = phase_read_count[phase_index] + 1;
                mask_count[mem_we ? mem_wmask : 0] = mask_count[mem_we ? mem_wmask : 0] + 1;
                if (accepted_count != 0 && phase == previous_phase &&
                    mem_addr == previous_address + 1'b1)
                    consecutive = consecutive + 1;
                else
                    consecutive = 1;
                if (consecutive > max_consecutive) max_consecutive = consecutive;
                if (accepted_count != 0 && phase == previous_phase &&
                    mem_addr != previous_address + 1'b1)
                    nonsequential_count[phase_index] = nonsequential_count[phase_index] + 1;
                previous_phase = phase;
                previous_address = mem_addr;
                accepted_count = accepted_count + 1;
                pending_count = pending_count + 1;
                if (pending_count > max_pending) max_pending = pending_count;
            end
            if (mem_ack) begin
                if (response_count >= accepted_count)
                    $fatal(1, "unexpected SDRAM acknowledgement");
                if (!response_is_write[ack_head] &&
                    !(CORRUPT_READ != 0 && ack_head == CORRUPT_INDEX) &&
                    mem_rdata !== response_expected[ack_head])
                    $fatal(1, "benchmark read mismatch index=%0d got=%h expected=%h",
                           ack_head, mem_rdata, response_expected[ack_head]);
                ack_head = ack_head + 1;
                response_count = response_count + 1;
                pending_count = pending_count - 1;
            end
        end
    end

    reg result_seen = 1'b0;
    reg report_pending = 1'b0;
    reg [3:0] report_delay = 0;
    integer report_count = 0;
    reg [31:0] rng_state = 32'hb16b00b5;
    integer report_phase;
    integer report_words;

    task automatic next_random;
        begin
            rng_state = rng_state ^ (rng_state << 13);
            rng_state = rng_state ^ (rng_state >> 17);
            rng_state = rng_state ^ (rng_state << 5);
        end
    endtask

    // The board reporter acknowledges each result after a varying delay.
    // This covers the engine's stable-result handshake independently of the
    // UART implementation and prevents phase transitions from being assumed
    // to happen in a fixed number of clocks.
    always @(posedge clk) begin
        if (rst) begin
            result_seen <= 1'b0;
            report_pending <= 1'b0;
            report_delay <= 0;
            reply_toggle <= 1'b0;
            report_count = 0;
        end else if (!report_pending && result_toggle != result_seen) begin
            result_seen <= result_toggle;
            report_pending <= 1'b1;
            next_random();
            report_delay <= (rng_state[3:0] % 6) + 1;
            report_phase = report_count;
            report_words = phase < 2 ? (1 << FULL_BITS) :
                           phase == 5 ? (2 << RANDOM_BITS) : (1 << RANDOM_BITS);
            if (phase !== report_count[3:0] || words !== report_words ||
                (CORRUPT_READ == 0 && errors != 0) ||
                (CORRUPT_READ == 0 && terminal !== (phase == 5)) ||
                (CORRUPT_READ != 0 && report_count != 0 &&
                 (errors == 0 || !terminal || expected == actual ||
                  error_address == 0)) ||
                cycles !== phase_cycle_count[report_count])
                $fatal(1, "bad benchmark report phase=%0d words=%0d cycles=%0d counted=%0d errors=%h terminal=%b",
                       phase, words, cycles, phase_cycle_count[report_count],
                       errors, terminal);
            report_count = report_count + 1;
        end else if (report_pending) begin
            if (report_delay != 0)
                report_delay <= report_delay - 1'b1;
            else begin
                reply_toggle <= result_toggle;
                report_pending <= 1'b0;
            end
        end
    end

    integer watchdog;
    initial begin
        if (!$value$plusargs("SEED=%d", rng_state)) rng_state = 32'hb16b00b5;
        for (i = 0; i < (1 << FULL_BITS); i = i + 1)
            shadow[i] = 32'h0;
        for (i = 0; i < 6; i = i + 1) begin
            phase_accept_count[i] = 0;
            phase_read_count[i] = 0;
            phase_write_count[i] = 0;
            nonsequential_count[i] = 0;
        end
        for (i = 0; i < 16; i = i + 1) mask_count[i] = 0;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        watchdog = 0;
        while (!done && !(CORRUPT_READ != 0 && failed &&
                          report_count >= 1 && !report_pending)) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            if (watchdog > 1000000)
                $fatal(1, "benchmark watchdog phase=%0d cycles=%0d", phase, cycles);
        end
        repeat (5) @(negedge clk);
        if (CORRUPT_READ != 0) begin
            if (!failed || done || report_count != 1 || errors == 0 ||
                expected == actual || error_address == 0)
                $fatal(1, "corruption did not produce a diagnostic failed=%b done=%b reports=%0d errors=%h address=%h expected=%h actual=%h",
                       failed, done, report_count, errors, error_address,
                       expected, actual);
            $display("PASS SDRAM benchmark fault clk=%0d period=%0.3f tac=%0.3f reports=%0d errors=%h address=%h expected=%h actual=%h",
                     CLK_MHZ, CLOCK_PERIOD_NS, T_AC, report_count, errors,
                     error_address, expected, actual);
            $finish;
        end else begin
        if (failed)
            $fatal(1, "benchmark engine failed errors=%h address=%h expected=%h actual=%h",
                   errors, error_address, expected, actual);
        if (!done || report_count != 6)
            $fatal(1, "benchmark did not complete all reports done=%b reports=%0d",
                   done, report_count);
        if (response_count != accepted_count || pending_count != 0)
            $fatal(1, "response accounting mismatch accepted=%0d responses=%0d pending=%0d",
                   accepted_count, response_count, pending_count);
        if (max_pending < 2 || max_consecutive < 8)
            $fatal(1, "queued/burst traffic not exercised pending=%0d burst=%0d",
                   max_pending, max_consecutive);
        if (phase_write_count[0] == 0 || phase_read_count[1] == 0 ||
            phase_read_count[2] == 0 || phase_write_count[3] == 0 ||
            phase_read_count[4] == 0 || phase_write_count[5] == 0 ||
            phase_read_count[5] == 0)
            $fatal(1, "benchmark phase traffic incomplete");
        if (nonsequential_count[2] == 0 || nonsequential_count[3] == 0)
            $fatal(1, "random traffic did not vary addresses");
        if (FULL_BITS >= 16 && phase_cycle_count[0] <= 65535 &&
            phase_cycle_count[1] <= 65535)
            $fatal(1, "long benchmark did not cross the 16-bit cycle carry");
        if (mask_count[0] == 0 || mask_count[15] == 0 ||
            mask_count[1] == 0 || mask_count[5] == 0)
            $fatal(1, "mask traffic did not cover zero/full/partial lanes");
        if (memory.refresh_count < 8)
            $fatal(1, "refresh coverage missing: %0d", memory.refresh_count);
        $display("PASS SDRAM benchmark clk=%0d period=%0.3f tac=%0.3f accepted=%0d reads=%0d writes=%0d max_pending=%0d max_burst=%0d refreshes=%0d reports=%0d",
                 CLK_MHZ, CLOCK_PERIOD_NS, T_AC, accepted_count, read_count,
                 write_count, max_pending, max_consecutive, memory.refresh_count,
                 report_count);
        $finish;
        end
    end
endmodule

`default_nettype wire
