// IcePi clocks: 166 2/3 MHz SDRAM and 55 5/9 MHz CPU from 50 MHz.

`default_nettype none

// Core divider settings from ecppll; CLKOS adds 292.5 degrees at the same rate.
module icepi_sdram_pll (
    input wire refclk,
    input wire rst,
    output wire outclk,
    output wire pinclk,
    output wire cpu_clk,
    output wire locked
);
    (* FREQUENCY_PIN_CLKI="50" *)
    (* FREQUENCY_PIN_CLKOP="166.667" *)
    (* FREQUENCY_PIN_CLKOS="166.667" *)
    (* FREQUENCY_PIN_CLKOS2="55.555556" *)
    (* ICP_CURRENT="12" *)
    (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *)
    (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("ENABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(3),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_DIV(4),
        .CLKOP_CPHASE(2),
        .CLKOP_FPHASE(0),
        // 292.5 degrees: three VCO cycles plus two eighth-cycle steps.
        .CLKOS_ENABLE("ENABLED"),
        .CLKOS_DIV(4),
        .CLKOS_CPHASE(5),
        .CLKOS_FPHASE(2),
        .CLKOS2_ENABLE("ENABLED"),
        .CLKOS2_DIV(12),
        .CLKOS2_CPHASE(2),
        .CLKOS2_FPHASE(0),
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(10)
    ) pll_i (
        .RST(rst),
        .STDBY(1'b0),
        .CLKI(refclk),
        .CLKOP(outclk),
        .CLKOS(pinclk),
        .CLKOS2(cpu_clk),
        .CLKOS3(),
        .CLKFB(outclk),
        .CLKINTFB(),
        .PHASESEL0(1'b0),
        .PHASESEL1(1'b0),
        .PHASEDIR(1'b1),
        .PHASESTEP(1'b1),
        .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0),
        .ENCLKOS(1'b0),
        .ENCLKOS2(1'b0),
        .ENCLKOS3(1'b0),
        .LOCK(locked)
    );
endmodule

`default_nettype wire
