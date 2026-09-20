`timescale 1ns/1ps
`default_nettype none

// Behavioral models for the ECP5 clock and four-bit DDR output primitives.
// The real ODDRX2F emits D0..D3 over the four ECLK edges in one serial-clock
// period. This model presents those same bits on Q for reconstruction.
module ECLKSYNCB(input wire ECLKI, input wire STOP, output wire ECLKO);
    assign ECLKO = ECLKI;
endmodule

module CLKDIVF (
    input wire CLKI, RST, ALIGNWD,
    output reg CDIVX
);
    parameter DIV = "2.0";
    initial CDIVX = 1'b0;
    always @(posedge CLKI)
        CDIVX <= RST ? 1'b0 : ~CDIVX;
endmodule

module ODDRX2F (
    input wire SCLK, ECLK, RST,
    input wire D0, D1, D2, D3,
    output reg Q
);
    integer phase;
    reg d1_q, d2_q, d3_q;
    initial begin Q = 1'b0; phase = 0; end
    // SCLK is the first ECLK edge of a four-edge transfer.
    always @(posedge SCLK) begin
        if (RST) phase = 0;
        else begin
            // Capture the full quartet before the serializer shifts its
            // source register on this same clock edge.
            d1_q = D1;
            d2_q = D2;
            d3_q = D3;
            Q <= D0;
            phase = 1;
        end
    end
    always @(negedge ECLK) begin
        if (RST) phase = 0;
        else if (phase == 1) begin Q <= d1_q; phase = 2; end
        else if (phase == 3) begin Q <= d3_q; phase = 0; end
    end
    always @(posedge ECLK) begin
        if (RST) phase = 0;
        else if (phase == 2) begin Q <= d2_q; phase = 3; end
    end
endmodule

