`timescale 1ns/1ps
`default_nettype none
module cpu_memory_tb #(
    parameter integer DATA_BITS = 16,
    parameter realtime CPU_PERIOD = 15.0
);
    localparam integer ADDRESS_BITS = DATA_BITS == 16 ? 23 : 24;
    reg cpu_clk = 0, memory_clk = 0;
    always #(CPU_PERIOD/2) cpu_clk = ~cpu_clk;
    always #3 memory_clk = ~memory_clk;
    reg rst = 1;
    wire [23:0] cpu_addr, memory_addr;
    wire [31:0] cpu_wdata, cpu_rdata, memory_wdata, memory_rdata;
    wire [3:0] cpu_wmask, memory_wmask;
    wire cpu_we, cpu_cyc, cpu_stb, cpu_stall, cpu_ack, cpu_ready;
    wire memory_we, memory_cyc, memory_stb, memory_stall, memory_ack, memory_ready;
    wire [`LED_BITS-1:0] led;
    `SOC_NAME #(.MEM_HEX(`FIRMWARE), .UART_CLK_DIV(8), .TIMER_TICK_DIV(10000)) dut (
        .clk(cpu_clk), .rst(rst), .uart_rx(1'b1), .button(2'b11),
        .uart_tx(), .led(led), .palette_we(), .palette_addr(), .palette_wdata(), .fb_we(), .fb_addr(), .fb_wmask(), .fb_wdata(), .dbg_fb_writes(), .dbg_uart_tx_count(), .dbg_uart_rx_count(),
        .sdram_addr(cpu_addr), .sdram_wdata(cpu_wdata), .sdram_wmask(cpu_wmask),
        .sdram_we(cpu_we), .sdram_cyc(cpu_cyc), .sdram_stb(cpu_stb),
        .sdram_stall(cpu_stall), .sdram_ack(cpu_ack), .sdram_rdata(cpu_rdata)
    );
    reg [23:0] video_addr = 0;
    reg video_cyc = 0, video_stb = 0;
    wire video_stall, video_ack;
    wire [31:0] video_rdata;
    riscc_sdram_fabric fabric (
        .cpu_clk(cpu_clk), .cpu_rst(rst), .memory_clk(memory_clk), .memory_rst(rst),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_wmask(cpu_wmask),
        .cpu_we(cpu_we), .cpu_cyc(cpu_cyc), .cpu_stb(cpu_stb),
        .cpu_stall(cpu_stall), .cpu_ack(cpu_ack), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .video_addr(video_addr), .video_cyc(video_cyc), .video_stb(video_stb),
        .video_stall(video_stall), .video_ack(video_ack), .video_rdata(video_rdata),
        .memory_addr(memory_addr), .memory_wdata(memory_wdata), .memory_wmask(memory_wmask),
        .memory_we(memory_we), .memory_cyc(memory_cyc), .memory_stb(memory_stb),
        .memory_stall(memory_stall), .memory_ack(memory_ack), .memory_rdata(memory_rdata),
        .memory_ready(memory_ready)
    );
    wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire [12:0] sd_addr;
    wire [1:0] sd_ba;
    wire [DATA_BITS/8-1:0] sd_dqm;
    wire [DATA_BITS-1:0] sd_dq_i, sd_dq_o;
    riscc_sdram #(.DATA_BITS(DATA_BITS), .CLK_MHZ(167), .INIT_CYCLES(4000), .FIFO_BITS(3),
                  .REFRESH_CYCLES(100), .TRCD(4), .TRP(4), .TRFC(14), .TRAS(8), .TWR(3)) controller (
        .clk(memory_clk), .rst(rst), .mem_addr(memory_addr[ADDRESS_BITS-1:0]),
        .mem_wdata(memory_wdata), .mem_wmask(memory_wmask), .mem_we(memory_we),
        .mem_cyc(memory_cyc), .mem_stb(memory_stb), .mem_stall(memory_stall),
        .mem_ack(memory_ack), .mem_rdata(memory_rdata), .ready(memory_ready),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm),
        .sd_dq_i(sd_dq_i), .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe)
    );
    riscc_sdram_model #(.DATA_BITS(DATA_BITS), .INIT_CYCLES(4000),
        .TRCD(4), .TRP(4), .TRFC(14), .TRAS(8), .TWR(3), .T_AC(0.1), .MAX_REFRESH_GAP(160)) memory (
        .clk(~memory_clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba),
        .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe(sd_dq_oe), .dq_o(sd_dq_i)
    );
    integer reads = 0, writes = 0, video_reads = 0, cycles = 0;
    integer phase_reads = 0, phase_writes = 0, passes = 0;
    integer memory_accepts = 0, memory_responses = 0;
    integer memory_outstanding = 0, memory_max_outstanding = 0;
    integer cpu_accepts = 0, cpu_responses = 0;
    integer cpu_outstanding = 0, cpu_max_outstanding = 0;
    integer early_write_acks = 0;
    integer sequential_reads = 0;
    integer physical_reads = 0;
    integer physical_read_streak = 0, physical_max_read_streak = 0;
    integer physical_read_gap = 0;
    integer physical_read_cadence = 0, physical_max_read_cadence = 0;
    reg physical_read_seen = 0;
    localparam integer PHYSICAL_READ_PERIOD = DATA_BITS == 16 ? 2 : 1;
    reg previous_memory_read = 0;
    reg [23:0] previous_memory_addr = 0;
    reg [3:0] phase = 0;
    // Hold initialization long enough for the CPU to reach its first store.
    reg waited_for_sdram = 0;
    reg [31:0] rng = 1;
    localparam integer VIDEO_QUEUE_DEPTH = 16;
    reg [23:0] video_expected [0:VIDEO_QUEUE_DEPTH-1];
    integer video_queue_head = 0, video_queue_tail = 0;
    integer video_queue_count = 0, video_max_pending = 0;
    integer video_pipelined = 0;
    integer metadata_checks = 0;
    wire backing_accept = dut.cpu.mem_cyc && dut.cpu.mem_stb &&
                          !dut.cpu.mem_stall;
    wire backing_is_sdram = DATA_BITS == 16 ?
        dut.cpu.mem_addr[29:23] == 7'h08 : dut.cpu.mem_addr[29:24] == 6'h04;
    wire memory_accept = memory_cyc && memory_stb && !memory_stall;
    wire physical_read = !sd_cs_n && sd_ras_n && !sd_cas_n && sd_we_n;
    wire video_accept = video_cyc && video_stb && !video_stall;

    // The SDRAM fabric must be able to keep a line refill in flight.  Count
    // accepted commands at the controller boundary, rather than CPU-side
    // requests, so this catches a serial bridge hidden behind a fast cache.
    always @(posedge memory_clk) begin
        if (rst) begin
            memory_accepts = 0;
            early_write_acks = 0;
            memory_responses = 0;
            memory_outstanding = 0;
            memory_max_outstanding = 0;
            cpu_accepts = 0;
            cpu_responses = 0;
            cpu_outstanding = 0;
            cpu_max_outstanding = 0;
            sequential_reads = 0;
            physical_reads = 0;
            physical_read_streak = 0;
            physical_max_read_streak = 0;
            physical_read_gap = 0;
            physical_read_cadence = 0;
            physical_max_read_cadence = 0;
            physical_read_seen = 0;
            previous_memory_read = 0;
            previous_memory_addr = 0;
        end else begin
            // The controller owns the payload after capture.
            // Physical completion must not acknowledge a later bridge request.
            if ((fabric.cpu_accept && fabric.host_we)) begin
                if (!fabric.host_ack)
                    $fatal(1, "write not acknowledged at controller capture");
                if (!memory_ack) early_write_acks = early_write_acks + 1;
            end
            if (fabric.host_ack && fabric.owner_write_q && !(fabric.cpu_accept && fabric.host_we))
                $fatal(1, "early or duplicate write acknowledgement");
            if (physical_read) begin
                physical_reads = physical_reads + 1;
                physical_read_streak = physical_read_streak + 1;
                if (physical_read_seen && physical_read_gap < PHYSICAL_READ_PERIOD)
                    physical_read_cadence = physical_read_cadence + 1;
                else
                    physical_read_cadence = 1;
                physical_read_gap = 0;
                physical_read_seen = 1;
            end else begin
                physical_read_streak = 0;
                if (physical_read_seen)
                    physical_read_gap = physical_read_gap + 1;
            end
            if (physical_read_streak > physical_max_read_streak)
                physical_max_read_streak = physical_read_streak;
            if (physical_read_cadence > physical_max_read_cadence)
                physical_max_read_cadence = physical_read_cadence;
            if (memory_ack) begin
                if (memory_outstanding == 0)
                    $fatal(1, "SDRAM response without an outstanding command");
                memory_outstanding = memory_outstanding - 1;
                memory_responses = memory_responses + 1;
                if (!fabric.owner_video_q) begin
                    if (cpu_outstanding == 0)
                        $fatal(1, "CPU SDRAM response without an outstanding command");
                    cpu_outstanding = cpu_outstanding - 1;
                    cpu_responses = cpu_responses + 1;
                end
            end
            if (memory_accept) begin
                memory_outstanding = memory_outstanding + 1;
                memory_accepts = memory_accepts + 1;
                if (!fabric.owner_video_q) begin
                    cpu_outstanding = cpu_outstanding + 1;
                    cpu_accepts = cpu_accepts + 1;
                end
                if (!memory_we && previous_memory_read &&
                    memory_addr == previous_memory_addr + 1'b1)
                    sequential_reads = sequential_reads + 1;
                previous_memory_read = !memory_we;
                previous_memory_addr = memory_addr;
            end
            if (memory_outstanding > memory_max_outstanding)
                memory_max_outstanding = memory_outstanding;
            if (cpu_outstanding > cpu_max_outstanding)
                cpu_max_outstanding = cpu_outstanding;
        end
    end

    // Video fetch runs in the memory domain and verifies CPU writes directly in SDRAM.
    always @(posedge memory_clk) begin
        if (rst) begin
            video_cyc <= 0; video_stb <= 0;
            video_addr <= 0; video_reads <= 0;
            video_queue_head = 0;
            video_queue_tail = 0;
            video_queue_count = 0;
            video_max_pending = 0;
            video_pipelined = 0;
        end else begin
            rng <= (rng << 1) ^ (rng[31] ? 32'h04c11db7 : 32'd0);
            if (video_ack) begin
                if (video_queue_count == 0)
                    $fatal(1, "video response without an outstanding request");
                if (video_rdata !== 32'ha5000000 +
                    {8'd0,video_expected[video_queue_head]})
                    $fatal(1, "video stale/corrupt word %h got %h",
                           video_expected[video_queue_head], video_rdata);
                video_reads <= video_reads + 1;
                video_queue_head = (video_queue_head + 1) % VIDEO_QUEUE_DEPTH;
            end
            if (video_accept) begin
                video_expected[video_queue_tail] <= video_addr;
                video_queue_tail = (video_queue_tail + 1) % VIDEO_QUEUE_DEPTH;
                video_addr <= video_addr == 39 ? 0 : video_addr + 1;
                if (video_queue_count != 0)
                    video_pipelined = video_pipelined + 1;
            end
            case ({video_accept, video_ack})
                2'b10: video_queue_count = video_queue_count + 1;
                2'b01: video_queue_count = video_queue_count - 1;
                default: ;
            endcase
            if (video_queue_count > video_max_pending)
                video_max_pending = video_queue_count;
            // Keep several reads in flight, while leaving room for the
            // fabric to apply backpressure and arbitrate CPU refills.
            if (video_cyc && video_stb && video_stall) begin
                // A stalled request must retain its address and strobe until
                // the fabric accepts it.
                video_cyc <= 1;
                video_stb <= 1;
            end else begin
                video_cyc <= phase != 0 || video_queue_count != 0;
                video_stb <= phase != 0 && video_queue_count < 8 && rng[2:0] != 0;
            end
        end
    end
    always @(posedge cpu_clk) begin
        if (cycles > 2000000) $fatal(1, "CPU SDRAM timeout phase=%0d", phase);
        if (rst) begin
            cycles <= 0;
            reads = 0; writes = 0; phase = 0;
            waited_for_sdram = 0;
            metadata_checks = 0;
        end else begin
            cycles <= cycles + 1;
            if (backing_accept) begin
                if (dut.cpu.mem_addr < 30'h1000)
                    $fatal(1, "local SRAM request reached backing port");
                if (dut.cpu.mem_cacheable !== backing_is_sdram)
                    $fatal(1, "cache-region selection mismatch at %h", dut.cpu.mem_addr);
                metadata_checks = metadata_checks + 1;
            end
            if (cpu_cyc && cpu_stb && !cpu_ready) begin
                if (!cpu_stall || cpu_ack) $fatal(1, "SDRAM access accepted before ready");
                waited_for_sdram = 1;
            end
            // The LED is written by the CPU on an earlier edge. Check the
            // completed phase before counting a request accepted on this
            // edge, so that the request belongs to the following phase.
            if (led[3:0] != phase) begin
                case (led[3:0])
                    1: if (reads != 0 || writes != 56) $fatal(1,"store miss allocated reads=%0d writes=%0d",reads,writes);
                    2: if (reads-phase_reads != 16) $fatal(1,"cold refill was not 64 bytes");
                    3: if (reads != phase_reads) $fatal(1,"warm cache reads reached SDRAM");
                    4: if (reads != phase_reads || writes-phase_writes != 2) $fatal(1,"masked store hit not write-through");
                    5: if (reads-phase_reads != 32 || writes-phase_writes != 1) $fatal(1,"conflict refills did not fetch two 64-byte lines");
                    14: $fatal(1,"CPU firmware data mismatch phase=%0d",phase);
                    15: begin
                        if (!waited_for_sdram) $fatal(1, "missing initialization stall coverage");
                        if (metadata_checks == 0) $fatal(1, "missing cache-region checks");
                        if (video_reads < 40 || video_max_pending < 2 ||
                            video_pipelined == 0 || memory.refresh_count < 10)
                            $fatal(1,"missing video pipeline/refresh coverage video=%0d max=%0d pipelined=%0d",
                                   video_reads, video_max_pending, video_pipelined);
                        if (early_write_acks == 0)
                            $fatal(1, "no write acknowledged before physical completion");
                        if (sequential_reads < 8 || cpu_max_outstanding < 2 ||
                            physical_max_read_cadence < 4)
                            $fatal(1, "SDRAM reads were not pipelined sequential=%0d cpu_max=%0d physical_cadence=%0d",
                                   sequential_reads, cpu_max_outstanding,
                                   physical_max_read_cadence);
                        passes = passes + 1;
                        $display("PASS CPU SDRAM x%0d run=%0d cycles=%0d reads=%0d writes=%0d video=%0d video_max=%0d refresh=%0d memory_accepts=%0d cpu_accepts=%0d sequential_reads=%0d max_outstanding=%0d cpu_max=%0d physical_reads=%0d physical_cadence=%0d",
                                 DATA_BITS,passes,cycles,reads,writes,video_reads,
                                 video_max_pending,memory.refresh_count,
                                 memory_accepts,cpu_accepts,sequential_reads,
                                 memory_max_outstanding,cpu_max_outstanding,
                                 physical_reads,physical_max_read_cadence);
                    end
                    default: $fatal(1,"unexpected CPU phase %d",led);
                endcase
                phase = led[3:0]; phase_reads = reads; phase_writes = writes;
            end
            if (cpu_cyc && cpu_stb && !cpu_stall) begin
                if (cpu_we) writes = writes + 1;
                else reads = reads + 1;
            end
        end
    end
    initial begin
        if (!$value$plusargs("SEED=%d",rng)) rng = 1;
        repeat (8) @(negedge cpu_clk); rst = 0;
        wait(passes == 1);
        @(negedge cpu_clk); rst = 1;
        repeat (8) @(negedge cpu_clk); rst = 0;
        wait(passes == 2);
        $finish;
    end
endmodule
`default_nettype wire
