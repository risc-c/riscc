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
    wire [9:0] red_code;
    wire [9:0] green_code;
    wire [9:0] blue_code;

    icepi_tmds_encoder enc_b (
        .clk(pix_clk),
        .data(b),
        .c({vsync, hsync}),
        .de(de),
        .out(blue_code)
    );

    icepi_tmds_encoder enc_g (
        .clk(pix_clk),
        .data(g),
        .c(2'b00),
        .de(de),
        .out(green_code)
    );

    icepi_tmds_encoder enc_r (
        .clk(pix_clk),
        .data(r),
        .c(2'b00),
        .de(de),
        .out(red_code)
    );

    reg [9:0] red_word;
    reg [9:0] green_word;
    reg [9:0] blue_word;

    always @(posedge pix_clk) begin
        red_word <= red_code;
        green_word <= green_code;
        blue_word <= blue_code;
    end

    localparam [9:0] SHIFT_CLOCK_INIT = 10'b0000011111;

    reg [9:0] red_shift = 10'd0;
    reg [9:0] green_shift = 10'd0;
    reg [9:0] blue_shift = 10'd0;
    reg [9:0] clock_shift = SHIFT_CLOCK_INIT;
    reg       shift_off_sync = 1'b0;
    reg [7:0] shift_sync_wait = 8'd0;
    reg [6:0] sync_fail = 7'd0;

    always @(posedge pix_clk) begin
        if (rst)
            shift_off_sync <= 1'b0;
        else
            shift_off_sync <= (clock_shift[5:4] != SHIFT_CLOCK_INIT[5:4]);
    end

    always @(posedge shift_clk) begin
        if (rst) begin
            red_shift <= 10'd0;
            green_shift <= 10'd0;
            blue_shift <= 10'd0;
            clock_shift <= SHIFT_CLOCK_INIT;
            shift_sync_wait <= 8'd0;
            sync_fail <= 7'd0;
        end else begin
            if (shift_off_sync) begin
                if (shift_sync_wait[7])
                    shift_sync_wait <= 8'd0;
                else
                    shift_sync_wait <= shift_sync_wait + 8'd1;
            end else begin
                shift_sync_wait <= 8'd0;
            end

            if (clock_shift[5:4] == SHIFT_CLOCK_INIT[5:4]) begin
                red_shift <= red_word;
                green_shift <= green_word;
                blue_shift <= blue_word;
            end else begin
                red_shift <= {2'b00, red_shift[9:2]};
                green_shift <= {2'b00, green_shift[9:2]};
                blue_shift <= {2'b00, blue_shift[9:2]};
            end

            if (!shift_sync_wait[7]) begin
                clock_shift <= {clock_shift[1:0], clock_shift[9:2]};
            end else begin
                if (sync_fail[6]) begin
                    clock_shift <= SHIFT_CLOCK_INIT;
                    sync_fail <= 7'd0;
                end else begin
                    sync_fail <= sync_fail + 7'd1;
                end
            end
        end
    end

    wire [1:0] blue_pair = blue_shift[1:0];
    wire [1:0] green_pair = green_shift[1:0];
    wire [1:0] red_pair = red_shift[1:0];
    wire [1:0] clock_pair = clock_shift[1:0];

`ifdef VERILATOR
    assign tmds = {clock_pair[0], red_pair[0], green_pair[0], blue_pair[0]};
`else
    ODDRX1F ddr_clock (
        .D0(clock_pair[0]),
        .D1(clock_pair[1]),
        .Q(tmds[3]),
        .SCLK(shift_clk),
        .RST(1'b0)
    );

    ODDRX1F ddr_red (
        .D0(red_pair[0]),
        .D1(red_pair[1]),
        .Q(tmds[2]),
        .SCLK(shift_clk),
        .RST(1'b0)
    );

    ODDRX1F ddr_green (
        .D0(green_pair[0]),
        .D1(green_pair[1]),
        .Q(tmds[1]),
        .SCLK(shift_clk),
        .RST(1'b0)
    );

    ODDRX1F ddr_blue (
        .D0(blue_pair[0]),
        .D1(blue_pair[1]),
        .Q(tmds[0]),
        .SCLK(shift_clk),
        .RST(1'b0)
    );
`endif
endmodule

`default_nettype wire
