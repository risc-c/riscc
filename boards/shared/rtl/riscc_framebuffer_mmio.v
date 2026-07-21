`timescale 10ns/10ns
`default_nettype none

// CPU-side half of the board-local 4-bpp demo framebuffer.  The demo keeps
// 24 KiB of the 64 KiB CPU address space for firmware, then places the
// framebuffer immediately above it.  Scanout RAM and video timing remain
// board-local so each FPGA keeps its native RAM inference and output path.
module riscc_framebuffer_mmio #(
    parameter [14:0] WORDS = 15'd19200,
    // Allocate the upper 32 KiB except the final eight MMIO words.  This
    // preserves the IcePi's one-bit framebuffer write decode at 50 MHz.
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
    generate
        if (HIGH_HALF_APERTURE != 0) begin : g_high_half
            // CPU addresses are words.  0x4000..0x7ff7 are framebuffer;
            // 0x7ff8..0x7fff remain the normal 0xfff0..0xffff MMIO space.
            assign fb_sel = cpu_addr[14] && !(&cpu_addr[14:3]);
            assign fb_addr = {1'b0, cpu_addr[13:0]};
        end else begin : g_range
            localparam [14:0] FB_BASE = 15'h3000; // byte address 0x6000
            assign fb_sel = (cpu_addr >= FB_BASE) &&
                            (cpu_addr < FB_BASE + WORDS);
            assign fb_addr = cpu_addr - FB_BASE;
        end
    endgenerate
    assign fb_wmask = cpu_wmask;
    assign fb_wdata = cpu_wdata;

    assign fb_we = !rst && cpu_we && fb_sel;
endmodule

`default_nettype wire
