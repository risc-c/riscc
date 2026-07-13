`timescale 10ns/10ns
`default_nettype none

// CPU-side half of the common 160x120, 4-bpp demo framebuffer.  Scanout RAM
// and video timing remain board-local so each FPGA keeps its native RAM
// inference and output path.
module riscc_framebuffer_mmio #(
    parameter integer CHECK_RANGE = 0,
    parameter [12:0] WORDS = 13'd4800
) (
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [14:0] cpu_addr,
    input  wire [1:0]  cpu_wmask,
    input  wire [15:0] cpu_wdata,

    output wire        fb_sel,
    output wire        fb_we,
    output wire [12:0] fb_addr,
    output wire [1:0]  fb_wmask,
    output wire [15:0] fb_wdata
);
    assign fb_sel = cpu_addr[14] & ~cpu_addr[13];
    assign fb_addr = cpu_addr[12:0];
    assign fb_wmask = cpu_wmask;
    assign fb_wdata = cpu_wdata;

    generate
        if (CHECK_RANGE != 0) begin : g_range_check
            // fb_sel already fixes the upper aperture bits, so the low 13
            // address bits are the framebuffer word offset directly.
            wire [12:0] fb_offset = cpu_addr[12:0];
            assign fb_we = !rst && cpu_we && fb_sel &&
                           (fb_offset < WORDS);
        end else begin : g_full_aperture
            assign fb_we = !rst && cpu_we && fb_sel;
        end
    endgenerate
endmodule

`default_nettype wire
