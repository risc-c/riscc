// DE23-Lite ADV7513: 24-bit RGB, separate syncs, HDMI video without audio/HDCP.
// Register values: Terasic HDMI_ASx4 and ADI ADV7513 Programming Guide Rev B.
`default_nettype none
module adv7513_init #(
    parameter integer POWERUP_CYCLES = 10000000, // 200 ms at 50 MHz
    parameter integer I2C_HALF_CYCLES = 250
) (
    input wire clk, rst, interrupt_n,
    inout wire scl, sda,
    output reg ready
);
    localparam integer TIMER_BITS = POWERUP_CYCLES > 1 ? $clog2(POWERUP_CYCLES) : 1;
    localparam [TIMER_BITS-1:0] WAIT_LAST = POWERUP_CYCLES - 1;
    localparam [2:0] WAIT=0, QUERY=1, QUERY_WAIT=2, WRITE=3,
        WRITE_WAIT=4, VERIFY=5, VERIFY_WAIT=6, READY=7;
    localparam [5:0] LAST_REGISTER = 32;
    reg [TIMER_BITS-1:0] timer;
    reg [2:0] state;
    reg [5:0] index;
    reg start, read;
    reg [15:0] setting;
    wire [23:0] command = read ? 24'h724200 : {8'h72, setting};
    wire done, nack;
    wire [7:0] rdata;
    (* ASYNC_REG = "TRUE" *) reg [1:0] interrupt_sync;
    always @(posedge clk) begin
        if (rst) interrupt_sync <= 2'b11;
        else interrupt_sync <= {interrupt_sync[0], interrupt_n};
    end
    riscc_i2c_reg #(.HALF_CYCLES(I2C_HALF_CYCLES)) writer (
        .clk(clk), .rst(rst), .start(start), .read(read), .data(command),
        .scl(scl), .sda(sda), .busy(), .done(done), .nack(nack), .rdata(rdata)
    );
    always @* begin
        case (index)
            0: setting = 16'h4110; // Power up only after HPD has been read high.
            1: setting = 16'h96ff; // Clear stale interrupts (write-one-to-clear).
            2: setting = 16'h94c0; // Enable HPD and monitor-sense interrupts only.
            3: setting = 16'h9500;
            4: setting = 16'h9803; // Required fixed-register values.
            5: setting = 16'h9902;
            6: setting = 16'h9ae0;
            7: setting = 16'h9c30;
            8: setting = 16'h9d61;
            9: setting = 16'ha2a4;
            10: setting = 16'ha3a4;
            11: setting = 16'ha504;
            12: setting = 16'hab40;
            13: setting = 16'hd1ff;
            14: setting = 16'hde10;
            15: setting = 16'he0d0;
            16: setting = 16'he460;
            17: setting = 16'hf900;
            18: setting = 16'hfa7d;
            19: setting = 16'h1500; // RGB 4:4:4, separate HS/VS/DE.
            20: setting = 16'h1630; // 24-bit RGB input, 8 bits per component.
            21: setting = 16'h1702; // 16:9 picture aspect ratio.
            22: setting = 16'h1846; // Disable color-space conversion.
            23: setting = 16'haf16; // HDMI mode; HDCP disabled.
            24: setting = 16'hba60; // Input clock delay = zero.
            25: setting = 16'h0b0e; // SPDIF disabled; retain required fixed bits.
            26: setting = 16'h0c80; // Disable every I2S input.
            27: setting = 16'h4080; // General control packet.
            28: setting = 16'h5510; // AVI: RGB, active-format information present.
            29: setting = 16'h5628; // AVI: 16:9, active aspect same as picture.
            30: setting = 16'h4411; // AVI enabled, audio/N-CTS packets disabled.
            31: setting = 16'h96ff;
            default: setting = 16'h97ff;
        endcase
    end
    // INT is a notification, not HPD itself. Read HPD before power-up and again
    // after setup. Polling also recovers when a transition occurs during setup.
    always @(posedge clk) begin
        start <= 0;
        if (rst) begin
            timer <= WAIT_LAST;
            state <= WAIT;
            index <= 0;
            ready <= 0;
            read <= 0;
        end else case (state)
            WAIT: begin
                if (timer != 0) timer <= timer - 1'b1;
                else state <= QUERY;
            end
            QUERY, VERIFY: begin
                read <= 1;
                start <= 1;
                state <= state == QUERY ? QUERY_WAIT : VERIFY_WAIT;
            end
            QUERY_WAIT, VERIFY_WAIT: if (done) begin
                timer <= WAIT_LAST;
                if (nack || !rdata[6]) begin
                    ready <= 0;
                    state <= WAIT;
                end else if (state == VERIFY_WAIT || ready) begin
                    ready <= interrupt_sync[1];
                    state <= interrupt_sync[1] ? READY : WAIT;
                end else begin index <= 0; state <= WRITE; end
            end
            WRITE: begin
                read <= 0;
                start <= 1;
                state <= WRITE_WAIT;
            end
            WRITE_WAIT: if (done) begin
                if (nack) begin
                    ready <= 0;
                    timer <= WAIT_LAST;
                    state <= WAIT;
                end else if (index == LAST_REGISTER) state <= VERIFY;
                else begin index <= index + 1'b1; state <= WRITE; end
            end
            READY: begin
                if (!interrupt_sync[1]) begin
                    ready <= 0;
                    timer <= WAIT_LAST;
                    state <= WAIT;
                end else if (timer == 0) state <= QUERY;
                else timer <= timer - 1'b1;
            end
            default: begin ready <= 0; state <= WAIT; timer <= WAIT_LAST; end
        endcase
    end
endmodule
`default_nettype wire
