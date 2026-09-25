`timescale 1ns/1ps
`default_nettype none

// Protocol-level tests for the small, open-drain HDMI configuration buses.
// The pull-ups below are deliberately behavioural (tri1), just as they are
// on the board.  The slave model never drives a logic one onto either bus.
module board_i2c_tb;
    reg clk = 1'b0;
    always #1 clk = ~clk;

    integer checks = 0;
    integer errors = 0;

    // A direct engine instance is useful for exercising error paths which
    // the board-specific wrappers intentionally hide.
    reg wr_rst = 1'b1;
    reg wr_start = 1'b0;
    reg wr_read = 1'b0;
    reg [23:0] wr_data = 24'd0;
    wire wr_busy, wr_done, wr_nack;
    wire [7:0] wr_rdata;
    tri1 wr_scl, wr_sda;
    reg wr_scl_slave_low = 1'b0;
    reg wr_sda_slave_low = 1'b0;
    assign wr_scl = wr_scl_slave_low ? 1'b0 : 1'bz;
    assign wr_sda = wr_sda_slave_low ? 1'b0 : 1'bz;
    reg wr_monitor_active = 1'b0;
    reg wr_monitor_started = 1'b0;
    reg wr_monitor_allow_stop = 1'b0;
    reg wr_monitor_previous_sda = 1'b1;
    integer wr_high_changes = 0;

    // I2C permits SDA transitions while SCL is high only for START and STOP.
    // This monitor runs on the resolved bus, so it also catches an accidental
    // push-pull one from the master (the slave model only ever drives zero).
    always @(wr_sda) begin
        if (wr_monitor_active && wr_scl === 1'b1 &&
            wr_sda !== wr_monitor_previous_sda) begin
            if (!wr_monitor_started && wr_sda === 1'b0)
                wr_monitor_started = 1'b1;
            else if (wr_monitor_allow_stop && wr_sda === 1'b1)
                wr_monitor_allow_stop = 1'b0;
            else
                wr_high_changes = wr_high_changes + 1;
        end
        wr_monitor_previous_sda = wr_sda;
    end

    riscc_i2c_reg #(.HALF_CYCLES(4), .TIMEOUT_CYCLES(100)) writer (
        .clk(clk), .rst(wr_rst), .start(wr_start), .read(wr_read),
        .data(wr_data), .scl(wr_scl), .sda(wr_sda), .busy(wr_busy),
        .done(wr_done), .nack(wr_nack), .rdata(wr_rdata)
    );

    reg tfp_rst = 1'b1;
    wire tfp_ready;
    tri1 tfp_scl, tfp_sda;
    reg tfp_scl_slave_low = 1'b0;
    reg tfp_sda_slave_low = 1'b0;
    assign tfp_scl = tfp_scl_slave_low ? 1'b0 : 1'bz;
    assign tfp_sda = tfp_sda_slave_low ? 1'b0 : 1'bz;
    reg tfp_monitor_active = 1'b0;
    reg tfp_monitor_started = 1'b0;
    reg tfp_monitor_allow_stop = 1'b0;
    reg tfp_monitor_previous_sda = 1'b1;
    integer tfp_high_changes = 0;
    always @(tfp_sda) begin
        if (tfp_monitor_active && tfp_scl === 1'b1 &&
            tfp_sda !== tfp_monitor_previous_sda) begin
            if (!tfp_monitor_started && tfp_sda === 1'b0)
                tfp_monitor_started = 1'b1;
            else if (tfp_monitor_allow_stop && tfp_sda === 1'b1)
                tfp_monitor_allow_stop = 1'b0;
            else
                tfp_high_changes = tfp_high_changes + 1;
        end
        tfp_monitor_previous_sda = tfp_sda;
    end
    atum_tfp410_init #(.POWERUP_CYCLES(3), .I2C_HALF_CYCLES(4)) tfp (
        .clk(clk), .rst(tfp_rst), .scl(tfp_scl), .sda(tfp_sda),
        .ready(tfp_ready)
    );

    reg adv_rst = 1'b1;
    reg adv_interrupt_n = 1'b1;
    wire adv_ready;
    tri1 adv_scl, adv_sda;
    reg adv_scl_slave_low = 1'b0;
    reg adv_sda_slave_low = 1'b0;
    assign adv_scl = adv_scl_slave_low ? 1'b0 : 1'bz;
    assign adv_sda = adv_sda_slave_low ? 1'b0 : 1'bz;
    reg adv_monitor_active = 1'b0;
    reg adv_monitor_started = 1'b0;
    reg adv_monitor_allow_start = 1'b0;
    reg adv_monitor_allow_stop = 1'b0;
    reg adv_monitor_previous_sda = 1'b1;
    integer adv_high_changes = 0;
    always @(adv_sda) begin
        if (adv_monitor_active && adv_scl === 1'b1 &&
            adv_sda !== adv_monitor_previous_sda) begin
            if (!adv_monitor_started && adv_sda === 1'b0)
                adv_monitor_started = 1'b1;
            else if (adv_monitor_allow_start && adv_sda === 1'b0)
                adv_monitor_allow_start = 1'b0;
            else if (adv_monitor_allow_stop && adv_sda === 1'b1)
                adv_monitor_allow_stop = 1'b0;
            else
                adv_high_changes = adv_high_changes + 1;
        end
        adv_monitor_previous_sda = adv_sda;
    end
    adv7513_init #(.POWERUP_CYCLES(3), .I2C_HALF_CYCLES(4)) adv (
        .clk(clk), .rst(adv_rst), .interrupt_n(adv_interrupt_n),
        .scl(adv_scl), .sda(adv_sda), .ready(adv_ready)
    );

    task automatic fail(input [1023:0] message);
        begin
            errors = errors + 1;
            $display("FAIL board I2C: %0s", message);
        end
    endtask

    task automatic check(input condition, input [1023:0] message);
        begin
            checks = checks + 1;
            if (!condition) fail(message);
        end
    endtask

    task automatic reset_writer;
        begin
            wr_rst = 1'b1;
            wr_start = 1'b0;
            wr_read = 1'b0;
            wr_scl_slave_low = 1'b0;
            wr_sda_slave_low = 1'b0;
            repeat (4) @(posedge clk);
            wr_rst = 1'b0;
            repeat (2) @(posedge clk);
            check(wr_scl === 1'b1 && wr_sda === 1'b1,
                  "writer bus is idle high after reset");
        end
    endtask

    task automatic pulse_writer;
        begin
            @(negedge clk);
            wr_start = 1'b1;
            @(negedge clk);
            wr_start = 1'b0;
        end
    endtask

    // A write transaction consists of three bytes and an ACK phase after
    // each byte.  The slave samples on rising SCL, then asserts ACK before
    // the following rising edge.  stretch_first holds SCL low during the
    // first ACK to exercise the master's clock-stretch wait path.
    task automatic capture_write(
        input [7:0] expected0,
        input [7:0] expected1,
        input [7:0] expected2,
        input [2:0] ack_mask,
        input stretch_first
    );
        integer i, j;
        reg [7:0] value;
        reg [7:0] expected;
        begin
            wr_monitor_previous_sda = wr_sda;
            wr_monitor_started = 1'b0;
            wr_monitor_allow_stop = 1'b0;
            wr_high_changes = 0;
            wr_monitor_active = 1'b1;
            @(negedge wr_sda);
            check(wr_scl === 1'b1, "write START occurs while SCL is high");
            for (i = 0; i < 3; i = i + 1) begin
                value = 8'h00;
                for (j = 0; j < 8; j = j + 1) begin
                    @(posedge wr_scl);
                    #0.1;
                    value = {value[6:0], wr_sda};
                end
                case (i)
                    0: expected = expected0;
                    1: expected = expected1;
                    default: expected = expected2;
                endcase
                check(value === expected, "write byte matches expected value");

                // The writer pulls SCL low after the data bit.  Assert the
                // slave response during that low phase, before release.
                @(negedge wr_scl);
                wr_sda_slave_low = ack_mask[i];
                if (stretch_first && i == 0) begin
                    wr_scl_slave_low = 1'b1;
                    repeat (12) @(posedge clk);
                    wr_scl_slave_low = 1'b0;
                end
                @(posedge wr_scl);
                #0.1;
                check(wr_sda === (ack_mask[i] ? 1'b0 : 1'b1),
                      "write ACK/NACK level is visible on SDA");
                @(negedge wr_scl);
                wr_sda_slave_low = 1'b0;
                if (!ack_mask[i]) begin
                    // The register engine aborts immediately on a NACK and
                    // emits STOP without attempting the remaining bytes.
                    wr_monitor_allow_stop = 1'b1;
                    wait (wr_scl === 1'b1 && wr_sda === 1'b1);
                    #0.1;
                    check(wr_scl === 1'b1, "NACK abort emits STOP while SCL is high");
                    check(wr_high_changes === 0,
                          "SDA is stable while SCL is high on NACK abort");
                    wr_monitor_active = 1'b0;
                    disable capture_write;
                end
            end
            // STOP is SDA rising while SCL remains high.
            wr_monitor_allow_stop = 1'b1;
            wait (wr_scl === 1'b1 && wr_sda === 1'b1);
            #0.1;
            check(wr_scl === 1'b1, "write STOP occurs while SCL is high");
            check(wr_high_changes === 0,
                  "SDA is stable while SCL is high during write");
            wr_monitor_active = 1'b0;
        end
    endtask

    // Read form: write address and register, repeated START, read address,
    // then eight slave-driven bits and a master NACK before STOP.
    task automatic capture_read(input [7:0] returned_value,
                                input [2:0] write_ack_mask,
                                input read_address_ack);
        integer i, j;
        reg [7:0] value;
        begin
            @(negedge wr_sda);
            check(wr_scl === 1'b1, "read START occurs while SCL is high");
            for (i = 0; i < 2; i = i + 1) begin
                value = 8'h00;
                for (j = 0; j < 8; j = j + 1) begin
                    @(posedge wr_scl);
                    #0.1;
                    value = {value[6:0], wr_sda};
                end
                if (i == 0)
                    check(value === 8'h72, "read uses ADV7513 write address 0x72");
                else
                    check(value === 8'h42, "read uses HPD register 0x42");
                @(negedge wr_scl);
                wr_sda_slave_low = write_ack_mask[i];
                @(posedge wr_scl);
                #0.1;
                check(wr_sda === (write_ack_mask[i] ? 1'b0 : 1'b1),
                      "read write phase ACK/NACK level is visible");
                @(negedge wr_scl);
                wr_sda_slave_low = 1'b0;
            end
            // Repeated START: the bus stays idle-high between the two
            // address phases without a STOP.
            @(negedge wr_sda);
            check(wr_scl === 1'b1, "read repeated START occurs while SCL is high");
            value = 8'h00;
            for (j = 0; j < 8; j = j + 1) begin
                @(posedge wr_scl);
                #0.1;
                value = {value[6:0], wr_sda};
            end
            check(value === 8'h73, "read uses ADV7513 read address 0x73");
            @(negedge wr_scl);
            wr_sda_slave_low = read_address_ack;
            @(posedge wr_scl);
            #0.1;
            check(wr_sda === (read_address_ack ? 1'b0 : 1'b1),
                  "read address ACK/NACK level is visible");
            @(negedge wr_scl);
            wr_sda_slave_low = 1'b0;

            // Slave data is valid while SCL is high, and changes only in
            // the preceding low phase.
            value = 8'h00;
            for (j = 0; j < 8; j = j + 1) begin
                wr_sda_slave_low = ~returned_value[7-j];
                @(posedge wr_scl);
                #0.1;
                value = {value[6:0], wr_sda};
                @(negedge wr_scl);
            end
            wr_sda_slave_low = 1'b0;
            check(value === returned_value, "read data byte matches HPD value");
            // Master NACK: SDA must remain released during this ninth clock.
            @(posedge wr_scl);
            #0.1;
            check(wr_sda === 1'b1, "read master NACK releases SDA");
            @(negedge wr_scl);
            wait (wr_scl === 1'b1 && wr_sda === 1'b1);
            #0.1;
            check(wr_scl === 1'b1, "read STOP occurs while SCL is high");
        end
    endtask

    task automatic test_open_drain_and_write;
        begin
            reset_writer();
            // External low must win over the master's released line, and
            // releasing the external device must restore the pull-up level.
            wr_sda_slave_low = 1'b1;
            #0.2;
            check(wr_sda === 1'b0, "SDA is wired-AND low when slave pulls low");
            wr_sda_slave_low = 1'b0;
            #0.2;
            check(wr_sda === 1'b1, "SDA returns high after slave release");
            wr_scl_slave_low = 1'b1;
            #0.2;
            check(wr_scl === 1'b0, "SCL is wired-AND low when slave pulls low");
            wr_scl_slave_low = 1'b0;
            #0.2;
            check(wr_scl === 1'b1, "SCL returns high after slave release");

            wr_data = 24'h7808bf;
            fork
                capture_write(8'h78, 8'h08, 8'hbf, 3'b111, 1'b1);
                pulse_writer();
            join
            wait (wr_done === 1'b1);
            check(wr_nack === 1'b0, "ACKed write does not report NACK");
            check(wr_busy === 1'b0, "writer is idle after ACKed write");
        end
    endtask

    task automatic test_nack_and_reset;
        begin
            reset_writer();
            wr_data = 24'h123456;
            fork
                capture_write(8'h12, 8'h34, 8'h56, 3'b101, 1'b0);
                pulse_writer();
            join
            wait (wr_done === 1'b1);
            check(wr_nack === 1'b1, "NACKed write reports NACK");

            // Reset in the middle of a transaction must release both lines
            // and permit a later transaction to start cleanly.
            reset_writer();
            wr_data = 24'habcdef;
            pulse_writer();
            wait (wr_scl === 1'b1 && wr_sda === 1'b0);
            repeat (2) @(posedge clk);
            wr_rst = 1'b1;
            repeat (3) @(posedge clk);
            check(wr_busy === 1'b0, "reset aborts an active write");
            check(wr_scl === 1'b1 && wr_sda === 1'b1,
                  "reset releases SCL and SDA");
            wr_rst = 1'b0;
            repeat (2) @(posedge clk);
            wr_data = 24'hcafeba;
            fork
                capture_write(8'hca, 8'hfe, 8'hba, 3'b111, 1'b0);
                pulse_writer();
            join
            wait (wr_done === 1'b1);
            check(wr_nack === 1'b0, "writer recovers after reset");
        end
    endtask

    task automatic test_stuck_scl_timeout;
        integer waited;
        begin
            reset_writer();
            wr_scl_slave_low = 1'b1;
            wr_data = 24'h000000;
            pulse_writer();
            waited = 0;
            while (!wr_done && waited < 300) begin
                @(posedge clk);
                waited = waited + 1;
            end
            check(wr_done === 1'b1, "stuck SCL reaches timeout");
            check(wr_nack === 1'b1, "stuck SCL timeout reports NACK");
            check(wr_busy === 1'b0, "stuck SCL timeout clears busy");
            wr_scl_slave_low = 1'b0;
            #0.2;
            check(wr_scl === 1'b1 && wr_sda === 1'b1,
                  "timeout releases both bus lines");
        end
    endtask

    task automatic test_stuck_sda_recovery;
        integer pulses;
        integer waited;
        reg previous_scl;
        begin
            reset_writer();
            // Simulate a peripheral that was reset in the middle of a read
            // and is still holding SDA.  The engine must issue nine recovery
            // clocks and STOP before accepting a new command.
            wr_sda_slave_low = 1'b1;
            wr_data = 24'h724200;
            wr_read = 1'b1;
            pulse_writer();
            pulses = 0;
            waited = 0;
            previous_scl = wr_scl;
            while (!wr_done && waited < 2000) begin
                @(posedge clk);
                waited = waited + 1;
                if (previous_scl === 1'b0 && wr_scl === 1'b1) begin
                    pulses = pulses + 1;
                    if (pulses == 8)
                        wr_sda_slave_low = 1'b0;
                end
                previous_scl = wr_scl;
            end
            check(wr_done === 1'b1, "stuck SDA recovery reaches done");
            check(wr_nack === 1'b1, "stuck SDA recovery reports NACK");
            check(pulses >= 9, "stuck SDA recovery emits nine SCL pulses");
            check(wr_scl === 1'b1 && wr_sda === 1'b1,
                  "stuck SDA recovery leaves bus idle");
            wr_read = 1'b0;
            wr_data = 24'habcdef;
            fork
                capture_write(8'hab, 8'hcd, 8'hef, 3'b111, 1'b0);
                pulse_writer();
            join
            wait (wr_done === 1'b1);
            check(wr_nack === 1'b0, "write succeeds after stuck SDA recovery");
        end
    endtask

    task automatic test_tfp;
        begin
            tfp_rst = 1'b1;
            tfp_scl_slave_low = 1'b0;
            tfp_sda_slave_low = 1'b0;
            repeat (4) @(posedge clk);
            tfp_rst = 1'b0;
            fork
                begin
                    capture_tfp_write(8'h78, 8'h08, 8'hbf);
                end
                begin
                    wait (tfp_ready === 1'b1);
                end
            join
            check(tfp_ready === 1'b1, "TFP410 init becomes ready after ACKed write");
        end
    endtask

    task automatic capture_tfp_write(input [7:0] expected0,
                                     input [7:0] expected1,
                                     input [7:0] expected2);
        integer i, j;
        reg [7:0] value;
        reg [7:0] expected;
        begin
            tfp_monitor_previous_sda = tfp_sda;
            tfp_monitor_started = 1'b0;
            tfp_monitor_allow_stop = 1'b0;
            tfp_high_changes = 0;
            tfp_monitor_active = 1'b1;
            @(negedge tfp_sda);
            check(tfp_scl === 1'b1, "TFP START occurs while SCL is high");
            for (i = 0; i < 3; i = i + 1) begin
                value = 0;
                for (j = 0; j < 8; j = j + 1) begin
                    @(posedge tfp_scl);
                    #0.1;
                    value = {value[6:0], tfp_sda};
                end
                case (i)
                    0: expected = expected0;
                    1: expected = expected1;
                    default: expected = expected2;
                endcase
                check(value === expected, "TFP write byte matches expected value");
                @(negedge tfp_scl);
                tfp_sda_slave_low = 1'b1;
                @(posedge tfp_scl);
                #0.1;
                check(tfp_sda === 1'b0, "TFP slave ACK is asserted");
                @(negedge tfp_scl);
                tfp_sda_slave_low = 1'b0;
            end
            tfp_monitor_allow_stop = 1'b1;
            wait (tfp_scl === 1'b1 && tfp_sda === 1'b1);
            #0.1;
            check(tfp_scl === 1'b1, "TFP STOP occurs while SCL is high");
            check(tfp_high_changes === 0,
                  "TFP SDA is stable while SCL is high");
            tfp_monitor_active = 1'b0;
        end
    endtask

    // The full ADV7513 list is the list from Terasic's DE23-Lite reference
    // design.  The test intentionally compares every byte, since a shifted
    // address or a missing entry leaves the board silent.
    reg [15:0] adv_lut [0:32];
    integer adv_lut_index;
    task automatic init_adv_lut;
        begin
            adv_lut[0]=16'h4110; adv_lut[1]=16'h96ff; adv_lut[2]=16'h94c0;
            adv_lut[3]=16'h9500; adv_lut[4]=16'h9803; adv_lut[5]=16'h9902;
            adv_lut[6]=16'h9ae0; adv_lut[7]=16'h9c30; adv_lut[8]=16'h9d61;
            adv_lut[9]=16'ha2a4; adv_lut[10]=16'ha3a4; adv_lut[11]=16'ha504;
            adv_lut[12]=16'hab40; adv_lut[13]=16'hd1ff; adv_lut[14]=16'hde10;
            adv_lut[15]=16'he0d0; adv_lut[16]=16'he460; adv_lut[17]=16'hf900;
            adv_lut[18]=16'hfa7d; adv_lut[19]=16'h1500; adv_lut[20]=16'h1630;
            adv_lut[21]=16'h1702; adv_lut[22]=16'h1846; adv_lut[23]=16'haf16;
            adv_lut[24]=16'hba60; adv_lut[25]=16'h0b0e; adv_lut[26]=16'h0c80;
            adv_lut[27]=16'h4080; adv_lut[28]=16'h5510; adv_lut[29]=16'h5628;
            adv_lut[30]=16'h4411; adv_lut[31]=16'h96ff; adv_lut[32]=16'h97ff;
        end
    endtask

    task automatic capture_adv_write(input [15:0] expected,
                                     input ack_transaction);
        integer i, j;
        reg [7:0] value;
        begin
            adv_monitor_previous_sda = adv_sda;
            adv_monitor_started = 1'b0;
            adv_monitor_allow_start = 1'b0;
            adv_monitor_allow_stop = 1'b0;
            adv_high_changes = 0;
            adv_monitor_active = 1'b1;
            @(negedge adv_sda);
            check(adv_scl === 1'b1, "ADV START occurs while SCL is high");
            for (i = 0; i < 3; i = i + 1) begin
                value = 0;
                for (j = 0; j < 8; j = j + 1) begin
                    @(posedge adv_scl);
                    #0.1;
                    value = {value[6:0], adv_sda};
                end
                if (i == 0) check(value === 8'h72,
                                   "ADV write uses address 0x72");
                if (i == 1) check(value === expected[15:8],
                                   "ADV register byte matches reference");
                if (i == 2) check(value === expected[7:0],
                                   "ADV value byte matches reference");
                @(negedge adv_scl);
                adv_sda_slave_low = ack_transaction;
                @(posedge adv_scl);
                #0.1;
                check(adv_sda === (ack_transaction ? 1'b0 : 1'b1),
                      "ADV ACK/NACK level is visible on SDA");
                @(negedge adv_scl);
                adv_sda_slave_low = 1'b0;
                if (!ack_transaction) begin
                    // The shared engine stops at the first NACK.
                    adv_monitor_allow_stop = 1'b1;
                    wait (adv_scl === 1'b1 && adv_sda === 1'b1);
                    #0.1;
                    check(adv_scl === 1'b1,
                          "ADV NACK recovery emits STOP while SCL is high");
                    check(adv_high_changes === 0,
                          "ADV SDA is stable while SCL is high on NACK abort");
                    adv_monitor_active = 1'b0;
                    disable capture_adv_write;
                end
            end
            adv_monitor_allow_stop = 1'b1;
            wait (adv_scl === 1'b1 && adv_sda === 1'b1);
            #0.1;
            check(adv_scl === 1'b1, "ADV STOP occurs while SCL is high");
            check(adv_high_changes === 0,
                  "ADV SDA is stable while SCL is high during write");
            adv_monitor_active = 1'b0;
        end
    endtask

    task automatic capture_adv_hpd_read(input [7:0] hpd_value);
        integer i, j;
        reg [7:0] value;
        begin
            adv_monitor_previous_sda = adv_sda;
            adv_monitor_started = 1'b0;
            adv_monitor_allow_start = 1'b0;
            adv_monitor_allow_stop = 1'b0;
            adv_high_changes = 0;
            adv_monitor_active = 1'b1;
            @(negedge adv_sda);
            check(adv_scl === 1'b1, "ADV HPD read START occurs while SCL is high");
            for (i = 0; i < 2; i = i + 1) begin
                value = 0;
                for (j = 0; j < 8; j = j + 1) begin
                    @(posedge adv_scl);
                    #0.1;
                    value = {value[6:0], adv_sda};
                end
                if (i == 0) begin
                    check(value === 8'h72,
                                   "ADV HPD read write address is 0x72");
                end else begin
                    check(value === 8'h42, "ADV HPD register is 0x42");
                end
                @(negedge adv_scl);
                adv_sda_slave_low = 1'b1;
                @(posedge adv_scl);
                #0.1;
                check(adv_sda === 1'b0, "ADV HPD write phase is ACKed");
                @(negedge adv_scl);
                adv_sda_slave_low = 1'b0;
            end
            adv_monitor_allow_start = 1'b1;
            @(negedge adv_sda);
            check(adv_scl === 1'b1, "ADV HPD repeated START is well formed");
            value = 0;
            for (j = 0; j < 8; j = j + 1) begin
                @(posedge adv_scl);
                #0.1;
                value = {value[6:0], adv_sda};
            end
            check(value === 8'h73, "ADV HPD read address is 0x73");
            @(negedge adv_scl);
            adv_sda_slave_low = 1'b1;
            @(posedge adv_scl);
            #0.1;
            check(adv_sda === 1'b0, "ADV HPD read address is ACKed");
            @(negedge adv_scl);
            adv_sda_slave_low = 1'b0;
            for (j = 0; j < 8; j = j + 1) begin
                adv_sda_slave_low = ~hpd_value[7-j];
                @(posedge adv_scl);
                @(negedge adv_scl);
            end
            adv_sda_slave_low = 1'b0;
            // Master NACK and STOP.
            @(posedge adv_scl);
            #0.1;
            check(adv_sda === 1'b1, "ADV HPD read is master-NACKed");
            @(negedge adv_scl);
            adv_monitor_allow_stop = 1'b1;
            wait (adv_scl === 1'b1 && adv_sda === 1'b1);
            #0.1;
            check(adv_scl === 1'b1, "ADV HPD read STOP is well formed");
            check(adv_high_changes === 0,
                  "ADV SDA is stable while SCL is high during HPD read");
            adv_monitor_active = 1'b0;
        end
    endtask

    task automatic test_adv;
        integer i;
        begin
            init_adv_lut();
            adv_rst = 1'b1;
            adv_interrupt_n = 1'b1;
            adv_scl_slave_low = 1'b0;
            adv_sda_slave_low = 1'b0;
            repeat (4) @(posedge clk);
            adv_rst = 1'b0;
            // A disconnected monitor must leave ready low.  The controller
            // continues polling, so let it complete one such probe first.
            capture_adv_hpd_read(8'h00);
            check(adv_ready === 1'b0, "ADV stays not-ready when HPD is low");

            // Reconnect and deliberately NACK the first setup write.  The
            // controller must restart with a fresh HPD query.
            capture_adv_hpd_read(8'h60);
            capture_adv_write(adv_lut[0], 1'b0);
            capture_adv_hpd_read(8'h60);
            for (i = 0; i < 33; i = i + 1)
                capture_adv_write(adv_lut[i], 1'b1);
            capture_adv_hpd_read(8'h60);
            wait (adv_ready === 1'b1);
            check(adv_ready === 1'b1, "ADV becomes ready only after full ACKed list");

            // An interrupt requests a fresh probe and complete list.  Keep
            // INT low until the synchronized ready indication clears.
            adv_interrupt_n = 1'b0;
            wait (adv_ready === 1'b0);
            adv_interrupt_n = 1'b1;
            capture_adv_hpd_read(8'h60);
            for (i = 0; i < 33; i = i + 1)
                capture_adv_write(adv_lut[i], 1'b1);
            capture_adv_hpd_read(8'h60);
            wait (adv_ready === 1'b1);
            check(adv_ready === 1'b1, "ADV recovers after interrupt");
        end
    endtask

    initial begin
        test_open_drain_and_write();
        test_nack_and_reset();
        test_stuck_scl_timeout();
        test_stuck_sda_recovery();
        reset_writer();
        wr_data = 24'h724200;
        wr_read = 1'b1;
        fork
            capture_read(8'h60, 3'b111, 1'b1);
            pulse_writer();
        join
        wait (wr_done === 1'b1);
        check(wr_nack === 1'b0, "HPD read does not report NACK");
        check(wr_rdata === 8'h60, "HPD read returns 0x60");
        wr_read = 1'b0;
        test_tfp();
        test_adv();
        if (errors != 0)
            $fatal(1, "board I2C test failed with %0d errors (%0d checks)", errors, checks);
        $display("PASS board I2C: %0d protocol checks", checks);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "board I2C test timeout");
    end
endmodule

`default_nettype wire
