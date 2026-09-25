// agilex3_sdram.v : Agilex 3 x32 SDRAM geometry, clock forwarding, and input capture.
// Low-speed capture uses the controller's falling-edge sampler. IO_CAPTURE
// adds a rising-edge input I/O register and a core entry register.
// CAPTURE_RETIME gives the I/O-to-fabric path a full capture-clock cycle
// before the phase crossing to clk. All three clocks come from one PLL.
`timescale 1ns/1ps
`default_nettype none
module agilex3_sdram #(
    parameter integer CLK_MHZ = 125,
    parameter integer READ_DELAY = 0,
    parameter integer IO_CAPTURE = 0,
    parameter integer CAPTURE_RETIME = 0,
    parameter integer INIT_CYCLES = CLK_MHZ * 200,
    parameter integer FIFO_BITS = 3
) (
    input wire clk, rst,
    input wire capture_clk, forward_clk,
    input wire [23:0] mem_addr,
    input wire [31:0] mem_wdata,
    input wire [3:0] mem_wmask,
    input wire mem_we, mem_cyc, mem_stb,
    output wire mem_stall, mem_ack,
    output wire [31:0] mem_rdata,
    output wire ready,
    output wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [12:0] sd_addr,
    output wire [1:0] sd_ba,
    output wire [3:0] sd_dqm,
    inout wire [31:0] sd_dq
);
    wire [31:0] dq_out;
    wire dq_oe;
    wire [31:0] captured_dq, controller_rdata;
    generate
        if (IO_CAPTURE != 0) begin : g_io_capture
            (* altera_attribute = "-name FAST_INPUT_REGISTER ON" *)
            reg [31:0] sample_q;
            always @(posedge capture_clk) sample_q <= sd_dq;
            reg [31:0] response_q;
            if (CAPTURE_RETIME != 0) begin : g_retime
                reg [31:0] handoff_q;
                always @(posedge capture_clk) handoff_q <= sample_q;
                always @(posedge clk) response_q <= handoff_q;
            end else begin : g_same_clock
                always @(posedge clk) response_q <= sample_q;
            end
            assign captured_dq = sample_q;
            assign mem_rdata = response_q;
        end else begin : g_raw_capture
            assign captured_dq = sd_dq;
            assign mem_rdata = controller_rdata;
        end
    endgenerate
    wire pin_clk = IO_CAPTURE != 0 ? forward_clk : clk;
    // Forward the selected PLL clock through the dedicated output DDR cell.
`ifndef VERILATOR
    tennm_ph2_ddio_out #(
        .mode("MODE_DDR"),
        .asclr_ena("ASCLR_ENA_NONE"),
        .sclr_ena("SCLR_ENA_NONE")
    ) clock_out (
        .clk(pin_clk),
        .ena(1'b1),
        .areset(1'b1),
        .sreset(1'b0),
        .datainhi(1'b0),
        .datainlo(1'b1),
        .dataout(sd_clk)
    );
`else
    assign sd_clk = ~pin_clk;
`endif
    assign sd_dq = dq_oe ? dq_out : {32{1'bz}};
    // The capture phase and optional handoff stage must match READ_DELAY.
    // The 125 MHz board uses capture at +6 ns, a full-cycle handoff, and
    // READ_DELAY=1: response_q and the read acknowledgement update together.
    riscc_sdram #(
        .DATA_BITS(32),
        .ROW_BITS(13),
        .COL_BITS(9),
        .CLK_MHZ(CLK_MHZ),
        .INIT_CYCLES(INIT_CYCLES),
        .READ_DELAY(READ_DELAY),
        .FIFO_BITS(FIFO_BITS),
        .INPUT_REGISTERED(IO_CAPTURE)
    ) controller (
        .clk(clk),
        .rst(rst),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_we(mem_we),
        .mem_cyc(mem_cyc),
        .mem_stb(mem_stb),
        .mem_stall(mem_stall),
        .mem_ack(mem_ack),
        .mem_rdata(controller_rdata),
        .ready(ready),
        .sd_cke(sd_cke),
        .sd_cs_n(sd_cs_n),
        .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n),
        .sd_addr(sd_addr),
        .sd_ba(sd_ba),
        .sd_dqm(sd_dqm),
        .sd_dq_i(captured_dq),
        .sd_dq_o(dq_out),
        .sd_dq_oe(dq_oe)
    );
endmodule
`default_nettype wire
