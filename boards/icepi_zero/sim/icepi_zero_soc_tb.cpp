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

static void tick(Vicepi_zero_soc_sim *top, TxCapture &txcap, uint64_t cycle)
{
    top->clk = 0;
    top->shift_clk = 0;
    if (cycle & 1)
        top->pix_clk = 0;
    top->eval();

    top->clk = 1;
    top->shift_clk = 1;
    if (!(cycle & 1))
        top->pix_clk = 1;
    top->eval();
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

    uint64_t sim_cycle = 0;
    for (int i = 0; i < 40; i++)
        tick(top, txcap, sim_cycle++);
    top->rst = 0;

    bool injecting = false;
    bool julia_started = false;
    bool ticker_scrolled = false;
    uint32_t julia_writes = 0;
    uint32_t julia_nonzero = 0;
    const int max_cycles = 5000000;
    for (int run_cycle = 0; run_cycle < max_cycles; run_cycle++)
    {
        if (!injecting && txcap.out.find("RISC-C on Icepi Zero") != std::string::npos)
            injecting = true;
        top->uart_rx = injecting ? rxdrv.value() : 1;
        tick(top, txcap, sim_cycle++);

        // Julia rows start at framebuffer row 10. Ignore the first and last
        // packed word of each row because those contain the white border.
        // A later write in the ticker band proves that the time service
        // advanced its scroll while incremental Julia rendering continued.
        if (top->dbg_fb_we)
        {
            if (top->dbg_fb_addr >= 800)
            {
                const unsigned column = unsigned(top->dbg_fb_addr) % 80;

                julia_started = true;
                if (column > 0 && column < 79)
                {
                    julia_writes++;
                    if (top->dbg_fb_wdata != 0)
                        julia_nonzero++;
                }
            }
            else if (julia_started && top->dbg_fb_addr >= 80)
            {
                ticker_scrolled = true;
            }
        }

        if (txcap.out.find("RISC-C on Icepi Zero") != std::string::npos &&
            julia_writes >= 38 && julia_nonzero > 0 &&
            top->dbg_uart_rx_count >= 3 && ticker_scrolled)
        {
            std::printf("RTL-SOC PASS uart=%s fb_writes=%u julia=%u/%u scroll=%u rx=%u tx=%u\n",
                txcap.out.c_str(),
                unsigned(top->dbg_fb_writes),
                julia_nonzero, julia_writes,
                unsigned(ticker_scrolled),
                unsigned(top->dbg_uart_rx_count),
                unsigned(top->dbg_uart_tx_count));
            delete top;
            return 0;
        }
    }

    std::printf("RTL-SOC FAIL uart=%s fb_writes=%u julia=%u/%u scroll=%u rx=%u tx=%u\n",
        txcap.out.c_str(),
        unsigned(top->dbg_fb_writes),
        julia_nonzero, julia_writes,
        unsigned(ticker_scrolled),
        unsigned(top->dbg_uart_rx_count),
        unsigned(top->dbg_uart_tx_count));
    delete top;
    return 1;
}
