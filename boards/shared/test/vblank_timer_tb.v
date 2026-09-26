`timescale 1ns/1ps
`default_nettype none

module vblank_timer_case #(
    parameter integer PIPELINE_WRITES = 0
) (output reg done = 0);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    reg blank = 1;
    reg we = 0;
    reg [15:0] data = 0;
    wire [15:0] ticks;
    wire irq;
    riscc_timer_mmio #(.EXTERNAL_TICK(1), .TICK_DIV(3),
        .PIPELINE_WRITES(PIPELINE_WRITES)) dut (
        .clk(clk), .rst(rst), .video_vblank(blank), .cpu_we(we),
        .cpu_addr(4'ha), .cpu_wdata(data), .cpu_rdata(ticks), .irq(irq));

    task cycles(input integer n);
        repeat (n) begin @(posedge clk); #1; end
    endtask
    task check(input integer expected_ticks, input expected_irq);
        if (ticks !== expected_ticks[15:0] || irq !== expected_irq)
            $fatal(1, "pipeline=%0d ticks=%0d expected=%0d irq=%b expected=%b",
                PIPELINE_WRITES, ticks, expected_ticks, irq, expected_irq);
    endtask
    task arm(input [15:0] delay);
        @(negedge clk); data = delay; we = 1;
        @(negedge clk); we = 0;
        cycles(2);
    endtask
    task frame;
        @(negedge clk); #2; blank = 0;
        cycles(6);
        @(negedge clk); #2; blank = 1;
        cycles(6);
    endtask

    initial begin
        cycles(3);
        @(negedge clk); rst = 0;
        cycles(12); check(0, 0); // Reset during blank is not a frame.
        arm(1);
        @(negedge clk); #2; blank = 0;
        cycles(8); check(0, 0); // Falling edge never ticks.
        @(negedge clk); #2; blank = 1;
        cycles(1); check(0, 0);
        cycles(1); check(0, 0); // No tick before synchronization.
        cycles(1); check(1, 1);
        cycles(20); check(1, 1); // Long blank does not retrigger.
        arm(2); check(1, 0); // Write acknowledges and rearms.
        frame(); check(2, 0);
        frame(); check(3, 1);
        arm(0); check(3, 0);
        frame(); check(4, 0); // Disabled one-shot still counts frames.
        @(negedge clk); dut.ticks_q = 16'hffff;
        frame(); check(0, 0); // Software's frame counter wraps at 16 bits.
        done = 1;
    end
endmodule

module vblank_timer_tb;
    wire direct_done, pipeline_done;
    vblank_timer_case direct_case(direct_done);
    vblank_timer_case #(.PIPELINE_WRITES(1)) pipeline_case(pipeline_done);
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;
    wire [15:0] ticks;
    wire irq;
    reg internal_done = 0;
    integer n;
    riscc_timer_mmio #(.TICK_DIV(4)) internal_timer (
        .clk(clk), .rst(rst), .video_vblank(1'b0), .cpu_we(1'b0),
        .cpu_addr(4'ha), .cpu_wdata(16'd0), .cpu_rdata(ticks), .irq(irq));
    initial begin
        repeat (3) @(negedge clk);
        rst = 0;
        for (n = 1; n <= 80; n = n + 1) begin
            @(posedge clk); #1;
            if (ticks !== n / 4 || irq !== 1'b0)
                $fatal(1, "internal timer changed: clock=%0d ticks=%0d", n, ticks);
        end
        internal_done = 1;
    end
    initial begin
        wait (direct_done && pipeline_done && internal_done);
        $display("PASS: vblank timer direct/pipelined writes, edges, IRQ, wrap, internal divider");
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "vblank timer timeout");
    end
endmodule

`default_nettype wire
