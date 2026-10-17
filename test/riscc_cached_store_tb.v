// Production CPU/SRAM/cache store routing, including displacement and XLEN wrap.
// Read back complete words so byte/halfword stores must preserve adjacent lanes.
`timescale 1ns/1ps
`default_nettype none
/* verilator lint_off WIDTH */
module riscc_cached_store_tb #(
    parameter integer XLEN = 32,
    parameter integer SRAM_ADDR_BITS = 14,
    parameter SRAM_HEX = ""
);
    localparam integer CODE_BYTE = 16'h8000;
    localparam integer LOCAL_BYTES = 1 << SRAM_ADDR_BITS;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire [XLEN-3:0] addr;
    wire [31:0] wdata;
    wire [3:0] mask;
    wire we, cyc, stb;
    reg [15:0] code [0:2047];
    reg [31:0] backing [0:16383], expected [0:16383];
    reg [XLEN-1:0] request_addr [0:255];
    reg request_we [0:255];
    reg [3:0] request_mask [0:255];
    reg [31:0] request_data [0:255];
    reg [XLEN-1:0] read_value [0:255];
    integer pc = 0, requests = 0, reads = 0, stores = 0;
    integer accepted = 0, returned = 0, cycles = 0;
    integer forwarded_a = 0, forwarded_b = 0, stalled = 0;
    reg pending_q = 0, we_q = 0;
    reg [XLEN-3:0] addr_q = 0;
    reg [31:0] data_q = 0;
    reg [3:0] mask_q = 0;
    integer wait_q = 0;
    wire ack = pending_q && wait_q == 0;
    wire stall = (pending_q && wait_q != 0) || cycles % 7 == 2;
    wire [31:0] rdata = addr_q >= CODE_BYTE / 4 && addr_q < CODE_BYTE / 4 + 1024 ?
        {code[(addr_q - CODE_BYTE / 4)*2 + 1], code[(addr_q - CODE_BYTE / 4)*2]} :
        backing[addr_q[13:0]];
    integer i, lane;

    riscc_cached #(.XLEN(XLEN), .RESET_PC(XLEN'(CODE_BYTE / 2)),
        .SRAM_ADDR_BITS(SRAM_ADDR_BITS), .SRAM_HEX(SRAM_HEX)) dut (
        .clk(clk), .rst(rst), .irq(1'b0), .mem_cacheable(),
        .mem_addr(addr), .mem_rdata(rdata), .mem_wdata(wdata), .mem_wmask(mask),
        .mem_we(we), .mem_cyc(cyc), .mem_stb(stb), .mem_stall(stall), .mem_ack(ack)
    );

    function automatic [15:0] enc_i(input integer rd, op, value);
        enc_i = 16'h8000 | (rd << 11) | (op << 8) | (value & 255);
    endfunction
    function automatic [15:0] enc_mem(input bit write, input integer rd, disp);
        enc_mem = 16'h4100 | (rd << 11) | (XLEN == 32 ?
            ((disp & 252) | ((disp < 0) << 1)) : (disp & 254)) | write;
    endfunction
    task automatic emit(input [15:0] ins);
        begin code[pc] = ins; pc = pc + 1; end
    endtask
    task automatic constant(input integer rd, input [XLEN-1:0] value);
        integer byte_index;
        begin
            emit(enc_i(rd, 0, value >> (XLEN - 8)));
            for (byte_index = XLEN / 8 - 2; byte_index >= 0; byte_index = byte_index - 1) begin
                emit(16'hc07f | (rd << 11) | (rd << 8)); // SLLI rd,rd,8
                emit(enc_i(rd, 5, value >> (byte_index * 8)));
            end
        end
    endtask
    task automatic expect_request(input [XLEN-1:0] address, input bit write,
                                  input [3:0] lanes, input [31:0] value);
        begin
            request_addr[requests] = address;
            request_we[requests] = write;
            request_mask[requests] = lanes;
            request_data[requests] = value;
            requests = requests + 1;
        end
    endtask
    task automatic readback(input [XLEN-1:0] word_byte);
        integer half_index;
        reg [XLEN-1:0] address;
        begin
            for (half_index = 0; half_index < 32 / XLEN; half_index = half_index + 1) begin
                address = word_byte + half_index * 2;
                constant(1, address);
                emit(enc_mem(0, 3, 0));
                expect_request(address, 0, XLEN == 32 ? 15 : address[1] ? 12 : 3, 0);
                read_value[reads] = expected[word_byte[15:2]] >> (half_index * 16);
                reads = reads + 1;
            end
        end
    endtask
    // kind: native immediate, byte direct, halfword direct.
    task automatic store_case(input [XLEN-1:0] base, input integer disp, kind);
        reg [XLEN-1:0] address, value;
        reg [31:0] bus_value;
        reg [3:0] lanes;
        integer byte_index, producer;
        begin
            address = base + disp;
            value = 32'ha55a8011 ^ (stores * 32'h01030713);
            constant(1, base);
            constant(2, value);
            // MUL by one lets the store queue behind its producer even with
            // instruction-cache latency. Alternate address/data forwarding.
            producer = stores & 1 ? 2 : 1;
            emit(16'hc03e | (producer << 11) | (producer << 8));
            if (kind == 0) begin
                emit(enc_mem(1, 2, disp));
                lanes = XLEN == 32 ? 15 : address[1] ? 12 : 3;
                bus_value = XLEN == 32 ? value : {2{value[15:0]}};
            end else begin
                emit(16'hd158 | (kind == 2 ? 2 : 0)); // STB/STH r2,[r1]
                lanes = kind == 1 ? (1 << address[1:0]) : address[1] ? 12 : 3;
                bus_value = kind == 1 ? {4{value[7:0]}} : {2{value[15:0]}};
            end
            expect_request(address, 1, lanes, bus_value);
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (lanes[byte_index])
                    expected[address[15:2]][byte_index*8 +: 8] = bus_value[byte_index*8 +: 8];
            stores = stores + 1;
            readback({address[XLEN-1:2], 2'b00});
        end
    endtask

    initial begin
        for (i = 0; i < 2048; i = i + 1) code[i] = 16'ha7ff; // JMP8 -1
        for (i = 0; i < 16384; i = i + 1) begin
            backing[i] = 32'h11223344;
            expected[i] = 32'h11223344;
        end
        emit(enc_i(6, 0, 1));
                store_case(LOCAL_BYTES - 4, 0, 0);
        store_case(LOCAL_BYTES - 4, 4, 0);
        store_case(LOCAL_BYTES, -4, 0);
        store_case(LOCAL_BYTES, 0, 0);
        store_case(-4, 4, 0);                 // positive XLEN wrap into SRAM
        store_case(0, -4, 0);                 // negative wrap out of SRAM
        store_case(LOCAL_BYTES - 124, 124, 0);
        store_case(LOCAL_BYTES + 124, -128, 0);
        if (XLEN == 32) begin
            store_case(LOCAL_BYTES - 252, 252, 0);
            store_case(LOCAL_BYTES + 252, -256, 0);
        end
        for (i = 0; i < 8; i = i + 1) store_case(LOCAL_BYTES - 4 + i, 0, 1);
        for (i = 0; i < 4; i = i + 1) store_case(i, 0, 1);
        if (XLEN == 32) begin
            store_case(LOCAL_BYTES - 2, 0, 2);
            store_case(LOCAL_BYTES + 2, 0, 2);
        end else begin
            store_case(LOCAL_BYTES - 2, 0, 0);
            store_case(LOCAL_BYTES + 2, 0, 0);
        end
        if (pc >= 2048 || requests >= 256) $fatal(1, "store fixture overflow");
        repeat (6) @(negedge clk);
        rst = 0;
    end

    always @(posedge clk) if (!rst) begin
        cycles <= cycles + 1;
        if (cyc && stb && stall) stalled = stalled + 1;
        if (dut.d_cyc && dut.d_stb && !dut.d_stall) begin
            if (accepted >= requests || dut.d_addr !== request_addr[accepted][XLEN-1:2] ||
                dut.d_we !== request_we[accepted] || dut.d_sel !== request_mask[accepted])
                $fatal(1, "CPU request %0d address/type/mask mismatch", accepted);
            if (dut.d_we) begin
                if (dut.d_wdata !== request_data[accepted] ||
                    dut.d_store_local !== ((request_addr[accepted] >> SRAM_ADDR_BITS) == 0))
                    $fatal(1, "store %0d data/local classification mismatch", accepted);
                if (dut.d_store_local && dut.d_store_addr !== request_addr[accepted][XLEN-1:2])
                    $fatal(1, "optimized SRAM store address mismatch");
                if (dut.cpu.x_forward_a_q) forwarded_a = forwarded_a + 1;
                if (dut.cpu.x_forward_b_q) forwarded_b = forwarded_b + 1;
            end
            accepted = accepted + 1;
        end
        if (dut.cpu.rf_we && dut.cpu.w_dst_q == 3) begin
            if (returned >= reads || dut.cpu.rf_wdata !== read_value[returned])
                $fatal(1, "readback %0d got=%h expected=%h", returned,
                       dut.cpu.rf_wdata, read_value[returned]);
            returned = returned + 1;
        end
        if (ack && we_q)
            for (lane = 0; lane < 4; lane = lane + 1)
                if (mask_q[lane]) backing[addr_q[13:0]][lane*8 +: 8] <= data_q[lane*8 +: 8];
        if (cyc && stb && !stall) begin
            pending_q <= 1;
            wait_q <= we ? 9 : 3;
            addr_q <= addr;
            we_q <= we;
            data_q <= wdata;
            mask_q <= mask;
            if ((addr >> (SRAM_ADDR_BITS - 2)) == 0)
                $fatal(1, "local SRAM request escaped to backing memory");
        end else if (ack) pending_q <= 0;
        else if (pending_q) wait_q <= wait_q - 1;
        if (pending_q && !cyc) $fatal(1, "backing CYC dropped before ACK");
        if (returned == reads && !dut.db_cyc && !pending_q) begin
            if (accepted != requests || !forwarded_a || !forwarded_b || !stalled)
                $fatal(1, "missing coverage: requests=%0d/%0d forward_a=%0d forward_b=%0d stalls=%0d",
                                       accepted, requests, forwarded_a, forwarded_b, stalled);
            for (i = LOCAL_BYTES / 4; i < 16384; i = i + 1)
                if (backing[i] !== expected[i]) $fatal(1, "external store was lost");
            $display("PASS Cached stores XLEN=%0d SRAM=%0d stores=%0d reads=%0d forward_a=%0d forward_b=%0d stalls=%0d",
                     XLEN, SRAM_ADDR_BITS, stores, reads, forwarded_a, forwarded_b, stalled);
            $finish;
        end
        if (cycles > 50000) $fatal(1, "production SRAM store timeout");
    end
endmodule
/* verilator lint_on WIDTH */
`default_nettype wire
