`default_nettype none

module top (
    input wire CLOCK0_50,
    input wire CLOCK1_50,
    input wire [1:0] KEY,
    output wire FPGA_UART_TX,
    input wire FPGA_UART_RX,
    output wire [3:0] LED,
    inout wire HDMI_I2C_SCL,
    inout wire HDMI_I2C_SDA,
    output wire HDMI_TX_HS,
    output wire HDMI_TX_VS,
    output wire [23:0] HDMI_TX_D,
    output wire HDMI_TX_DE,
    output wire HDMI_TX_CLK_p,
    output wire HDMI_ISEL,
    output wire HDMI_PD_n
);
    wire sys_clk;
    wire sys_pll_locked;
    atum_sys_pll sys_pll (
        .refclk(CLOCK1_50), .rst(1'b0), .outclk(sys_clk),
        .locked(sys_pll_locked)
    );

    wire pix_clk;
    wire pix_pll_locked;
    atum_hdmi_pll hdmi_pll (
        .refclk(CLOCK0_50),
        .outclk(pix_clk),
        .locked(pix_pll_locked),
        .rst(1'b0)
    );

    // Required on Agilex 3: the configuration reset-release endpoint holds
    // user logic until the device initialization sequence is complete. Its
    // output is active low, matching Terasic's HDMI reference design.
    wire ninit_done;
    wire configuration_ready = ~ninit_done;
    atum_reset_release config_reset_release (.ninit_done(ninit_done));

    // These status signals are asynchronous to sys_clk.  Synchronize them
    // before allowing the reset counter to release the SoC.  The long count
    // additionally debounces PLL lock and the push button.
    (* ASYNC_REG = "TRUE" *) reg [1:0] configuration_ready_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pix_pll_lock_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sys_pll_lock_sync;
    reg [17:0] reset_count;
    always @(posedge sys_clk) begin
        configuration_ready_sync <=
            {configuration_ready_sync[0], configuration_ready};
        pix_pll_lock_sync <= {pix_pll_lock_sync[0], pix_pll_locked};
        sys_pll_lock_sync <= {sys_pll_lock_sync[0], sys_pll_locked};
        if (!configuration_ready_sync[1] || !pix_pll_lock_sync[1] ||
            !sys_pll_lock_sync[1] || !KEY[0])
            reset_count <= 18'd0;
        else if (!reset_count[17])
            reset_count <= reset_count + 1'b1;
    end
    wire soc_rst = !reset_count[17];

    // Assert reset immediately, then deassert it through two flops in the
    // pixel domain.  This avoids releasing the HDMI logic near a pixel edge.
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_rst_sync;
    always @(posedge pix_clk or posedge soc_rst) begin
        if (soc_rst)
            video_rst_sync <= 2'b11;
        else
            video_rst_sync <= {video_rst_sync[0], 1'b0};
    end

    wire [3:0] led_raw;
    wire fb_we;
    wire [14:0] fb_addr;
    wire [1:0] fb_wmask;
    wire [15:0] fb_wdata;
    wire tfp410_ready;

    atum_a3_nano_soc #(
        .MEM_HEX("mem/demo.memh"),
        .UART_CLK_DIV(1953)
    ) soc (
        .clk(sys_clk), .rst(soc_rst), .uart_rx(FPGA_UART_RX),
        .button(KEY), .uart_tx(FPGA_UART_TX), .led(led_raw), .fb_we(fb_we),
        .fb_addr(fb_addr), .fb_wmask(fb_wmask), .fb_wdata(fb_wdata),
        .dbg_fb_writes(), .dbg_uart_tx_count(), .dbg_uart_rx_count()
    );

    atum_fb_hdmi video (
        .cpu_clk(sys_clk), .cpu_we(fb_we), .cpu_addr(fb_addr),
        .cpu_wmask(fb_wmask), .cpu_wdata(fb_wdata), .pix_clk(pix_clk),
        .rst(video_rst_sync[1]), .pix_clk_out(HDMI_TX_CLK_p),
        .hdmi_hs(HDMI_TX_HS), .hdmi_vs(HDMI_TX_VS), .hdmi_de(HDMI_TX_DE),
        .hdmi_rgb(HDMI_TX_D)
    );

    atum_tfp410_init #(
        .POWERUP_CYCLES(4500000), .I2C_HALF_CYCLES(1125)
    ) tfp410_init (
        .clk(sys_clk), .rst(soc_rst), .scl(HDMI_I2C_SCL),
        .sda(HDMI_I2C_SDA), .ready(tfp410_ready)
    );

    assign HDMI_ISEL = 1'b1;
    assign HDMI_PD_n = 1'b1;
    // The physical LEDs are active low.  LED3 indicates transmitter setup.
    assign LED = ~{tfp410_ready, led_raw[2:0]};
endmodule

`default_nettype wire
