`timescale 1ns/1ps
`default_nettype none

module video_palette_tb;
    reg cpu_clk = 1'b0;
    reg pix_clk = 1'b0;
    always #5 cpu_clk = ~cpu_clk;
    always #7 pix_clk = ~pix_clk;

    reg write_en = 1'b0;
    reg [7:0] write_addr = 8'd0;
    reg [23:0] write_rgb = 24'd0;
    reg [7:0] index = 8'd0;
    wire [23:0] rgb;

    riscc_video_palette dut (
        .cpu_clk(cpu_clk),
        .write_en(write_en),
        .write_addr(write_addr),
        .write_rgb(write_rgb),
        .pix_clk(pix_clk),
        .index(index),
        .rgb(rgb)
    );

    function [23:0] initial_color(input integer entry);
        initial_color = (entry * 24'h01_2345 + 24'h00_5161) & 24'hff_ffff;
    endfunction

    function [23:0] rewrite_color(input integer entry);
        rewrite_color = (entry * 24'h03_17a9 + 24'h55_0001) & 24'hff_ffff;
    endfunction

    task write_entry(input integer entry, input [23:0] color);
        begin
            @(negedge cpu_clk);
            write_addr = entry[7:0];
            write_rgb = color;
            write_en = 1'b1;
            @(posedge cpu_clk);
            #1;
            @(negedge cpu_clk);
            write_en = 1'b0;
        end
    endtask

    task expect_pixel(input integer entry, input [23:0] expected);
        begin
            @(negedge pix_clk);
            index = entry[7:0];
            @(posedge pix_clk);
            #1;
            if (rgb !== expected)
                $fatal(1, "palette read entry %0d: got %h expected %h",
                       entry, rgb, expected);
        end
    endtask

    integer i;
    integer read_i;
    integer write_i;
    initial begin
        // The power-up initialization must provide a deterministic black
        // palette before software has written any entries.
        repeat (2) @(posedge pix_clk);
        for (i = 0; i < 256; i = i + 1)
            expect_pixel(i, 24'h000000);

        // Fill every entry, including the upper half of the address range.
        for (i = 0; i < 256; i = i + 1)
            write_entry(i, initial_color(i));
        for (i = 0; i < 256; i = i + 1)
            expect_pixel(i, initial_color(i));

        // Keep the pixel port active while rewriting a disjoint set of
        // entries.  This checks independent clocks without depending on the
        // undefined result of a same-entry read/write collision.
        fork
            begin
                for (read_i = 0; read_i < 128; read_i = read_i + 1)
                    expect_pixel(128 + read_i, initial_color(128 + read_i));
            end
            begin
                for (write_i = 0; write_i < 128; write_i = write_i + 1)
                    write_entry(write_i, rewrite_color(write_i));
            end
        join
        for (i = 0; i < 128; i = i + 1)
            expect_pixel(i, rewrite_color(i));

        // Disabled writes must leave entries unchanged.
        @(negedge cpu_clk);
        write_en = 1'b0;
        for (i = 0; i < 32; i = i + 1) begin
            write_addr = (i * 37) & 8'hff;
            write_rgb = 24'he1_2345 ^ i;
            @(posedge cpu_clk);
            #1;
        end
        for (i = 0; i < 128; i = i + 1)
            expect_pixel(i, rewrite_color(i));
        for (i = 128; i < 256; i = i + 1)
            expect_pixel(i, initial_color(i));

        $display("PASS video palette: init, all 256 entries, asynchronous active reads, disabled writes");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "video palette test timeout");
    end
endmodule

`default_nettype wire
