#include "Vriscc_demo_soc_sim.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <string>

static constexpr int BAUD_DIV = 8;

struct TxCapture
{
    enum State
    {
        IDLE,
        DATA,
        STOP
    } state = IDLE;
    int wait = 0;
    int bit = 0;
    uint8_t cur = 0;
    std::string out;

    void sample(int tx)
    {
        switch (state)
        {
        case IDLE:
            if (!tx)
        {
                state = DATA;
                wait = BAUD_DIV + BAUD_DIV / 2;
                bit = 0;
                cur = 0;
        }
            break;
        case DATA:
            if (--wait <= 0)
        {
                if (tx)
                    cur |= uint8_t(1u << bit);
                bit++;
                wait = BAUD_DIV;
                if (bit == 8)
                    state = STOP;
        }
            break;
        case STOP:
            if (--wait <= 0)
        {
                out.push_back(char(cur));
                state = IDLE;
        }
            break;
        }
    }
};

// Four evaluation phases per 200 MHz CPU cycle preserve both clock edges.
// Pixel/CPU ratios are 49/66 (1080p) and 49/132 (720p).
static unsigned pixel_phase = 0;
static unsigned pixel_threshold = 132;
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

struct FrameMonitor
{
    unsigned frame = 0;
    unsigned edges = 0;
    unsigned redraws = 0;
    unsigned checked = 0;
    unsigned irq_acks = 0;
    unsigned cycle = 0;
    unsigned redraw_start = 0;
    unsigned max_redraw_cycles = 0;
    bool drawing = false;
    bool outside_blank = false;
    bool last_blank = true;
    bool last_irq = false;
    bool irq_seen = false;
    bool failed = false;

    template<class Top> void sample(const Top *top)
    {
        ++cycle;
        if (top->dbg_vblank && !last_blank)
            ++edges;
        last_blank = top->dbg_vblank;
        if (top->dbg_frame_count != frame)
        {
            if (top->dbg_frame_count != frame + 1 || edges != frame + 1)
                failed = true;
            if (frame != 0)
            {
                if (redraws != 1 || drawing || !irq_seen || irq_acks != 1)
                    failed = true;
                ++checked;
            }
            frame = top->dbg_frame_count;
            redraws = 0;
            irq_acks = 0;
            irq_seen = false;
        }
        irq_seen |= bool(top->dbg_timer_irq);
        if (last_irq && !top->dbg_timer_irq)
            ++irq_acks;
        last_irq = top->dbg_timer_irq;
        // Address 160 starts the seven glyph rows of an IRQ redraw. Ignore
        // startup border/ticker initialization before the first real frame.
        if (frame != 0 && top->dbg_fb_we && top->dbg_fb_addr == 160)
        {
            drawing = true;
            redraw_start = cycle;
            if (++redraws > 1)
                failed = true;
        }
        if (drawing && top->dbg_fb_we && top->dbg_fb_addr >= 160 &&
            top->dbg_fb_addr < 720)
        {
            if (!top->dbg_vblank)
                outside_blank = true;
            if (top->dbg_fb_addr == 719)
            {
                const unsigned duration = cycle - redraw_start + 1;
                if (duration > max_redraw_cycles)
                    max_redraw_cycles = duration;
                drawing = false;
                failed |= outside_blank;
            }
        }
    }
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *expected_banner = argc > 1 ? argv[1] : "RISC-C on Atum A3 Nano";
    Vriscc_demo_soc_sim *top = new Vriscc_demo_soc_sim;
    TxCapture txcap;
    pixel_threshold = std::string(expected_banner).find("DE23") != std::string::npos ? 264 : 132;
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
        // Julia begins at framebuffer row 10.  Each row is 80 packed words;
        // ignore the two white-border words when checking animation writes.
        frames.sample(top);
        if (frames.failed)
            break;
        if (top->dbg_fb_we)
        {
            if (top->dbg_fb_addr >= 800)
            {
                const unsigned column = unsigned(top->dbg_fb_addr) % 80;

                if (column > 0 && column < 79)
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
