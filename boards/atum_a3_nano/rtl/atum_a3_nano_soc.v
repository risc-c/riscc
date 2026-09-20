// atum_a3_nano_soc.v : RISC-C demo SoC for the Atum A3 Nano board.

`timescale 10ns/10ns
`default_nettype none

module atum_a3_nano_soc #(
    parameter MEM_HEX = "mem/demo.memh",
    parameter integer UART_CLK_DIV = 1447,
    parameter integer TIMER_TICK_DIV = 166667
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx,
    input  wire [1:0]  button,
    output wire        uart_tx,
    output wire [3:0]  led,
    output wire        fb_we,
    output wire [13:0] fb_addr,
    output wire [3:0]  fb_wmask,
    output wire [31:0] fb_wdata,
    output wire palette_we,
    output wire [7:0] palette_addr,
    output wire [23:0] palette_wdata,
    output wire [23:0] sdram_addr,
    output wire [31:0] sdram_wdata,
    output wire [3:0]  sdram_wmask,
    output wire sdram_we, sdram_cyc, sdram_stb,
    input wire sdram_stall, sdram_ack,
    input wire [31:0] sdram_rdata,

    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    localparam [3:0] LED_W = 4'hc;  // byte 0xfffffff0
    localparam [1:0] RSEL_RAM      = 2'd0;
    localparam [1:0] RSEL_UNMAPPED = 2'd1;
    localparam [1:0] RSEL_MMIO     = 2'd2;
    localparam [1:0] RSEL_SDRAM    = 2'd3;

    // All bus addresses are 32-bit word indices; masks select byte lanes.
    wire [29:0] mem_addr;
    wire [31:0] mem_rdata;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we, mem_cyc, mem_stb;
    wire mem_stall;
    reg mem_ack_q;
    wire cpu_irq;
    // Unified 16 KiB boot/program/data SRAM, stored as 4096 32-bit words.
    (* ramstyle = "M20K" *) reg [31:0] ram [0:4095];
    reg [31:0] ram_rdata_q;
    reg [31:0] mmio_rdata_q;
    reg [1:0] rsel_q;
    reg [3:0] led_q;
