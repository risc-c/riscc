// Wire-level functional test for the shared 8N1 UART.

`timescale 1ns/1ps
`default_nettype none

module uart_mmio_tb #(
    parameter integer CLK_DIV = 16,
    parameter integer PIPELINE_WRITES = 0
);
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg cpu_sel = 1'b0;
    reg cpu_we = 1'b0;
    reg [3:0] cpu_addr = 4'h0;
    reg [15:0] cpu_wdata = 16'h0;
    wire [15:0] cpu_rdata;
    reg uart_rx = 1'b1;
    wire uart_tx;
    wire irq;
    wire [31:0] dbg_tx_count;
    wire [31:0] dbg_rx_count;

    localparam [3:0] UART_DATA = 4'h8;
    localparam [3:0] UART_STATE = 4'h9;

    always #5 clk = ~clk;

    riscc_uart_mmio #(
        .CLK_DIV(CLK_DIV),
        .DATA_WIDTH(16),
        .PIPELINE_WRITES(PIPELINE_WRITES)
    ) dut (
        .clk(clk), .rst(rst), .cpu_sel(cpu_sel), .cpu_we(cpu_we),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(irq),
        .dbg_tx_count(dbg_tx_count), .dbg_rx_count(dbg_rx_count)
    );

    integer failures = 0;
    integer i;
    integer guard;
    reg [15:0] status;
    reg [7:0] received;
    reg [7:0] values [0:5];
    reg [9:0] tx_frame;

    task automatic fail_check(input [8*120-1:0] message);
        begin
            $display("FAIL div=%0d pipeline=%0d: %0s", CLK_DIV,
                     PIPELINE_WRITES, message);
            failures = failures + 1;
        end
    endtask

    task automatic mmio_write(input [3:0] address, input [15:0] data);
        begin
            @(negedge clk);
            cpu_sel = 1'b1;
            cpu_we = 1'b1;
            cpu_addr = address;
            cpu_wdata = data;
            @(posedge clk);
            @(negedge clk);
            cpu_sel = 1'b0;
            cpu_we = 1'b0;
            cpu_addr = 4'h0;
            if (PIPELINE_WRITES != 0) begin
                // The write pipeline captures the bus transaction first;
                // the UART consumes it on the following edge.
                @(posedge clk);
                #1;
            end
        end
    endtask

    task automatic read_status(output [15:0] value);
        begin
            cpu_sel = 1'b1;
            cpu_we = 1'b0;
            cpu_addr = UART_STATE;
            #1;
            value = cpu_rdata;
            @(posedge clk);
            #1;
            cpu_sel = 1'b0;
            cpu_addr = 4'h0;
        end
    endtask

    task automatic read_data(output [7:0] value);
        begin
            cpu_sel = 1'b1;
            cpu_we = 1'b0;
            cpu_addr = UART_DATA;
            #1;
            value = cpu_rdata[7:0];
            @(posedge clk);
            #1;
            cpu_sel = 1'b0;
            cpu_addr = 4'h0;
        end
    endtask

    task automatic wait_rx_ready;
        begin
            cpu_sel = 1'b1;
            cpu_we = 1'b0;
            cpu_addr = UART_STATE;
            guard = 0;
            while (!cpu_rdata[1] && guard < CLK_DIV * 40) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!cpu_rdata[1])
                fail_check("RX ready timeout");
        end
    endtask

    task automatic send_byte(input [7:0] value);
        integer bit_index;
        begin
            cpu_sel = 1'b0;
            cpu_we = 1'b0;
            cpu_addr = 4'h0;
            @(negedge clk);
            uart_rx = 1'b0;
            repeat (CLK_DIV) @(negedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                repeat (CLK_DIV) @(negedge clk);
            end
            uart_rx = 1'b1;
            repeat (CLK_DIV * 2) @(negedge clk);
        end
    endtask

    task automatic receive_byte(input [7:0] expected);
        begin
            send_byte(expected);
            wait_rx_ready();
            if (!irq)
                fail_check("RX IRQ did not assert for a normal received byte");
            read_status(status);
            if (!status[1] || status[2])
                fail_check("normal RX status did not report ready without overflow");
            read_data(received);
            if (received !== expected)
                fail_check("normal RX byte mismatch");
            read_status(status);
            if (status[1] || status[2] || irq)
                fail_check("RX data read did not clear ready and overflow");
        end
    endtask

    task automatic check_tx(input [7:0] value);
        integer bit_index;
        begin
            tx_frame = {1'b1, value, 1'b0};
            mmio_write(UART_DATA, {8'h00, value});
            if (irq)
                fail_check("TX IRQ remained asserted while transmitter was busy");

            // The first bit is launched after CLK_DIV clocks from the write;
            // sample all ten frame bits at their baud-cell centers.
            repeat (CLK_DIV + CLK_DIV / 2) @(posedge clk);
            #1;
            if (uart_tx !== tx_frame[0])
                fail_check("TX start bit mismatch");
            for (bit_index = 1; bit_index < 10; bit_index = bit_index + 1) begin
                repeat (CLK_DIV) @(posedge clk);
                #1;
                if (uart_tx !== tx_frame[bit_index])
                    fail_check("TX data or stop bit mismatch");
            end
            if (!irq)
                fail_check("TX IRQ did not reassert when transmitter became ready");
        end
    endtask

    initial begin
        values[0] = 8'h00;
        values[1] = 8'h01;
        values[2] = 8'h55;
        values[3] = 8'haa;
        values[4] = 8'h80;
        values[5] = 8'hff;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        read_status(status);
        if (status !== 16'h0001 || irq)
            fail_check("reset state did not report TX ready and no IRQ");

        // Enable RX IRQ and verify each full 8N1 frame, including read-clear.
        mmio_write(UART_STATE, 16'h0001);
        if (irq)
            fail_check("RX IRQ asserted before a byte arrived");
        for (i = 0; i < 6; i = i + 1)
            receive_byte(values[i]);

        // A second unread byte replaces the first and sets the overrun bit.
        send_byte(8'h3c);
        wait_rx_ready();
        send_byte(8'hc3);
        wait_rx_ready();
        read_status(status);
        if (!status[1] || !status[2] || !irq)
            fail_check("RX overrun did not set status and IRQ");
        read_data(received);
        if (received !== 8'hc3)
            fail_check("RX overrun did not retain the newest byte");
        read_status(status);
        if (status[1] || status[2] || irq)
            fail_check("RX read did not clear overrun, ready, and IRQ");

        // Enable TX IRQ, then check the complete start/data/stop waveform.
        mmio_write(UART_STATE, 16'h0002);
        if (!irq)
            fail_check("TX IRQ did not assert while transmitter was ready");
        check_tx(8'ha5);

        if (failures != 0)
            $fatal(1, "UART MMIO regression failed (%0d checks)", failures);
        $display("PASS UART MMIO div=%0d pipeline=%0d rx=%0d tx=%0d",
                 CLK_DIV, PIPELINE_WRITES, dbg_rx_count, dbg_tx_count);
        $finish;
    end
endmodule

`default_nettype wire
