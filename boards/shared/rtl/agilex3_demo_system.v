// Shared Terasic demo system; physical pins and transmitter control live in each board top.

`default_nettype none

module agilex3_demo_system #(
    parameter integer CPU_DIV = 10,
    parameter integer VIDEO_PHASE_PS = 0,
    parameter integer VIDEO_PHASE_STEPS = 0,
    parameter integer MEMORY_DIV = 16,
    parameter integer MEMORY_MHZ = 125,
    parameter integer MEMORY_IO_CAPTURE = 1,
    parameter integer MEMORY_READ_DELAY = 1,
    parameter integer MEMORY_PHASE_PS = 6938,
    parameter integer MEMORY_PHASE_STEPS = 111,
    parameter integer VIDEO_SCALE = 6
) (
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
    output wire HDMI_TX_HS,
    output wire HDMI_TX_VS,
    output wire [23:0] HDMI_TX_D,
    output wire HDMI_TX_DE,
    output wire pix_clk, pix_forward_clk,
    output wire control_rst
);
    wire memory_clk, memory_pin_clk, memory_capture_clk, memory_locked;
    wire [23:0] cpu_addr, video_addr, memory_addr;
    wire [31:0] cpu_wdata, cpu_rdata, video_rdata, memory_wdata, memory_rdata;
    wire [3:0] cpu_wmask, memory_wmask;
    wire cpu_we, cpu_cyc, cpu_stb, cpu_stall, cpu_ack;
    wire video_cyc, video_stb, video_stall, video_ack;
    wire memory_we, memory_cyc, memory_stb, memory_stall, memory_ack, memory_ready;

    wire sys_clk;
    wire pix_pll_locked;
    agilex3_video_pll #(
        .PIXEL_DIV(VIDEO_SCALE == 4 ? 22 : 11),
        .FORWARD_PHASE_PS(VIDEO_PHASE_PS),
        .FORWARD_PHASE_STEPS(VIDEO_PHASE_STEPS)
    ) hdmi_pll (
        .refclk(CLOCK0_50),
        .outclk(pix_clk),
        .forward_clk(pix_forward_clk),
        .locked(pix_pll_locked),
        .rst(1'b0)
    );

    // Required on Agilex 3: the configuration reset-release endpoint holds
    // user logic until the device initialization sequence is complete. Its
    // output is active low, matching Terasic's HDMI reference design.
    wire ninit_done;
    wire configuration_ready = ~ninit_done;
    agilex3_reset_release config_reset_release (.ninit_done(ninit_done));

    // These status signals are asynchronous to sys_clk. Synchronize them
    // before allowing the reset counter to release the SoC. The long count
    // additionally debounces PLL lock and the push button.
    (* ASYNC_REG = "TRUE" *) reg [1:0] configuration_ready_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pix_pll_lock_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] memory_lock_sync;
    reg [17:0] reset_count;
    always @(posedge sys_clk) begin
        memory_lock_sync <= {memory_lock_sync[0], memory_locked};
        configuration_ready_sync <=
            {configuration_ready_sync[0], configuration_ready};
        pix_pll_lock_sync <= {pix_pll_lock_sync[0], pix_pll_locked};
        if (!configuration_ready_sync[1] || !pix_pll_lock_sync[1] ||
            !memory_lock_sync[1] || !KEY[0])
            reset_count <= 18'd0;
        else if (!reset_count[17])
            reset_count <= reset_count + 1'b1;
    end
    wire reset_request = !reset_count[17] || !configuration_ready ||
        !memory_locked || !pix_pll_locked || !KEY[0];
    (* ASYNC_REG = "TRUE" *) reg [1:0] cpu_reset_sync = 2'b11;
    always @(posedge sys_clk or posedge reset_request) begin
        if (reset_request)
            cpu_reset_sync <= 2'b11;
        else
            cpu_reset_sync <= {cpu_reset_sync[0], 1'b0};
    end
    wire soc_rst = cpu_reset_sync[1];
    (* ASYNC_REG = "TRUE" *) reg [1:0] control_reset_sync = 2'b11;
    always @(posedge CLOCK1_50 or posedge soc_rst) begin
        if (soc_rst) control_reset_sync <= 2'b11;
        else control_reset_sync <= {control_reset_sync[0], 1'b0};
    end
    assign control_rst = control_reset_sync[1];

    // Buttons are asynchronous board inputs, including when read by firmware.
    (* ASYNC_REG = "TRUE" *) reg [1:0] button_meta, button_sync;
    always @(posedge sys_clk) begin
        if (soc_rst) begin
            button_meta <= 2'b11;
            button_sync <= 2'b11;
        end else begin
            button_meta <= KEY;
            button_sync <= button_meta;
        end
    end

    // Assert reset immediately, then deassert it through two flops in the
    // pixel domain. This avoids releasing the HDMI logic near a pixel edge.
    (* ASYNC_REG = "TRUE" *) reg [1:0] video_rst_sync;
    always @(posedge pix_clk or posedge soc_rst) begin
        if (soc_rst)
            video_rst_sync <= 2'b11;
        else
            video_rst_sync <= {video_rst_sync[0], 1'b0};
    end


    wire palette_we;
    wire vblank;
    wire [7:0] palette_addr;
    wire [23:0] palette_wdata;
    riscc_demo_soc #(
        .MEM_HEX("mem/demo.memh"),
        .UART_CLK_DIV((2000000000 + CPU_DIV * 57600) / (CPU_DIV * 115200))
    ) soc (
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .clk(sys_clk),
        .rst(soc_rst),
        .video_vblank(vblank),
        .uart_rx(FPGA_UART_RX),
        .button(button_sync),
        .uart_tx(FPGA_UART_TX),
        .led(LED),
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

    riscc_video_parallel #(.SCALE(VIDEO_SCALE)) video (
        .cpu_clk(sys_clk),
        .palette_we(palette_we),
        .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .memory_clk(memory_clk),
        .memory_rst(memory_rst),
        .memory_addr(video_addr),
        .memory_cyc(video_cyc),
        .memory_stb(video_stb),
        .memory_stall(video_stall),
        .memory_ack(video_ack),
        .memory_rdata(video_rdata),
        .memory_ready(memory_ready),
        .underrun(),
        .pix_clk(pix_clk),
        .rst(video_rst_sync[1]),
        .vblank(vblank),
        .hdmi_hs(HDMI_TX_HS),
        .hdmi_vs(HDMI_TX_VS),
        .hdmi_de(HDMI_TX_DE),
        .hdmi_rgb(HDMI_TX_D)
    );

    (* ASYNC_REG = "TRUE" *) reg [1:0] memory_reset_sync = 2'b11;
    always @(posedge memory_clk or posedge soc_rst) begin
        if (soc_rst) memory_reset_sync <= 2'b11;
        else memory_reset_sync <= {memory_reset_sync[0], 1'b0};
    end
    wire memory_rst = memory_reset_sync[1];

    riscc_sdram_fabric fabric (
        .cpu_clk(sys_clk),
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

    agilex3_sdram_pll #(
        .CPU_DIV(CPU_DIV), .MEMORY_DIV(MEMORY_DIV),
        .FORWARD_PHASE_PS(MEMORY_PHASE_PS),
        .FORWARD_PHASE_STEPS(MEMORY_PHASE_STEPS)
    ) memory_pll (
        .refclk(CLOCK1_50),
        .rst(!configuration_ready),
        .outclk(memory_clk),
        .forward_clk(memory_pin_clk),
        .capture_clk(memory_capture_clk),
        .cpu_outclk(sys_clk),
        .locked(memory_locked)
    );
    agilex3_sdram #(
        .CLK_MHZ(MEMORY_MHZ),
        .READ_DELAY(MEMORY_READ_DELAY),
        .IO_CAPTURE(MEMORY_IO_CAPTURE),
        .CAPTURE_RETIME(1)
    ) memory (
        .clk(memory_clk),
        .rst(memory_rst),
        .capture_clk(memory_capture_clk),
        .forward_clk(memory_pin_clk),
        .mem_addr(memory_addr),
        .mem_wdata(memory_wdata),
        .mem_wmask(memory_wmask),
        .mem_we(memory_we),
        .mem_cyc(memory_cyc),
        .mem_stb(memory_stb),
        .mem_stall(memory_stall),
        .mem_ack(memory_ack),
        .mem_rdata(memory_rdata),
        .ready(memory_ready),
        .sd_clk(sd_clk),
        .sd_cke(sd_cke),
        .sd_cs_n(sd_cs_n),
        .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n),
        .sd_addr(sd_addr),
        .sd_ba(sd_ba),
        .sd_dqm(sd_dqm),
        .sd_dq(sd_dq)
    );
endmodule

`default_nettype wire