`ifdef VERILATOR
    reg [31:0] fb_writes_q;
`endif

    // SDRAM is a flat cached region; only high MMIO bypasses the cache.
    wire ram_sel = (mem_addr[29:12] == 18'd0);
    wire periph_region = &mem_addr[29:4];
    wire sdram_sel = mem_addr[29:24] == 6'h04;
    reg sdram_pending_q;
    assign mem_stall = sdram_pending_q || (sdram_sel && sdram_stall);
    assign sdram_addr = mem_addr[23:0];
    assign sdram_wdata = mem_wdata;
    assign sdram_wmask = mem_wmask;
    assign sdram_we = mem_we;
    assign sdram_cyc = mem_cyc && (sdram_sel || sdram_pending_q);
    assign sdram_stb = mem_stb && sdram_sel && !sdram_pending_q;
    always @(posedge clk) begin
        if (rst) sdram_pending_q <= 0;
        else begin
            if (mem_accept && sdram_sel) sdram_pending_q <= 1;
            if (sdram_ack) sdram_pending_q <= 0;
        end
    end
    wire mmio_sel = periph_region && mem_addr[3];
    wire mem_accept = mem_cyc && mem_stb && !mem_stall && !rst;
    // A request is accepted once, at the clock edge where CYC/STB are
    // asserted.  The registered ACK and read data are consumed by the CPU
    // on the following cycle.
    wire cpu_write_commit = mem_accept && mem_we;
    // Palette entries are write-only 0x00RRGGBB words at 0xfffff800.
    assign palette_we = cpu_write_commit && (mem_addr[29:8] == 22'h3ffffe) &&
                        (&mem_wmask[2:0]);
    assign palette_addr = mem_addr[7:0];
    assign palette_wdata = mem_wdata[23:0];
    wire mmio_we = cpu_write_commit && mmio_sel && mem_wmask[0];
    wire led_sel = mmio_sel && (mem_addr[3:0] == LED_W[3:0]);
    wire [31:0] uart_rdata;
    wire uart_irq;
    wire [31:0] timer_rdata;
    wire timer_irq;
    wire [31:0] irq_rdata;

    initial begin
        if (MEM_HEX != "")
            $readmemh(MEM_HEX, ram);
    end

    riscc_cached #(
        .XLEN(32),
        // High MMIO is uncached; low SRAM uses the default data cache.
        .RESET_PC(0)
    ) cpu (
        .clk(clk),
        .rst(rst),
        .irq(cpu_irq),
        .mem_addr(mem_addr),
        .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_we(mem_we),
        .mem_cyc(mem_cyc),
        .mem_stb(mem_stb),
        .mem_stall(mem_stall),
        .mem_ack(mem_ack_q || sdram_ack)
    );

    // The inferred RAM and MMIO read mux are synchronous.  ACK is one cycle
    // after request acceptance and may remain asserted for back-to-back
    // accepted requests.
    always @(posedge clk) begin
        if (rst)
            mem_ack_q <= 1'b0;
        else
            mem_ack_q <= mem_accept && !sdram_sel;
    end

    // Observe framebuffer stores for simulation; video reads SDRAM independently.
    wire fb_store = cpu_write_commit && sdram_sel && (sdram_addr < 24'd14400);
    assign fb_we = fb_store;
    assign fb_addr = mem_addr[13:0];
    assign fb_wmask = mem_wmask;
    assign fb_wdata = mem_wdata;

    riscc_uart_mmio #(
        .DATA_WIDTH(32),
        .CLK_DIV(UART_CLK_DIV)
    ) uart (
        .clk(clk),
        .rst(rst),
        .cpu_sel(mmio_sel && mem_accept && mem_wmask[0]),
        .cpu_we(mmio_we),
        .cpu_addr(mem_addr[3:0]),
        .cpu_wdata(mem_wdata),
        .cpu_rdata(uart_rdata),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .irq(uart_irq),
        .dbg_tx_count(dbg_uart_tx_count),
        .dbg_rx_count(dbg_uart_rx_count)
    );

    riscc_timer_mmio #(
        .DATA_WIDTH(32),
        .TICK_DIV(TIMER_TICK_DIV)
    ) timer (
        .clk(clk),
        .rst(rst),
        .cpu_we(mmio_we),
        .cpu_addr(mem_addr[3:0]),
        .cpu_wdata(mem_wdata),
        .cpu_rdata(timer_rdata),
        .irq(timer_irq)
    );

    // Register the IRQ path to meet the Atum CPU clock.
    riscc_irq_ctrl #(
        .DATA_WIDTH(32),
        .REGISTER_IRQ(1)
    ) irq_ctrl (
        .clk(clk),
        .rst(rst),
        .cpu_we(mmio_we),
        .cpu_addr(mem_addr[3:0]),
        .cpu_wdata(mem_wdata),
        .cpu_rdata(irq_rdata),
        .sources({timer_irq, uart_irq}),
        .irq(cpu_irq)
    );

    // Read response, memory writes, and board-visible state.
    assign mem_rdata = (rsel_q == RSEL_RAM) ? ram_rdata_q :
                       (rsel_q == RSEL_UNMAPPED) ? 32'd0 :
                       (rsel_q == RSEL_SDRAM) ? sdram_rdata :
                       mmio_rdata_q;
    assign led = led_q;
`ifdef VERILATOR
    assign dbg_fb_writes = fb_writes_q;
`else
    assign dbg_fb_writes = 32'd0;
`endif

    always @(posedge clk) begin
        if (mem_accept && ram_sel)
            ram_rdata_q <= ram[mem_addr[11:0]];
        if (cpu_write_commit && ram_sel) begin
            if (mem_wmask[0])
                ram[mem_addr[11:0]][7:0] <= mem_wdata[7:0];
            if (mem_wmask[1])
                ram[mem_addr[11:0]][15:8] <= mem_wdata[15:8];
            if (mem_wmask[2])
                ram[mem_addr[11:0]][23:16] <= mem_wdata[23:16];
            if (mem_wmask[3])
                ram[mem_addr[11:0]][31:24] <= mem_wdata[31:24];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            mmio_rdata_q <= 32'h00000000;
            rsel_q <= RSEL_RAM;
            led_q <= 4'h0;
`ifdef VERILATOR
            fb_writes_q <= 32'd0;
`endif
        end else begin
            if (mem_accept) begin
                mmio_rdata_q <= uart_rdata | timer_rdata | irq_rdata;
                rsel_q <= sdram_sel ? RSEL_SDRAM : ram_sel ? RSEL_RAM :
                          mmio_sel ? RSEL_MMIO : RSEL_UNMAPPED;
            end
            if (cpu_write_commit) begin
`ifdef VERILATOR
                if (fb_store)
                    fb_writes_q <= fb_writes_q + 32'd1;
`endif
                if (led_sel && mem_wmask[0])
                    led_q <= mem_wdata[3:0] ^ {2'b00, ~button};
            end
        end
    end
endmodule

`default_nettype wire
