set board_cpu_div 10
set board_memory_div 16
set board_memory_phase 312.1875
set board_sdram_io_capture 1
set board_pixel_div 11
set board_sdram_clk sd_clk
set board_sdram_dq {sd_dq[*]}
set board_sdram_control {sd_addr[*] sd_ba[*] sd_dqm[*] sd_cke sd_cs_n sd_ras_n sd_cas_n sd_we_n}
set board_status_ports {FPGA_UART_TX LED[*]}
set board_i2c_ports {HDMI_I2C_SCL HDMI_I2C_SDA}
source ../../../boards/shared/agilex3.sdc
