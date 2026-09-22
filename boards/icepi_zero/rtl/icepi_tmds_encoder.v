// icepi_tmds_encoder.v : single-channel TMDS encoder for IcePi Zero.

`default_nettype none

// Minimal TMDS encoder for the IcePi DVI output. The first stage minimizes
// transitions; the running-disparity stage selects the polarity for DC balance.
module icepi_tmds_encoder (
    input  wire       clk,
    input  wire [7:0] data,
    input  wire [1:0] c,
    input  wire       de,
    output reg  [9:0] out
);
    // The TMDS tie-break on bit 0 reduces to a majority of bits 7:1.
    wire [2:0] tail_ones = {2'b00, data[1]} + {2'b00, data[2]} +
                           {2'b00, data[3]} + {2'b00, data[4]} +
                           {2'b00, data[5]} + {2'b00, data[6]} +
                           {2'b00, data[7]};
    wire use_xnor = tail_ones[2];
    wire [7:0] q_m_data;
    reg [8:0] q_m;
    reg [3:0] balance;
    reg de_q;
    reg [1:0] c_q;

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
    // Register the transition-minimized word and the control inputs together.
    always @(posedge clk) begin
        q_m <= {~use_xnor, q_m_data};
        balance <= q_m_ones - 4'd4;
        de_q <= de;
        c_q <= c;
    end
    wire balance_sign_eq = (balance[3] == disparity_q[3]);
    wire invert_q_m = (balance == 0 || disparity_q == 0) ?
                      ~q_m[8] : balance_sign_eq;
    // Complementing the balance lets both polarities share the same adder.
    // Include the two's-complement carry and the TMDS polarity correction.
    wire balanced = balance == 0 || disparity_q == 0;
    wire [3:0] correction = balanced ? {3'b000, invert_q_m} :
        invert_q_m ? (q_m[8] ? 4'd2 : 4'd1) :
                     (q_m[8] ? 4'd0 : 4'hf);
    wire [3:0] disparity_next = disparity_q +
        (balance ^ {4{invert_q_m}}) + correction;

    initial
        disparity_q = 4'd0;

    // Apply running-disparity correction during active video, or emit a control code.
    always @(posedge clk) begin
        if (de_q) begin
            out <= {invert_q_m, q_m[8], q_m[7:0] ^ {8{invert_q_m}}};
            disparity_q <= disparity_next;
        end else begin
            case (c_q)
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
