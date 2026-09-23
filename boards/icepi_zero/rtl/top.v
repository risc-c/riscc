// top.v : physical top level for the IcePi Zero board.

`default_nettype none

module top #(
    parameter MEM_HEX = "build/icepi_zero/demo.memh"
) (
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba, sdram_dqm,
    output wire sdram_csn, sdram_cke, sdram_clk,
    output wire sdram_wen, sdram_casn, sdram_rasn,
    inout wire [15:0] sdram_dq,
    input  wire       clk,
    input  wire       usb_rx,
    input  wire [1:0] button,
    output wire       usb_tx,
    output wire [3:0] gpdi_dp,
    output wire [4:0] led
);
    wire cpu_clk, memory_clk, memory_pin_clk, memory_locked;
    wire [23:0] cpu_addr, video_addr, memory_addr;
    wire [31:0] cpu_wdata, cpu_rdata, video_rdata, memory_wdata, memory_rdata;
    wire [3:0] cpu_wmask, memory_wmask;
    wire cpu_we, cpu_cyc, cpu_stb, cpu_stall, cpu_ack;
    wire video_cyc, video_stb, video_stall, video_ack;
    wire memory_we, memory_cyc, memory_stb, memory_stall, memory_ack, memory_ready;

    wire clkp;
    wire clk5x;
    wire pll_locked;

    icepi_dvi_pll pll (
        .clk_in(clk),
        .clkp(clkp),
        .clk5x(clk5x),
        .locked(pll_locked)
    );

    reg [7:0] reset_count_q = 8'h00;
    // Hold the SoC in reset until both clocks are locked and the button is released.
    wire reset_request = !reset_count_q[7] || !pll_locked || !memory_locked || !button[0];
    (* ASYNC_REG = "TRUE" *) reg [1:0] cpu_reset_sync = 2'b11;
    always @(posedge cpu_clk or posedge reset_request) begin
        if (reset_request)
            cpu_reset_sync <= 2'b11;
        else
            cpu_reset_sync <= {cpu_reset_sync[0], 1'b0};
    end
    wire soc_rst = cpu_reset_sync[1];

    always @(posedge clk) begin
        if (!pll_locked || !memory_locked || !button[0])
            reset_count_q <= 8'h00;
        else if (!reset_count_q[7])
            reset_count_q <= reset_count_q + 8'd1;
    end

    wire palette_we;
    wire [7:0] palette_addr;
    wire [23:0] palette_wdata;
    icepi_zero_soc #(
        .MEM_HEX(MEM_HEX),
        .UART_CLK_DIV(579),
        .TIMER_TICK_DIV(66667),
        .PIPELINE_MMIO_WRITES(1)
    ) soc (
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .clk(cpu_clk),
`ifdef ICEPI_VIDEO_TEST
        // The fixed-pattern test isolates video from CPU and SDRAM activity.
        .rst(1'b1),
`else
        .rst(soc_rst),
`endif
        .uart_rx(usb_rx),
        .button(button),
        .uart_tx(usb_tx),
        .led(led),
        .fb_we(),
        .fb_addr(),
        .fb_wmask(),
        .fb_wdata(),
        .sdram_addr(cpu_addr),
        .sdram_wdata(cpu_wdata),
        .sdram_wmask(cpu_wmask),
        .sdram_we(cpu_we),
        .sdram_cyc(cpu_cyc),
        .sdram_stb(cpu_stb),
        .sdram_stall(cpu_stall),
        .sdram_ack(cpu_ack),
        .sdram_rdata(cpu_rdata),
        .dbg_fb_writes(),
        .dbg_uart_tx_count(),
        .dbg_uart_rx_count()
    );

    icepi_fb_dvi video (
        .cpu_clk(cpu_clk),
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .memory_clk(memory_clk),
`ifdef ICEPI_VIDEO_TEST
        .memory_rst(1'b1),
`else
        .memory_rst(memory_rst),
`endif
        .memory_addr(video_addr),
        .memory_cyc(video_cyc),
        .memory_stb(video_stb),
        .memory_stall(video_stall),
        .memory_ack(video_ack),
        .memory_rdata(video_rdata),
        .memory_ready(memory_ready),
        .underrun(),
        .pix_clk(clkp),
        .shift_clk(clk5x),
        .rst(video_reset_sync[1]),
        .tmds(gpdi_dp)
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] memory_reset_sync = 2'b11;
    always @(posedge memory_clk or posedge soc_rst) begin
        if (soc_rst)
            memory_reset_sync <= 2'b11;
        else
            memory_reset_sync <= {memory_reset_sync[0], 1'b0};
    end
    wire memory_rst = memory_reset_sync[1];

    riscc_sdram_fabric fabric (
        .cpu_clk(cpu_clk),
        .cpu_rst(soc_rst),
        .memory_clk(memory_clk),
        .memory_rst(memory_rst),
        .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata),
        .cpu_wmask(cpu_wmask),
        .cpu_we(cpu_we),
        .cpu_cyc(cpu_cyc),
        .cpu_stb(cpu_stb),
        .cpu_stall(cpu_stall),
        .cpu_ack(cpu_ack),
        .cpu_rdata(cpu_rdata),
        .cpu_ready(),
        .video_addr(video_addr),
        .video_cyc(video_cyc),
        .video_stb(video_stb),
        .video_stall(video_stall),
        .video_ack(video_ack),
        .video_rdata(video_rdata),
        .memory_addr(memory_addr),
        .memory_wdata(memory_wdata),
        .memory_wmask(memory_wmask),
        .memory_we(memory_we),
        .memory_cyc(memory_cyc),
        .memory_stb(memory_stb),
        .memory_stall(memory_stall),
        .memory_ack(memory_ack),
        .memory_rdata(memory_rdata),
        .memory_ready(memory_ready)
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] video_reset_sync = 2'b11;
    always @(posedge clkp or posedge soc_rst) begin
        if (soc_rst)
            video_reset_sync <= 2'b11;
        else
            video_reset_sync <= {video_reset_sync[0], 1'b0};
    end
    icepi_sdram_pll memory_pll (
        .refclk(clk),
        .rst(1'b0),
        .outclk(memory_clk),
        .pinclk(memory_pin_clk),
        .cpu_clk(cpu_clk),
        .locked(memory_locked)
    );
    icepi_sdram #(
        .CLK_MHZ(167),
        .READ_DELAY(1)
    ) memory (
        .clk(memory_clk),
        .pin_clk(memory_pin_clk),
`ifdef ICEPI_VIDEO_TEST
        .rst(1'b1),
`else
        .rst(memory_rst),
`endif
        .mem_addr(memory_addr[22:0]),
        .mem_wdata(memory_wdata),
        .mem_wmask(memory_wmask),
        .mem_we(memory_we),
        .mem_cyc(memory_cyc),
        .mem_stb(memory_stb),
        .mem_stall(memory_stall),
        .mem_ack(memory_ack),
        .mem_rdata(memory_rdata),
        .ready(memory_ready),
        .sd_clk(sdram_clk),
        .sd_cke(sdram_cke),
        .sd_cs_n(sdram_csn),
        .sd_ras_n(sdram_rasn),
        .sd_cas_n(sdram_casn),
        .sd_we_n(sdram_wen),
        .sd_addr(sdram_a),
        .sd_ba(sdram_ba),
        .sd_dqm(sdram_dqm),
        .sd_dq(sdram_dq)
    );
endmodule

`default_nettype wire
