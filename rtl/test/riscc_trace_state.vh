// Shared architectural trace shadow state.
//
// The including core supplies:
//   RISCC_TRACE_W, tr_commit_i, tr_pc_i, tr_ir_i, tr_ie_i,
//   tr_rf_we_i, tr_rf_bank_i, tr_rf_reg_i, tr_rf_lsb_i, tr_rf_data_i.

    reg [15:0] tr_r [0:7];
    reg [15:0] tr_s [0:7];
    reg        tr_valid;
    reg        tr_pending;
    reg [14:0] tr_pc;
    reg [15:0] tr_ir;
    reg [15:0] tr_ir_live;
    reg        tr_ie;
    integer tr_i;

    always @(posedge clk) begin
        tr_valid <= 1'b0;
        if (rst) begin
            for (tr_i = 0; tr_i < 8; tr_i = tr_i + 1) begin
                tr_r[tr_i] <= 16'h0000;
                tr_s[tr_i] <= 16'h0000;
            end
            tr_pending <= 1'b0;
            tr_ir_live <= 16'h0000;
        end else begin
            if (tr_rf_we_i) begin
                if (tr_rf_bank_i)
                    tr_s[tr_rf_reg_i][tr_rf_lsb_i +: RISCC_TRACE_W] <= tr_rf_data_i;
                else
                    tr_r[tr_rf_reg_i][tr_rf_lsb_i +: RISCC_TRACE_W] <= tr_rf_data_i;
            end

            if (tr_pending) begin
                tr_valid <= 1'b1;
                tr_pc <= tr_pc_i;
                tr_ir <= tr_ir_live;
                tr_ie <= tr_ie_i;
                tr_pending <= 1'b0;
            end

            if (tr_commit_i) begin
                tr_ir_live <= tr_ir_i;
                tr_pending <= 1'b1;
            end
        end
    end

    assign trace_valid = tr_valid;
    assign trace_pc = tr_pc;
    assign trace_ir = tr_ir;
    assign trace_ie = tr_ie;
    assign trace_r0 = tr_r[0];
    assign trace_r1 = tr_r[1];
    assign trace_r2 = tr_r[2];
    assign trace_r3 = tr_r[3];
    assign trace_r4 = tr_r[4];
    assign trace_r5 = tr_r[5];
    assign trace_r6 = tr_r[6];
    assign trace_r7 = tr_r[7];
    assign trace_s0 = tr_s[0];
    assign trace_s1 = tr_s[1];
    assign trace_s2 = tr_s[2];
    assign trace_s3 = tr_s[3];
    assign trace_s4 = tr_s[4];
    assign trace_s5 = tr_s[5];
    assign trace_s6 = tr_s[6];
    assign trace_s7 = tr_s[7];
