`timescale 10ns/10ns
`default_nettype none

// Minimal 8N1 UART for the common demo MMIO map.  It intentionally has one
// byte of receive storage and no transmit FIFO; software uses the ready bits.
module riscc_uart_mmio #(
    parameter integer CLK_DIV = 434
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        cpu_sel,
    input  wire        cpu_we,
    input  wire [3:0]  cpu_addr,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,

    input  wire        uart_rx,
    output reg         uart_tx,
    output wire        irq,

    output wire [31:0] dbg_tx_count,
    output wire [31:0] dbg_rx_count
);
    localparam [3:0] UART_TX_W     = 4'h8; // byte 0xfff0
    localparam [3:0] UART_RX_W     = 4'h9; // byte 0xfff2
    localparam [3:0] UART_STATUS_W = 4'ha; // byte 0xfff4
    localparam [3:0] UART_CTRL_W   = 4'hb; // byte 0xfff6
    localparam integer DIV_BITS = $clog2(CLK_DIV + 1);

    function automatic [DIV_BITS-1:0] div_value(input integer value);
        begin
            div_value = value[DIV_BITS-1:0];
        end
    endfunction

    localparam [DIV_BITS-1:0] CLK_DIV_LAST = div_value(CLK_DIV - 1);
    localparam [DIV_BITS-1:0] CLK_DIV_HALF = div_value(CLK_DIV / 2);

    reg [7:0] rx_data;
    reg       rx_ready;
    reg       rx_overflow;
    reg [1:0] irq_en;

    reg [9:0] tx_shift;
    reg [3:0] tx_bits;
    reg [DIV_BITS-1:0] tx_div;
    wire tx_ready = (tx_bits == 4'd0);

    reg [1:0] rx_sync;
    reg [3:0] rx_bits;
    reg [DIV_BITS-1:0] rx_div;
    reg [7:0] rx_shift;
    wire rx_line = rx_sync[1];

`ifdef VERILATOR
    reg [31:0] dbg_tx_count_q;
    reg [31:0] dbg_rx_count_q;
    assign dbg_tx_count = dbg_tx_count_q;
    assign dbg_rx_count = dbg_rx_count_q;
`else
    assign dbg_tx_count = 32'd0;
    assign dbg_rx_count = 32'd0;
`endif

    wire ctrl_write = cpu_we && (cpu_addr == UART_CTRL_W);
    wire tx_write = cpu_we && (cpu_addr == UART_TX_W);
    wire rx_read = cpu_sel && !cpu_we && (cpu_addr == UART_RX_W);

    assign irq = (irq_en[0] && rx_ready) || (irq_en[1] && tx_ready);
    assign cpu_rdata =
        (cpu_addr == UART_RX_W) ? {8'h00, rx_data} :
        (cpu_addr == UART_STATUS_W) ?
            {13'h0000, rx_overflow, rx_ready, tx_ready} :
        (cpu_addr == UART_CTRL_W) ? {14'h0000, irq_en} :
        16'h0000;

    always @(posedge clk) begin
        if (rst) begin
            uart_tx <= 1'b1;
            tx_shift <= 10'h3ff;
            tx_bits <= 4'd0;
            tx_div <= {DIV_BITS{1'b0}};
            rx_sync <= 2'b11;
            rx_bits <= 4'd0;
            rx_div <= {DIV_BITS{1'b0}};
            rx_shift <= 8'h00;
            rx_data <= 8'h00;
            rx_ready <= 1'b0;
            rx_overflow <= 1'b0;
            irq_en <= 2'b00;
`ifdef VERILATOR
            dbg_tx_count_q <= 32'd0;
            dbg_rx_count_q <= 32'd0;
`endif
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};

            if (ctrl_write)
                irq_en <= cpu_wdata[1:0];

            if (rx_read) begin
                rx_ready <= 1'b0;
                rx_overflow <= 1'b0;
            end

            if (tx_write && tx_ready) begin
                tx_shift <= {1'b1, cpu_wdata[7:0], 1'b0};
                tx_bits <= 4'd10;
                tx_div <= {DIV_BITS{1'b0}};
`ifdef VERILATOR
                dbg_tx_count_q <= dbg_tx_count_q + 32'd1;
`endif
            end else if (!tx_ready) begin
                if (tx_div == CLK_DIV_LAST) begin
                    tx_div <= {DIV_BITS{1'b0}};
                    uart_tx <= tx_shift[0];
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_bits <= tx_bits - 4'd1;
                end else begin
                    tx_div <= tx_div + 1'b1;
                end
            end else begin
                uart_tx <= 1'b1;
            end

            if (rx_bits == 4'd0) begin
                rx_div <= {DIV_BITS{1'b0}};
                if (!rx_line) begin
                    rx_bits <= 4'd10;
                    rx_div <= CLK_DIV_HALF;
                end
            end else if (rx_div == CLK_DIV_LAST) begin
                rx_div <= {DIV_BITS{1'b0}};
                if (rx_bits >= 4'd3) begin
                    rx_shift <= {rx_line, rx_shift[7:1]};
                end else if (rx_bits == 4'd2) begin
                    if (rx_ready)
                        rx_overflow <= 1'b1;
                    rx_data <= rx_shift;
                    rx_ready <= 1'b1;
`ifdef VERILATOR
                    dbg_rx_count_q <= dbg_rx_count_q + 32'd1;
`endif
                end
                rx_bits <= rx_bits - 4'd1;
            end else begin
                rx_div <= rx_div + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
