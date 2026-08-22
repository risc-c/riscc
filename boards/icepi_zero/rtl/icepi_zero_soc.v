// icepi_zero_soc.v : RISC-C demo SoC for the IcePi Zero board.

`timescale 10ns/10ns
`default_nettype none

module icepi_zero_soc #(
    parameter MEM_HEX = "build/icepi_zero/demo.memh",
    parameter integer UART_CLK_DIV = 434,
    parameter integer TIMER_TICK_DIV = 50000,
    parameter integer PIPELINE_MMIO_WRITES = 0,
    parameter integer PIPELINE_FB_WRITES = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx,
    input  wire [1:0]  button,

    output wire        uart_tx,
    output wire [4:0]  led,
    output wire        fb_we,
    output wire [13:0] fb_addr,
    output wire [1:0]  fb_wmask,
    output wire [15:0] fb_wdata,

    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    localparam [14:0] LED_ADDR = 15'h7ffc; // byte 0xfff8
    localparam [1:0] READ_RAM  = 2'd0;
    localparam [1:0] READ_FB   = 2'd1;
    localparam [1:0] READ_MMIO = 2'd2;

    // CPU memory interface and registered read response.
    wire [14:0] cpu_addr;
    wire [15:0] cpu_rdata;
    wire [15:0] cpu_wdata;
    wire [1:0]  cpu_wmask;
    wire        cpu_we;
    wire        cpu_irq;

    (* ram_style = "block" *) reg [15:0] ram [0:16383];
    reg [15:0] ram_rdata_q;
    reg [15:0] mmio_rdata_q;
    reg [1:0]  read_source_q;
    reg [4:0]  led_q;
