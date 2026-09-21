// atum_sdram_pll.v : 166 2/3 MHz SDRAM clock PLL for Atum.

`default_nettype none

// A 2 GHz VCO supplies SDRAM at 166 2/3 MHz and CPU at 200 MHz.
// The forwarded SDRAM clock advances by 11/16 ns (318.75 degrees).
// Counter 2 independently selects CPU frequency; each VCO phase tap is 62.5 ps.
module atum_sdram_pll #(
    parameter integer CPU_DIV = 10
) (
    input wire refclk,
    input wire rst,
    output wire outclk,
    output wire forward_clk,
    output wire cpu_outclk,
    output wire locked
);
    wire [6:0] pll_out;

    (* altera_attribute = "-name DESIGN_ASSISTANT_EXCLUDE \"RES-50002\"" *)
    tennm_ph2_iopll #(
        .bandwidth_mode("BANDWIDTH_MODE_AUTO"),
        .base_address(16'd0),
        .cascade_mode("CASCADE_MODE_STANDALONE"),
        .clk_switch_auto_en("FALSE"),
        .clk_switch_manual_en("FALSE"),
        .compensation_clk_source("COMPENSATION_CLK_SOURCE_UNUSED"),
        .compensation_mode("COMPENSATION_MODE_DIRECT"),
        .fb_clk_delay(0),
        .fb_clk_fractional_div_den(1),
        .fb_clk_fractional_div_num(1),
        .fb_clk_fractional_div_value(1),
        .fb_clk_m_div(40),
        .out_clk_0_c_div(12),
        .out_clk_0_core_en("TRUE"),
        .out_clk_0_delay(0),
        .out_clk_0_dutycycle_den(24),
        .out_clk_0_dutycycle_num(12),
        .out_clk_0_dutycycle_percent(50),
        .out_clk_0_freq(36'd166666667),
        .out_clk_0_phase_ps(0),
        .out_clk_0_phase_shifts(0),
        .out_clk_1_c_div(12), .out_clk_1_core_en("TRUE"),
        .out_clk_1_delay(0), .out_clk_1_dutycycle_den(24),
        .out_clk_1_dutycycle_num(12), .out_clk_1_dutycycle_percent(50),
        .out_clk_1_freq(36'd166666667), .out_clk_1_phase_ps(5313),
        .out_clk_1_phase_shifts(85),
        .out_clk_2_c_div(CPU_DIV), .out_clk_2_core_en("TRUE"),
        .out_clk_2_delay(0), .out_clk_2_dutycycle_den(2 * CPU_DIV),
        .out_clk_2_dutycycle_num(CPU_DIV), .out_clk_2_dutycycle_percent(50),
        .out_clk_2_freq((36'd2000000000 + CPU_DIV / 2) / CPU_DIV), .out_clk_2_phase_ps(0),
        .out_clk_2_phase_shifts(0),
        .out_clk_3_c_div(1), .out_clk_3_core_en("FALSE"),
        .out_clk_3_delay(0), .out_clk_3_dutycycle_den(4),
        .out_clk_3_dutycycle_num(2), .out_clk_3_dutycycle_percent(50),
        .out_clk_3_freq(36'd2000000000), .out_clk_3_phase_ps(0),
        .out_clk_3_phase_shifts(0),
        .out_clk_4_c_div(1), .out_clk_4_core_en("FALSE"),
        .out_clk_4_delay(0), .out_clk_4_dutycycle_den(4),
        .out_clk_4_dutycycle_num(2), .out_clk_4_dutycycle_percent(50),
        .out_clk_4_freq(36'd2000000000), .out_clk_4_phase_ps(0),
        .out_clk_4_phase_shifts(0),
        .out_clk_5_c_div(1), .out_clk_5_core_en("FALSE"),
        .out_clk_5_delay(0), .out_clk_5_dutycycle_den(4),
        .out_clk_5_dutycycle_num(2), .out_clk_5_dutycycle_percent(50),
        .out_clk_5_freq(36'd2000000000), .out_clk_5_phase_ps(0),
        .out_clk_5_phase_shifts(0),
        .out_clk_6_c_div(1), .out_clk_6_core_en("FALSE"),
        .out_clk_6_delay(0), .out_clk_6_dutycycle_den(4),
        .out_clk_6_dutycycle_num(2), .out_clk_6_dutycycle_percent(50),
        .out_clk_6_freq(36'd2000000000), .out_clk_6_phase_ps(0),
        .out_clk_6_phase_shifts(0),
        .out_clk_cascading_source("OUT_CLK_CASCADING_SOURCE_UNUSED"),
        .out_clk_external_0_source("OUT_CLK_EXTERNAL_0_SOURCE_UNUSED"),
        .out_clk_external_1_source("OUT_CLK_EXTERNAL_1_SOURCE_UNUSED"),
        .out_clk_periph_0_delay(0), .out_clk_periph_0_en("TRUE"),
        .out_clk_periph_1_delay(0), .out_clk_periph_1_en("TRUE"),
        .pfd_clk_freq(32'd50000000),
        .protocol_mode("PROTOCOL_MODE_BASIC"),
        .ref_clk_0_freq(32'd50000000),
        .ref_clk_1_freq(32'd0),
        .ref_clk_delay(0),
        .ref_clk_n_div(1),
        .self_reset_en("TRUE"),
        .set_dutycycle("SET_DUTYCYCLE_FRACTION"),
        .set_fractional("SET_FRACTIONAL_FRACTION"),
        .set_freq("SET_FREQ_DIVISION_VERIFY"),
        .set_phase("SET_PHASE_NUM_SHIFTS_VERIFY"),
        .vco_clk_freq(36'd2000000000)
    ) pll (
        .lock(locked),
        .out_clk(pll_out),
        .permit_cal(1'b1),
        .ref_clk0(refclk),
        .reset(rst)
    );

    assign outclk = pll_out[0];
    assign forward_clk = pll_out[1];
    assign cpu_outclk = pll_out[2];
endmodule

`default_nettype wire
