`timescale 1ns/1ps
`default_nettype none

// Exercise the complete IcePi DVI scanout/palette path.  The checker uses
// the internal pre-TMDS RGB/DE signals because the serializer is unrelated to
// indexed framebuffer addressing.
module video_palette_icepi_tb;
    reg cpu_clk = 1'b0;
    reg memory_clk = 1'b0;
    reg pix_clk = 1'b0;
    reg shift_clk = 1'b0;
    always #3 cpu_clk = ~cpu_clk;
    always #2 memory_clk = ~memory_clk;
    // 1280x720p60 uses a 74.285714 MHz pixel clock (13.461538 ns period).
    // The serializer simulation is selected with VERILATOR below, while this
    // clock still exercises the board-rate scanout timing.
    always #6.730769 pix_clk = ~pix_clk;
    always #0.5 shift_clk = ~shift_clk;

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
    wire [3:0] tmds;

    icepi_fb_dvi dut (
        .cpu_clk(cpu_clk), .palette_we(palette_we),
        .palette_addr(palette_addr), .palette_wdata(palette_wdata),
        .memory_clk(memory_clk), .memory_rst(memory_rst),
        .memory_ready(memory_ready), .memory_addr(memory_addr),
        .memory_cyc(memory_cyc), .memory_stb(memory_stb),
        .memory_stall(memory_stall), .memory_ack(memory_ack),
        .memory_rdata(memory_rdata), .underrun(underrun),
        .pix_clk(pix_clk), .shift_clk(shift_clk), .rst(rst), .tmds(tmds),
        .vblank()
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
    integer visible_line;
    integer guard;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            write_palette(i);

        if (dut.H_ACTIVE !== 1280 || dut.H_TOTAL !== 1650 ||
            dut.V_ACTIVE !== 720 || dut.V_TOTAL !== 750)
            $fatal(1, "IcePi timing is not 1280x720p60");

        repeat (4) @(posedge memory_clk);
        memory_ready = 1'b1;
        memory_rst = 1'b0;
        rst = 1'b0;

        // The framebuffer fills the 1280x720 active region at exactly 4x.
        // Check two source rows so both horizontal and vertical replication
        // are exercised without simulating a complete frame.
        visible_line = 0;
        guard = 0;
        while (visible_line < 8) begin
            displayed = 0;
            while (!dut.active_d) begin
                @(posedge pix_clk);
                #1;
                guard = guard + 1;
                if (guard > 10000000)
                    $fatal(1, "timed out waiting for IcePi framebuffer output");
            end
            while (displayed < 1280) begin
                if (!dut.active_d)
                    $fatal(1, "IcePi framebuffer line ended at pixel %0d", displayed);
                if (dut.rgb !== palette_color(
                        pixel_index(visible_line / 4, displayed / 4)))
                    $fatal(1, "IcePi line %0d pixel %0d: got %h expected %h",
                           visible_line, displayed, dut.rgb,
                           palette_color(pixel_index(visible_line / 4,
                                                    displayed / 4)));
                @(posedge pix_clk);
                #1;
                displayed = displayed + 1;
            end
            // The next pixel is the horizontal blanking interval. This also
            // checks that the active region is exactly 1280 pixels wide.
            if (dut.active_d)
                $fatal(1, "IcePi framebuffer active region exceeds 1280 pixels");
            visible_line = visible_line + 1;
        end
        if (underrun)
            $fatal(1, "unexpected IcePi scanout underrun");
        if (memory_max_pending < 2 || memory_pipelined == 0)
            $fatal(1, "scanout did not pipeline reads (max_pending=%0d pipelined=%0d)",
                   memory_max_pending, memory_pipelined);
        $display("PASS IcePi video palette scanout: 256 colors, 1280x720 timing, 4x scaling (max %0d outstanding)",
                 memory_max_pending);
        $finish;
    end

    initial begin
        #10000000;
        $fatal(1, "IcePi video palette scanout timeout");
    end
endmodule

`default_nettype wire
