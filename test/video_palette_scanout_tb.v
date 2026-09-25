`timescale 1ns/1ps
`default_nettype none

// Exercise the shared scanout/palette path. The SDRAM model returns indexed
// pixels from row/word addresses; the checker observes the delayed parallel
// stream and verifies the first 320-pixel source row at either supported
// integer scale.
module video_palette_scanout_tb #(
    parameter integer SCALE = 6
);
    localparam integer H_TOTAL = SCALE == 4 ? 1650 : 2200;
    localparam integer H_SYNC = SCALE == 4 ? 40 : 44;
    localparam integer H_ACTIVE_START = SCALE == 4 ? 260 : 192;
    localparam integer H_ACTIVE_END = SCALE == 4 ? 1540 : 2112;
    localparam integer V_TOTAL = SCALE == 4 ? 750 : 1125;
    localparam integer V_SYNC = 5;
    localparam integer V_ACTIVE_START = SCALE == 4 ? 25 : 41;
    localparam integer V_ACTIVE_END = SCALE == 4 ? 745 : 1121;
    localparam integer ACTIVE_PIXELS = 320 * SCALE;
    reg cpu_clk = 1'b0;
    reg memory_clk = 1'b0;
    reg pix_clk = 1'b0;
    always #3 cpu_clk = ~cpu_clk;
    always #2 memory_clk = ~memory_clk;
    always #1 pix_clk = ~pix_clk;

    reg [7:0] palette_addr = 8'd0;
    reg [23:0] palette_wdata = 24'd0;
    reg palette_we = 1'b0;
    reg memory_rst = 1'b1;
    reg memory_ready = 1'b0;
    reg rst = 1'b1;
    wire [23:0] memory_addr;
    wire memory_cyc, memory_stb;
    wire memory_stall;
    reg memory_ack = 1'b0;
    reg [31:0] memory_rdata = 32'd0;
    wire underrun;
    wire hdmi_hs, hdmi_vs, hdmi_de;
    wire [23:0] hdmi_rgb;

    riscc_video_parallel #(.SCALE(SCALE)) dut (
        .cpu_clk(cpu_clk), .palette_we(palette_we),
        .palette_addr(palette_addr), .palette_wdata(palette_wdata),
        .memory_clk(memory_clk), .memory_rst(memory_rst),
        .memory_ready(memory_ready), .memory_addr(memory_addr),
        .memory_cyc(memory_cyc), .memory_stb(memory_stb),
        .memory_stall(memory_stall), .memory_ack(memory_ack),
        .memory_rdata(memory_rdata), .underrun(underrun),
        .pix_clk(pix_clk), .rst(rst),
        .hdmi_hs(hdmi_hs), .hdmi_vs(hdmi_vs), .hdmi_de(hdmi_de),
        .hdmi_rgb(hdmi_rgb)
    );

    function [7:0] pixel_index(input integer row, input integer column);
        pixel_index = (row * 13 + column * 3 + column / 4) & 255;
    endfunction

    function [23:0] palette_color(input integer entry);
        palette_color = {entry[7:0], (entry ^ 8'ha5),
                         (entry * 8'h3d) ^ 8'h5a};
    endfunction

    function [31:0] memory_word(input integer row, input integer word);
        integer column;
        begin
            column = word * 4;
            memory_word = {pixel_index(row, column + 3),
                           pixel_index(row, column + 2),
                           pixel_index(row, column + 1),
                           pixel_index(row, column)};
        end
    endfunction

    task write_palette(input integer entry);
        begin
            @(negedge cpu_clk);
            palette_addr = entry[7:0];
            palette_wdata = palette_color(entry);
            palette_we = 1'b1;
            @(posedge cpu_clk);
            #1;
            @(negedge cpu_clk);
            palette_we = 1'b0;
        end
    endtask

    // Queued SDRAM responses with randomized latency and backpressure. The
    // scanout issues all 80 words for each source row before replies drain.
    localparam integer QUEUE_DEPTH = 32;
    reg [23:0] memory_queue_addr [0:QUEUE_DEPTH-1];
    integer memory_queue_due [0:QUEUE_DEPTH-1];
    integer memory_queue_head = 0;
    integer memory_queue_tail = 0;
    integer memory_queue_count = 0;
    integer memory_cycle = 0;
    integer memory_accepts = 0;
    integer memory_max_pending = 0;
    integer memory_pipelined = 0;
    reg [31:0] memory_random = 32'h4b1d2e39;
    wire memory_pop = memory_queue_count != 0 &&
                      memory_queue_due[memory_queue_head] <= memory_cycle;
    assign memory_stall = memory_queue_count >= QUEUE_DEPTH - 1 ||
                          memory_random[0];
    always @(posedge memory_clk) begin
        memory_ack <= 1'b0;
        memory_random <= {memory_random[30:0],
                          memory_random[31] ^ memory_random[21] ^
                          memory_random[1] ^ memory_random[0]};
        if (memory_rst) begin
            memory_queue_head = 0;
            memory_queue_tail = 0;
            memory_queue_count = 0;
            memory_cycle = 0;
            memory_accepts = 0;
            memory_max_pending = 0;
            memory_pipelined = 0;
        end else begin
            memory_cycle = memory_cycle + 1;
            if (memory_pop) begin
                memory_rdata <= memory_word(memory_queue_addr[memory_queue_head] / 80,
                                             memory_queue_addr[memory_queue_head] % 80);
                memory_ack <= 1'b1;
                memory_queue_head = (memory_queue_head + 1) % QUEUE_DEPTH;
            end
            if (memory_stb && !memory_stall) begin
                if (!memory_cyc)
                    $fatal(1, "SDRAM stb without cyc");
                memory_queue_addr[memory_queue_tail] <= memory_addr;
                memory_queue_due[memory_queue_tail] <= memory_cycle +
                    2 + memory_random[4:2];
                memory_queue_tail = (memory_queue_tail + 1) % QUEUE_DEPTH;
                memory_accepts = memory_accepts + 1;
                if (memory_queue_count != 0)
                    memory_pipelined = memory_pipelined + 1;
            end
            case ({memory_stb && !memory_stall, memory_pop})
                2'b10: memory_queue_count = memory_queue_count + 1;
                2'b01: memory_queue_count = memory_queue_count - 1;
                default: ;
            endcase
            if (memory_queue_count > memory_max_pending)
                memory_max_pending = memory_queue_count;
        end
    end

    integer i;
    integer displayed;
    integer guard;
    integer line_cycles;
    integer h_sample;
    initial begin
        // Populate every palette entry, including values above the old 4-bit
        // framebuffer range, while video remains in reset.
        for (i = 0; i < 256; i = i + 1)
            write_palette(i);

        repeat (4) @(posedge memory_clk);
        memory_ready = 1'b1;
        memory_rst = 1'b0;
        rst = 1'b0;

        // Wait for the first delayed active interval, then verify all output
        // pixels of the first 320-pixel source row.
        guard = 0;
        while (!hdmi_de) begin
            @(posedge pix_clk);
            #1;
            guard = guard + 1;
            if (guard > 3000000)
                $fatal(1, "timed out waiting for HDMI active output");
        end
        if (hdmi_vs !== 1'b1)
            $fatal(1, "active video started during vertical sync");
        if (hdmi_hs !== 1'b1)
            $fatal(1, "active video started during horizontal sync");

        // Check the active row's palette alignment and then its blanking
        // interval. The cycle count catches accidental use of 1080p timing
        // for the 720p mode (or vice versa).
        for (displayed = 0; displayed < ACTIVE_PIXELS;
             displayed = displayed + 1) begin
            if (!hdmi_de)
                $fatal(1, "active video ended at pixel %0d", displayed);
            if (hdmi_hs !== (H_ACTIVE_START + displayed >= H_SYNC))
                $fatal(1, "horizontal sync alignment at pixel %0d", displayed);
            if (hdmi_rgb !== palette_color(pixel_index(0, displayed / SCALE)))
                $fatal(1, "HDMI pixel %0d: got %h expected %h", displayed,
                       hdmi_rgb, palette_color(pixel_index(0, displayed / SCALE)));
            @(posedge pix_clk);
            #1;
        end
        if (hdmi_de)
            $fatal(1, "active video did not end at the expected width");

        line_cycles = ACTIVE_PIXELS;
        h_sample = H_ACTIVE_END;
        while (!hdmi_de) begin
            if (hdmi_hs !== (h_sample >= H_SYNC))
                $fatal(1, "horizontal sync alignment in blanking at cycle %0d",
                       line_cycles);
            @(posedge pix_clk);
            #1;
            line_cycles = line_cycles + 1;
            h_sample = h_sample + 1;
            if (h_sample == H_TOTAL)
                h_sample = 0;
            if (line_cycles > H_TOTAL)
                $fatal(1, "horizontal line exceeded expected period");
        end
        if (line_cycles != H_TOTAL)
            $fatal(1, "horizontal period %0d expected %0d",
                   line_cycles, H_TOTAL);

        // Check one complete following line, including the low horizontal
        // sync pulse at its beginning and the active/de transition.
        h_sample = H_ACTIVE_START;
        for (line_cycles = 0; line_cycles < H_TOTAL;
             line_cycles = line_cycles + 1) begin
            if (hdmi_de !== (h_sample >= H_ACTIVE_START &&
                             h_sample < H_ACTIVE_END))
                $fatal(1, "data enable alignment at horizontal cycle %0d",
                       line_cycles);
            if (hdmi_hs !== (h_sample >= H_SYNC))
                $fatal(1, "horizontal sync width at cycle %0d", line_cycles);
            if (hdmi_vs !== 1'b1)
                $fatal(1, "vertical sync asserted in active frame");
            @(posedge pix_clk);
            #1;
            h_sample = h_sample + 1;
            if (h_sample == H_TOTAL)
                h_sample = 0;
        end
        if (underrun)
            $fatal(1, "unexpected scanout underrun");
        if (memory_max_pending < 2 || memory_pipelined == 0)
            $fatal(1, "scanout did not pipeline reads (max_pending=%0d pipelined=%0d)",
                   memory_max_pending, memory_pipelined);
        $display("PASS video palette scanout: scale %0d (%0dx%0d), active %0d pixels, line %0d cycles (max %0d outstanding)",
                 SCALE, H_TOTAL, V_TOTAL, ACTIVE_PIXELS, H_TOTAL,
                 memory_max_pending);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "video palette scanout timeout");
    end
endmodule

`default_nettype wire
