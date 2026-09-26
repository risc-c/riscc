// Exercise the real board address decoders independently of CPU execution.
`timescale 1ns/1ps
`default_nettype none

// Backend bus driver replacing only the CPU/cache instance for this test.
module riscc_cached #(
    parameter integer XLEN = 32,
    parameter integer CACHE_ADDR_BITS = XLEN,
    parameter [XLEN-1:0] CACHE_BASE = 0,
    parameter integer SRAM_ADDR_BITS = 0,
    parameter REGISTER_FETCH = 1'b0,
    parameter SRAM_HEX = "",
    parameter RESET_PC = 0
) (
    input wire clk, rst, irq,
    output wire [29:0] mem_addr,
    input wire [31:0] mem_rdata,
    output wire [31:0] mem_wdata,
    output wire [3:0] mem_wmask,
    output wire mem_we, mem_cyc, mem_stb, mem_cacheable,
    input wire mem_stall, mem_ack
);
    assign mem_cacheable = (board_map_tb.addr >> CACHE_ADDR_BITS) ==
                           (CACHE_BASE >> CACHE_ADDR_BITS);
    assign mem_addr = board_map_tb.addr[31:2];
    assign mem_wdata = board_map_tb.wdata;
    assign mem_wmask = board_map_tb.wmask;
    assign mem_we = board_map_tb.we;
    assign mem_cyc = board_map_tb.request;
    assign mem_stb = board_map_tb.request;
endmodule

