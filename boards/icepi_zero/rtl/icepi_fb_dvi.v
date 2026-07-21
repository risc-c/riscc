`timescale 10ns/10ns
`default_nettype none

module icepi_fb_dvi (
    input  wire        cpu_clk,
    input  wire        cpu_we,
    input  wire [13:0] cpu_addr,
    input  wire [1:0]  cpu_wmask,
    input  wire [15:0] cpu_wdata,

    input  wire        pix_clk,
    input  wire        shift_clk,
    input  wire        rst,
    output wire [3:0]  tmds
);
    localparam [9:0] H_ACTIVE = 10'd640;
    localparam [9:0] H_FRONT  = 10'd16;
    localparam [9:0] H_SYNC   = 10'd96;
    localparam [9:0] H_BACK   = 10'd48;
    localparam [9:0] H_TOTAL  = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;

    localparam [9:0] V_ACTIVE = 10'd480;
    localparam [9:0] V_FRONT  = 10'd10;
    localparam [9:0] V_SYNC   = 10'd2;
    localparam [9:0] V_BACK   = 10'd33;
    localparam [9:0] V_TOTAL  = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

    // The Icepi/capture path samples the visible window a few pixels after
    // the nominal sync-derived origin. Keep sync timings standard, but place
    // the DVI active island slightly later in the front porch.
    localparam [9:0] H_ACTIVE_START = 10'd8;
    localparam [9:0] V_ACTIVE_START = 10'd8;
    localparam [9:0] H_ACTIVE_END   = H_ACTIVE_START + H_ACTIVE;
    localparam [9:0] V_ACTIVE_END   = V_ACTIVE_START + V_ACTIVE;

    reg [9:0] px;
    reg [9:0] py;

    wire active = (px >= H_ACTIVE_START) && (px < H_ACTIVE_END) &&
                  (py >= V_ACTIVE_START) && (py < V_ACTIVE_END);
    wire hsync = ~((px >= H_ACTIVE + H_FRONT) &&
                   (px <  H_ACTIVE + H_FRONT + H_SYNC));
    wire vsync = ~((py >= V_ACTIVE + V_FRONT) &&
                   (py <  V_ACTIVE + V_FRONT + V_SYNC));

    wire [9:0] active_x = active ? (px - H_ACTIVE_START) : 10'd0;
    wire [9:0] active_y = active ? (py - V_ACTIVE_START) : 10'd0;
    // Keep the 640x480 timing that the IcePi DVI path already supports.
    // The 320x180 framebuffer is doubled into a centered 640x360 image.
    localparam [9:0] FB_TOP = 10'd60;
    localparam [9:0] FB_BOTTOM = FB_TOP + 10'd360;
    wire fb_visible = active && (active_y >= FB_TOP) &&
                      (active_y < FB_BOTTOM);
    wire [8:0] sx = active_x[9:1];
    wire [9:0] fb_y = active_y - FB_TOP;
    wire [7:0] sy = fb_y[8:1];
    wire [16:0] pix_index = {1'b0, sy, 8'b00000000} +
                             {3'b000, sy, 6'b000000} +
                             {8'b00000000, sx};
    wire [13:0] fb_vid_addr = fb_visible ? pix_index[15:2] : 14'd0;
    wire [1:0] pix_lane = pix_index[1:0];
    wire [15:0] fb_vid_word;

    icepi_fb_ram framebuffer (
        .cpu_clk(cpu_clk),
        .cpu_we(cpu_we),
        .cpu_addr(cpu_addr),
        .cpu_wmask(cpu_wmask),
        .cpu_wdata(cpu_wdata),
        .vid_clk(pix_clk),
        .vid_addr(fb_vid_addr),
        .vid_rdata(fb_vid_word)
    );

    reg [9:0] px_q;
    reg [9:0] py_q;
    reg [1:0] pix_lane_q;
    reg active_q;
    reg fb_visible_q;
    reg hsync_q;
    reg vsync_q;

    always @(posedge pix_clk) begin
        if (rst) begin
            px <= 10'd0;
            py <= 10'd0;
            px_q <= 10'd0;
            py_q <= 10'd0;
            pix_lane_q <= 2'd0;
            active_q <= 1'b0;
            fb_visible_q <= 1'b0;
            hsync_q <= 1'b1;
            vsync_q <= 1'b1;
        end else begin
            if (px == H_TOTAL - 10'd1) begin
                px <= 10'd0;
                py <= (py == V_TOTAL - 10'd1) ? 10'd0 : (py + 10'd1);
            end else begin
                px <= px + 10'd1;
            end

            px_q <= active_x;
            py_q <= active_y;
            pix_lane_q <= pix_lane;
            active_q <= active;
            fb_visible_q <= fb_visible;
            hsync_q <= hsync;
            vsync_q <= vsync;
        end
    end

    wire [3:0] fb_nibble =
        !fb_visible_q ? 4'h0 :
        (pix_lane_q == 2'd0) ? fb_vid_word[3:0] :
        (pix_lane_q == 2'd1) ? fb_vid_word[7:4] :
        (pix_lane_q == 2'd2) ? fb_vid_word[11:8] :
                               fb_vid_word[15:12];

    function automatic [23:0] palette(input [3:0] idx);
        begin
            case (idx)
            4'h0: palette = 24'h02040a;
            4'h1: palette = 24'h06112b;
            4'h2: palette = 24'h0a1f4d;
            4'h3: palette = 24'h0d3274;
            4'h4: palette = 24'h10499c;
            4'h5: palette = 24'h1464c4;
            4'h6: palette = 24'h1a82e6;
            4'h7: palette = 24'h25a4ff;
            4'h8: palette = 24'h45bdff;
            4'h9: palette = 24'h6dd3ff;
            4'ha: palette = 24'h98e5ff;
            4'hb: palette = 24'hbdf1ff;
            4'hc: palette = 24'hd8f8ff;
            4'hd: palette = 24'heafcff;
            4'he: palette = 24'hf6feff;
            default: palette = 24'hffffff;
            endcase
        end
    endfunction

    localparam [23:0] OUTSIDE_RGB = 24'hff00ff;

`ifdef ICEPI_VIDEO_TEST
    wire test_border = active_q &&
        ((px_q < 10'd4) || (px_q >= H_ACTIVE - 10'd4) ||
         (py_q < 10'd4) || (py_q >= V_ACTIVE - 10'd4));
    wire test_center = active_q &&
        (((px_q >= 10'd318) && (px_q < 10'd322)) ||
         ((py_q >= 10'd238) && (py_q < 10'd242)));
    wire [23:0] test_bars =
        (px_q < 10'd80)  ? 24'hff0000 :
        (px_q < 10'd160) ? 24'hffff00 :
        (px_q < 10'd240) ? 24'h00ff00 :
        (px_q < 10'd320) ? 24'h00ffff :
        (px_q < 10'd400) ? 24'h0000ff :
        (px_q < 10'd480) ? 24'hff00ff :
        (px_q < 10'd560) ? 24'hffffff :
                           24'h202020;
    wire [23:0] active_rgb =
        test_border ? 24'hffffff :
        test_center ? 24'hff00ff :
        ((px_q[5:0] == 6'd0) || (py_q[5:0] == 6'd0)) ? 24'h404040 :
        test_bars;
`else
    wire [23:0] active_rgb = palette(fb_nibble);
`endif

    wire [23:0] rgb = active_q ?
                      (fb_visible_q ? active_rgb : 24'h000000) :
                      OUTSIDE_RGB;

    icepi_tmds_ddr tmds_out (
        .pix_clk(pix_clk),
        .shift_clk(shift_clk),
        .rst(rst),
        .vsync(vsync_q),
        .hsync(hsync_q),
        .de(active_q),
        .r(rgb[23:16]),
        .g(rgb[15:8]),
        .b(rgb[7:0]),
        .tmds(tmds)
    );
endmodule

`default_nettype wire
