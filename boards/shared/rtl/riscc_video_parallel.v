// riscc_video_parallel.v : SDRAM framebuffer and parallel RGB scanout pipeline.

`timescale 1ns/1ps
`default_nettype none

// 1080p60 or 720p60 timing for parallel RGB transmitters. Integer scaling
// of the RISC-C 320x180 framebuffer in both directions needs no
// resampling RAM or second framebuffer.
module riscc_video_parallel #(
    parameter integer SCALE = 6 // 6: 1080p60, 4: 720p60
) (
    input wire cpu_clk, palette_we,
    input wire [7:0] palette_addr,
    input wire [23:0] palette_wdata,
    input wire memory_clk, memory_rst, memory_ready,
    output wire [23:0] memory_addr,
    output wire memory_cyc, memory_stb,
    input wire memory_stall, memory_ack,
    input wire [31:0] memory_rdata,
    output wire underrun,
    input  wire pix_clk,
    input  wire rst,
    output wire hdmi_hs,
    output wire hdmi_vs,
    output wire hdmi_de,
    output wire [23:0] hdmi_rgb
);
    localparam [11:0] H_TOTAL = SCALE == 4 ? 12'd1650 : 12'd2200;
    localparam [11:0] H_SYNC = SCALE == 4 ? 12'd40 : 12'd44;
    localparam [11:0] H_ACTIVE_START = SCALE == 4 ? 12'd260 : 12'd192;
    localparam [11:0] H_ACTIVE_END = SCALE == 4 ? 12'd1540 : 12'd2112;
    localparam [10:0] V_TOTAL = SCALE == 4 ? 11'd750 : 11'd1125;
    localparam [10:0] V_SYNC = 11'd5;
    localparam [10:0] V_ACTIVE_START = SCALE == 4 ? 11'd25 : 11'd41;
    localparam [10:0] V_ACTIVE_END = SCALE == 4 ? 11'd745 : 11'd1121;

    localparam [2:0] LAST_REPEAT = SCALE[2:0] - 3'd1;
    reg [11:0] h_count;
    reg [10:0] v_count;
    reg [8:0] source_x;
    reg [7:0] source_y;
    reg [2:0] h_repeat;
    reg [2:0] v_repeat;
    wire active = (h_count >= H_ACTIVE_START) && (h_count < H_ACTIVE_END) &&
                  (v_count >= V_ACTIVE_START) && (v_count < V_ACTIVE_END);
    wire hsync = h_count >= H_SYNC;
    wire vsync = v_count >= V_SYNC;
    // Repeat counters advance source_x every SCALE pixels and source_y every SCALE lines.
    reg active_q;
    reg hsync_q;
    reg vsync_q;
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
        .line_start(active && h_count == H_ACTIVE_START && v_repeat == 0),
        .source_x(source_x),
        .source_y(source_y),
        .pixel(fb_index),
        .pixel_valid(fb_pixel_valid),
        .underrun(underrun)
    );

    always @(posedge pix_clk) begin
        if (rst) begin
            h_count <= 12'd0;
            v_count <= 11'd0;
            source_x <= 9'd0;
            source_y <= 8'd0;
            h_repeat <= 3'd0;
            v_repeat <= 3'd0;
            active_q <= 1'b0;
            hsync_q <= 1'b0;
            vsync_q <= 1'b0;
        end else begin
            // Prime the source coordinate one cycle before active video so the
            // synchronous framebuffer read aligns with DE.
            if (h_count == H_ACTIVE_START - 1'b1) begin
                source_x <= 9'd0;
                h_repeat <= 3'd0;
            end else if ((h_count >= H_ACTIVE_START) &&
                         (h_count < H_ACTIVE_END)) begin
                if (h_repeat == LAST_REPEAT) begin
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
                    if (v_repeat == LAST_REPEAT) begin
                        source_y <= source_y + 1'b1;
                        v_repeat <= 3'd0;
                    end else begin
                        v_repeat <= v_repeat + 1'b1;
                    end
                end
            end

            if (h_count == H_TOTAL - 1'b1) begin
                h_count <= 12'd0;
                v_count <= (v_count == V_TOTAL - 1'b1) ?
                           11'd0 : v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
            active_q <= active;
            hsync_q <= hsync;
            vsync_q <= vsync;
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

    assign hdmi_hs = hsync_d;
    assign hdmi_vs = vsync_d;
    assign hdmi_de = active_d;
    assign hdmi_rgb = active_d && valid_d ? palette_rgb : 24'h000000;
endmodule

`default_nettype wire
