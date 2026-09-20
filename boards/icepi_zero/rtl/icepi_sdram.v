// Icepi x16 SDRAM pins with dedicated input, output, and tristate registers.
// PIN_PIPELINE accounts for the output stage; rising-edge capture gives
// a full cycle into the controller.
// pin_clk supplies the separately phased device clock.
// READ_DELAY aligns responses with that phase; the 292.5-degree PLL uses 1.
`timescale 1ns/1ps
`default_nettype none
module icepi_sdram #(
    parameter integer CLK_MHZ = 150,
    parameter integer INIT_CYCLES = CLK_MHZ * 200,
    parameter integer REFRESH_CYCLES = (CLK_MHZ * 64000 / 8192) - 32,
    parameter integer READ_DELAY = 0,
    parameter integer FIFO_BITS = 3
) (
    input wire clk, rst,
    input wire pin_clk,
    input wire [22:0] mem_addr,
    input wire [31:0] mem_wdata,
    input wire [3:0] mem_wmask,
    input wire mem_we, mem_cyc, mem_stb,
    output wire mem_stall, mem_ack,
    output wire [31:0] mem_rdata,
    output wire ready,
    output wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output wire [12:0] sd_addr,
    output wire [1:0] sd_ba,
    output wire [1:0] sd_dqm,
    inout wire [15:0] sd_dq
);
    // Keep the I/O-to-core data path unconditional, like the x32 wrapper.
    // Adjacent SDRAM beats form one bus word; mem_ack selects valid pairs.
    reg [15:0] previous_q;
    reg [31:0] response_q;
    always @(posedge clk) begin
        previous_q <= dq_sample;
        response_q <= {dq_sample, previous_q};
    end
    assign mem_rdata = response_q;
    wire [15:0] dq_out;
    wire dq_oe;
    wire [15:0] dq_sample, dq_pin, dq_tristate, dq_input;
    wire [12:0] addr_o;
    wire [1:0] ba_o, dqm_o;
    wire cke_o, cs_o, ras_o, cas_o, we_o;
    wire [21:0] control_o = {addr_o, ba_o, dqm_o, cke_o, cs_o, ras_o, cas_o, we_o};
    wire [21:0] control_pin;
    assign {sd_addr, sd_ba, sd_dqm, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = control_pin;
    genvar pin;
    generate for (pin = 0; pin < 16; pin = pin + 1) begin : g_dq_pin
`ifndef VERILATOR
        TRELLIS_IO #(.DIR("BIDIR")) pad (
            .B(sd_dq[pin]), .I(dq_pin[pin]), .T(dq_tristate[pin]), .O(dq_input[pin])
        );
`else
        assign sd_dq[pin] = dq_tristate[pin] ? 1'bz : dq_pin[pin];
        assign dq_input[pin] = sd_dq[pin];
`endif
    end endgenerate
`ifndef VERILATOR
    ODDRX1F clock_out (
        .SCLK(pin_clk), .RST(1'b0),
        .D0(1'b1), .D1(1'b0), .Q(sd_clk)
    );
    genvar bit_index;
    generate for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin : g_input
        (* syn_useioff = 1, ioff_dir = "input" *)
        TRELLIS_FF #(.CLKMUX("CLK"), .CEMUX("1"), .LSRMUX("LSR"),
                     .REGSET("RESET"), .SRMODE("ASYNC")) capture (
            .DI(dq_input[bit_index]), .CLK(clk), .CE(1'b1), .LSR(1'b0),
            .Q(dq_sample[bit_index])
        );
        (* keep *) OFS1P3DX data_out (
            .D(dq_out[bit_index]), .SCLK(clk), .SP(1'b1), .CD(1'b0),
            .Q(dq_pin[bit_index])
        );
        (* keep *) OFS1P3DX tristate_out (
            .D(!dq_oe), .SCLK(clk), .SP(1'b1), .CD(1'b0),
            .Q(dq_tristate[bit_index])
        );
    end endgenerate
    generate for (pin = 0; pin < 22; pin = pin + 1) begin : g_control
        (* keep *) OFS1P3DX control_out (
            .D(control_o[pin]), .SCLK(clk), .SP(1'b1), .CD(1'b0),
            .Q(control_pin[pin])
        );
    end endgenerate
`else
    reg [15:0] sample_q, data_q;
    reg tristate_q;
    reg [21:0] control_q;
    always @(posedge clk) begin
        data_q <= dq_out;
        tristate_q <= !dq_oe;
        control_q <= control_o;
    end
    assign dq_pin = data_q;
    assign dq_tristate = {16{tristate_q}};
    assign control_pin = control_q;

    always @(posedge clk) sample_q <= dq_input;
    assign dq_sample = sample_q;
    assign sd_clk = pin_clk;
`endif
    riscc_sdram #(
        .DATA_BITS(16), .ROW_BITS(13), .COL_BITS(9),
        .CLK_MHZ(CLK_MHZ), .INIT_CYCLES(INIT_CYCLES), .INPUT_REGISTERED(1), .PIN_PIPELINE(1),
        .REFRESH_CYCLES(REFRESH_CYCLES), .READ_DELAY(READ_DELAY), .FIFO_BITS(FIFO_BITS)
    ) controller (
        .clk(clk), .rst(rst), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask), .mem_we(mem_we), .mem_cyc(mem_cyc),
        .mem_stb(mem_stb), .mem_stall(mem_stall), .mem_ack(mem_ack),
        .mem_rdata(), .ready(ready), .sd_cke(cke_o),
        .sd_cs_n(cs_o), .sd_ras_n(ras_o), .sd_cas_n(cas_o),
        .sd_we_n(we_o), .sd_addr(addr_o), .sd_ba(ba_o), .sd_dqm(dqm_o),
        .sd_dq_i(dq_sample), .sd_dq_o(dq_out), .sd_dq_oe(dq_oe)
    );
endmodule
`default_nettype wire