module board_map_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [31:0] addr = 0, wdata = 0;
    reg [3:0] wmask = 0;
    reg we = 0, request = 0;
    wire fb_we;
    wire [13:0] fb_addr;
    wire [3:0] fb_wmask;
    wire [31:0] fb_wdata;
    wire palette_we;
    wire [7:0] palette_addr;
    wire [23:0] palette_wdata;
    wire [`LED_BITS-1:0] led;
    wire [31:0] fb_count, tx_count;
    wire [23:0] sd_addr;
    wire [31:0] sd_wdata;
    wire [3:0] sd_wmask;
    wire sd_we, sd_cyc, sd_stb;
    reg sd_ack = 0;
    reg [31:0] sd_rdata = 0;
    reg [31:0] backing [int unsigned];
    reg [31:0] value;
    always @(posedge clk) begin
        sd_ack <= sd_cyc && sd_stb && !rst;
        if (sd_cyc && sd_stb && !rst) begin
            value = backing.exists({8'd0, sd_addr}) != 0 ? backing[{8'd0, sd_addr}] : 0;
            if (sd_we) begin
                for (integer lane = 0; lane < 4; lane = lane + 1)
                    if (sd_wmask[lane]) value[lane*8 +: 8] = sd_wdata[lane*8 +: 8];
                backing[{8'd0, sd_addr}] = value;
            end
            sd_rdata <= value;
        end
    end
    reg [31:0] result;
    integer checks = 0;
    `SOC_NAME #(.MEM_HEX(""), .UART_CLK_DIV(8), .TIMER_EXTERNAL_TICK(0), .TIMER_TICK_DIV(10000)) dut (
        .video_vblank(1'b0),
        .clk(clk), .rst(rst), .uart_rx(1'b1), .button(2'b11),
        .uart_tx(), .led(led), .fb_we(fb_we), .fb_addr(fb_addr),
        .fb_wmask(fb_wmask), .fb_wdata(fb_wdata),
        .palette_we(palette_we), .palette_addr(palette_addr),
        .palette_wdata(palette_wdata),
        .dbg_fb_writes(fb_count), .dbg_uart_tx_count(tx_count),
        .dbg_uart_rx_count(),
        .sdram_addr(sd_addr), .sdram_wdata(sd_wdata), .sdram_wmask(sd_wmask),
        .sdram_we(sd_we), .sdram_cyc(sd_cyc), .sdram_stb(sd_stb),
        .sdram_stall(1'b0), .sdram_ack(sd_ack), .sdram_rdata(sd_rdata)
    );

    task automatic access(input [31:0] a, input bit wr,
                          input [3:0] mask, input [31:0] data,
                          input bit expect_fb);
        @(negedge clk);
        addr = a; we = wr; wmask = mask; wdata = data; request = 1;
        #1;
        if (fb_we !== expect_fb)
            $fatal(1, "Framebuffer decode at %h: got %b expected %b", a, fb_we, expect_fb);
        if (palette_we)
            $fatal(1, "Unexpected palette write at %h", a);
        @(posedge clk); #1;
        if (!dut.cpu.mem_ack)
            $fatal(1, "Missing response at %h", a);
        result = dut.cpu.mem_rdata;
        @(negedge clk); request = 0;
        @(posedge clk);
        checks = checks + 1;
    endtask

    task automatic palette_access(input [31:0] a, input [3:0] mask,
                                  input [31:0] data, input [7:0] expected_addr,
                                  input bit expected_write);
        @(negedge clk);
        addr = a; we = 1; wmask = mask; wdata = data; request = 1;
        #1;
        if (fb_we)
            $fatal(1, "Palette access decoded as framebuffer at %h", a);
        if (palette_we !== expected_write)
            $fatal(1, "Palette write at %h: got %b expected %b", a,
                   palette_we, expected_write);
        if (palette_addr !== expected_addr || palette_wdata !== data[23:0])
            $fatal(1, "Palette payload at %h: addr %h data %h", a,
                   palette_addr, palette_wdata);
        if (sd_cyc || sd_stb)
            $fatal(1, "Palette access generated SDRAM traffic at %h", a);
        @(posedge clk); #1;
        if (!dut.cpu.mem_ack)
            $fatal(1, "Missing palette response at %h", a);
        @(negedge clk); request = 0;
        @(posedge clk);
        checks = checks + 1;
    endtask

    task automatic read_check(input [31:0] a, input [3:0] mask,
                              input [31:0] expected);
        access(a, 0, mask, 0, 0);
        if (result !== expected)
            $fatal(1, "Read %h mask %h: got %h expected %h", a, mask, result, expected);
    endtask

    task automatic alias_check(input [31:0] a);
        access(a, 1, 4'hf, 32'hdeadbeef, 0);
        read_check(a, 4'hf, 0);
        if (fb_count != 0 || tx_count != 0 || led != 0)
            $fatal(1, "Unmapped address %h changed a peripheral", a);
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;
        // Backend-only address aliases, SDRAM boundary, and high aliases.
        alias_check(32'h4000);
        alias_check(32'h8000);
        alias_check(32'hfff0);
        alias_check(32'hfff8);
        alias_check(32'h10000);
        alias_check(32'h13ffc);
        alias_check(32'h1fff0);
        alias_check(32'h1fff8);
        alias_check(`SDRAM_END);
        alias_check(32'hffff8000);
        alias_check(32'hfffff07c);
        alias_check(32'h80000000);
        alias_check(32'hffff0000);
        alias_check(32'hffff3ffc);
        alias_check(32'hffff7ffc);
        // Native RC32 MMIO registers are four-byte aligned.  Peripheral
        // writes use the low byte lane; upper-lane-only writes are ignored.
        read_check(32'hffffffe4, 4'hf, 32'h00000001);
        access(32'hffffffe0, 1, 4'hf, 32'h00000041, 0);
        if (tx_count != 1) $fatal(1, "UART data write failed");
        access(32'hffffffe0, 1, 4'hc, 32'h42000000, 0);
        if (tx_count != 1) $fatal(1, "UART upper-lane write changed TX");
        read_check(32'hffffffe4, 4'hf, 32'h00000000);

        // A full-width timer write arms the one-shot.  An upper-lane-only
        // write must leave it idle, so no timer source becomes pending.
        access(32'hffffffe8, 1, 4'hc, 32'h00010000, 0);
        if (dut.timer.count_q !== 16'h0000)
            $fatal(1, "Timer upper-lane write changed count");
        read_check(32'hffffffec, 4'hf, 32'h00000000);
        access(32'hffffffe8, 1, 4'hf, 32'h00001234, 0);
        if (dut.timer.count_q !== 16'h1234)
            $fatal(1, "Timer low-lane write failed");
        read_check(32'hffffffe8, 4'hf, 32'h00000000);

        // The IRQ enable register has the same lane rule.
        access(32'hffffffec, 1, 4'hc, 32'h00020000, 0);
        if (dut.irq_ctrl.enable_q !== 2'b00)
            $fatal(1, "IRQ upper-lane write changed enable state");
        access(32'hffffffec, 1, 4'hf, 32'h00000002, 0);
        if (dut.irq_ctrl.enable_q !== 2'b10)
            $fatal(1, "IRQ low-lane write failed");
        read_check(32'hffffffec, 4'hf, 32'h00000000);

        access(32'hfffffff0, 1, 4'hf, 32'h0000000a, 0);
        if (led != 10) $fatal(1, "LED write failed");
        access(32'hfffffff0, 1, 4'hc, 32'hbeef0000, 0);
        if (led != 10) $fatal(1, "LED upper-lane write changed output");
        read_check(32'hfffffff4, 4'hf, 32'h00000000);
        // The indexed framebuffer is one byte per pixel: the debug tap
        // exposes the complete cached 32-bit word and its four byte lanes.
        access(32'h10000000, 1, 4'hf, 32'h44332211, 1);
        if (fb_addr != 0 || fb_wmask != 4'hf || fb_wdata != 32'h44332211)
            $fatal(1, "Framebuffer first-word translation failed");
        access(32'h10000004, 1, 4'h1, 32'h000000a5, 1);
        if (fb_addr != 1 || fb_wmask != 4'h1 || fb_wdata != 32'h000000a5)
            $fatal(1, "Framebuffer byte-lane translation failed");
        access(32'h10000008, 1, 4'h8, 32'hd7000000, 1);
        if (fb_addr != 2 || fb_wmask != 4'h8 || fb_wdata != 32'hd7000000)
            $fatal(1, "Framebuffer upper-byte translation failed");
        access(32'h1000e0fc, 1, 4'hf, 32'hcafe9876, 1);
        if (fb_addr != 14399 || fb_wmask != 4'hf || fb_wdata != 32'hcafe9876)
            $fatal(1, "Framebuffer end translation failed");
        access(32'h1000e100, 1, 4'hf, 32'hffffffff, 0);
        if (fb_count != 4) $fatal(1, "Unexpected framebuffer writes: %d", fb_count);
        // Palette entries are aligned words at 0xfffff800.  All RGB bytes
        // must be present; the high byte is ignored and palette writes never
        // reach SDRAM.
        palette_access(32'hfffff800, 4'h7, 32'h00112233, 8'h00, 1);
        palette_access(32'hfffffbfc, 4'hf, 32'h00a1b2c3, 8'hff, 1);
        palette_access(32'hfffff804, 4'h3, 32'h00deadbe, 8'h01, 0);
        palette_access(32'hfffff808, 4'hb, 32'h00cafeba, 8'h02, 0);
        read_check(32'hfffff800, 4'hf, 0);
        read_check(32'hfffffbfc, 4'hf, 0);
        read_check(32'hffff8000, 4'h3, 0);
        read_check(32'h10000000, 4'hf, 32'h44332211);
        read_check(32'h10000004, 4'hf, 32'h000000a5);
        read_check(32'h10000008, 4'hf, 32'hd7000000);
        read_check(32'h1000e0fc, 4'hf, 32'hcafe9876);
        read_check(32'hfffffff4, 4'hf, 0);
        access(`SDRAM_END - 4, 1, 4'hf, 32'hfedcba98, 0);
        read_check(`SDRAM_END - 4, 4'hf, 32'hfedcba98);
        read_check(32'h10000000, 4'hf, 32'h44332211);
        $display("PASS RC32 board address map: %0d transactions", checks);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Address-map test timeout");
    end
endmodule
`default_nettype wire
