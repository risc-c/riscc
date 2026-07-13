`default_nettype none

// Minimal TMDS encoder for the Icepi DVI output.  The first stage minimizes
// transitions; the running-disparity stage selects the polarity for DC balance.
module icepi_tmds_encoder (
    input  wire       clk,
    input  wire [7:0] data,
    input  wire [1:0] c,
    input  wire       de,
    output reg  [9:0] out
);
    wire [3:0] data_ones = {3'b000, data[0]} + {3'b000, data[1]} +
                            {3'b000, data[2]} + {3'b000, data[3]} +
                            {3'b000, data[4]} + {3'b000, data[5]} +
                            {3'b000, data[6]} + {3'b000, data[7]};
    wire use_xnor = (data_ones > 4'd4) ||
                    ((data_ones == 4'd4) && !data[0]);
    wire [7:0] q_m_data;
    wire [8:0] q_m = {~use_xnor, q_m_data};

    assign q_m_data[0] = data[0];
    assign q_m_data[1] = q_m_data[0] ^ data[1] ^ use_xnor;
    assign q_m_data[2] = q_m_data[1] ^ data[2] ^ use_xnor;
    assign q_m_data[3] = q_m_data[2] ^ data[3] ^ use_xnor;
    assign q_m_data[4] = q_m_data[3] ^ data[4] ^ use_xnor;
    assign q_m_data[5] = q_m_data[4] ^ data[5] ^ use_xnor;
    assign q_m_data[6] = q_m_data[5] ^ data[6] ^ use_xnor;
    assign q_m_data[7] = q_m_data[6] ^ data[7] ^ use_xnor;

    reg [3:0] disparity_q;
    wire [3:0] q_m_ones = {3'b000, q_m_data[0]} +
                           {3'b000, q_m_data[1]} +
                           {3'b000, q_m_data[2]} +
                           {3'b000, q_m_data[3]} +
                           {3'b000, q_m_data[4]} +
                           {3'b000, q_m_data[5]} +
                           {3'b000, q_m_data[6]} +
                           {3'b000, q_m_data[7]};
    wire [3:0] balance = q_m_ones - 4'd4;
    wire balance_sign_eq = (balance[3] == disparity_q[3]);
    wire invert_q_m = (balance == 0 || disparity_q == 0) ?
                      ~q_m[8] : balance_sign_eq;
    wire [3:0] disparity_step = balance -
        (((q_m[8] ^ ~balance_sign_eq) &&
          !(balance == 0 || disparity_q == 0)) ? 4'd1 : 4'd0);
    wire [3:0] disparity_next = invert_q_m ?
                                disparity_q - disparity_step :
                                disparity_q + disparity_step;

    initial
        disparity_q = 4'd0;

    always @(posedge clk) begin
        if (de) begin
            out <= {invert_q_m, q_m[8], q_m_data ^ {8{invert_q_m}}};
            disparity_q <= disparity_next;
        end else begin
            case (c)
                2'b00: out <= 10'b1101010100;
                2'b01: out <= 10'b0010101011;
                2'b10: out <= 10'b0101010100;
                default: out <= 10'b1010101011;
            endcase
            disparity_q <= 4'd0;
        end
    end
endmodule

`default_nettype wire
