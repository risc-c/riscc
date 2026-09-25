set board_cpu_div 10
set board_memory_div 16
set board_memory_phase 312.1875
set board_sdram_io_capture 1
set board_pixel_div 22
set board_sdram_clk DRAM_CLK
set board_sdram_dq {DRAM_DQ[*]}
set board_sdram_control {DRAM_ADDR[*] DRAM_BA[*] DRAM_DQM[*] DRAM_CKE DRAM_CS_n DRAM_RAS_n DRAM_CAS_n DRAM_WE_n}
set board_status_ports {UART_TX LEDR[*]}
set board_i2c_ports {I2C_SCL I2C_SDA}
source ../../../boards/shared/agilex3.sdc

# ADV7513: tVSU=1.8 ns, tVHLD=1.3 ns (datasheet Rev D, Table 2).
# Reserve 0.2 ns for board/package data-to-clock skew.
create_generated_clock -name hdmi_forward \
    -source [get_nodes {system|hdmi_pll|pll~ncntr_reg}] \
    -multiply_by 98 -divide_by 22 -phase 65.454545 \
    [get_pins {system|hdmi_pll|pll|out_clk[1]}]
create_generated_clock -name hdmi_tx_clk -source [get_pins {system|hdmi_pll|pll|out_clk[1]}] -invert [get_ports HDMI_TX_CLK]
set_output_delay -clock hdmi_tx_clk -max 2.000 [get_ports {HDMI_TX_D[*] HDMI_TX_HS HDMI_TX_VS HDMI_TX_DE}]
set_output_delay -clock hdmi_tx_clk -min -1.500 [get_ports {HDMI_TX_D[*] HDMI_TX_HS HDMI_TX_VS HDMI_TX_DE}]
# External asynchronous interrupt is synchronized before use by the initializer.
set_false_path -to [get_registers {transmitter|interrupt_sync[0]}]
