// agilex3_sdram_pll.v : 125 MHz SDRAM and 200 MHz CPU clocks.

`default_nettype none

// A 2 GHz VCO supplies independently divided SDRAM and CPU clocks.
// At 125 MHz, C1 advances by 1.0625 ns before the output DDR inversion.
// C3 captures read data at +6 ns; a full-cycle register precedes core handoff.
// The CPU divider is independent; each VCO phase tap is 62.5 ps.
module agilex3_sdram_pll #(
    parameter integer CPU_DIV = 10,
    parameter integer MEMORY_DIV = 16,
    parameter integer FORWARD_PHASE_PS = 6938,
    parameter integer FORWARD_PHASE_STEPS = 111
) (
    input wire refclk,
    input wire rst,
    output wire outclk,
    output wire forward_clk,
    output wire capture_clk,
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
        .out_clk_0_c_div(MEMORY_DIV),
        .out_clk_0_core_en("TRUE"),
        .out_clk_0_delay(0),
        .out_clk_0_dutycycle_den(2 * MEMORY_DIV),
        .out_clk_0_dutycycle_num(MEMORY_DIV),
        .out_clk_0_dutycycle_percent(50),
        .out_clk_0_freq((36'd2000000000 + MEMORY_DIV / 2) / MEMORY_DIV),
        .out_clk_0_phase_ps(0),
        .out_clk_0_phase_shifts(0),
        .out_clk_1_c_div(MEMORY_DIV),
        .out_clk_1_core_en("TRUE"),
        .out_clk_1_delay(0),
        .out_clk_1_dutycycle_den(2 * MEMORY_DIV),
        .out_clk_1_dutycycle_num(MEMORY_DIV),
        .out_clk_1_dutycycle_percent(50),
        .out_clk_1_freq((36'd2000000000 + MEMORY_DIV / 2) / MEMORY_DIV),
        .out_clk_1_phase_ps(FORWARD_PHASE_PS),
        .out_clk_1_phase_shifts(FORWARD_PHASE_STEPS),
        .out_clk_2_c_div(CPU_DIV),
        .out_clk_2_core_en("TRUE"),
        .out_clk_2_delay(0),
        .out_clk_2_dutycycle_den(2 * CPU_DIV),
        .out_clk_2_dutycycle_num(CPU_DIV),
        .out_clk_2_dutycycle_percent(50),
        .out_clk_2_freq((36'd2000000000 + CPU_DIV / 2) / CPU_DIV),
        .out_clk_2_phase_ps(0),
        .out_clk_2_phase_shifts(0),
        .out_clk_3_c_div(MEMORY_DIV),
        .out_clk_3_core_en("TRUE"),
        .out_clk_3_delay(0),
        .out_clk_3_dutycycle_den(2 * MEMORY_DIV),
        .out_clk_3_dutycycle_num(MEMORY_DIV),
        .out_clk_3_dutycycle_percent(50),
        .out_clk_3_freq((36'd2000000000 + MEMORY_DIV / 2) / MEMORY_DIV),
        .out_clk_3_phase_ps(6000),
        .out_clk_3_phase_shifts(96),
        .out_clk_4_c_div(1),
        .out_clk_4_core_en("FALSE"),
        .out_clk_4_delay(0),
        .out_clk_4_dutycycle_den(4),
        .out_clk_4_dutycycle_num(2),
        .out_clk_4_dutycycle_percent(50),
        .out_clk_4_freq(36'd2000000000),
        .out_clk_4_phase_ps(0),
        .out_clk_4_phase_shifts(0),
        .out_clk_5_c_div(1),
        .out_clk_5_core_en("FALSE"),
        .out_clk_5_delay(0),
        .out_clk_5_dutycycle_den(4),
        .out_clk_5_dutycycle_num(2),
        .out_clk_5_dutycycle_percent(50),
        .out_clk_5_freq(36'd2000000000),
        .out_clk_5_phase_ps(0),
        .out_clk_5_phase_shifts(0),
        .out_clk_6_c_div(1),
        .out_clk_6_core_en("FALSE"),
        .out_clk_6_delay(0),
        .out_clk_6_dutycycle_den(4),
        .out_clk_6_dutycycle_num(2),
        .out_clk_6_dutycycle_percent(50),
        .out_clk_6_freq(36'd2000000000),
        .out_clk_6_phase_ps(0),
        .out_clk_6_phase_shifts(0),
        .out_clk_cascading_source("OUT_CLK_CASCADING_SOURCE_UNUSED"),
        .out_clk_external_0_source("OUT_CLK_EXTERNAL_0_SOURCE_UNUSED"),
        .out_clk_external_1_source("OUT_CLK_EXTERNAL_1_SOURCE_UNUSED"),
        .out_clk_periph_0_delay(0),
        .out_clk_periph_0_en("TRUE"),
        .out_clk_periph_1_delay(0),
        .out_clk_periph_1_en("TRUE"),
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
    assign capture_clk = pll_out[3];
    assign cpu_outclk = pll_out[2];
endmodule

`default_nettype wire
