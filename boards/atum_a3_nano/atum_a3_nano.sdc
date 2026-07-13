# CLOCK1_50 feeds the local IOPLL, which generates the 225 MHz SoC clock.
create_clock -name sys_clk_ref -period 20.000 [get_ports {CLOCK1_50}]
create_generated_clock -name sys_clk \
    -source [get_ports {CLOCK1_50}] \
    -multiply_by 9 -divide_by 2 \
    [get_pins {sys_pll|pll|out_clk[0]}]

# PLL lock is an asynchronous status signal. Only its first synchronizer
# stage may sample it directly; the second stage is timed normally.
set_false_path -to [get_registers {sys_pll_lock_sync[0]}]

create_clock -name hdmi_clk_ref -period 20.000 [get_ports {CLOCK0_50}]
create_generated_clock -name hdmi_pll_n_cnt_clk \
    -source [get_ports {CLOCK0_50}] -divide_by 3 \
    [get_nodes {hdmi_pll|pll~ncntr_reg}]
create_generated_clock -name hdmi_pll_m_cnt_clk \
    -source [get_nodes {hdmi_pll|pll~ncntr_reg}] \
    [get_nodes {hdmi_pll|pll~mcntr_reg}]
create_generated_clock -name pix_clk \
    -source [get_nodes {hdmi_pll|pll~ncntr_reg}] \
    -multiply_by 98 -divide_by 11 \
    [get_pins {hdmi_pll|pll|out_clk[0]}]

# The SoC and PLL/video domains exchange only synchronized control signals
# and dual-clock framebuffer data; they have no synchronous phase relation.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk sys_clk_ref}] \
    -group [get_clocks {pix_clk hdmi_clk_ref hdmi_pll_n_cnt_clk hdmi_pll_m_cnt_clk}]

derive_clock_uncertainty
