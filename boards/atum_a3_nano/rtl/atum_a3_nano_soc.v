`timescale 10ns/10ns
`default_nettype none

module atum_a3_nano_soc #(
    parameter MEM_HEX = "mem/demo.memh",
    parameter integer UART_CLK_DIV = 434,
    parameter integer TIMER_TICK_DIV = 225000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx,
    input  wire [1:0]  button,
    output wire        uart_tx,
    output wire [3:0]  led,
    output wire        fb_we,
    output wire [12:0] fb_addr,
    output wire [1:0]  fb_wmask,
    output wire [15:0] fb_wdata,
    output wire [31:0] dbg_fb_writes,
    output wire [31:0] dbg_uart_tx_count,
    output wire [31:0] dbg_uart_rx_count
);
    localparam [14:0] LED_W = 15'h7ff4;     // byte 0xffe8
    localparam [1:0] RSEL_RAM = 2'd0;
    localparam [1:0] RSEL_FB = 2'd1;
    localparam [1:0] RSEL_MMIO = 2'd2;

    wire [14:0] cpu_addr;
    wire [15:0] cpu_rdata;
    wire [15:0] cpu_wdata;
    wire [1:0] cpu_wmask;
    wire cpu_we;
    wire cpu_irq;
    (* ramstyle = "M20K" *) reg [15:0] ram [0:16383];
    reg [15:0] ram_rdata_q;
    reg [15:0] mmio_rdata_q;
    reg [1:0] rsel_q;
    reg [3:0] led_q;
`ifdef VERILATOR
    reg [31:0] fb_writes_q;
`endif

    wire ram_sel = ~cpu_addr[14];
    wire mmio_sel = cpu_addr[14] & cpu_addr[13];
    wire mmio_we = cpu_we && mmio_sel;
    wire led_sel = mmio_sel && (cpu_addr[3:0] == LED_W[3:0]);
    wire fb_sel;
    wire [15:0] uart_rdata;
    wire uart_irq;
    wire [15:0] timer_rdata;
    wire timer_irq;
    wire [15:0] irq_rdata;

    initial begin
        if (MEM_HEX != "")
            $readmemh(MEM_HEX, ram);
    end

    riscc_faster cpu (
        .clk(clk), .rst(rst), .irq(cpu_irq), .mem_addr(cpu_addr),
        .mem_rdata(cpu_rdata), .mem_wdata(cpu_wdata),
        .mem_wmask(cpu_wmask), .mem_we(cpu_we)
    );

    riscc_framebuffer_mmio #(
        .CHECK_RANGE(1), .WORDS(4800)
    ) framebuffer_mmio (
        .rst(rst), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wmask(cpu_wmask), .cpu_wdata(cpu_wdata), .fb_sel(fb_sel),
        .fb_we(fb_we), .fb_addr(fb_addr), .fb_wmask(fb_wmask),
        .fb_wdata(fb_wdata)
    );

    riscc_uart_mmio #(.CLK_DIV(UART_CLK_DIV)) uart (
        .clk(clk), .rst(rst), .cpu_sel(mmio_sel), .cpu_we(mmio_we),
        .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata), .cpu_rdata(uart_rdata), .uart_rx(uart_rx),
        .uart_tx(uart_tx), .irq(uart_irq), .dbg_tx_count(dbg_uart_tx_count),
        .dbg_rx_count(dbg_uart_rx_count)
    );

    riscc_timer_mmio #(.TICK_DIV(TIMER_TICK_DIV)) timer (
        .clk(clk), .rst(rst), .cpu_we(mmio_we), .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata), .cpu_rdata(timer_rdata), .irq(timer_irq)
    );

    // Preserve the registered peripheral-to-CPU IRQ boundary used by the
    // 225 MHz Atum build.
    riscc_irq_ctrl #(.REGISTER_IRQ(1)) irq_ctrl (
        .clk(clk), .rst(rst), .cpu_we(mmio_we), .cpu_addr(cpu_addr[3:0]),
        .cpu_wdata(cpu_wdata), .cpu_rdata(irq_rdata),
        .sources({timer_irq, uart_irq}), .irq(cpu_irq)
    );
    assign cpu_rdata = (rsel_q == RSEL_RAM) ? ram_rdata_q :
                       (rsel_q == RSEL_FB) ? 16'h0000 : mmio_rdata_q;
    assign led = led_q;
`ifdef VERILATOR
    assign dbg_fb_writes = fb_writes_q;
`else
    assign dbg_fb_writes = 32'd0;
`endif

    always @(posedge clk) begin
        ram_rdata_q <= ram[cpu_addr[13:0]];
        if (!rst && cpu_we && ram_sel) begin
            if (cpu_wmask[0]) ram[cpu_addr[13:0]][7:0] <= cpu_wdata[7:0];
            if (cpu_wmask[1]) ram[cpu_addr[13:0]][15:8] <= cpu_wdata[15:8];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            mmio_rdata_q <= 16'h0000;
            rsel_q <= RSEL_RAM;
            led_q <= 4'h0;
`ifdef VERILATOR
            fb_writes_q <= 32'd0;
`endif
        end else begin
            mmio_rdata_q <= uart_rdata | timer_rdata | irq_rdata;
            rsel_q <= ram_sel ? RSEL_RAM : (fb_sel ? RSEL_FB : RSEL_MMIO);
            if (cpu_we) begin
`ifdef VERILATOR
                if (fb_we)
                    fb_writes_q <= fb_writes_q + 32'd1;
                else
`endif
                if (led_sel)
                    led_q <= cpu_wdata[3:0] ^ {2'b00, ~button};
            end
        end
    end
endmodule

`default_nettype wire
