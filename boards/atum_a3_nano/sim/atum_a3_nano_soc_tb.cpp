#include "Vatum_a3_nano_soc_sim.h"
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

static void tick(Vatum_a3_nano_soc_sim *top, TxCapture &txcap)
{
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    txcap.sample(top->uart_tx);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vatum_a3_nano_soc_sim *top = new Vatum_a3_nano_soc_sim;
    TxCapture txcap;
    top->clk = 0;
    top->rst = 1;
    top->uart_rx = 1;

    for (int i = 0; i < 40; i++)
        tick(top, txcap);
    top->rst = 0;

    uint32_t julia_writes = 0;
    uint32_t julia_nonzero = 0;
    bool julia_started = false;
    bool ticker_scrolled = false;
    for (int cycle = 0; cycle < 5000000; cycle++)
    {
        tick(top, txcap);
        // Julia begins at framebuffer row 10.  Each row is 40 packed words;
        // ignore the two white-border words when checking animation writes.
        // A later ticker-band write proves the time-driven scroll ran.
        if (top->dbg_fb_we)
        {
            if (top->dbg_fb_addr >= 400)
            {
                const unsigned column = unsigned(top->dbg_fb_addr) % 40;

                julia_started = true;
                if (column > 0 && column < 39)
                {
                    julia_writes++;
                    if (top->dbg_fb_wdata != 0)
                        julia_nonzero++;
                }
            }
            else if (julia_started && top->dbg_fb_addr >= 40)
            {
                ticker_scrolled = true;
            }
        }
        if (txcap.out.find("RISC-C on Atum A3 Nano") != std::string::npos &&
            julia_writes >= 38 && julia_nonzero > 0 && ticker_scrolled)
        {
            std::printf("Atum RTL-SOC PASS uart=%s fb_writes=%u julia=%u/%u scroll=%u tx=%u\n",
                txcap.out.c_str(), unsigned(top->dbg_fb_writes),
                julia_nonzero, julia_writes, unsigned(ticker_scrolled),
                unsigned(top->dbg_uart_tx_count));
            delete top;
            return 0;
        }
    }

    std::printf("Atum RTL-SOC FAIL uart=%s fb_writes=%u julia=%u/%u scroll=%u tx=%u\n",
        txcap.out.c_str(), unsigned(top->dbg_fb_writes),
        julia_nonzero, julia_writes, unsigned(ticker_scrolled),
        unsigned(top->dbg_uart_tx_count));
    delete top;
    return 1;
}
