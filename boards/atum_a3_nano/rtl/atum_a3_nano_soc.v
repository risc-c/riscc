`timescale 10ns/10ns
`default_nettype none

module atum_a3_nano_soc #(
    parameter MEM_HEX = "mem/demo.memh",
    parameter integer UART_CLK_DIV = 434
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
    localparam [14:0] FB_BASE_W = 15'h4000; // byte 0x8000
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
    reg [31:0] fb_writes_q;

    wire ram_sel = ~cpu_addr[14];
    wire fb_sel = cpu_addr[14] & ~cpu_addr[13];
    wire led_sel = (cpu_addr == LED_W);
    wire [14:0] fb_cpu_offset = cpu_addr - FB_BASE_W;
    wire [12:0] fb_cpu_addr = fb_cpu_offset[12:0];
    wire fb_in_range = fb_cpu_offset < 15'd4800;
    wire fb_cpu_we = !rst && cpu_we && fb_sel && fb_in_range;
    wire [15:0] uart_rdata;
    wire uart_irq;

    initial begin
        if (MEM_HEX != "")
            $readmemh(MEM_HEX, ram);
    end

    riscc_faster cpu (
        .clk(clk), .rst(rst), .irq(cpu_irq), .mem_addr(cpu_addr),
        .mem_rdata(cpu_rdata), .mem_wdata(cpu_wdata),
        .mem_wmask(cpu_wmask), .mem_we(cpu_we)
    );

    atum_uart_mmio #(.CLK_DIV(UART_CLK_DIV)) uart (
        .clk(clk), .rst(rst), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(uart_rdata), .uart_rx(uart_rx),
        .uart_tx(uart_tx), .irq(uart_irq), .dbg_tx_count(dbg_uart_tx_count),
        .dbg_rx_count(dbg_uart_rx_count)
    );

    assign cpu_irq = uart_irq;
    assign cpu_rdata = (rsel_q == RSEL_RAM) ? ram_rdata_q :
                       (rsel_q == RSEL_FB) ? 16'h0000 : mmio_rdata_q;
    assign led = led_q;
    assign dbg_fb_writes = fb_writes_q;
    assign fb_we = fb_cpu_we;
    assign fb_addr = fb_cpu_addr;
    assign fb_wmask = cpu_wmask;
    assign fb_wdata = cpu_wdata;

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
            fb_writes_q <= 32'd0;
        end else begin
            mmio_rdata_q <= uart_rdata;
            rsel_q <= ram_sel ? RSEL_RAM : (fb_sel ? RSEL_FB : RSEL_MMIO);
            if (cpu_we) begin
                if (fb_cpu_we)
                    fb_writes_q <= fb_writes_q + 32'd1;
                else if (led_sel)
                    led_q <= cpu_wdata[3:0] ^ {2'b00, ~button};
            end
        end
    end
endmodule

`default_nettype wire
