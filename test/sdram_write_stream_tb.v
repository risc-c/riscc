// Delayed controller completions must not serialize successive CPU writes.
`timescale 1ns/1ps
`default_nettype none
module sdram_write_stream_tb #(parameter CPU_HALF = 5, MEMORY_HALF = 3);
    reg cpu_clk = 0, memory_clk = 0, rst = 1;
    always #CPU_HALF cpu_clk = !cpu_clk;
    always #MEMORY_HALF memory_clk = !memory_clk;
    reg [23:0] cpu_addr = 0;
    reg [31:0] cpu_wdata = 0;
    reg [3:0] cpu_wmask = 0;
    reg cpu_we = 0, cpu_cyc = 0, cpu_stb = 0;
    wire cpu_stall, cpu_ack, cpu_ready;
    wire [31:0] cpu_rdata;
    reg video_cyc = 0, video_stb = 0;
    wire video_stall, video_ack;
    wire [31:0] video_rdata;
    wire [23:0] memory_addr;
    wire [31:0] memory_wdata;
    wire [3:0] memory_wmask;
    wire memory_we, memory_cyc, memory_stb;
    reg [39:0] replies = 0;
    reg [31:0] data_pipe [0:39];
    reg [31:0] ram [0:127];
    integer cycles = 0, writes = 0, completed_writes = 0, max_pending = 0;
    reg [39:0] write_replies = 0;
    reg hold_controller = 1;
    wire memory_stall = hold_controller || cycles % 7 == 0;
    // More than two full wraps exercise all three bridge slots and the
    // fabric's five-bit issued/returned grant counters.
    localparam integer STREAM_COUNT = 72;
    reg [23:0] stream_addr [0:STREAM_COUNT-1];
    reg [31:0] stream_data [0:STREAM_COUNT-1];
    reg [3:0] stream_mask [0:STREAM_COUNT-1];
    reg [31:0] stream_expected [0:STREAM_COUNT-1];
    reg [23:0] video_addr = 0;
    reg stream_monitor = 0;
    integer stream_captured = 0, stream_run = 0, stream_max_run = 0;
    integer stream_last_capture_cycle = -100;
    riscc_sdram_fabric dut (
        .cpu_clk(cpu_clk), .cpu_rst(rst), .memory_clk(memory_clk), .memory_rst(rst),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_wmask(cpu_wmask),
        .cpu_we(cpu_we), .cpu_cyc(cpu_cyc), .cpu_stb(cpu_stb),
        .cpu_stall(cpu_stall), .cpu_ack(cpu_ack), .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .video_addr(video_addr), .video_cyc(video_cyc), .video_stb(video_stb),
        .video_stall(video_stall), .video_ack(video_ack), .video_rdata(video_rdata),
        .memory_addr(memory_addr), .memory_wdata(memory_wdata), .memory_wmask(memory_wmask),
        .memory_we(memory_we), .memory_cyc(memory_cyc), .memory_stb(memory_stb),
        .memory_stall(memory_stall), .memory_ack(replies[39]),
        .memory_ready(!rst), .memory_rdata(data_pipe[39])
    );
    always @(posedge memory_clk) begin
        cycles <= cycles + 1;
        replies <= replies << 1;
        write_replies <= write_replies << 1;
        for (integer i = 1; i < 40; i = i + 1) data_pipe[i] <= data_pipe[i-1];
        if (write_replies[39]) completed_writes = completed_writes + 1;
        if (!rst && memory_cyc && memory_stb && !memory_stall) begin
            replies[0] <= 1;
            write_replies[0] <= memory_we;
            data_pipe[0] <= ram[memory_addr[6:0]];
            if (memory_we) begin
                writes = writes + 1;
                if (stream_monitor) begin
                    if (stream_captured >= STREAM_COUNT)
                        $fatal(1, "extra streamed write at capture %0d", stream_captured);
                    if (memory_addr !== stream_addr[stream_captured] ||
                        memory_wdata !== stream_data[stream_captured] ||
                        memory_wmask !== stream_mask[stream_captured])
                        $fatal(1, "stream write %0d mismatch: got addr=%h data=%h mask=%h expected addr=%h data=%h mask=%h",
                               stream_captured, memory_addr, memory_wdata, memory_wmask,
                               stream_addr[stream_captured], stream_data[stream_captured],
                               stream_mask[stream_captured]);
                    if (cycles == stream_last_capture_cycle + 1)
                        stream_run = stream_run + 1;
                    else
                        stream_run = 1;
                    if (stream_run > stream_max_run) stream_max_run = stream_run;
                    stream_last_capture_cycle = cycles;
                    stream_captured = stream_captured + 1;
                end
                for (integer b = 0; b < 4; b = b + 1)
                    if (memory_wmask[b]) ram[memory_addr[6:0]][b*8+:8] <= memory_wdata[b*8+:8];
                if (writes-completed_writes > max_pending) max_pending = writes-completed_writes;
            end else if (completed_writes != writes)
                $fatal(1, "read/video grant bypassed pending writes");
        end
        if (cycles > 3000) $fatal(1, "timeout");
    end
    task access(input bit writing, input [23:0] addr, input [31:0] value, input [3:0] mask);
        begin
            @(negedge cpu_clk);
            cpu_addr = addr; cpu_wdata = value; cpu_wmask = mask;
            cpu_we = writing; cpu_cyc = 1; cpu_stb = 1;
            do @(posedge cpu_clk); while (cpu_stall);
            @(negedge cpu_clk); cpu_stb = 0;
            if (writing && !cpu_ack)
                $fatal(1, "store must acknowledge at capture");
            while (!cpu_ack) @(negedge cpu_clk);
            if (!writing && cpu_rdata !== value) $fatal(1, "read mismatch");
            cpu_cyc = 0;
        end
    endtask
    task stream_stores;
        integer i;
        begin
            @(negedge cpu_clk);
            cpu_we = 1;
            cpu_cyc = 1;
            cpu_stb = 1;
            cpu_addr = stream_addr[0];
            cpu_wdata = stream_data[0];
            cpu_wmask = stream_mask[0];
            for (i = 0; i < STREAM_COUNT; i = i + 1) begin
                // Sample stall before the edge that captures this command.
                // The producer does not wait for physical replies.
                begin : wait_cpu_capture
                    while (1) begin
                        @(posedge cpu_clk);
                        if (!cpu_stall) disable wait_cpu_capture;
                    end
                end
                @(negedge cpu_clk);
                if (!cpu_ack) $fatal(1, "stream store %0d did not acknowledge at capture", i);
                if (i + 1 < STREAM_COUNT) begin
                    cpu_addr = stream_addr[i+1];
                    cpu_wdata = stream_data[i+1];
                    cpu_wmask = stream_mask[i+1];
                end
            end
            cpu_stb = 0;
            cpu_cyc = 0;
        end
    endtask
    initial begin
        for (integer i = 0; i < 128; i = i + 1) ram[i] = 0;
        for (integer i = 0; i < STREAM_COUNT; i = i + 1) begin
            stream_addr[i] = 8 + i;
            stream_data[i] = 32'ha5000000 + i * 32'h01010101;
            case (i % 8)
                0: stream_mask[i] = 4'hf;
                1: stream_mask[i] = 4'h1;
                2: stream_mask[i] = 4'h2;
                3: stream_mask[i] = 4'h4;
                4: stream_mask[i] = 4'h8;
                5: stream_mask[i] = 4'h3;
                6: stream_mask[i] = 4'h6;
                default: stream_mask[i] = 4'h9;
            endcase
            stream_expected[i] = 0;
            for (integer b = 0; b < 4; b = b + 1)
                if (stream_mask[i][b]) stream_expected[i][b*8+:8] = stream_data[i][b*8+:8];
        end
        #31; rst = 0;
        wait(cpu_ready);
        access(1, 0, 32'h12345678, 4'hf);
        access(1, 1, 32'habcdef01, 4'hf);
        access(1, 0, 32'h0000aa00, 4'h2);
        repeat (12) @(negedge cpu_clk);
        if (writes != 0 || !cpu_stall)
            $fatal(1, "three reused command slots must hold three writes");
        @(negedge memory_clk); hold_controller = 0;
        // Video is independent of CPU retirement; wait for controller capture.
        while (dut.crossing.busy_q) @(negedge cpu_clk);
        wait(writes == 3);
        if (max_pending < 2) $fatal(1, "writes still wait for physical completion");
        @(negedge memory_clk); video_cyc = 1; video_stb = 1;
        do @(posedge memory_clk); while (video_stall);
        @(negedge memory_clk); video_stb = 0;
        wait(video_ack);
        if (video_rdata !== 32'h1234aa78) $fatal(1, "video read mismatch");
        @(negedge memory_clk); video_cyc = 0;
        access(0, 0, 32'h1234aa78, 4'hf);
        access(0, 1, 32'habcdef01, 4'hf);

        // Keep the CPU request asserted across captures. The memory-side
        // monitor checks that all queued commands arrive once and in order.
        stream_monitor = 1;
        stream_stores;

        // A video request arriving as the stream drains must wait behind all
        // writes and return the newly written value.
        video_addr = stream_addr[0];
        @(negedge memory_clk); video_cyc = 1; video_stb = 1;
        begin : wait_video_capture
            while (1) begin
                @(posedge memory_clk);
                if (!video_stall) disable wait_video_capture;
            end
        end
        @(negedge memory_clk); video_stb = 0;
        while (!video_ack) @(negedge memory_clk);
        if (video_rdata !== stream_expected[0])
            $fatal(1, "stream video read mismatch: got %h expected %h",
                   video_rdata, stream_expected[0]);
        @(negedge memory_clk); video_cyc = 0;

        wait(stream_captured == STREAM_COUNT);
        if (stream_max_run < 2)
            $fatal(1, "queued stores never captured on consecutive memory clocks (max run=%0d)",
                   stream_max_run);
        for (integer i = 0; i < STREAM_COUNT; i = i + 1)
            access(0, stream_addr[i], stream_expected[i], 4'hf);
        $display("PASS queued writes, %0d-command stream, masks, stalls, video/read ordering: max_pending=%0d max_stream_run=%0d",
                 STREAM_COUNT, max_pending, stream_max_run);
        $finish;
    end
endmodule
`default_nettype wire
