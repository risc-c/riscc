`timescale 1ns/1ps
`default_nettype none

module tmds_encoder_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [7:0] data = 8'd0;
    reg [1:0] c = 2'b00;
    reg de = 1'b0;
    wire [9:0] out;
    icepi_tmds_encoder dut (.clk(clk), .data(data), .c(c), .de(de), .out(out));

    integer disparity;
    reg [9:0] expected_previous;
    reg have_previous;
    integer checks;

    function integer signed4(input integer value);
        integer reduced;
        begin
            reduced = value & 15;
            signed4 = reduced >= 8 ? reduced - 16 : reduced;
        end
    endfunction

    // The reference follows the DVI/HDMI TMDS transition-minimized coding
    // rule and the running-disparity update used by the encoder.  The
    // encoder's q_m and control registers add one clock; its output register
    // adds the second clock, which drive_and_check accounts for below.
    task reference_encode(
        input [7:0] in_data,
        input [1:0] in_c,
        input in_de,
        output [9:0] symbol
    );
        reg [8:0] q_m;
        reg use_xnor;
        reg sign_equal;
        reg invert;
        reg subtract_one;
        integer ones;
        integer q_ones;
        integer balance;
        integer step;
        integer i;
        begin
            if (!in_de) begin
                case (in_c)
                    2'b00: symbol = 10'b1101010100;
                    2'b01: symbol = 10'b0010101011;
                    2'b10: symbol = 10'b0101010100;
                    default: symbol = 10'b1010101011;
                endcase
                disparity = 0;
            end else begin
                ones = 0;
                for (i = 0; i < 8; i = i + 1)
                    ones = ones + in_data[i];
                use_xnor = (ones > 4) || ((ones == 4) && !in_data[0]);
                q_m[0] = in_data[0];
                for (i = 1; i < 8; i = i + 1)
                    q_m[i] = q_m[i - 1] ^ in_data[i] ^ use_xnor;
                q_m[8] = ~use_xnor;
                q_ones = 0;
                for (i = 0; i < 8; i = i + 1)
                    q_ones = q_ones + q_m[i];
                balance = signed4(q_ones - 4);
                sign_equal = (balance < 0) == (disparity < 0);
                if ((balance == 0) || (disparity == 0))
                    invert = !q_m[8];
                else
                    invert = sign_equal;
                subtract_one = (q_m[8] == sign_equal) &&
                               (balance != 0) && (disparity != 0);
                step = signed4(balance - (subtract_one ? 1 : 0));
                if (invert)
                    disparity = signed4(disparity - step);
                else
                    disparity = signed4(disparity + step);
                symbol = {invert, q_m[8], q_m[7:0] ^ {8{invert}}};
            end
        end
    endtask

    task drive_and_check(input [7:0] next_data,
                         input [1:0] next_c, input next_de);
        reg [9:0] next_expected;
        begin
            @(negedge clk);
            data = next_data;
            c = next_c;
            de = next_de;
            @(posedge clk);
            #1;
            if (have_previous) begin
                if (out !== expected_previous)
                    $fatal(1, "TMDS mismatch at check %0d: got %b expected %b",
                           checks, out, expected_previous);
                checks = checks + 1;
            end
            reference_encode(next_data, next_c, next_de, next_expected);
            expected_previous = next_expected;
            have_previous = 1'b1;
        end
    endtask

    integer i;
    reg [31:0] random_state;
    initial begin
        disparity = 0;
        have_previous = 1'b0;
        expected_previous = 10'd0;
        checks = 0;

        // Exercise every control symbol repeatedly; each control period also
        // verifies that the reference and DUT clear running disparity.
        for (i = 0; i < 4; i = i + 1) begin
            drive_and_check(8'h00, i[1:0], 1'b0);
            drive_and_check(8'hff, i[1:0], 1'b0);
        end

        // Every possible active-video byte, including all transition and
        // population-count boundary cases.
        for (i = 0; i < 256; i = i + 1)
            drive_and_check(i[7:0], 2'b00, 1'b1);

        // Long deterministic runs stress disparity state over thousands of
        // symbols and insert controls at irregular intervals.
        random_state = 32'h1;
        for (i = 0; i < 10000; i = i + 1) begin
            random_state = {random_state[30:0],
                            random_state[31] ^ random_state[21] ^
                            random_state[1] ^ random_state[0]};
            if ((i % 257) == 0)
                drive_and_check(random_state[7:0], i[1:0], 1'b0);
            else
                drive_and_check(random_state[7:0], random_state[9:8], 1'b1);
        end

        // Flush the final active symbol through both registered stages.
        drive_and_check(8'h00, 2'b11, 1'b0);
        $display("PASS TMDS encoder: all 256 data bytes, controls, and %0d checks",
                 checks);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "TMDS encoder test timeout");
    end
endmodule

`default_nettype wire
