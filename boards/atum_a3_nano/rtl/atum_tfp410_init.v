// TFP410 single-register setup, using the shared open-drain I2C writer.
`default_nettype none
module atum_tfp410_init #(
    parameter integer POWERUP_CYCLES = 1000000,
    parameter integer I2C_HALF_CYCLES = 250
) (
    input wire clk, rst,
    inout wire scl, sda,
    output reg ready
);
    localparam integer TIMER_BITS = POWERUP_CYCLES > 1 ? $clog2(POWERUP_CYCLES) : 1;
    localparam [TIMER_BITS-1:0] POWERUP_LAST = POWERUP_CYCLES - 1;
    reg [TIMER_BITS-1:0] timer;
    reg started, start;
    wire done;
    riscc_i2c_reg #(.HALF_CYCLES(I2C_HALF_CYCLES)) writer (
        .clk(clk), .rst(rst), .start(start), .read(1'b0), .data(24'h7808bf),
        .scl(scl), .sda(sda), .busy(), .done(done), .nack(), .rdata()
    );
    // Preserve the Atum ready indication: the setup transaction has completed.
    always @(posedge clk) begin
        start <= 0;
        if (rst) begin
            timer <= POWERUP_LAST;
            started <= 0;
            ready <= 0;
        end else if (!started) begin
            if (timer != 0) timer <= timer - 1'b1;
            else begin start <= 1; started <= 1; end
        end else if (done) ready <= 1;
    end
endmodule
`default_nettype wire
