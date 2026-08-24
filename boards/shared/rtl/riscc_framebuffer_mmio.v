// riscc_framebuffer_mmio.v : shared CPU-to-framebuffer write aperture.

`timescale 10ns/10ns
`default_nettype none

// CPU-side half of the board-local 4-bpp demo framebuffer. The framebuffer
// begins at byte address 0x8000. Scanout RAM and video timing remain
// board-local so each FPGA keeps its native RAM inference and output path.
module riscc_framebuffer_mmio #(
    parameter [14:0] WORDS = 15'd14400,
    // Allocate the upper 32 KiB except the final eight MMIO words. This
    // preserves Icepi's one-bit framebuffer write decode at 50 MHz.
    parameter HIGH_HALF_APERTURE = 0
) (
    input  wire        rst,
    input  wire        cpu_we,
    input  wire [14:0] cpu_addr,
    input  wire [1:0]  cpu_wmask,
    input  wire [15:0] cpu_wdata,

    output wire        fb_sel,
    output wire        fb_we,
    output wire [14:0] fb_addr,
    output wire [1:0]  fb_wmask,
    output wire [15:0] fb_wdata
);
    // CPU addresses are halfwords. The wide aperture ends before the final
    // eight MMIO words; the normal aperture ends after the displayed image.
    wire aperture_sel = cpu_addr[14] && !(&cpu_addr[14:3]);
    wire range_sel = cpu_addr[14] && (fb_addr < WORDS);

    assign fb_sel = HIGH_HALF_APERTURE ? aperture_sel : range_sel;
    assign fb_addr = {1'b0, cpu_addr[13:0]};
    assign fb_wmask = cpu_wmask;
    assign fb_wdata = cpu_wdata;

    assign fb_we = !rst && cpu_we && fb_sel;
endmodule

`default_nettype wire
