#include "Vatum_a3_nano_soc_sim.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <string>

static constexpr int BaudDiv = 8;

struct TxCapture {
    enum State { Idle, Data, Stop } state = Idle;
    int wait = 0;
    int bit = 0;
    uint8_t current = 0;
    std::string output;

    void sample(int tx)
    {
        switch (state) {
        case Idle:
            if (!tx) {
                state = Data;
                wait = BaudDiv + BaudDiv / 2;
                bit = 0;
                current = 0;
            }
            break;
        case Data:
            if (--wait <= 0) {
                if (tx)
                    current |= uint8_t(1u << bit);
                ++bit;
                wait = BaudDiv;
                if (bit == 8)
                    state = Stop;
            }
            break;
        case Stop:
            if (--wait <= 0) {
                output.push_back(char(current));
                state = Idle;
            }
            break;
        }
    }
};

static void tick(Vatum_a3_nano_soc_sim *top, TxCapture &capture)
{
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    capture.sample(top->uart_tx);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    auto *top = new Vatum_a3_nano_soc_sim;
    TxCapture capture;

    top->clk = 0;
    top->rst = 1;
    top->uart_rx = 1;
    for (int cycle = 0; cycle < 40; ++cycle)
        tick(top, capture);
    top->rst = 0;

    static const std::string Expected = "LLVM RISCC PASS\n";
    for (int cycle = 0; cycle < 1000000; ++cycle) {
        tick(top, capture);
        if (capture.output.find(Expected) != std::string::npos) {
            std::printf("Atum compiler UART PASS: %s", capture.output.c_str());
            delete top;
            return 0;
        }
    }

    std::printf("Atum compiler UART FAIL: %s\n", capture.output.c_str());
    delete top;
    return 1;
}
