// DE23-Lite physical interface. Names match Terasic's rev B pin tables.
`default_nettype none
module top (
    input wire CLOCK0_50, CLOCK1_50,
    input wire [1:0] KEY,
    input wire UART_RX,
    output wire UART_TX,
    output wire [9:0] LEDR,
    output wire DRAM_CLK, DRAM_CKE, DRAM_CS_n, DRAM_RAS_n, DRAM_CAS_n, DRAM_WE_n,
    output wire [12:0] DRAM_ADDR,
    output wire [1:0] DRAM_BA,
    output wire [3:0] DRAM_DQM,
    inout wire [31:0] DRAM_DQ,
    output wire HDMI_TX_CLK, HDMI_TX_HS, HDMI_TX_VS, HDMI_TX_DE,
    output wire [23:0] HDMI_TX_D,
    input wire HDMI_TX_INT,
    inout wire I2C_SCL, I2C_SDA,
    output wire HDMI_I2S0, HDMI_MCLK, HDMI_SCLK, HDMI_LRCLK
);
    wire pix_clk, pix_forward_clk, soc_rst, hsync_n, vsync_n;
    wire [3:0] led_raw;
    wire transmitter_ready;
    wire [23:0] rgb;
    wire video_de;
    // 200 MHz CPU, 125 MHz SDRAM, 720p60.
    agilex3_demo_system #(
        .CPU_DIV(10), .VIDEO_PHASE_PS(2449), .VIDEO_PHASE_STEPS(32),
        .VIDEO_SCALE(4)
    ) system (
        .CLOCK0_50(CLOCK0_50), .CLOCK1_50(CLOCK1_50), .KEY(KEY),
        .FPGA_UART_TX(UART_TX), .FPGA_UART_RX(UART_RX), .LED(led_raw),
        .HDMI_TX_HS(hsync_n), .HDMI_TX_VS(vsync_n),
        .HDMI_TX_D(rgb), .HDMI_TX_DE(video_de),
        .pix_clk(pix_clk), .pix_forward_clk(pix_forward_clk),
        .control_rst(soc_rst),
        .sd_clk(DRAM_CLK), .sd_cke(DRAM_CKE), .sd_cs_n(DRAM_CS_n),
        .sd_ras_n(DRAM_RAS_n), .sd_cas_n(DRAM_CAS_n), .sd_we_n(DRAM_WE_n),
        .sd_addr(DRAM_ADDR), .sd_ba(DRAM_BA), .sd_dqm(DRAM_DQM), .sd_dq(DRAM_DQ)
    );
    // Delay the inverted pin clock by 32 VCO taps (2.449 ns) to balance
    // ADV7513 setup/hold across the different clock and data I/O banks.
    assign HDMI_TX_CLK = ~pix_forward_clk;
    // Register all video signals together before the output buffers. The slow
    // HVIO data banks need this stage for ADV7513 setup at the forwarded clock.
    (* altera_attribute = "-name FAST_OUTPUT_REGISTER ON" *) reg [26:0] video_q;
    always @(posedge pix_clk) begin
        video_q <= {~hsync_n, ~vsync_n, video_de, rgb};
    end
    assign {HDMI_TX_HS, HDMI_TX_VS, HDMI_TX_DE, HDMI_TX_D} = video_q;
    // No audio stream: disable audio in the transmitter and hold its inputs low.
    assign {HDMI_I2S0, HDMI_MCLK, HDMI_SCLK, HDMI_LRCLK} = 4'b0000;
    assign LEDR = ~{6'b000000, transmitter_ready, led_raw[2:0]};
    adv7513_init transmitter (
        .clk(CLOCK1_50), .rst(soc_rst), .interrupt_n(HDMI_TX_INT),
        .scl(I2C_SCL), .sda(I2C_SDA), .ready(transmitter_ready)
    );
endmodule
`default_nettype wire
