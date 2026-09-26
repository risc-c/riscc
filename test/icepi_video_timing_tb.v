`timescale 1ns/1ps
`default_nettype none

// End-to-end IcePi video timing check.  This deliberately observes the four
// pins emitted by icepi_tmds_ddr instead of the scanout's internal counters.
// The ECP5 primitive models are supplied by tmds_serializer_tb.v.
module icepi_video_timing_tb #(
    parameter real PHASE_NS = 0.0
);
    localparam [9:0] CONTROL_00 = 10'b1101010100;
    localparam [9:0] CONTROL_01 = 10'b0010101011;
    localparam [9:0] CONTROL_10 = 10'b0101010100;
    localparam [9:0] CONTROL_11 = 10'b1010101011;

    reg pix_clk = 1'b0;
    reg shift_clk = 1'b0;
    always #5 pix_clk = ~pix_clk;
    initial begin
        #(PHASE_NS);
        forever #1 shift_clk = ~shift_clk;
    end

    reg rst = 1'b1;
    wire [3:0] tmds;

    // ICEPI_VIDEO_TEST supplies a fixed image independent of SDRAM. The
    // framebuffer/palette path has its own scanout regression.
    icepi_fb_dvi dut (
        .cpu_clk(pix_clk),
        .palette_we(1'b0),
        .palette_addr(8'd0),
        .palette_wdata(24'd0),
        .memory_clk(pix_clk),
        .memory_rst(1'b1),
        .memory_ready(1'b0),
        .memory_addr(),
        .memory_cyc(),
        .memory_stb(),
        .memory_stall(1'b0),
        .memory_ack(1'b0),
        .memory_rdata(32'd0),
        .underrun(),
        .pix_clk(pix_clk),
        .shift_clk(shift_clk),
        .rst(rst),
        .vblank(),
        .tmds(tmds)
    );

    function [23:0] test_color(input integer x, input integer y);
        begin
            if ((x < 4) || (x >= 1276) || (y < 4) || (y >= 716))
                test_color = 24'hffffff;
            else if (((x >= 638) && (x < 642)) ||
                     ((y >= 358) && (y < 362)))
                test_color = 24'hff00ff;
            else if ((x[5:0] == 0) || (y[5:0] == 0))
                test_color = 24'h404040;
            else if (x < 160)
                test_color = 24'hff0000;
            else if (x < 320)
                test_color = 24'hffff00;
            else if (x < 480)
                test_color = 24'h00ff00;
            else if (x < 640)
                test_color = 24'h00ffff;
            else if (x < 800)
                test_color = 24'h0000ff;
            else if (x < 960)
                test_color = 24'hff00ff;
            else if (x < 1120)
                test_color = 24'hffffff;
            else
                test_color = 24'h202020;
        end
    endfunction

    function is_control(input [9:0] symbol);
        begin
            is_control = (symbol == CONTROL_00) || (symbol == CONTROL_01) ||
                         (symbol == CONTROL_10) || (symbol == CONTROL_11);
        end
    endfunction

    function [1:0] control_code(input [9:0] symbol);
        begin
            case (symbol)
                CONTROL_00: control_code = 2'b00;
                CONTROL_01: control_code = 2'b01;
                CONTROL_10: control_code = 2'b10;
                CONTROL_11: control_code = 2'b11;
                default:    control_code = 2'bxx;
            endcase
        end
    endfunction

    function [7:0] decode_data(input [9:0] symbol);
        reg [8:0] q_m;
        reg use_xnor, invert;
        integer i;
        begin
            invert = symbol[9];
            use_xnor = !symbol[8];
            q_m[7:0] = symbol[7:0] ^ {8{invert}};
            decode_data[0] = q_m[0];
            for (i = 1; i < 8; i = i + 1)
                decode_data[i] = q_m[i - 1] ^ q_m[i] ^ use_xnor;
        end
    endfunction

    reg aligned = 1'b0;
    reg previous_hsync = 1'b0;
    reg previous_vsync = 1'b0;
    reg frame_started = 1'b0;
    reg finished = 1'b0;
    integer line_index = 0;
    integer raster_x = 0;
    integer raster_y = 0;
    integer line_symbols = 0;
    integer decoded_symbols = 0;

    task check_symbol(input [9:0] red, input [9:0] green,
                      input [9:0] blue, input integer x, input integer y);
        reg [1:0] control;
        reg current_hsync, current_vsync, current_de;
        reg [23:0] actual_rgb;
        begin
            if (is_control(blue)) begin
                control = control_code(blue);
                current_de = 1'b0;
                current_hsync = control[0];
                current_vsync = control[1];
                if (red !== CONTROL_00 || green !== CONTROL_00)
                    $fatal(1, "malformed control period x=%0d y=%0d r=%b g=%b b=%b",
                           x, y, red, green, blue);
            end else begin
                current_de = 1'b1;
                current_hsync = 1'b0;
                current_vsync = 1'b0;
                if (is_control(red) || is_control(green))
                    $fatal(1, "control symbol on active channel x=%0d y=%0d",
                           x, y);
                actual_rgb = {decode_data(red), decode_data(green),
                              decode_data(blue)};
            end

            // The CEA raster origin is the coincident leading edge of HSYNC
            // and VSYNC. The 1280x720 active image begins 260 pixels and 25
            // lines after that origin.
            if (current_de !== ((x >= 260) && (x < 1540) &&
                                (y >= 25) && (y < 745)))
                $fatal(1, "DE mismatch x=%0d y=%0d de=%b", x, y, current_de);
            if (current_hsync !== ((x < 40)))
                $fatal(1, "HSYNC mismatch x=%0d y=%0d hs=%b", x, y,
                       current_hsync);
            if (current_vsync !== ((y < 5)))
                $fatal(1, "VSYNC mismatch x=%0d y=%0d vs=%b", x, y,
                       current_vsync);
            if (current_de && actual_rgb !== test_color(x - 260, y - 25))
                $fatal(1, "RGB mismatch x=%0d y=%0d got=%h expected=%h",
                       x, y, actual_rgb, test_color(x - 260, y - 25));
        end
    endtask

    task process_pixel(input [9:0] red, input [9:0] green,
                       input [9:0] blue);
        reg [1:0] control;
        reg current_hsync, current_vsync;
        reg hsync_rise, vsync_rise;
        begin
            control = control_code(blue);
            current_hsync = is_control(blue) && control[0];
            current_vsync = is_control(blue) && control[1];
            hsync_rise = !previous_hsync && current_hsync;
            vsync_rise = !previous_vsync && current_vsync;

            if (!frame_started) begin
                if (vsync_rise) begin
                    if (!hsync_rise)
                        $fatal(1, "VSYNC began outside HSYNC at acquisition");
                    frame_started = 1'b1;
                    line_index = 0;
                    raster_x = 0;
                    raster_y = 0;
                    line_symbols = 0;
                end
            end else if (hsync_rise) begin
                if (line_symbols != 1650 || raster_x != 0)
                    $fatal(1, "line length/alignment mismatch before y=%0d: symbols=%0d x=%0d",
                           raster_y, line_symbols, raster_x);
                if (line_index == 749) begin
                    if (!vsync_rise)
                        $fatal(1, "frame ended without VSYNC rising at line 750");
                    finished = 1'b1;
                    $display("PASS IcePi external 720p raster: symbols=%0d lines=750 phase=%0.2f ns",
                             decoded_symbols, PHASE_NS);
                    $finish;
                end
                line_index = line_index + 1;
                raster_y = (raster_y == 749) ? 0 : raster_y + 1;
                raster_x = 0;
                line_symbols = 0;
            end

            if (frame_started && !finished) begin
                check_symbol(red, green, blue, raster_x, raster_y);
                line_symbols = line_symbols + 1;
                raster_x = (raster_x == 1649) ? 0 : raster_x + 1;
            end
            previous_hsync = current_hsync;
            previous_vsync = current_vsync;
            decoded_symbols = decoded_symbols + 1;
        end
    endtask

    task capture_quartet(output [3:0] red, output [3:0] green,
                         output [3:0] blue, output [3:0] clock);
        begin
            @(posedge dut.tmds_out.serial_clk);
            #0.1;
            red[0] = tmds[2]; green[0] = tmds[1];
            blue[0] = tmds[0]; clock[0] = tmds[3];
            @(negedge dut.tmds_out.edge_clk);
            #0.1;
            red[1] = tmds[2]; green[1] = tmds[1];
            blue[1] = tmds[0]; clock[1] = tmds[3];
            @(posedge dut.tmds_out.edge_clk);
            #0.1;
            red[2] = tmds[2]; green[2] = tmds[1];
            blue[2] = tmds[0]; clock[2] = tmds[3];
            @(negedge dut.tmds_out.edge_clk);
            #0.1;
            red[3] = tmds[2]; green[3] = tmds[1];
            blue[3] = tmds[0]; clock[3] = tmds[3];
        end
    endtask

    // The external clock channel repeats 1111100000. Five four-bit DDR
    // transfers therefore form one aligned 20-bit pair transfer.
    initial begin
        reg [3:0] red0, red1, red2, red3, red4;
        reg [3:0] green0, green1, green2, green3, green4;
        reg [3:0] blue0, blue1, blue2, blue3, blue4;
        reg [3:0] clock0, clock1, clock2, clock3, clock4;
        reg [19:0] clock_word, red_word, green_word, blue_word;
        integer candidate_count;
        wait (!rst);
        // Let the reset and pixel-pair crossings settle before acquisition.
        repeat (100) @(negedge pix_clk);
        candidate_count = 0;
        clock0 = 0; clock1 = 0; clock2 = 0; clock3 = 0; clock4 = 0;
        clock_word = 0;
        while (clock_word !== 20'b00000111110000011111) begin
            if (candidate_count == 50)
                $fatal(1, "could not acquire forwarded clock alignment");
            clock0 = clock1;
            clock1 = clock2;
            clock2 = clock3;
            clock3 = clock4;
            capture_quartet(red4, green4, blue4, clock4);
            clock_word = {clock4, clock3, clock2, clock1, clock0};
            candidate_count = candidate_count + 1;
        end
        aligned = 1'b1;
        forever begin
            capture_quartet(red0, green0, blue0, clock0);
            capture_quartet(red1, green1, blue1, clock1);
            capture_quartet(red2, green2, blue2, clock2);
            capture_quartet(red3, green3, blue3, clock3);
            capture_quartet(red4, green4, blue4, clock4);
            clock_word = {clock4, clock3, clock2, clock1, clock0};
            red_word = {red4, red3, red2, red1, red0};
            green_word = {green4, green3, green2, green1, green0};
            blue_word = {blue4, blue3, blue2, blue1, blue0};
            if (clock_word !== 20'b00000111110000011111)
                $fatal(1, "forwarded clock is not five-high/five-low: %b",
                       clock_word);
            process_pixel(red_word[9:0], green_word[9:0], blue_word[9:0]);
            process_pixel(red_word[19:10], green_word[19:10],
                          blue_word[19:10]);
        end
    end

    initial begin
        repeat (20) @(negedge pix_clk);
        rst = 1'b0;
    end

    initial begin
        #20000000;
        if (!finished)
            $fatal(1, "IcePi external 720p raster timeout (aligned=%b frame=%b symbols=%0d)",
                   aligned, frame_started, decoded_symbols);
    end
endmodule

`default_nettype wire
