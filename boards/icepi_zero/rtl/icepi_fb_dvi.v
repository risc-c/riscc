// icepi_fb_dvi.v : framebuffer scanout and DVI timing for IcePi Zero.

`timescale 10ns/10ns
`default_nettype none

module icepi_fb_dvi (
    input wire cpu_clk, palette_we,
    input wire [7:0] palette_addr,
    input wire [23:0] palette_wdata,
    input wire memory_clk, memory_rst, memory_ready,
    output wire [23:0] memory_addr,
    output wire memory_cyc, memory_stb,
    input wire memory_stall, memory_ack,
    input wire [31:0] memory_rdata,
    output wire underrun,

    input  wire        pix_clk,
    input  wire        shift_clk,
    input  wire        rst,
    output wire        vblank,
    output wire [3:0]  tmds
);
    localparam [10:0] H_ACTIVE = 11'd1280;
    localparam [10:0] H_SYNC_START = 11'd1390;
    localparam [10:0] H_SYNC_END = 11'd1430;
    localparam [10:0] H_TOTAL = 11'd1650;
    localparam [9:0] V_ACTIVE = 10'd720;
    localparam [9:0] V_TOTAL = 10'd750;
    reg [10:0] h_count_q;
    reg [9:0] v_count_q;
    wire active = h_count_q < H_ACTIVE && v_count_q < V_ACTIVE;
    wire hsync = h_count_q >= H_SYNC_START && h_count_q < H_SYNC_END;
    wire vsync = v_count_q >= 10'd725 && v_count_q < 10'd730;
    wire [10:0] active_x = h_count_q;
    wire [9:0] active_y = v_count_q;
    // Repeat each framebuffer pixel across a 4x4 square in the 720p raster.
    wire [8:0] sx = active_x[10:2];
    wire [9:0] fb_y = active_y;
    wire [7:0] sy = fb_y[9:2];
    wire [7:0] fb_index;
    wire fb_pixel_valid;
    riscc_sdram_scanout scanout (
        .memory_clk(memory_clk),
        .memory_rst(memory_rst),
        .memory_ready(memory_ready),
        .memory_addr(memory_addr),
        .memory_cyc(memory_cyc),
        .memory_stb(memory_stb),
        .memory_stall(memory_stall),
        .memory_ack(memory_ack),
        .memory_rdata(memory_rdata),
        .pix_clk(pix_clk),
        .rst(rst),
        .visible(active),
        .line_start(active && active_x == 0 && fb_y[1:0] == 0),
        .source_x(sx),
        .source_y(sy),
        .pixel(fb_index),
        .pixel_valid(fb_pixel_valid),
        .underrun(underrun)
    );

    reg [10:0] active_x_q;
    reg [9:0] active_y_q;
    reg active_q;
    reg hsync_q;
    reg vsync_q;
    reg vblank_q;
    assign vblank = vblank_q;

    always @(posedge pix_clk) begin
        if (rst) begin
            h_count_q <= 11'd0;
            // Start in vertical blanking so the first SDRAM row can prefetch.
            v_count_q <= V_ACTIVE;
            active_x_q <= 11'd0;
            active_y_q <= 10'd0;
            active_q <= 1'b0;
            hsync_q <= 1'b1;
            vsync_q <= 1'b1;
            vblank_q <= 1'b1;
        end else begin
            if (h_count_q == H_TOTAL - 11'd1) begin
                h_count_q <= 11'd0;
            end else begin
                h_count_q <= h_count_q + 11'd1;
            end
            // CEA-861 progressive sync edges coincide. Advance the video
            // line at HSYNC, before the following line's active pixels.
            if (h_count_q == H_SYNC_START - 11'd1)
                v_count_q <= (v_count_q == V_TOTAL - 10'd1) ?
                             10'd0 : (v_count_q + 10'd1);

            active_x_q <= active_x;
            active_y_q <= active_y;
            active_q <= active;
            hsync_q <= hsync;
            vsync_q <= vsync;
            vblank_q <= v_count_q >= V_ACTIVE;
        end
    end

    wire [23:0] palette_rgb;
    riscc_video_palette palette (
        .cpu_clk(cpu_clk),
        .write_en(palette_we),
        .write_addr(palette_addr),
        .write_rgb(palette_wdata),
        .pix_clk(pix_clk),
        .index(fb_index),
        .rgb(palette_rgb)
    );
    // Palette block RAM adds one pixel clock after the line-buffer read.
    reg active_d,
        hsync_d,
        vsync_d,
        valid_d;
    always @(posedge pix_clk) begin
        if (rst) begin
            active_d <= 0;
            hsync_d <= 1;
            vsync_d <= 1;
            valid_d <= 0;
        end else begin
            active_d <= active_q;
            hsync_d <= hsync_q;
            vsync_d <= vsync_q;
            valid_d <= fb_pixel_valid;
        end
    end


    localparam [23:0] OUTSIDE_RGB = 24'hff00ff;

`ifdef ICEPI_VIDEO_TEST
    wire test_border = active_q &&
        ((active_x_q < 10'd4) || (active_x_q >= H_ACTIVE - 10'd4) ||
         (active_y_q < 10'd4) || (active_y_q >= V_ACTIVE - 10'd4));
    wire test_center = active_q &&
        (((active_x_q >= 11'd638) && (active_x_q < 11'd642)) ||
         ((active_y_q >= 10'd358) && (active_y_q < 10'd362)));
    wire [23:0] test_bars =
        (active_x_q < 11'd160)  ? 24'hff0000 :
        (active_x_q < 11'd320) ? 24'hffff00 :
        (active_x_q < 11'd480) ? 24'h00ff00 :
        (active_x_q < 11'd640) ? 24'h00ffff :
        (active_x_q < 11'd800) ? 24'h0000ff :
        (active_x_q < 11'd960) ? 24'hff00ff :
        (active_x_q < 11'd1120) ? 24'hffffff :
                           24'h202020;
    wire [23:0] test_rgb =
        test_border ? 24'hffffff :
        test_center ? 24'hff00ff :
        ((active_x_q[5:0] == 6'd0) || (active_y_q[5:0] == 6'd0)) ? 24'h404040 :
        test_bars;
    reg [23:0] active_rgb;
    always @(posedge pix_clk)
        active_rgb <= test_rgb;
`else
    wire [23:0] active_rgb = valid_d ? palette_rgb : 24'h000000;
`endif

    wire [23:0] rgb = active_d ? active_rgb : OUTSIDE_RGB;

    icepi_tmds_ddr tmds_out (
        .pix_clk(pix_clk),
        .shift_clk(shift_clk),
        .rst(rst),
        .vsync(vsync_d),
        .hsync(hsync_d),
        .de(active_d),
        .r(rgb[23:16]),
        .g(rgb[15:8]),
        .b(rgb[7:0]),
        .tmds(tmds)
    );
endmodule

`default_nettype wire
