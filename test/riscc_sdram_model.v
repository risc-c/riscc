// Independent command-level SDR SDRAM model. Test-only SystemVerilog.
// Timing is checked at device clock edges, not against controller state.
`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_model #(
    parameter integer DATA_BITS = 16, ROW_BITS = 13, COL_BITS = 9,
    parameter integer CAS = 3, INIT_CYCLES = 20,
    parameter integer TRCD = 1, TRP = 1, TRFC = 4, TRAS = 3, TWR = 2,
    parameter integer MAX_REFRESH_GAP = 0,
    parameter realtime T_AC = 0.001
) (
    input wire clk, rst, cke, cs_n, ras_n, cas_n, we_n,
    input wire [12:0] addr,
    input wire [1:0] ba,
    input wire [DATA_BITS/8-1:0] dqm,
    input wire [DATA_BITS-1:0] dq_i,
    input wire dq_oe,
    output reg [DATA_BITS-1:0] dq_o
);
    localparam integer BL = DATA_BITS == 16 ? 2 : 1;
    reg [DATA_BITS-1:0] memory [longint unsigned];
    integer cycle = 0, start_cycle = 0, last_refresh = -1000000;
    integer last_mode = -1000000, init_refs = 0;
    integer last_act [0:3], last_pre [0:3], last_write [0:3], last_read_end [0:3];
    reg [ROW_BITS-1:0] row [0:3];
    reg [3:0] opened = 0;
    reg initialized = 0, precharged = 0;
    longint unsigned read_address [0:31];
    integer read_due [0:31];
    integer head = 0, tail = 0;
    reg write_second = 0;
    longint unsigned write_address;
    integer write_bank;
    reg [DATA_BITS/8-1:0] dqm_prev = 0, dqm_prev2 = 0;
    integer refresh_count = 0, read_count = 0, write_count = 0, activate_count = 0;
    integer b, j, k;
    longint unsigned address;
    reg [DATA_BITS-1:0] value;
    wire [3:0] command = {cs_n, ras_n, cas_n, we_n};

    task store_word(input longint unsigned a);
        reg [DATA_BITS-1:0] v;
        begin
            if (!dq_oe) $fatal(1, "SDRAM write without DQ drive");
            v = memory.exists(a) != 0 ? memory[a] : 0;
            for (integer lane = 0; lane < DATA_BITS/8; lane = lane + 1)
                if (!dqm[lane]) v[lane*8 +: 8] = dq_i[lane*8 +: 8];
            memory[a] = v;
        end
    endtask

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (rst) begin
            start_cycle = cycle;
            opened = 0;
            initialized = 0;
            precharged = 0;
            init_refs = 0;
            last_refresh = -1000000;
            last_mode = -1000000;
            head = 0;
            tail = 0;
            write_second = 0;
            dq_o <= 0;
            dqm_prev = 0;
            dqm_prev2 = 0;
            for (b = 0; b < 4; b = b + 1) begin
                last_act[b] = -1000000;
                last_pre[b] = -1000000;
                last_write[b] = -1000000;
                last_read_end[b] = -1000000;
            end
        end else begin
            if (!initialized && cycle - start_cycle < INIT_CYCLES &&
                dqm != {DATA_BITS/8{1'b1}}) $fatal(1, "DQM not held high at power-up");
            if (!cke) $fatal(1, "unexpected CKE low after reset");
            if (initialized && MAX_REFRESH_GAP != 0 &&
                cycle - last_refresh > MAX_REFRESH_GAP)
                $fatal(1, "refresh deadline missed");
            dq_o <= #(T_AC) 0;
            if (head != tail && read_due[head] == cycle) begin
                if (dq_oe) $fatal(1, "SDRAM DQ bus contention");
                if (dqm_prev2 != 0) $fatal(1, "read masked by delayed DQM");
                address = read_address[head];
                value = memory.exists(address) != 0 ? memory[address] : 0;
                dq_o <= #(T_AC) value;
                head = (head + 1) % 32;
            end
            if (write_second) begin
                store_word(write_address);
                last_write[write_bank] = cycle;
                write_second = 0;
                if (command != 4'b0111) $fatal(1, "command overlaps write burst");
            end
            if (command != 4'b0111 && command != 4'b1111) begin
                if (cycle - start_cycle < INIT_CYCLES)
                    $fatal(1, "power-up delay violated");
                if (cycle - last_refresh < TRFC) $fatal(1, "tRFC violated");
                if (cycle - last_mode < 2) $fatal(1, "tMRD violated");
            end
            case (command)
                4'b0010: begin // PRECHARGE
                    for (b = 0; b < 4; b = b + 1) begin
                        if (addr[10] || b == int'(ba)) begin
                            if (opened[b] && cycle - last_act[b] < TRAS)
                                $fatal(1, "tRAS violated");
                            if (cycle - last_write[b] < TWR) $fatal(1, "tWR violated");
                            if (cycle <= last_read_end[b]) $fatal(1, "read burst truncated");
                            opened[b] = 0;
                            last_pre[b] = cycle;
                        end
                    end
                    if (addr[10]) precharged = 1;
                end
                4'b0001: begin // AUTO REFRESH
                    if (opened != 0 || !precharged) $fatal(1, "refresh with open banks");
                    for (b = 0; b < 4; b = b + 1)
                        if (cycle - last_pre[b] < TRP) $fatal(1, "refresh tRP violated");
                    if (head != tail || write_second) $fatal(1, "refresh with data pending");
                    last_refresh = cycle;
                    init_refs = init_refs + 1;
                    refresh_count = refresh_count + 1;
                end
                4'b0000: begin // MODE REGISTER SET
                    if (opened != 0 || init_refs < 8) $fatal(1, "bad initialization order");
                    if (addr != 13'((CAS << 4) | (BL == 2 ? 1 : 0)) || ba != 0)
                        $fatal(1, "bad SDRAM mode %h", addr);
                    last_mode = cycle;
                    initialized = 1;
                end
                4'b0011: begin // ACTIVE
                    if (!initialized || opened[ba]) $fatal(1, "invalid ACTIVATE");
                    if (cycle - last_pre[ba] < TRP) $fatal(1, "ACT tRP violated");
                    if (cycle - last_act[ba] < TRAS + TRP) $fatal(1, "tRC violated");
                    opened[ba] = 1;
                    row[ba] = addr[ROW_BITS-1:0];
                    last_act[ba] = cycle;
                    activate_count = activate_count + 1;
                end
                4'b0100, 4'b0101: begin
                    if (!initialized || !opened[ba]) $fatal(1, "access to closed bank");
                    if (cycle - last_act[ba] < TRCD) $fatal(1, "tRCD violated");
                    if (addr[10]) $fatal(1, "unexpected auto-precharge");
                    address = (longint'(row[ba]) << (COL_BITS+2)) |
                              (longint'(ba) << COL_BITS) | longint'(addr[COL_BITS-1:0]);
                    if (BL == 2 && addr[0]) $fatal(1, "unaligned BL2 transfer");
                    if (!we_n) begin
                        if (head != tail) $fatal(1, "write interrupts read pipeline");
                        store_word(address);
                        last_write[ba] = cycle;
                        write_address = address + 1;
                        write_bank = int'(ba);
                        write_second = BL == 2;
                        write_count = write_count + 1;
                    end else begin
                        if (dq_oe) $fatal(1, "DQ driven during READ");
                        for (k = 0; k < BL; k = k + 1) begin
                            j = (tail + 31) % 32;
                            if (head != tail && read_due[j] >= cycle + CAS - 1 + k)
                                $fatal(1, "overlapping read bursts");
                            read_address[tail] = address + longint'(k);
                            // CAS counts to the receiving edge; the SDRAM
                            // launches data one edge earlier (Winbond 10.2).
                            read_due[tail] = cycle + CAS - 1 + k;
                            tail = (tail + 1) % 32;
                            if (tail == head) $fatal(1, "model read queue overflow");
                        end
                        last_read_end[ba] = cycle + CAS + BL - 2;
                        read_count = read_count + 1;
                    end
                end
                4'b0111, 4'b1111: ;
                default: $fatal(1, "unsupported SDRAM command");
            endcase
            dqm_prev2 = dqm_prev;
            dqm_prev = dqm;
        end
    end
endmodule
`default_nettype wire
