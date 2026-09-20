# CLOCK1_50 feeds one IOPLL with separate CPU and SDRAM output counters.
# CPU_DIV=9 selects 166 2/3 MHz; update this ratio when tuning that divider.
create_clock -name sys_clk_ref -period 20.000 [get_ports {CLOCK1_50}]
create_generated_clock -name sys_clk \
    -source [get_ports {CLOCK1_50}] \
    -multiply_by 10 -divide_by 3 \
    [get_pins {memory_pll|pll|out_clk[2]}]

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

create_generated_clock -name sdram_core -source [get_ports CLOCK1_50] \
    -multiply_by 10 -divide_by 3 [get_pins {memory_pll|pll|out_clk[0]}]
create_generated_clock -name sdram_forward -source [get_ports CLOCK1_50] \
    -multiply_by 10 -divide_by 3 -phase 320 [get_pins {memory_pll|pll|out_clk[1]}]
create_generated_clock -name sdram_clk \
    -source [get_pins {memory_pll|pll|out_clk[1]}] -invert [get_ports sd_clk]
set_false_path -to [get_registers {memory_lock_sync[0]}]

# CPU and memory retain clock crossings so their dividers can differ;
# video uses its own PLL. These domains communicate through handshakes and
# dual-clock line buffers.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk sys_clk_ref}] \
    -group [get_clocks {sdram_core sdram_forward sdram_clk}] \
    -group [get_clocks {pix_clk hdmi_clk_ref hdmi_pll_n_cnt_clk hdmi_pll_m_cnt_clk}]

# Credit sequence bits must arrive within one memory period.
foreach direction {producer consumer} {
    set launch [get_registers [format {fabric|crossing|%s_gray_q[*]} $direction]]
    set capture [get_registers [format {fabric|crossing|%s_meta_q[*]} $direction]]
    set_max_skew -from $launch -to $capture 4.0
    set_net_delay -from $launch -to $capture -max 4.0
}

derive_clock_uncertainty

# IS42VM32160G-6BLI: tAC <= 5.5 ns. Include 0.3 ns for package and board
# flight time; the minimum models the SDRAM's earliest valid output.
set_input_delay -clock sdram_clk -max 5.800 [get_ports {sd_dq[*]}]
set_input_delay -clock sdram_clk -min 1.800 [get_ports {sd_dq[*]}]

# CAS=3 launches the first read word two SDRAM edges after READ.
# READ_DELAY=1 / IO_CAPTURE=1 samples it four core edges after issue:
# 4*6 - (2*6 + 2.333) = 9.667 ns nominal launch-to-capture time.
# Select that edge, including the next streamed word's hold check.
# Deliberately do not add a hold multicycle: that would incorrectly
# allow the following word to overwrite the sampled word early.
set read_capture [get_registers {memory|g_io_capture.sample_q[*]}]
if {[get_collection_size $read_capture] != 32} {
    error "Expected 32 SDRAM I/O capture registers"
}
set_multicycle_path -setup 2 -from [get_ports {sd_dq[*]}] -to $read_capture

# Device setup/hold is 1.5/1.0 ns.  Include 0.15 ns output skew margin.
set_output_delay -clock sdram_clk -max 1.650 [get_ports {sd_addr[*] sd_ba[*] sd_dqm[*] sd_cke sd_cs_n sd_ras_n sd_cas_n sd_we_n}]
set_output_delay -clock sdram_clk -min -1.150 [get_ports {sd_addr[*] sd_ba[*] sd_dqm[*] sd_cke sd_cs_n sd_ras_n sd_cas_n sd_we_n}]
set_output_delay -clock sdram_clk -max 1.650 [get_ports {sd_dq[*]}]
set_output_delay -clock sdram_clk -min -1.150 [get_ports {sd_dq[*]}]

# Manual reset and status outputs are asynchronous to the memory clock.
set_false_path -from [get_ports {KEY[0]}]
set_false_path -to [get_ports {FPGA_UART_TX LED[*]}]

# At 166 MHz the I/O registers have fixed pin locations. The external loop
# budgets are checked by quartus_sta and qualified on hardware; they are not
# closed here. Keep those failures from dominating internal placement/routing.
# This exception is fitter-only: final STA retains every input/output budget.
if {$::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {
    set_false_path -from [get_ports {sd_dq[*]}]
    set_false_path -to [get_ports {sd_addr[*] sd_ba[*] sd_dqm[*] sd_dq[*] sd_cke sd_cs_n sd_ras_n sd_cas_n sd_we_n}]
    set_clock_uncertainty -setup 0.750 -from [get_clocks sdram_core] -to [get_clocks sdram_core]
}
