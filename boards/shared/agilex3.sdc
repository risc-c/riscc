# CLOCK1_50 feeds one IOPLL with separate CPU and SDRAM output counters.
# The board CPU divider selects its frequency from the 2 GHz VCO.
create_clock -name sys_clk_ref -period 20.000 [get_ports {CLOCK1_50}]
create_generated_clock -name sys_clk \
    -source [get_ports {CLOCK1_50}] \
    -multiply_by 40 -divide_by $board_cpu_div \
    [get_pins {system|memory_pll|pll|out_clk[2]}]

create_clock -name hdmi_clk_ref -period 20.000 [get_ports {CLOCK0_50}]
create_generated_clock -name hdmi_pll_n_cnt_clk \
    -source [get_ports {CLOCK0_50}] -divide_by 3 \
    [get_nodes {system|hdmi_pll|pll~ncntr_reg}]
create_generated_clock -name hdmi_pll_m_cnt_clk \
    -source [get_nodes {system|hdmi_pll|pll~ncntr_reg}] \
    [get_nodes {system|hdmi_pll|pll~mcntr_reg}]
create_generated_clock -name pix_clk \
    -source [get_nodes {system|hdmi_pll|pll~ncntr_reg}] \
    -multiply_by 98 -divide_by $board_pixel_div \
    [get_pins {system|hdmi_pll|pll|out_clk[0]}]

create_generated_clock -name sdram_core -source [get_ports CLOCK1_50] \
    -multiply_by 40 -divide_by $board_memory_div [get_pins {system|memory_pll|pll|out_clk[0]}]
set memory_clocks {sdram_core sdram_clk}
if {$board_sdram_io_capture} {
    create_generated_clock -name sdram_forward -source [get_ports CLOCK1_50] \
        -multiply_by 40 -divide_by $board_memory_div -phase $board_memory_phase \
        [get_pins {system|memory_pll|pll|out_clk[1]}]
    create_generated_clock -name sdram_clk \
        -source [get_pins {system|memory_pll|pll|out_clk[1]}] -invert [get_ports $board_sdram_clk]
    create_generated_clock -name sdram_capture -source [get_ports CLOCK1_50] \
        -multiply_by 40 -divide_by $board_memory_div -phase 270 \
        [get_pins {system|memory_pll|pll|out_clk[3]}]
    lappend memory_clocks sdram_forward sdram_capture
} else {
    create_generated_clock -name sdram_clk \
        -source [get_pins {system|memory_pll|pll|out_clk[0]}] -invert [get_ports $board_sdram_clk]
}
set_false_path -to [get_registers {system|memory_lock_sync[0]}]

# CPU and memory retain clock crossings so their dividers can differ;
# video uses its own PLL. These domains communicate through handshakes and
# dual-clock line buffers.
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk sys_clk_ref}] \
    -group [get_clocks $memory_clocks] \
    -group [get_clocks {pix_clk hdmi_clk_ref hdmi_pll_n_cnt_clk hdmi_pll_m_cnt_clk}]

# Credit sequence bits must arrive within one memory period.
foreach direction {producer consumer} {
    set launch [get_registers [format {system|fabric|crossing|%s_gray_q[*]} $direction]]
    set capture [get_registers [format {system|fabric|crossing|%s_meta_q[*]} $direction]]
    set_max_skew -from $launch -to $capture 4.0
    set_net_delay -from $launch -to $capture -max 4.0
}

derive_clock_uncertainty

# IS42VM32160G-6BLI: tAC <= 5.5 ns. Include 0.3 ns for package and board
# flight time; the minimum models the SDRAM's earliest valid output.
set_input_delay -clock sdram_clk -max 5.800 [get_ports $board_sdram_dq]
set_input_delay -clock sdram_clk -min 1.800 [get_ports $board_sdram_dq]

# CAS=3 launches the first read word two device edges after READ.
# At 125 MHz, the forwarded pin edge is nominally +2.9375 ns, and the
# capture edge is +6 ns. The first sample is at 3*8 + 6 = 30 ns:
# 30 - (2*8 + 2.9375) = 11.0625 ns nominal launch-to-capture time.
# Setup multicycle 2 selects that sample. Keep the default hold edge so
# the next streamed word cannot overwrite it early. A capture-clock
# handoff register and core register align data with READ_DELAY=1's ACK.
if {$board_sdram_io_capture} {
    set read_capture [get_registers {system|memory|g_io_capture.sample_q[*]}]
    if {[get_collection_size $read_capture] != 32} {
        error "Expected 32 SDRAM I/O capture registers"
    }
    set_multicycle_path -setup 2 -from [get_ports $board_sdram_dq] -to $read_capture
}

# Device setup/hold is 1.5/1.0 ns.  Include 0.15 ns output skew margin.
set_output_delay -clock sdram_clk -max 1.650 [get_ports $board_sdram_control]
set_output_delay -clock sdram_clk -min -1.150 [get_ports $board_sdram_control]
set_output_delay -clock sdram_clk -max 1.650 [get_ports $board_sdram_dq]
set_output_delay -clock sdram_clk -min -1.150 [get_ports $board_sdram_dq]

# Manual reset and status outputs are asynchronous to the memory clock.
set_false_path -from [get_ports {KEY[0]}]
set_false_path -from [get_ports {KEY[1]}] -to [get_registers {system|button_meta[1]}]
set_false_path -to [get_registers {system|soc|uart|rx_sync[0]}]
set_false_path -to [get_ports $board_status_ports]

# PLL lock and configuration status may assert reset at any time. Only the
# reset pins of the two-stage synchronizer are asynchronous; its data path
# and the synchronized reset distribution remain timed.
set reset_pins [get_pins {system|cpu_reset_sync[*]|clrn}]
if {[get_collection_size $reset_pins] != 2} {
    error "Expected two CPU reset synchronizer clear pins"
}
set_false_path -to $reset_pins
# Asynchronous reset assertion into the reference-clock synchronizer is
# intentional. Its second stage releases reset only on a reference-clock edge.
set_false_path -from [get_registers {system|cpu_reset_sync[1]}] \
    -to [get_registers {system|control_reset_sync[*]}]
# I2C inputs are asynchronous, sampled by two-stage synchronizers.
set_false_path -to [get_registers {transmitter|writer|scl_sync[0] transmitter|writer|sda_sync[0]}]
# I2C has no receiver clock derived from an FPGA reference. The engine times
# microsecond bit windows and waits for synchronized SCL to rise.
set_false_path -to [get_ports $board_i2c_ports]

# Fitter-only internal routing margin. External I/O budgets remain active
# during fitting as well as final timing analysis.
if {$::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {
    # The fixed HVIO input registers have a long clock-to-core handoff.
    # Keep 1.1 ns of fitting margin for that path at all timing corners.
    set_clock_uncertainty -setup 1.100 -from [get_clocks sdram_capture] -to [get_clocks sdram_capture]
    # Leave routing margin for the 200 MHz CPU.
    set_clock_uncertainty -setup 0.250 -from [get_clocks sys_clk] -to [get_clocks sys_clk]
}
