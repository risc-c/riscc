// atum_tfp410_init.v : one-shot TFP410 configuration controller.

`default_nettype none

// One-time TFP410 setup for the Atum A3 Nano HDMI transmitter. The Terasic
// HDMI reference writes 0xbf to control register 0x08 through I2C; this
// open-drain controller performs the same write after power-up.
module atum_tfp410_init #(
    parameter integer POWERUP_CYCLES = 1000000, // 20 ms at 50 MHz
    parameter integer I2C_HALF_CYCLES = 250     // 5 us phase; ~67 kHz bus rate
) (
    input  wire clk,
    input  wire rst,
    inout  wire scl,
    inout  wire sda,
    output reg ready
);
    localparam [3:0] ST_WAIT = 4'd0;
    localparam [3:0] ST_START = 4'd1;
    localparam [3:0] ST_BIT_LOW = 4'd2;
    localparam [3:0] ST_BIT_HIGH = 4'd3;
    localparam [3:0] ST_BIT_FALL = 4'd4;
    localparam [3:0] ST_ACK_HIGH = 4'd5;
    localparam [3:0] ST_ACK_LOW = 4'd6;
    localparam [3:0] ST_STOP_LOW = 4'd7;
    localparam [3:0] ST_STOP_HIGH = 4'd8;
    localparam [3:0] ST_STOP_RELEASE = 4'd9;

    localparam integer POWERUP_BITS =
        (POWERUP_CYCLES <= 1) ? 1 : $clog2(POWERUP_CYCLES);
    localparam integer I2C_BITS =
        (I2C_HALF_CYCLES <= 1) ? 1 : $clog2(I2C_HALF_CYCLES);

    localparam integer TIMER_BITS = POWERUP_BITS > I2C_BITS ? POWERUP_BITS : I2C_BITS;
    localparam [TIMER_BITS-1:0] POWERUP_LAST = POWERUP_CYCLES - 1;
    localparam [TIMER_BITS-1:0] I2C_LAST = I2C_HALF_CYCLES - 1;

    // Power-up and I2C phases never overlap, so they share one countdown.
    reg [TIMER_BITS-1:0] timer_q;
    reg [3:0] state;
    // Address/write bit, register 0x08, then control value 0xbf, MSB first.
    localparam [23:0] CONFIG_BITS = 24'h7808bf;
    reg [4:0] bit_index;
    reg scl_low;
    reg sda_low;

    // I2C is open drain. This controller deliberately does not require an
    // ACK so a missing transmitter leaves the SoC and HDMI timing operational.
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    always @(posedge clk) begin
        if (rst) begin
            timer_q <= POWERUP_LAST;
            state <= ST_WAIT;
            bit_index <= 5'd23;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            ready <= 1'b0;
        end else if (!ready) begin
            if (timer_q != 0) begin
                timer_q <= timer_q - 1'b1;
            end else begin
                timer_q <= I2C_LAST;
                case (state)
                    ST_WAIT: state <= ST_START;
                    ST_START: begin
                        // START: SDA falls while SCL is released high.
                        sda_low <= 1'b1;
                        scl_low <= 1'b0;
                        state <= ST_BIT_LOW;
                    end
                    ST_BIT_LOW: begin
                        scl_low <= 1'b1;
                        sda_low <= ~CONFIG_BITS[bit_index];
                        state <= ST_BIT_HIGH;
                    end
                    ST_BIT_HIGH: begin
                        scl_low <= 1'b0;
                        state <= ST_BIT_FALL;
                    end
                    ST_BIT_FALL: begin
                        scl_low <= 1'b1;
                        if (bit_index[2:0] == 3'd0) begin
                            sda_low <= 1'b0;
                            state <= ST_ACK_HIGH;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            state <= ST_BIT_LOW;
                        end
                    end
                    ST_ACK_HIGH: begin
                        // Release SDA for the transmitter's ACK bit.
                        scl_low <= 1'b0;
                        sda_low <= 1'b0;
                        state <= ST_ACK_LOW;
                    end
                    ST_ACK_LOW: begin
                        scl_low <= 1'b1;
                        if (bit_index == 5'd0) begin
                            sda_low <= 1'b1;
                            state <= ST_STOP_LOW;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            state <= ST_BIT_LOW;
                        end
                    end
                    ST_STOP_LOW: begin
                        scl_low <= 1'b0;
                        sda_low <= 1'b1;
                        state <= ST_STOP_HIGH;
                    end
                    ST_STOP_HIGH: begin
                        scl_low <= 1'b0;
                        sda_low <= 1'b1;
                        state <= ST_STOP_RELEASE;
                    end
                    ST_STOP_RELEASE: begin
                        // STOP: SDA rises while SCL is released high.
                        scl_low <= 1'b0;
                        sda_low <= 1'b0;
                        ready <= 1'b1;
                    end
                    default: ready <= 1'b1;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
