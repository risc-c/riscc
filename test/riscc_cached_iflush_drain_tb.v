// IFLUSH at a line boundary must drain a cold successor refill before clearing.
// IRQ arrives during the drain and must save the post-IFLUSH successor PC.
`timescale 1ns/1ps
`default_nettype none
/* verilator lint_off WIDTH */
module riscc_cached_iflush_drain_tb #(
    parameter integer XLEN = 32,
    parameter integer SRAM_ADDR_BITS = 0,
    parameter SRAM_HEX = ""
);
    localparam integer LINE_BYTES = XLEN == 32 ? 64 : 32;
    localparam integer FLUSH_PC = LINE_BYTES / 2 - 1;
    reg clk = 0, rst = 1, irq = 0;
    always #5 clk = ~clk;
    wire [XLEN-3:0] addr;
    wire [31:0] wdata;
    wire [3:0] mask;
    wire we, cyc, stb;
    reg [31:0] backing [0:255];
    reg pending_q = 0, write_q = 0;
    reg [XLEN-3:0] addr_q = 0;
    reg [31:0] data_q = 0;
    reg [3:0] mask_q = 0;
    integer wait_q = 0;
    wire ack = pending_q && wait_q == 0;
    wire stall = pending_q && wait_q != 0;
    integer cycles = 0, first_fill = 0, refetch = 0, drain = 0;
    integer starts = 0, irqs = 0, flush_commits = 0, successor_commits = 0;
    integer i, lane;

    riscc_cached #(.XLEN(XLEN), .SRAM_ADDR_BITS(SRAM_ADDR_BITS),
                   .SRAM_HEX(SRAM_HEX)) dut (
        .clk(clk), .rst(rst), .irq(irq), .mem_cacheable(),
        .mem_addr(addr), .mem_rdata(backing[addr_q]),
        .mem_wdata(wdata), .mem_wmask(mask), .mem_we(we),
        .mem_cyc(cyc), .mem_stb(stb), .mem_stall(stall), .mem_ack(ack)
    );

    function automatic [15:0] jump(input integer rel);
        jump = 16'ha700 | ((rel & 127) << 1) | ((rel >> 7) & 1);
    endfunction
    task automatic put(input integer pc, input [15:0] ins);
        if (pc[0]) backing[pc >> 1][31:16] = ins;
        else backing[pc >> 1][15:0] = ins;
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1) backing[i] = 32'hc000c000;
        put(0, 16'hb8c0); // LDI r7,192: external result address
        put(1, jump(6));
        put(2, 16'he8f8); // RETI S0
        put(8, 16'hf8f8); // STI
        put(9, jump(FLUSH_PC - 10));
        put(FLUSH_PC, 16'hd8f8);
        put(FLUSH_PC + 1, 16'h9855); // LDI r3,85
        put(FLUSH_PC + 2, 16'h5f01); // native ST r3,[r7]
        put(FLUSH_PC + 3, jump(-1));
        repeat (6) @(negedge clk);
        rst = 0;
    end

    always @(posedge clk) if (!rst) begin
        cycles = cycles + 1;
        if (dut.iflush_req && dut.i_cyc && dut.ib_cyc) begin
            drain = drain + 1;
            irq <= 1;
        end
        if ((dut.iflush_start && (dut.i_cyc || dut.ib_cyc)) ||
            (dut.iflush_req && dut.iflush_ack && dut.cpu.i_pending_q))
            $fatal(1, "IFLUSH reset/ACK preceded instruction drain");
        if (dut.iflush_start) begin
            starts = starts + 1;
            if (drain == 0 || first_fill != LINE_BYTES / 4)
                $fatal(1, "cold successor refill was not fully drained");
        end
        if (dut.cpu.take_irq) begin
            irqs = irqs + 1;
            irq <= 0;
            if (flush_commits != 1 || dut.iflush_req ||
                dut.cpu.x_pc_q != FLUSH_PC + 1 || dut.cpu.x_result != LINE_BYTES)
                $fatal(1, "IRQ did not preserve the post-IFLUSH PC");
        end
        if (dut.cpu.x_finish) begin
            if (dut.cpu.x_pc_q == FLUSH_PC) flush_commits = flush_commits + 1;
            if (dut.cpu.x_pc_q == FLUSH_PC + 1) begin
                successor_commits = successor_commits + 1;
                if (dut.cpu.x_result != 85) $fatal(1, "stale successor");
            end
        end
        if (ack) begin
            if (write_q) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (mask_q[lane])
                        backing[addr_q][lane*8 +: 8] <= data_q[lane*8 +: 8];
            end else if (addr_q >= LINE_BYTES / 4 && addr_q < LINE_BYTES / 2) begin
                if (starts == 0) first_fill = first_fill + 1;
                else refetch = refetch + 1;
            end
        end
        if (cyc && stb && !stall) begin
            pending_q <= 1;
            wait_q <= 7;
            addr_q <= addr;
            write_q <= we;
            data_q <= wdata;
            mask_q <= mask;
        end else if (ack) pending_q <= 0;
        else if (pending_q) wait_q <= wait_q - 1;
        if (pending_q && !cyc) $fatal(1, "backing CYC dropped before ACK");
        if (backing[48][15:0] == 85) begin
            if (starts != 1 || irqs != 1 || flush_commits != 1 ||
                successor_commits != 1 || refetch != LINE_BYTES / 4)
                $fatal(1, "missing or duplicate flush/IRQ/successor/refetch");
            $display("PASS Cached IFLUSH drain XLEN=%0d SRAM=%0d cycles=%0d drain=%0d refill=%0d refetch=%0d",
                     XLEN, SRAM_ADDR_BITS, cycles, drain, first_fill, refetch);
            $finish;
        end
        if (cycles > 10000) $fatal(1, "IFLUSH drain timeout");
    end
endmodule
/* verilator lint_on WIDTH */
`default_nettype wire
