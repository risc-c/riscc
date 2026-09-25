// Physical top for Atum A3 Nano.
`default_nettype none
module top (
    output wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [12:0] sd_addr,
    output wire [1:0] sd_ba,
    output wire [3:0] sd_dqm,
    inout wire [31:0] sd_dq,
    input  wire CLOCK0_50,
    input  wire CLOCK1_50,
    input  wire [1:0] KEY,
    output wire FPGA_UART_TX,
    input  wire FPGA_UART_RX,
    output wire [3:0] LED,
    inout  wire HDMI_I2C_SCL,
    inout  wire HDMI_I2C_SDA,
    output wire HDMI_TX_HS,
    output wire HDMI_TX_VS,
    output wire [23:0] HDMI_TX_D,
    output wire HDMI_TX_DE,
    output wire HDMI_TX_CLK_p,
    output wire HDMI_ISEL,
    output wire HDMI_PD_n
);
    wire pix_clk, soc_rst;
    wire [3:0] led_raw;
    wire transmitter_ready;
    agilex3_demo_system system (
        .CLOCK0_50(CLOCK0_50), .CLOCK1_50(CLOCK1_50), .KEY(KEY),
        .FPGA_UART_TX(FPGA_UART_TX), .FPGA_UART_RX(FPGA_UART_RX), .LED(led_raw),
        .HDMI_TX_HS(HDMI_TX_HS), .HDMI_TX_VS(HDMI_TX_VS),
        .HDMI_TX_D(HDMI_TX_D), .HDMI_TX_DE(HDMI_TX_DE),
        .pix_clk(pix_clk), .pix_forward_clk(), .control_rst(soc_rst),
        .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n),
        .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n),
        .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );
    // Data changes on the rising pixel edge; the transmitter samples halfway through.
    assign HDMI_TX_CLK_p = ~pix_clk;
    assign HDMI_ISEL = 1'b1;
    assign HDMI_PD_n = 1'b1;
    assign LED = ~{transmitter_ready, led_raw[2:0]};
    atum_tfp410_init #(
        .POWERUP_CYCLES(1000000), .I2C_HALF_CYCLES(250)
    ) transmitter (
        .clk(CLOCK1_50), .rst(soc_rst),
        .scl(HDMI_I2C_SCL), .sda(HDMI_I2C_SDA), .ready(transmitter_ready)
    );
endmodule
`default_nettype wire
