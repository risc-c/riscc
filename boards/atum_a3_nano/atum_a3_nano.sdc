set board_cpu_div 10
set board_memory_div 16
set board_memory_phase 312.1875
set board_sdram_io_capture 1
set board_pixel_div 22
set board_sdram_clk sd_clk
set board_sdram_dq {sd_dq[*]}
set board_sdram_control {sd_addr[*] sd_ba[*] sd_dqm[*] sd_cke sd_cs_n sd_ras_n sd_cas_n sd_we_n}
set board_status_ports {FPGA_UART_TX LED[*]}
set board_i2c_ports {HDMI_I2C_SCL HDMI_I2C_SDA}
source ../../../boards/shared/agilex3.sdc

# TFP410 SLDS145D, section 5.6 / Figure 5-2: single-edge input setup/hold
# budgets are 1.2/1.3 ns. https://www.ti.com/lit/ds/symlink/tfp410.pdf
# CTL_1_MODE=0xbf selects 24-bit, rising-edge capture; CTL_3_MODE retains
# its reset value (DKEN=0). The board drives differential IDCK with ~pix_clk.
# The timing table lists DSEL=0; use those published single-edge budgets
# for this DSEL=1 interface, with 0.2 ns additional data-to-clock board skew
# allowance. This allowance is a design budget, not measured PCB delay.
create_generated_clock -name hdmi_tx_clk \
    -source [get_pins {system|hdmi_pll|pll|out_clk[0]}] \
    -invert [get_ports HDMI_TX_CLK_p]
# Quartus creates the complementary differential pad automatically. It is
# the opposite clock phase, not an independent unconstrained data output.
create_generated_clock -name hdmi_tx_clk_n \
    -source [get_pins {system|hdmi_pll|pll|out_clk[0]}] \
    [get_ports {HDMI_TX_CLK_p(n)}]
set hdmi_data_ports [get_ports {HDMI_TX_D[*] HDMI_TX_HS HDMI_TX_VS HDMI_TX_DE}]
if {[get_collection_size $hdmi_data_ports] != 27} {
    error "Expected 24 RGB and 3 HDMI control outputs"
}
set_output_delay -clock hdmi_tx_clk -max 1.400 $hdmi_data_ports
set_output_delay -clock hdmi_tx_clk -min -1.500 $hdmi_data_ports
