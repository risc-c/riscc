// CPU-written 256-entry RGB palette with a synchronous pixel-clock read port.
`timescale 1ns/1ps
`default_nettype none
module riscc_video_palette (
    input wire cpu_clk, write_en,
    input wire [7:0] write_addr,
    input wire [23:0] write_rgb,
    input wire pix_clk,
    input wire [7:0] index,
    output reg [23:0] rgb
);
`ifdef RISCC_ECP5
    (* ram_style = "block" *)
`else
    (* ramstyle = "M20K, no_rw_check" *)
`endif
    reg [23:0] colors [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            colors[i] = 24'h000000;
    end
    always @(posedge cpu_clk)
        if (write_en) colors[write_addr] <= write_rgb;
    always @(posedge pix_clk)
        rgb <= colors[index];
endmodule
`default_nettype wire
