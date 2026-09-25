// Single-master, open-drain I2C byte-register access with ACK and stretch checking.
`default_nettype none
module riscc_i2c_reg #(
    parameter integer HALF_CYCLES = 250,
    parameter integer TIMEOUT_CYCLES = 50000
) (
    input wire clk, rst, start, read,
    input wire [23:0] data, // {seven-bit address, 1'b0, register, write value}
    inout wire scl, sda,
    output reg busy, done, nack,
    output reg [7:0] rdata
);
    localparam [4:0] IDLE=0, START=1, START_HOLD=2,
        BIT_SETUP=3, BIT_RISE=4, BIT_FALL=5,
        ACK_SETUP=6, ACK_RISE=7, ACK_SAMPLE=8,
        STOP_SETUP=9, STOP_RISE=10, STOP_RELEASE=11, BUS_FREE=12,
        RESTART_SETUP=13, RESTART_RISE=14, RESTART_HOLD=15,
        READ_SETUP=16, READ_RISE=17, READ_SAMPLE=18,
        NACK_SETUP=19, NACK_RISE=20, NACK_FALL=21,
        RECOVER_RISE=22, RECOVER_FALL=23;
    localparam integer TIMER_BITS = HALF_CYCLES > 1 ? $clog2(HALF_CYCLES) : 1;
    localparam integer TIMEOUT_BITS = TIMEOUT_CYCLES > 1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam [TIMER_BITS-1:0] TIMER_LAST = HALF_CYCLES - 1;
    localparam [TIMEOUT_BITS-1:0] TIMEOUT_LAST = TIMEOUT_CYCLES - 1;
    reg [4:0] state;
    reg [TIMER_BITS-1:0] timer;
    reg [TIMEOUT_BITS-1:0] timeout_count;
    reg [23:0] command;
    reg [4:0] bit_index;
    reg reading, read_address_sent;
    reg scl_low, sda_low;
    (* ASYNC_REG = "TRUE" *) reg [1:0] scl_sync, sda_sync;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
    wire wait_scl = !scl_low && !scl_sync[1];
    always @(posedge clk) begin
        scl_sync <= {scl_sync[0], scl};
        sda_sync <= {sda_sync[0], sda};
        done <= 0;
        if (rst) begin
            state <= IDLE;
            timer <= 0;
            timeout_count <= 0;
            bit_index <= 0;
            reading <= 0;
            read_address_sent <= 0;
            rdata <= 0;
            scl_low <= 0;
            sda_low <= 0;
            busy <= 0;
            done <= 0;
            nack <= 0;
            scl_sync <= 2'b11;
            sda_sync <= 2'b11;
        end else if (state == IDLE) begin
            if (start) begin
                command <= data;
                reading <= read;
                read_address_sent <= 0;
                bit_index <= 23;
                rdata <= 0;
                busy <= 1;
                nack <= 0;
                timer <= TIMER_LAST;
                timeout_count <= 0;
                state <= START;
            end
        end else if (wait_scl || (state == START && !sda_sync[1])) begin
            // A missing pull-up or stuck slave cannot hold the sequencer forever.
            timer <= TIMER_LAST;
            if (timeout_count == TIMEOUT_LAST) begin
                sda_low <= 0;
                nack <= 1;
                timeout_count <= 0;
                if (state == START && scl_sync[1]) begin
                    // A reset can interrupt a slave read while SDA is low.
                    // Nine clocks finish that byte/ACK, then issue STOP.
                    scl_low <= 1;
                    bit_index <= 8;
                    state <= RECOVER_RISE;
                end else begin
                    scl_low <= 0;
                    busy <= 0;
                    done <= 1;
                    state <= IDLE;
                end
            end else timeout_count <= timeout_count + 1'b1;
        end else begin
            timeout_count <= 0;
            if (timer != 0) timer <= timer - 1'b1;
            else begin
                timer <= TIMER_LAST;
                case (state)
                    START: begin sda_low <= 1; state <= START_HOLD; end
                    START_HOLD: begin scl_low <= 1; state <= BIT_SETUP; end
                    BIT_SETUP: begin
                        sda_low <= ~(command[bit_index] ||
                                     (read_address_sent && bit_index == 16));
                        state <= BIT_RISE;
                    end
                    BIT_RISE: begin scl_low <= 0; state <= BIT_FALL; end
                    BIT_FALL: begin
                        scl_low <= 1;
                        if (bit_index[2:0] == 0) state <= ACK_SETUP;
                        else begin
                            bit_index <= bit_index - 1'b1;
                            state <= BIT_SETUP;
                        end
                    end
                    ACK_SETUP: begin sda_low <= 0; state <= ACK_RISE; end
                    ACK_RISE: begin scl_low <= 0; state <= ACK_SAMPLE; end
                    ACK_SAMPLE: begin
                        nack <= nack || sda_sync[1];
                        scl_low <= 1;
                        if (sda_sync[1]) state <= STOP_SETUP;
                        else if (reading && read_address_sent) begin
                            bit_index <= 7;
                            state <= READ_SETUP;
                        end else if (reading && bit_index == 8) state <= RESTART_SETUP;
                        else if (bit_index == 0) state <= STOP_SETUP;
                        else begin
                            bit_index <= bit_index - 1'b1;
                            state <= BIT_SETUP;
                        end
                    end
                    RESTART_SETUP: begin sda_low <= 0; state <= RESTART_RISE; end
                    RESTART_RISE: begin scl_low <= 0; state <= RESTART_HOLD; end
                    RESTART_HOLD: begin
                        sda_low <= 1;
                        bit_index <= 23;
                        read_address_sent <= 1;
                        state <= START_HOLD;
                    end
                    READ_SETUP: begin sda_low <= 0; state <= READ_RISE; end
                    READ_RISE: begin scl_low <= 0; state <= READ_SAMPLE; end
                    READ_SAMPLE: begin
                        rdata <= {rdata[6:0], sda_sync[1]};
                        scl_low <= 1;
                        if (bit_index == 0) state <= NACK_SETUP;
                        else begin bit_index <= bit_index - 1'b1; state <= READ_SETUP; end
                    end
                    NACK_SETUP: begin sda_low <= 0; state <= NACK_RISE; end
                    NACK_RISE: begin scl_low <= 0; state <= NACK_FALL; end
                    NACK_FALL: begin scl_low <= 1; state <= STOP_SETUP; end
                    RECOVER_RISE: begin scl_low <= 0; state <= RECOVER_FALL; end
                    RECOVER_FALL: begin
                        scl_low <= 1;
                        if (bit_index == 0) state <= STOP_SETUP;
                        else begin bit_index <= bit_index - 1'b1; state <= RECOVER_RISE; end
                    end
                    STOP_SETUP: begin sda_low <= 1; state <= STOP_RISE; end
                    STOP_RISE: begin scl_low <= 0; state <= STOP_RELEASE; end
                    STOP_RELEASE: begin sda_low <= 0; state <= BUS_FREE; end
                    BUS_FREE: begin busy <= 0; done <= 1; state <= IDLE; end
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
