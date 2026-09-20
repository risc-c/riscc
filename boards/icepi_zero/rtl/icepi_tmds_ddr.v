// icepi_tmds_ddr.v : TMDS encoding, serialization, and DDR output stage.

`default_nettype none

module icepi_tmds_ddr (
    input  wire        pix_clk,
    input  wire        shift_clk,
    input  wire        rst,
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        de,
    output wire [3:0]  tmds
);
    reg [23:0] rgb_q;
    reg hsync_q, vsync_q, de_q;
    always @(posedge pix_clk) begin
        rgb_q <= {r,g,b};
        hsync_q <= hsync;
        vsync_q <= vsync;
        de_q <= de;
    end
    wire [9:0] red_code;
    wire [9:0] green_code;
    wire [9:0] blue_code;

    icepi_tmds_encoder enc_b (
        .clk(pix_clk),
        .data(rgb_q[7:0]),
        .c({vsync_q, hsync_q}),
        .de(de_q),
        .out(blue_code)
    );

    icepi_tmds_encoder enc_g (
        .clk(pix_clk),
        .data(rgb_q[15:8]),
        .c(2'b00),
        .de(de_q),
        .out(green_code)
    );

    icepi_tmds_encoder enc_r (
        .clk(pix_clk),
        .data(rgb_q[23:16]),
        .c(2'b00),
        .de(de_q),
        .out(red_code)
    );

    // Two pixels form twenty serial bits: five four-bit transfers to the
    // I/O gearing cells. Only those cells run at the 5x pixel edge clock.
    wire serial_clk;
    wire edge_clk;
`ifdef VERILATOR
    reg divided_clk = 0;
    always @(posedge shift_clk) divided_clk <= ~divided_clk;
    assign serial_clk = divided_clk;
    assign edge_clk = shift_clk;
`else
    ECLKSYNCB edge_buffer (.ECLKI(shift_clk), .STOP(1'b0), .ECLKO(edge_clk));
    CLKDIVF #(.DIV("2.0")) divider (
        .CLKI(edge_clk), .RST(rst), .ALIGNWD(1'b0), .CDIVX(serial_clk)
    );
`endif
    reg half_q = 0;
    reg [29:0] first_q;
    reg [59:0] pair_q;
    reg pair_toggle_q = 0;
    always @(posedge pix_clk) begin
        if (rst) begin
            half_q <= 0;
            pair_toggle_q <= 0;
        end else begin
            half_q <= ~half_q;
            if (!half_q)
                first_q <= {red_code, green_code, blue_code};
            else begin
                pair_q <= {red_code, first_q[29:20],
                           green_code, first_q[19:10],
                           blue_code, first_q[9:0]};
                pair_toggle_q <= ~pair_toggle_q;
            end
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [1:0] pair_sync_q = 0;
    reg pair_seen_q = 0;
    reg [19:0] red_shift_q = 0, green_shift_q = 0, blue_shift_q = 0;
    reg [19:0] clock_shift_q = 20'b00000111110000011111;
    always @(posedge serial_clk) begin
        pair_sync_q <= {pair_sync_q[0], pair_toggle_q};
        pair_seen_q <= pair_sync_q[1];
        if (pair_sync_q[1] != pair_seen_q) begin
            red_shift_q <= pair_q[59:40];
            green_shift_q <= pair_q[39:20];
            blue_shift_q <= pair_q[19:0];
            clock_shift_q <= 20'b00000111110000011111;
        end else begin
            red_shift_q <= {red_shift_q[3:0], red_shift_q[19:4]};
            green_shift_q <= {green_shift_q[3:0], green_shift_q[19:4]};
            blue_shift_q <= {blue_shift_q[3:0], blue_shift_q[19:4]};
            clock_shift_q <= {clock_shift_q[3:0], clock_shift_q[19:4]};
        end
    end

`ifdef VERILATOR
    assign tmds = {clock_shift_q[0], red_shift_q[0], green_shift_q[0], blue_shift_q[0]};
`else
    ODDRX2F ddr_clock (
        .D0(clock_shift_q[0]), .D1(clock_shift_q[1]),
        .D2(clock_shift_q[2]), .D3(clock_shift_q[3]),
        .Q(tmds[3]), .SCLK(serial_clk), .ECLK(edge_clk), .RST(rst)
    );
    ODDRX2F ddr_red (
        .D0(red_shift_q[0]), .D1(red_shift_q[1]),
        .D2(red_shift_q[2]), .D3(red_shift_q[3]),
        .Q(tmds[2]), .SCLK(serial_clk), .ECLK(edge_clk), .RST(rst)
    );
    ODDRX2F ddr_green (
        .D0(green_shift_q[0]), .D1(green_shift_q[1]),
        .D2(green_shift_q[2]), .D3(green_shift_q[3]),
        .Q(tmds[1]), .SCLK(serial_clk), .ECLK(edge_clk), .RST(rst)
    );
    ODDRX2F ddr_blue (
        .D0(blue_shift_q[0]), .D1(blue_shift_q[1]),
        .D2(blue_shift_q[2]), .D3(blue_shift_q[3]),
        .Q(tmds[0]), .SCLK(serial_clk), .ECLK(edge_clk), .RST(rst)
    );
`endif
endmodule

`default_nettype wire