`ifdef VERILATOR
    reg [31:0] fb_writes_q;
`endif

    // The high-half framebuffer decode stays deliberately shallow: an
    // acknowledged store reaches its EBR write-enable in the same 50 MHz
    // cycle.
    wire ram_sel = ~cpu_addr[14];
    wire fb_sel;
    wire mmio_sel = &cpu_addr[14:3];
    wire cpu_mem_valid;
    reg  cpu_mem_ready_q;
    wire cpu_write_commit =
        cpu_mem_valid && cpu_mem_ready_q && cpu_we;
    wire mmio_we = cpu_write_commit && mmio_sel;
    wire led_sel = mmio_sel && (cpu_addr[3:0] == LED_ADDR[3:0]);

    wire [15:0] uart_rdata;
    wire uart_irq;
    wire [15:0] timer_rdata;
    wire timer_irq;
    wire [15:0] irq_rdata;

    initial begin
        if (MEM_HEX != "")
            $readmemh(MEM_HEX, ram);
    end

    riscc16_fast cpu (
        .clk(clk),
        .rst(rst),
        .irq(cpu_irq),
        .mem_addr(cpu_addr),
        .mem_rdata(cpu_rdata),
        .mem_wdata(cpu_wdata),
        .mem_wmask(cpu_wmask),
        .mem_we(cpu_we),
        .mem_valid(cpu_mem_valid),
        .mem_ready(cpu_mem_ready_q)
    );

    // The inferred RAM and MMIO read mux are synchronous. Launch the read on
    // the first valid cycle and acknowledge it on the following cycle.
    always @(posedge clk)
        cpu_mem_ready_q <= cpu_mem_valid && !cpu_mem_ready_q;

    wire fb_we_raw;
    wire [14:0] fb_addr_full;
    wire [1:0] fb_wmask_raw;
    wire [15:0] fb_wdata_raw;
    // Board peripherals.
    riscc_framebuffer_mmio #(
        .WORDS(15'd14400),
        .HIGH_HALF_APERTURE(1)
    ) framebuffer_mmio (
        .rst(rst),
        .cpu_we(cpu_write_commit),
        .cpu_addr(cpu_addr),
        .cpu_wmask(cpu_wmask),
        .cpu_wdata(cpu_wdata),
        .fb_sel(fb_sel),
        .fb_we(fb_we_raw),
        .fb_addr(fb_addr_full),
        .fb_wmask(fb_wmask_raw),
        .fb_wdata(fb_wdata_raw)
    );
    generate
        if (PIPELINE_FB_WRITES != 0) begin : g_pipeline_fb_writes
            reg fb_we_q;
            reg [13:0] fb_addr_q;
            reg [1:0] fb_wmask_q;
            reg [15:0] fb_wdata_q;
            always @(posedge clk) begin
                if (rst) begin
                    fb_we_q <= 1'b0;
                    fb_addr_q <= 14'h0000;
                    fb_wmask_q <= 2'b00;
                    fb_wdata_q <= 16'h0000;
                end else begin
                    fb_we_q <= fb_we_raw;
                    fb_addr_q <= fb_addr_full[13:0];
                    fb_wmask_q <= fb_wmask_raw;
                    fb_wdata_q <= fb_wdata_raw;
                end
            end
            assign fb_we = fb_we_q;
            assign fb_addr = fb_addr_q;
            assign fb_wmask = fb_wmask_q;
            assign fb_wdata = fb_wdata_q;
        end else begin : g_direct_fb_writes
            assign fb_we = fb_we_raw;
            assign fb_addr = fb_addr_full[13:0];
            assign fb_wmask = fb_wmask_raw;
            assign fb_wdata = fb_wdata_raw;
        end
    endgenerate

    riscc_uart_mmio #(
        .CLK_DIV(UART_CLK_DIV),
        .PIPELINE_WRITES(PIPELINE_MMIO_WRITES)
    ) uart (
        .clk(clk),
        .rst(rst),
        .cpu_sel(mmio_sel),
        .cpu_we(mmio_we),
        .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata),
        .cpu_rdata(uart_rdata),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .irq(uart_irq),
        .dbg_tx_count(dbg_uart_tx_count),
        .dbg_rx_count(dbg_uart_rx_count)
    );

    riscc_timer_mmio #(
        .TICK_DIV(TIMER_TICK_DIV),
        .PIPELINE_WRITES(PIPELINE_MMIO_WRITES)
    ) timer (
        .clk(clk),
        .rst(rst),
        .cpu_we(mmio_we),
        .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata),
        .cpu_rdata(timer_rdata),
        .irq(timer_irq)
    );

    riscc_irq_ctrl #(
        .PIPELINE_WRITES(PIPELINE_MMIO_WRITES)
    ) irq_ctrl (
        .clk(clk),
        .rst(rst),
        .cpu_we(mmio_we),
        .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata),
        .cpu_rdata(irq_rdata),
        .sources({timer_irq, uart_irq}),
        .irq(cpu_irq)
    );

    // Read response, memory writes, and board-visible state.
    assign cpu_rdata =
        (read_source_q == READ_RAM) ? ram_rdata_q :
        (read_source_q == READ_FB) ? 16'h0000 : mmio_rdata_q;
    assign led = led_q;
`ifdef VERILATOR
    assign dbg_fb_writes = fb_writes_q;
`else
    assign dbg_fb_writes = 32'd0;
`endif

    always @(posedge clk) begin
        ram_rdata_q <= ram[cpu_addr[13:0]];
        if (!rst && cpu_write_commit && ram_sel) begin
            if (cpu_wmask[0])
                ram[cpu_addr[13:0]][7:0] <= cpu_wdata[7:0];
            if (cpu_wmask[1])
                ram[cpu_addr[13:0]][15:8] <= cpu_wdata[15:8];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            mmio_rdata_q <= 16'h0000;
            read_source_q <= READ_RAM;
            led_q <= 5'h00;
`ifdef VERILATOR
            fb_writes_q <= 32'd0;
`endif
        end else begin
            mmio_rdata_q <= uart_rdata | timer_rdata | irq_rdata;
            read_source_q <= ram_sel ? READ_RAM :
                             fb_sel ? READ_FB : READ_MMIO;

            if (cpu_write_commit) begin
`ifdef VERILATOR
                if (fb_sel)
                    fb_writes_q <= fb_writes_q + 32'd1;
                else
`endif
                if (led_sel) begin
                    led_q <= cpu_wdata[4:0] ^ {3'b000, ~button};
                end
            end
        end
    end
endmodule

`default_nettype wire