module tmds_serializer_tb #(
    parameter real PHASE_NS = 0.0
);
    reg pix_clk = 1'b0;
    reg shift_clk = 1'b0;
    always #5 pix_clk = ~pix_clk;
    // Five edge-clock cycles per pixel. CLKDIVF creates the 2.5x serial clk.
    initial begin
        shift_clk = 1'b0;
        #(1.0 + PHASE_NS);
        forever #1 shift_clk = ~shift_clk;
    end

    reg rst = 1'b1;
    reg [7:0] r = 8'd0, g = 8'd0, b = 8'd0;
    reg hsync = 1'b0, vsync = 1'b0, de = 1'b0;
    wire [3:0] tmds;
    icepi_tmds_ddr dut (
        .pix_clk(pix_clk), .shift_clk(shift_clk), .rst(rst),
        .r(r), .g(g), .b(b), .hsync(hsync), .vsync(vsync), .de(de),
        .tmds(tmds)
    );

    function integer signed4(input integer value);
        integer reduced;
        begin
            reduced = value & 15;
            signed4 = reduced >= 8 ? reduced - 16 : reduced;
        end
    endfunction

    task reference_encode(input [7:0] in_data, output [9:0] symbol,
                          inout integer disparity);
        reg [8:0] q_m;
        reg use_xnor, sign_equal, invert, subtract_one;
        integer ones, q_ones, balance, step, i;
        begin
            ones = 0;
            for (i = 0; i < 8; i = i + 1) ones = ones + in_data[i];
            use_xnor = (ones > 4) || ((ones == 4) && !in_data[0]);
            q_m[0] = in_data[0];
            for (i = 1; i < 8; i = i + 1)
                q_m[i] = q_m[i - 1] ^ in_data[i] ^ use_xnor;
            q_m[8] = ~use_xnor;
            q_ones = 0;
            for (i = 0; i < 8; i = i + 1) q_ones = q_ones + q_m[i];
            balance = signed4(q_ones - 4);
            sign_equal = (balance < 0) == (disparity < 0);
            if ((balance == 0) || (disparity == 0)) invert = !q_m[8];
            else invert = sign_equal;
            subtract_one = (q_m[8] == sign_equal) &&
                           (balance != 0) && (disparity != 0);
            step = signed4(balance - (subtract_one ? 1 : 0));
            if (invert) disparity = signed4(disparity - step);
            else disparity = signed4(disparity + step);
            symbol = {invert, q_m[8], q_m[7:0] ^ {8{invert}}};
        end
    endtask

    localparam integer PIXELS = 64;
    localparam integer SERIAL_CYCLES = 700;
    reg [7:0] input_r [0:PIXELS-1], input_g [0:PIXELS-1];
    reg [7:0] input_b [0:PIXELS-1];
    reg [9:0] expected_r [0:PIXELS-1], expected_g [0:PIXELS-1];
    reg [9:0] expected_b [0:PIXELS-1];
    reg [3:0] captured_r [0:SERIAL_CYCLES-1];
    reg [3:0] captured_g [0:SERIAL_CYCLES-1];
    reg [3:0] captured_b [0:SERIAL_CYCLES-1];
    reg [3:0] captured_clock [0:SERIAL_CYCLES-1];
    integer i, serial_count;
    integer dr, dg, db;
    reg [31:0] seed;

    task feed_pixels;
        begin
            for (i = 0; i < PIXELS; i = i + 1) begin
                @(negedge pix_clk);
                r = input_r[i]; g = input_g[i]; b = input_b[i]; de = 1'b1;
            end
            for (i = 0; i < 100; i = i + 1) begin
                @(negedge pix_clk);
                r = 0; g = 0; b = 0; de = 1'b0;
                hsync = i[0]; vsync = i[1];
            end
        end
    endtask

    // Sample one complete four-bit ODDRX2F transfer on each serial clock.
    task capture_serial;
        begin
            for (serial_count = 0; serial_count < SERIAL_CYCLES;
                 serial_count = serial_count + 1) begin
                @(posedge dut.serial_clk);
                #0.1; captured_r[serial_count][0] = tmds[2];
                captured_g[serial_count][0] = tmds[1];
                captured_b[serial_count][0] = tmds[0];
                captured_clock[serial_count][0] = tmds[3];
                @(negedge dut.edge_clk);
                #0.1; captured_r[serial_count][1] = tmds[2];
                captured_g[serial_count][1] = tmds[1];
                captured_b[serial_count][1] = tmds[0];
                captured_clock[serial_count][1] = tmds[3];
                @(posedge dut.edge_clk);
                #0.1; captured_r[serial_count][2] = tmds[2];
                captured_g[serial_count][2] = tmds[1];
                captured_b[serial_count][2] = tmds[0];
                captured_clock[serial_count][2] = tmds[3];
                @(negedge dut.edge_clk);
                #0.1; captured_r[serial_count][3] = tmds[2];
                captured_g[serial_count][3] = tmds[1];
                captured_b[serial_count][3] = tmds[0];
                captured_clock[serial_count][3] = tmds[3];
            end
        end
    endtask

    function [19:0] make_word(input integer first_serial, input integer channel);
        integer k;
        begin
            make_word = 20'd0;
            for (k = 0; k < 5; k = k + 1) begin
                case (channel)
                    0: make_word[k * 4 +: 4] = captured_r[first_serial + k];
                    1: make_word[k * 4 +: 4] = captured_g[first_serial + k];
                    2: make_word[k * 4 +: 4] = captured_b[first_serial + k];
                    default: make_word[k * 4 +: 4] = captured_clock[first_serial + k];
                endcase
            end
        end
    endfunction

    integer start, offset, group;
    reg found;
    initial begin
        seed = 32'h13579bdf;
        dr = 0; dg = 0; db = 0;
        for (i = 0; i < PIXELS; i = i + 1) begin
            seed = {seed[30:0], seed[31] ^ seed[21] ^ seed[1] ^ seed[0]};
            input_r[i] = seed[7:0] ^ i;
            input_g[i] = seed[15:8] + i * 3;
            input_b[i] = seed[23:16] ^ (i * 7);
            reference_encode(input_r[i], expected_r[i], dr);
            reference_encode(input_g[i], expected_g[i], dg);
            reference_encode(input_b[i], expected_b[i], db);
        end
        repeat (8) @(posedge pix_clk);
        rst = 1'b0;
        fork
            feed_pixels();
            capture_serial();
        join

        // Clock is the forwarded 20-bit pattern. Locate three complete
        // transfers, then compare eight changing RGB word pairs.
        found = 1'b0;
        for (start = 20; start < SERIAL_CYCLES - 50 && !found; start = start + 1) begin
            if (make_word(start, 3) == 20'b00000111110000011111 &&
                make_word(start + 5, 3) == 20'b00000111110000011111 &&
                make_word(start + 10, 3) == 20'b00000111110000011111) begin
                for (offset = 0; offset < PIXELS - 18 && !found;
                     offset = offset + 1) begin
                    found = 1'b1;
                    for (group = 0; group < 8; group = group + 1) begin
                        if (make_word(start + group * 5, 0) !=
                                {expected_r[offset + group * 2 + 1],
                                 expected_r[offset + group * 2]} ||
                            make_word(start + group * 5, 1) !=
                                {expected_g[offset + group * 2 + 1],
                                 expected_g[offset + group * 2]} ||
                            make_word(start + group * 5, 2) !=
                                {expected_b[offset + group * 2 + 1],
                                 expected_b[offset + group * 2]})
                            found = 1'b0;
                    end
                end
            end
        end
        if (!found) begin
            $display("expected pairs:");
            for (i = 0; i < 8; i = i + 1)
                $display("e%0d r=%b g=%b b=%b", i,
                         {expected_r[i * 2 + 1], expected_r[i * 2]},
                         {expected_g[i * 2 + 1], expected_g[i * 2]},
                         {expected_b[i * 2 + 1], expected_b[i * 2]});
            for (i = 20; i < 30; i = i + 1)
                $display("serial %0d clock %b red %b", i, make_word(i, 3),
                         make_word(i, 0));
            $display("raw23 red %h %h %h %h %h", captured_r[23],
                     captured_r[24], captured_r[25], captured_r[26],
                     captured_r[27]);
            $fatal(1, "could not reconstruct aligned 20-bit TMDS transfers");
        end
        $display("PASS TMDS serializer: 20-bit DDR words, forwarded clock alignment, changing RGB pairs");
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "TMDS serializer test timeout");
    end
endmodule

`default_nettype wire
