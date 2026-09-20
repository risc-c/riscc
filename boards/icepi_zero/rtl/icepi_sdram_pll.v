// IcePi SDRAM PLL: 166 2/3 MHz from the 50 MHz oscillator.

`default_nettype none

// Core divider settings from ecppll; CLKOS adds 292.5 degrees at the same rate.
module icepi_sdram_pll (
    input wire refclk,
    input wire rst,
    output wire outclk,
    output wire pinclk,
    output wire locked
);
    (* FREQUENCY_PIN_CLKI="50" *)
    (* FREQUENCY_PIN_CLKOP="166.667" *)
    (* FREQUENCY_PIN_CLKOS="166.667" *)
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
        .FEEDBK_PATH("CLKOP"),
        .CLKFB_DIV(10)
    ) pll_i (
        .RST(rst),
        .STDBY(1'b0),
        .CLKI(refclk),
        .CLKOP(outclk),
        .CLKOS(pinclk),
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
        .LOCK(locked)
    );
endmodule

`default_nettype wire
