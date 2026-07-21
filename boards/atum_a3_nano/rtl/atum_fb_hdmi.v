`timescale 1ns/1ps
`default_nettype none

module atum_fb_ram (
    input wire cpu_clk,
    input wire cpu_we,
    input wire [14:0] cpu_addr,
    input wire [1:0] cpu_wmask,
    input wire [15:0] cpu_wdata,
    input wire vid_clk,
    input wire [14:0] vid_addr,
    output reg [15:0] vid_rdata
);
    // 320x180 pixels, four 4-bit pixels per 16-bit word (14,400 words).
    (* ramstyle = "M20K, no_rw_check" *) reg [15:0] mem [0:14399];

    always @(posedge cpu_clk) begin
        if (cpu_we) begin
            if (cpu_wmask[0]) mem[cpu_addr][7:0] <= cpu_wdata[7:0];
            if (cpu_wmask[1]) mem[cpu_addr][15:8] <= cpu_wdata[15:8];
        end
    end

    always @(posedge vid_clk)
        vid_rdata <= mem[vid_addr];
endmodule

// 1920x1080p60 timing for the TFP410 parallel transmitter.  It scales the
// RISC-C 320x180 framebuffer by 6 in both directions, so no
// resampling RAM or second framebuffer is required.
module atum_fb_hdmi (
    input wire cpu_clk,
    input wire cpu_we,
    input wire [14:0] cpu_addr,
    input wire [1:0] cpu_wmask,
    input wire [15:0] cpu_wdata,
    input wire pix_clk,
    input wire rst,
    output wire pix_clk_out,
    output wire hdmi_hs,
    output wire hdmi_vs,
    output wire hdmi_de,
    output wire [23:0] hdmi_rgb
);
    localparam [11:0] H_TOTAL = 12'd2200;
    localparam [11:0] H_SYNC = 12'd44;
    localparam [11:0] H_ACTIVE_START = 12'd192;
    localparam [11:0] H_ACTIVE_END = 12'd2112;
    localparam [11:0] V_TOTAL = 12'd1125;
    localparam [11:0] V_SYNC = 12'd5;
    localparam [11:0] V_ACTIVE_START = 12'd41;
    localparam [11:0] V_ACTIVE_END = 12'd1121;

    reg [11:0] h_count;
    reg [11:0] v_count;
    reg [8:0] source_x;
    reg [7:0] source_y;
    reg [2:0] h_repeat;
    reg [2:0] v_repeat;
    wire active = (h_count >= H_ACTIVE_START) && (h_count < H_ACTIVE_END) &&
                  (v_count >= V_ACTIVE_START) && (v_count < V_ACTIVE_END);
    wire hsync = h_count >= H_SYNC;
    wire vsync = v_count >= V_SYNC;
    // Counters replace division by 6 in the 148.5 MHz pixel domain.
    // source_x changes after each group of six pixels; source_y after six lines.
    wire [16:0] source_pixel = ({1'b0, source_y} << 8) +
                                ({3'b000, source_y} << 6) +
                                {8'b00000000, source_x};
    wire [14:0] fb_vid_addr = active ? source_pixel[16:2] : 15'd0;
    wire [1:0] pix_lane = source_x[1:0];
    wire [15:0] fb_vid_word;

    reg active_q;
    reg hsync_q;
    reg vsync_q;
    reg [1:0] pix_lane_q;

    atum_fb_ram framebuffer (
        .cpu_clk(cpu_clk), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wmask(cpu_wmask), .cpu_wdata(cpu_wdata), .vid_clk(pix_clk),
        .vid_addr(fb_vid_addr), .vid_rdata(fb_vid_word)
    );

    always @(posedge pix_clk) begin
        if (rst) begin
            h_count <= 12'd0;
            v_count <= 12'd0;
            source_x <= 9'd0;
            source_y <= 8'd0;
            h_repeat <= 3'd0;
            v_repeat <= 3'd0;
            active_q <= 1'b0;
            hsync_q <= 1'b0;
            vsync_q <= 1'b0;
            pix_lane_q <= 2'd0;
        end else begin
            // Prime the source coordinate one cycle before its active region
            // starts, so the synchronous framebuffer read aligns with DE.
            if (h_count == H_ACTIVE_START - 1'b1) begin
                source_x <= 9'd0;
                h_repeat <= 3'd0;
            end else if ((h_count >= H_ACTIVE_START) &&
                         (h_count < H_ACTIVE_END)) begin
                if (h_repeat == 3'd5) begin
                    source_x <= source_x + 1'b1;
                    h_repeat <= 3'd0;
                end else begin
                    h_repeat <= h_repeat + 1'b1;
                end
            end

            if (h_count == H_TOTAL - 1'b1) begin
                if (v_count == V_ACTIVE_START - 1'b1) begin
                    source_y <= 8'd0;
                    v_repeat <= 3'd0;
                end else if ((v_count >= V_ACTIVE_START) &&
                             (v_count < V_ACTIVE_END)) begin
                    if (v_repeat == 3'd5) begin
                        source_y <= source_y + 1'b1;
                        v_repeat <= 3'd0;
                    end else begin
                        v_repeat <= v_repeat + 1'b1;
                    end
                end
            end

            if (h_count == H_TOTAL - 1'b1) begin
                h_count <= 12'd0;
                v_count <= (v_count == V_TOTAL - 1'b1) ? 12'd0 : v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
            active_q <= active;
            hsync_q <= hsync;
            vsync_q <= vsync;
            pix_lane_q <= pix_lane;
        end
    end

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

    wire [3:0] fb_nibble =
        (pix_lane_q == 2'd0) ? fb_vid_word[3:0] :
        (pix_lane_q == 2'd1) ? fb_vid_word[7:4] :
        (pix_lane_q == 2'd2) ? fb_vid_word[11:8] : fb_vid_word[15:12];

    assign pix_clk_out = ~pix_clk; // TFP410 samples data on the opposite edge.
    assign hdmi_hs = hsync_q;
    assign hdmi_vs = vsync_q;
    assign hdmi_de = active_q;
    assign hdmi_rgb = active_q ? palette(fb_nibble) : 24'h000000;
endmodule

`default_nettype wire
