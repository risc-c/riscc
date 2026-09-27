#ifndef RISCC_DEMO_CHECKS_H
#define RISCC_DEMO_CHECKS_H

#include <cstdint>
#include <string>

namespace demo_test
{

constexpr int BAUD_DIV = 8;
constexpr unsigned FRAMEBUFFER_WIDTH = 640;
constexpr unsigned FRAMEBUFFER_HEIGHT = 360;
constexpr unsigned WORDS_PER_ROW = FRAMEBUFFER_WIDTH / 4;
constexpr unsigned FRAMEBUFFER_WORDS = WORDS_PER_ROW * FRAMEBUFFER_HEIGHT;
constexpr unsigned TICKER_FIRST_WORD = 2 * WORDS_PER_ROW;
constexpr unsigned TICKER_LAST_WORD = 9 * WORDS_PER_ROW - 1;
constexpr unsigned JULIA_FIRST_WORD = 10 * WORDS_PER_ROW;

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

struct FrameMonitor
{
    unsigned frame = 0;
    unsigned edges = 0;
    unsigned redraws = 0;
    unsigned checked = 0;
    unsigned irq_acks = 0;
    unsigned cycle = 0;
    unsigned redraw_start = 0;
    unsigned redraw_next = 0;
    unsigned redraw_words = 0;
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
        // Address 320 starts the seven glyph rows of an IRQ redraw at the
        // 640-pixel framebuffer width. Ignore startup border/ticker
        // initialization before the first real frame.
        if (frame != 0 && top->dbg_fb_we &&
            top->dbg_fb_addr == TICKER_FIRST_WORD)
        {
            drawing = true;
            redraw_start = cycle;
            redraw_next = TICKER_FIRST_WORD;
            redraw_words = 0;
            if (++redraws > 1)
                failed = true;
        }
        if (drawing && top->dbg_fb_we)
        {
            if (top->dbg_fb_addr != redraw_next ||
                top->dbg_fb_addr > TICKER_LAST_WORD)
            {
                failed = true;
            }
            if (!top->dbg_vblank)
                outside_blank = true;
            redraw_next = unsigned(top->dbg_fb_addr) + 1;
            redraw_words++;
            if (top->dbg_fb_addr == TICKER_LAST_WORD)
            {
                const unsigned duration = cycle - redraw_start + 1;
                if (duration > max_redraw_cycles)
                    max_redraw_cycles = duration;
                if (redraw_words != TICKER_LAST_WORD -
                    TICKER_FIRST_WORD + 1)
                    failed = true;
                drawing = false;
                failed |= outside_blank;
            }
        }
    }
};

}  // namespace demo_test

#endif
