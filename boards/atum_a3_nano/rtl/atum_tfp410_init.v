`default_nettype none

// One-time TFP410 setup for the Atum A3 Nano HDMI transmitter.  The Terasic
// HDMI reference writes 0xbf to control register 0x08 through I2C; this
// compact open-drain controller performs the same write after power-up.
module atum_tfp410_init #(
    parameter integer POWERUP_CYCLES = 1000000, // 20 ms at 50 MHz
    parameter integer I2C_HALF_CYCLES = 250     // 5 us phase; ~67 kHz bus rate
) (
    input wire clk,
    input wire rst,
    inout wire scl,
    inout wire sda,
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
    localparam [3:0] ST_DONE = 4'd10;

    reg [20:0] powerup_count;
    reg [8:0] i2c_count;
    reg [3:0] state;
    reg [1:0] byte_index;
    reg [2:0] bit_index;
    reg scl_low;
    reg sda_low;
    reg [7:0] tx_byte;

    // I2C is open drain.  This controller deliberately does not require an
    // ACK so a missing transmitter leaves the SoC and HDMI timing operational.
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    always @* begin
        case (byte_index)
        2'd0: tx_byte = 8'h78; // TFP410 address (0x3c), write
        2'd1: tx_byte = 8'h08; // control register 1
        default: tx_byte = 8'hbf; // 24-bit single-edge input, normal output
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            powerup_count <= 21'd0;
            i2c_count <= 9'd0;
            state <= ST_WAIT;
            byte_index <= 2'd0;
            bit_index <= 3'd7;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            ready <= 1'b0;
        end else if (state == ST_WAIT) begin
            if (powerup_count == POWERUP_CYCLES - 1) begin
                state <= ST_START;
                powerup_count <= powerup_count;
            end else begin
                powerup_count <= powerup_count + 1'b1;
            end
        end else if (i2c_count == I2C_HALF_CYCLES - 1) begin
            i2c_count <= 9'd0;
            case (state)
            ST_START: begin
                // START: SDA falls while SCL is released high.
                sda_low <= 1'b1;
                scl_low <= 1'b0;
                state <= ST_BIT_LOW;
            end
            ST_BIT_LOW: begin
                scl_low <= 1'b1;
                sda_low <= ~tx_byte[bit_index];
                state <= ST_BIT_HIGH;
            end
            ST_BIT_HIGH: begin
                scl_low <= 1'b0;
                state <= ST_BIT_FALL;
            end
            ST_BIT_FALL: begin
                scl_low <= 1'b1;
                if (bit_index == 3'd0) begin
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
                if (byte_index == 2'd2) begin
                    sda_low <= 1'b1;
                    state <= ST_STOP_LOW;
                end else begin
                    byte_index <= byte_index + 1'b1;
                    bit_index <= 3'd7;
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
                state <= ST_DONE;
            end
            default: state <= ST_DONE;
            endcase
        end else begin
            i2c_count <= i2c_count + 1'b1;
        end
    end
endmodule

`default_nettype wire
