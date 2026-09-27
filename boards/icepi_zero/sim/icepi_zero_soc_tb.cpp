#include "Vicepi_zero_soc_sim.h"
#include "../../shared/test/demo_checks.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace demo_test;

struct RxDrive
{
    std::vector<uint8_t> bytes;
    size_t pos = 0;
    int phase = -1;
    int wait = 0;
    int gap = 0;

    explicit RxDrive(const char *text)
    {
        while (*text)
            bytes.push_back(uint8_t(*text++));
    }

    int value()
    {
        if (gap > 0)
        {
            gap--;
            return 1;
        }
        if (pos >= bytes.size())
            return 1;
        if (phase < 0)
        {
            phase = 0;
            wait = BAUD_DIV;
        }

        int bit = 1;
        if (phase == 0)
            bit = 0;
        else if (phase >= 1 && phase <= 8)
            bit = (bytes[pos] >> (phase - 1)) & 1;

        if (--wait <= 0)
        {
            wait = BAUD_DIV;
            phase++;
            if (phase == 10)
            {
                phase = -1;
                pos++;
                gap = 200;
            }
        }
        return bit;
    }
};

// The 74.286 MHz pixel clock runs at 39/35 of the 66.667 MHz CPU.
static unsigned pixel_phase = 0;
static void tick(Vicepi_zero_soc_sim *top, TxCapture &txcap)
{
    for (unsigned phase = 0; phase < 4; ++phase)
    {
        top->clk = phase >= 2;
        top->shift_clk = phase & 1;
        pixel_phase += 39;
        if (pixel_phase >= 70)
        {
            pixel_phase -= 70;
            top->pix_clk = !top->pix_clk;
        }
        top->eval();
    }
    txcap.sample(top->uart_tx);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vicepi_zero_soc_sim *top = new Vicepi_zero_soc_sim;
    TxCapture txcap;
    RxDrive rxdrv("12+");

    top->clk = 0;
    top->pix_clk = 0;
    top->shift_clk = 0;
    top->rst = 1;
    top->uart_rx = 1;

    for (int i = 0; i < 40; i++)
        tick(top, txcap);
    top->rst = 0;

    bool injecting = false;
    FrameMonitor frames;
    uint32_t julia_writes = 0;
    uint32_t julia_nonzero = 0;
    const int max_cycles = 15000000;
    for (int run_cycle = 0; run_cycle < max_cycles; run_cycle++)
    {
        if (!injecting && txcap.out.find("RISC-C on Icepi Zero") != std::string::npos)
            injecting = true;
        top->uart_rx = injecting ? rxdrv.value() : 1;
        tick(top, txcap);

        // Julia rows start at framebuffer row 10. Ignore the first and last
        // packed word of each row because those contain the white border.
        frames.sample(top);
        if (frames.failed)
            break;
        if (top->dbg_fb_we)
        {
            if (top->dbg_fb_addr >= FRAMEBUFFER_WORDS)
                frames.failed = true;
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

        if (frames.failed)
            break;
        if (txcap.out.find("RISC-C on Icepi Zero") != std::string::npos &&
            julia_writes >= 38 && julia_nonzero > 0 &&
            top->dbg_uart_rx_count >= 3 && frames.checked >= 3)
        {
            std::printf("RTL-SOC PASS uart=%s fb_writes=%u julia=%u/%u frames_checked=%u rx=%u tx=%u\n",
                txcap.out.c_str(),
                unsigned(top->dbg_fb_writes),
                julia_nonzero, julia_writes,
                frames.checked,
                unsigned(top->dbg_uart_rx_count),
                unsigned(top->dbg_uart_tx_count));
            std::printf("ticker redraw maximum=%u CPU cycles, entirely in vblank\n",
                frames.max_redraw_cycles);
            delete top;
            return 0;
        }
    }

    std::printf("RTL-SOC FAIL uart=%s fb_writes=%u julia=%u/%u frames_checked=%u rx=%u tx=%u\n",
        txcap.out.c_str(),
        unsigned(top->dbg_fb_writes),
        julia_nonzero, julia_writes,
        frames.checked,
        unsigned(top->dbg_uart_rx_count),
        unsigned(top->dbg_uart_tx_count));
    std::printf("frame=%u edges=%u redraws=%u irq_seen=%u irq_acks=%u failed=%u\n",
        frames.frame, frames.edges, frames.redraws, unsigned(frames.irq_seen),
        frames.irq_acks, unsigned(frames.failed));
    std::printf("redraw_cycles=%u outside_blank=%u drawing=%u\n",
        frames.max_redraw_cycles, unsigned(frames.outside_blank), unsigned(frames.drawing));
    delete top;
    return 1;
}
