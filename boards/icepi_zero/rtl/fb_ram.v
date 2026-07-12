`default_nettype none

module icepi_fb_ram (
    input  wire        cpu_clk,
    input  wire        cpu_we,
    input  wire [12:0] cpu_addr,
    input  wire [1:0]  cpu_wmask,
    input  wire [15:0] cpu_wdata,

    input  wire        vid_clk,
    input  wire [12:0] vid_addr,
    output reg  [15:0] vid_rdata
);
    (* ram_style = "block" *) reg [15:0] mem [0:4799];

    always @(posedge cpu_clk) begin
        if (cpu_we) begin
            if (cpu_wmask[0])
                mem[cpu_addr][7:0] <= cpu_wdata[7:0];
            if (cpu_wmask[1])
                mem[cpu_addr][15:8] <= cpu_wdata[15:8];
        end
    end

    always @(posedge vid_clk) begin
        vid_rdata <= mem[vid_addr];
    end
endmodule

`default_nettype wire
