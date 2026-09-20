`timescale 1ns/1ps
module sdram_scanout_tb;
    reg memory_clk=0, pix_clk=0;
    always #3 memory_clk=~memory_clk;
    always #7 pix_clk=~pix_clk;
    reg memory_rst=1, rst=1, ready=0;
    wire [23:0] addr;
    wire cyc,stb;
    reg ack=0;
    reg [31:0] data=0;
    reg visible=0,line_start=0;
    reg [8:0] x=0;
    reg [7:0] y=0;
    wire [7:0] pixel;
    wire valid,underrun;
    localparam integer QUEUE_DEPTH = 32;
    integer reads=0, accepted=0, max_pending=0, pipelined=0;
    integer cycle_count=0, queue_head=0, queue_tail=0, queue_count=0;
    integer queue_due [0:QUEUE_DEPTH-1];
    reg [23:0] queue_addr [0:QUEUE_DEPTH-1];
    integer lane;
    reg [31:0] random_q=32'h12345678;
    wire queue_pop = queue_count != 0 && queue_due[queue_head] <= cycle_count;
    wire stall = queue_count >= QUEUE_DEPTH-1 || random_q[0];
    riscc_sdram_scanout dut (
        .memory_clk(memory_clk),.memory_rst(memory_rst),.memory_ready(ready),
        .memory_addr(addr),.memory_cyc(cyc),.memory_stb(stb),.memory_stall(stall),
        .memory_ack(ack),.memory_rdata(data),.pix_clk(pix_clk),.rst(rst),
        .visible(visible),.line_start(line_start),.source_x(x),.source_y(y),
        .pixel(pixel),.pixel_valid(valid),.underrun(underrun)
    );
    // Distinct rows, word positions and lanes detect addressing and alignment errors.
    function [7:0] pattern(input integer row, input integer column);
        // Include values above the old four-bit range so lane and palette
        // index mistakes cannot pass while testing the indexed framebuffer.
        pattern=(row*13 + column*3 + column/4) & 255;
    endfunction
    always @(posedge memory_clk) begin
        ack<=0;
        random_q <= {random_q[30:0], random_q[31]^random_q[21]^random_q[1]^random_q[0]};
        if (memory_rst) begin
            cycle_count=0; queue_head=0; queue_tail=0; queue_count=0;
            reads=0; accepted=0; max_pending=0; pipelined=0;
        end
        else begin
            cycle_count = cycle_count + 1;
            if (queue_pop) begin
                for(lane=0;lane<8;lane=lane+1)
                    data[lane*8+:8]<=pattern(queue_addr[queue_head]/80,
                                              (queue_addr[queue_head]%80)*4+lane);
                ack<=1; reads=reads+1;
                queue_head=(queue_head+1)%QUEUE_DEPTH;
            end
            if(stb && !stall) begin
                if(!cyc) $fatal(1,"stb without cyc");
                queue_addr[queue_tail] <= addr;
                queue_due[queue_tail] <= cycle_count + 2 + random_q[4:2];
                queue_tail=(queue_tail+1)%QUEUE_DEPTH;
                accepted=accepted+1;
                if (queue_count != 0) pipelined=pipelined+1;
            end
            case ({stb && !stall, queue_pop})
                2'b10: queue_count=queue_count+1;
                2'b01: queue_count=queue_count-1;
                default: ;
            endcase
            if (queue_count > max_pending) max_pending=queue_count;
        end
    end
    integer frame,row,rep,col;
    task pixel_cycle(input integer px,input integer py,input integer first,input integer expected_valid);
        begin
            @(negedge pix_clk); x=px; y=py; visible=1; line_start=first;
            @(posedge pix_clk); #1;
            if(valid!==expected_valid[0]) $fatal(1,"valid mismatch y=%0d x=%0d",py,px);
            if(expected_valid && pixel!==pattern(py,px))
                $fatal(1,"pixel mismatch y=%0d x=%0d got=%h expected=%h",py,px,pixel,pattern(py,px));
            if(!expected_valid && pixel!==0) $fatal(1,"underrun must blank");
        end
    endtask
    initial begin
        #101; @(negedge pix_clk); rst=0; memory_rst=0;
        // No initialized SDRAM: the whole first source row must stay blank.
        for(col=0;col<320;col=col+1) pixel_cycle(col,0,col==0,0);
        if(!underrun) $fatal(1,"missing underrun status");
        @(negedge pix_clk); visible=0;line_start=0;ready=1;
        repeat(1000) @(posedge pix_clk);
        // Reset both domains and allow initial row prefetch before display.
        @(negedge pix_clk); rst=1; memory_rst=1;
        repeat(10) @(posedge pix_clk);
        @(negedge pix_clk); rst=0; memory_rst=0;
        repeat(1000) @(posedge pix_clk);
        for(frame=0;frame<3;frame=frame+1) begin
            for(row=0;row<180;row=row+1) begin
                for(rep=0;rep<2;rep=rep+1) begin
                    for(col=0;col<320;col=col+1)
                        pixel_cycle(col,row,rep==0 && col==0,1);
                    @(negedge pix_clk);visible=0;line_start=0;
                    repeat(10) @(posedge pix_clk);
                end
            end
            repeat(1000) @(posedge pix_clk);
        end
        if(underrun) $fatal(1,"unexpected underrun after prefetch");
        if(max_pending < 2 || pipelined == 0)
            $fatal(1,"scanout did not pipeline sequential reads (max_pending=%0d pipelined=%0d)",
                   max_pending,pipelined);
        $display("PASS scanout: three frames, repeated rows, wrap, queued stalls, startup underrun (%0d reads, max %0d outstanding)",reads,max_pending);
        $finish;
    end
    initial begin #20000000; $fatal(1,"timeout");end
endmodule
