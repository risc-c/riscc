#include "Vriscc_demo_soc_sim.h"
#include "demo_checks.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <string>

using namespace demo_test;

// Four evaluation phases per 200 MHz CPU cycle preserve both clock edges.
// The 720p pixel clock is 49/132 of 200 MHz.
static unsigned pixel_phase = 0;
static constexpr unsigned pixel_threshold = 264;
static void tick(Vriscc_demo_soc_sim *top, TxCapture &txcap)
{
    for (unsigned phase = 0; phase < 4; ++phase)
    {
        top->clk = phase >= 2;
        pixel_phase += 49;
        if (pixel_phase >= pixel_threshold)
        {
            pixel_phase -= pixel_threshold;
            top->pix_clk = !top->pix_clk;
        }
        top->eval();
    }
    txcap.sample(top->uart_tx);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *expected_banner = argc > 1 ? argv[1] : "RISC-C on Atum A3 Nano";
    Vriscc_demo_soc_sim *top = new Vriscc_demo_soc_sim;
    TxCapture txcap;
    top->pix_clk = 0;
    top->clk = 0;
    top->rst = 1;
    top->uart_rx = 1;

    for (int i = 0; i < 40; i++)
        tick(top, txcap);
    top->rst = 0;

    uint32_t julia_writes = 0;
    uint32_t julia_nonzero = 0;
    FrameMonitor frames;
    for (int cycle = 0; cycle < 15000000; cycle++)
    {
        tick(top, txcap);
        // Julia begins at framebuffer row 10.  Each row is 160 packed words;
        // ignore the two white-border words when checking animation writes.
        frames.sample(top);
        if (frames.failed)
            break;
        if (top->dbg_fb_we)
        {
            if (top->dbg_fb_addr >= JULIA_FIRST_WORD &&
                top->dbg_fb_addr < FRAMEBUFFER_WORDS)
            {
                const unsigned column = unsigned(top->dbg_fb_addr) % WORDS_PER_ROW;

                if (column > 0 && column + 1 < WORDS_PER_ROW)
                {
                    julia_writes++;
                    const uint32_t byte_mask =
                        (top->dbg_fb_wmask & 1 ? 0x000000ffu : 0u) |
                        (top->dbg_fb_wmask & 2 ? 0x0000ff00u : 0u) |
                        (top->dbg_fb_wmask & 4 ? 0x00ff0000u : 0u) |
                        (top->dbg_fb_wmask & 8 ? 0xff000000u : 0u);
                    if ((top->dbg_fb_wdata & byte_mask) != 0)
                        julia_nonzero++;
                }
            }
        }
        if (txcap.out.find(expected_banner) != std::string::npos &&
            julia_writes >= 38 && julia_nonzero > 0 && frames.checked >= 3)
        {
            std::printf("Agilex RTL-SOC PASS uart=%s fb_writes=%u julia=%u/%u frames_checked=%u tx=%u\n",
                txcap.out.c_str(), unsigned(top->dbg_fb_writes),
                julia_nonzero, julia_writes, frames.checked,
                unsigned(top->dbg_uart_tx_count));
            std::printf("ticker redraw maximum=%u CPU cycles, entirely in vblank\n",
                frames.max_redraw_cycles);
            delete top;
            return 0;
        }
    }

    std::printf("Agilex RTL-SOC FAIL uart=%s fb_writes=%u julia=%u/%u frames_checked=%u tx=%u\n",
        txcap.out.c_str(), unsigned(top->dbg_fb_writes),
        julia_nonzero, julia_writes, frames.checked,
        unsigned(top->dbg_uart_tx_count));
    std::printf("frame=%u edges=%u redraws=%u irq_seen=%u irq_acks=%u failed=%u\n",
        frames.frame, frames.edges, frames.redraws, unsigned(frames.irq_seen),
        frames.irq_acks, unsigned(frames.failed));
    std::printf("redraw_cycles=%u outside_blank=%u drawing=%u\n",
        frames.max_redraw_cycles, unsigned(frames.outside_blank), unsigned(frames.drawing));
    delete top;
    return 1;
}
