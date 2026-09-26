#include "Vicepi_zero_soc_sim.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

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
static void tick(Vicepi_zero_soc_sim *top, TxCapture &txcap, uint64_t)
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
    Vicepi_zero_soc_sim *top = new Vicepi_zero_soc_sim;
    TxCapture txcap;
    RxDrive rxdrv("12+");

    top->clk = 0;
    top->pix_clk = 0;
    top->shift_clk = 0;
    top->rst = 1;
    top->uart_rx = 1;

    uint64_t sim_cycle = 0;
    for (int i = 0; i < 40; i++)
        tick(top, txcap, sim_cycle++);
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
        tick(top, txcap, sim_cycle++);

        // Julia rows start at framebuffer row 10. Ignore the first and last
        // packed word of each row because those contain the white border.
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
