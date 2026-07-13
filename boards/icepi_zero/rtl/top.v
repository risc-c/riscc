`default_nettype none

module top (
    input  wire       clk,
    input  wire       usb_rx,
    input  wire [1:0] button,
    output wire       usb_tx,
    output wire [3:0] gpdi_dp,
    output wire [4:0] led
);
    wire clkp;
    wire clkt;
    wire clk5x;
    wire pll_locked;

    icepi_dvi_pll pll (
        .clk_in(clk),
        .clkp(clkp),
        .clkt(clkt),
        .clk5x(clk5x),
        .locked(pll_locked)
    );

    reg [7:0] rst_ctr = 8'h00;
    wire soc_rst = !rst_ctr[7];

    always @(posedge clk) begin
        if (!pll_locked)
            rst_ctr <= 8'h00;
        else if (!rst_ctr[7])
            rst_ctr <= rst_ctr + 8'd1;
    end

    wire        fb_we;
    wire [12:0] fb_addr;
    wire [1:0]  fb_wmask;
    wire [15:0] fb_wdata;

    icepi_zero_soc #(
        .MEM_HEX("build/icepi_zero/demo.memh"),
        .UART_CLK_DIV(434)
    ) soc (
        .clk(clk),
        .rst(soc_rst),
        .uart_rx(usb_rx),
        .button(button),
        .uart_tx(usb_tx),
        .led(led),
        .fb_we(fb_we),
        .fb_addr(fb_addr),
        .fb_wmask(fb_wmask),
        .fb_wdata(fb_wdata),
        .dbg_fb_writes(),
        .dbg_uart_tx_count(),
        .dbg_uart_rx_count()
    );

    icepi_fb_dvi video (
        .cpu_clk(clk),
        .cpu_we(fb_we),
        .cpu_addr(fb_addr),
        .cpu_wmask(fb_wmask),
        .cpu_wdata(fb_wdata),
        .pix_clk(clkp),
        .shift_clk(clk5x),
        .rst(soc_rst),
        .tmds(gpdi_dp)
    );
endmodule

`default_nettype wire
