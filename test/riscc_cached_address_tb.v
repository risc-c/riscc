// Public riscc_cached address/tag and self-modifying-code checks.
//
// The backing model is sparse on purpose: masking a 30-bit address to a small
// array would hide I-cache tag truncation and RC32 bit-31 aliases.  The test
// uses the public one-port wrapper, so instruction and data transactions also
// exercise the owner arbitration between the two internal caches.

`default_nettype none

module riscc_cached_address_tb #(
    parameter integer XLEN = 16,
    parameter integer RESET_PC = 0,
    // The RC32 coherence run overrides this with bit 15 so the 0x8000 byte
    // region is D-cache bypassed while the I-cache still caches all addresses.
    parameter integer DCACHE_UNCACHED_BIT = XLEN - 1
);
    localparam integer SLOT_COUNT = 256;
    localparam [31:0] RESULT_BYTE = 32'h0000_0100;
    localparam [31:0] DONE_BYTE = 32'h0000_0104;
    localparam [31:0] RC16_HIGH = 32'h0000_9000;
    localparam [31:0] RC16_LOW = 32'h0000_0080;
    localparam [31:0] RC16_TARGET = 32'h0000_8080;
    localparam [31:0] RC16_DONE_CODE = 32'h0000_9100;
    localparam [31:0] RC32_LOW = 32'h0001_0000;
    localparam [31:0] RC32_HIGH = 32'h8001_0000;
    localparam [31:0] RC32_TARGET = 32'h0000_8000;
    localparam [31:0] RC32_COH_TARGET = 32'h0000_8080;
    localparam [31:0] RC32_DONE_CODE = 32'h8001_0100;
    localparam [29:0] ICACHE_LINE_WORDS_ADDR = (XLEN == 32) ? 30'd16 : 30'd8;
    localparam integer ICACHE_LINE_WORDS = (XLEN == 32) ? 16 : 8;
    localparam [29:0] RESULT_WORD = RESULT_BYTE[31:2];
    localparam [29:0] DONE_WORD = DONE_BYTE[31:2];
    localparam [29:0] RC16_TARGET_WORD = RC16_TARGET[31:2];
    localparam [29:0] RC32_HIGH_WORD = RC32_HIGH[31:2];
    localparam [29:0] RC32_COH_TARGET_WORD = RC32_COH_TARGET[31:2];

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg irq = 1'b0;
    always #5 clk = ~clk;

    wire [XLEN-3:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0] mem_wmask;
    wire mem_we, mem_cyc, mem_stb;
    wire [31:0] mem_rdata;
    wire mem_ack, mem_stall;

    riscc_cached #(
        .XLEN(XLEN),
        .RESET_PC(RESET_PC[XLEN-1:0]),
        .DCACHE_UNCACHED_BIT(DCACHE_UNCACHED_BIT)
    ) dut (
        .clk(clk), .rst(rst), .irq(irq),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .mem_wdata(mem_wdata), .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_cyc(mem_cyc), .mem_stb(mem_stb),
        .mem_stall(mem_stall), .mem_ack(mem_ack)
    );

    reg [29:0] slot_addr [0:SLOT_COUNT-1];
    reg [31:0] slot_data [0:SLOT_COUNT-1];
    reg slot_valid [0:SLOT_COUNT-1];
    integer slot_count;
    integer i;

    reg backend_pending;
    reg [2:0] backend_delay;
    reg [29:0] backend_addr;
    reg [31:0] backend_data;
    integer cycle_count;
    integer backend_reads;
    integer backend_writes;
    integer expected_writes;
    integer response_count;
    integer target_line_reads;
    integer failed;
    integer done_seen;
    integer test_case;
    reg immediate_mode;
    reg wait_mode;
    reg stall_mode;

    reg stalled_last;
    reg [29:0] stalled_addr;
    reg [31:0] stalled_wdata;
    reg [3:0] stalled_wmask;
    reg stalled_we;
    integer stall_count;
    integer stall_release_count;

    wire [29:0] backend_now_addr = {{(32-XLEN){1'b0}}, mem_addr};
    wire [29:0] mem_addr_word = {{(32-XLEN){1'b0}}, mem_addr};
    wire backend_accept = mem_cyc && mem_stb && !mem_stall;
    wire backend_response = immediate_mode ? backend_accept : backend_pending;

    // Keep backpressure deterministic and independent of the memory contents.
    assign mem_stall = stall_mode && (cycle_count > 20) &&
                       ((cycle_count % 7) == 2);
    assign mem_ack = backend_response;
    assign mem_rdata = immediate_mode ? sparse_read(backend_now_addr) : backend_data;

    function automatic [31:0] sparse_read(input [29:0] address);
        integer n;
        begin
            sparse_read = 32'b0;
            for (n = 0; n < SLOT_COUNT; n = n + 1)
                if (slot_valid[n] && slot_addr[n] == address)
                    sparse_read = slot_data[n];
        end
    endfunction

    task automatic sparse_write(input [29:0] address, input [31:0] value);
        integer n;
        reg found;
        begin
            found = 1'b0;
            for (n = 0; n < SLOT_COUNT; n = n + 1)
                if (slot_valid[n] && slot_addr[n] == address) begin
                    slot_data[n] = value;
                    found = 1'b1;
                end
            if (!found) begin
                if (slot_count >= SLOT_COUNT) $fatal(1, "sparse memory full");
                slot_valid[slot_count] = 1'b1;
                slot_addr[slot_count] = address;
                slot_data[slot_count] = value;
                slot_count = slot_count + 1;
            end
        end
    endtask

    task automatic put_word(input [31:0] byte_address, input [31:0] value);
        begin sparse_write(byte_address[31:2], value); end
    endtask

    task automatic put16(input [31:0] byte_address, input [15:0] value);
        reg [31:0] old_word;
        reg [31:0] new_word;
        begin
            old_word = sparse_read(byte_address[31:2]);
            if (byte_address[1])
                new_word = {value, old_word[15:0]};
            else
                new_word = {old_word[31:16], value};
            sparse_write(byte_address[31:2], new_word);
        end
    endtask

    function automatic [15:0] enc_i(
        input [2:0] rd, input [2:0] op, input [7:0] imm);
        enc_i = {2'b10, rd, op, imm};
    endfunction

    function automatic [15:0] enc_mem(
        input store, input [2:0] rs, input [2:0] ra, input [7:0] disp);
        enc_mem = {2'b01, rs, ra, disp[7:1], store};
    endfunction

    function automatic [15:0] enc_r(
        input [2:0] rd, input [2:0] ra, input [4:0] func, input [2:0] rb);
        enc_r = {2'b11, rd, ra, func, rb};
    endfunction

    function automatic [15:0] enc_jmp(input [2:0] ra);
        enc_jmp = enc_r(3'd0, ra, 5'h1f, 3'd1);
    endfunction

    function automatic [15:0] enc_nop;
        enc_nop = enc_r(3'd0, 3'd0, 5'h05, 3'd0);
    endfunction

    function automatic [15:0] enc_ldpc(input [2:0] rd, input [7:0] offset);
        enc_ldpc = enc_i(rd, 3'd1, offset);
    endfunction

    task automatic put_ldi16(
        input [31:0] address, input [2:0] rd, input [15:0] value);
        begin
            put16(address, enc_i(rd, 3'd1, value[15:8]));
            put16(address + 2, enc_i(rd, 3'd5, value[7:0]));
        end
    endtask

    task automatic put_rc16_alias;
        reg [15:0] new_instruction;
        reg [15:0] new_jump;
        begin
            expected_writes = 5;
            new_instruction = enc_i(3'd2, 3'd0, 8'h5a);
            new_jump = enc_jmp(3'd7);

            // Low code and target differ only in bit 15 and share index 4.
            // The patching code uses indices 0/1, leaving the target warm.
            put_ldi16(RC16_HIGH + 0, 3'd4, RC16_HIGH[15:0] + 16'd10);
            put_ldi16(RC16_HIGH + 4, 3'd5, RC16_LOW[15:0]);
            put16(RC16_HIGH + 8, enc_jmp(3'd5));

            put_ldi16(RC16_HIGH + 10, 3'd4, RC16_HIGH[15:0] + 16'd20);
            put_ldi16(RC16_HIGH + 14, 3'd5, RC16_TARGET[15:0]);
            put16(RC16_HIGH + 18, enc_jmp(3'd5));

            // Patch both halfwords through the D-uncached 0x8000 region.
            put_ldi16(RC16_HIGH + 20, 3'd7, RC16_DONE_CODE[15:0]);
            put_ldi16(RC16_HIGH + 24, 3'd6, RC16_TARGET[15:0]);
            put_ldi16(RC16_HIGH + 28, 3'd1, new_instruction);
            put16(RC16_HIGH + 32, enc_mem(1'b1, 3'd1, 3'd6, 8'd0));
            put_ldi16(RC16_HIGH + 34, 3'd1, new_jump);
            put16(RC16_HIGH + 38, enc_mem(1'b1, 3'd1, 3'd6, 8'd2));
            put16(RC16_HIGH + 40, enc_jmp(3'd6));

            put16(RC16_LOW, enc_i(3'd3, 3'd0, 8'h33));
            put16(RC16_LOW + 2, enc_jmp(3'd4));
            put16(RC16_TARGET + 0, enc_i(3'd2, 3'd0, 8'h22));
            put16(RC16_TARGET + 2, enc_jmp(3'd4));

            put_ldi16(RC16_DONE_CODE + 0, 3'd6, RESULT_BYTE[15:0]);
            put16(RC16_DONE_CODE + 4, enc_mem(1'b1, 3'd2, 3'd6, 8'd0));
            put16(RC16_DONE_CODE + 6, enc_mem(1'b1, 3'd3, 3'd6, 8'd2));
            put16(RC16_DONE_CODE + 8, enc_i(3'd1, 3'd0, 8'ha5));
            put_ldi16(RC16_DONE_CODE + 10, 3'd6, DONE_BYTE[15:0]);
            put16(RC16_DONE_CODE + 14, enc_mem(1'b1, 3'd1, 3'd6, 8'd0));
        end
    endtask

    task automatic put_rc32_alias;
        begin
            expected_writes = 2;
            // Low code loads the full high target through LDPC+JALR.  The
            // two lines differ only in an address bit represented by the
            // full RC32 cache tag.
            put16(RC32_LOW + 0, enc_ldpc(3'd1, 8'h06));
            put16(RC32_LOW + 2, enc_jmp(3'd1));
            put16(RC32_LOW + 4, enc_nop());
            put16(RC32_LOW + 6, enc_nop());
            put_word(RC32_LOW + 8, RC32_HIGH);
            put_rc32_target(RC32_HIGH, 8'h5a);
        end
    endtask

    task automatic put_rc32_target(
        input [31:0] address, input [7:0] marker);
        begin
            // LDPC is placed at 4-byte-aligned PCs.  The literal offsets are
            // 12 bytes, encoded as signed word offsets with bit 1 set.
            put16(address + 0, enc_ldpc(3'd3, 8'h0e));
            put16(address + 2, enc_nop());
            put16(address + 4, enc_i(3'd2, 3'd0, marker));
            put16(address + 6, enc_mem(1'b1, 3'd2, 3'd3, 8'd0));
            put16(address + 8, enc_ldpc(3'd3, 8'h0e));
            put16(address + 10, enc_nop());
            put16(address + 12, enc_i(3'd2, 3'd0, 8'ha5));
            put16(address + 14, enc_mem(1'b1, 3'd2, 3'd3, 8'd0));
            put_word(address + 16, RESULT_BYTE);
            put_word(address + 24, DONE_BYTE);
        end
    endtask

    task automatic put_rc32_coherence;
        reg [31:0] new_word;
        begin
            expected_writes = 3;
            // The old target is fetched first and returns to the source. The
            // source then writes the replacement instruction word through
            // the explicit RC32 0x8000-region D-cache bypass and jumps back.
            put16(RC32_HIGH + 0, enc_ldpc(3'd4, 8'h1e));
            put16(RC32_HIGH + 2, enc_nop());
            put16(RC32_HIGH + 4, enc_ldpc(3'd5, 8'h1e));
            put16(RC32_HIGH + 6, enc_nop());
            put16(RC32_HIGH + 8, enc_jmp(3'd4));
            put16(RC32_HIGH + 10, enc_nop());
            put16(RC32_HIGH + 12, enc_ldpc(3'd5, 8'h1a));
            put16(RC32_HIGH + 14, enc_nop());
            put16(RC32_HIGH + 16, enc_ldpc(3'd1, 8'h1a));
            put16(RC32_HIGH + 18, enc_nop());
            put16(RC32_HIGH + 20, enc_mem(1'b1, 3'd1, 3'd4, 8'd0));
            put16(RC32_HIGH + 22, enc_jmp(3'd4));

            put_word(RC32_HIGH + 32, RC32_COH_TARGET);
            put_word(RC32_HIGH + 36, RC32_HIGH + 12);
            put_word(RC32_HIGH + 40, RC32_DONE_CODE);
            new_word = {enc_jmp(3'd5), enc_i(3'd2, 3'd0, 8'h5a)};
            put_word(RC32_HIGH + 44, new_word);

            put16(RC32_COH_TARGET + 0, enc_i(3'd2, 3'd0, 8'h22));
            put16(RC32_COH_TARGET + 2, enc_jmp(3'd5));
            put_rc32_done(RC32_DONE_CODE);
        end
    endtask

    task automatic put_rc32_done(input [31:0] address);
        begin
            put16(address + 0, enc_ldpc(3'd3, 8'h0e));
            put16(address + 2, enc_nop());
            put16(address + 4, enc_mem(1'b1, 3'd2, 3'd3, 8'd0));
            put16(address + 6, enc_nop());
            put16(address + 8, enc_ldpc(3'd3, 8'h0e));
            put16(address + 10, enc_nop());
            put16(address + 12, enc_i(3'd2, 3'd0, 8'ha5));
            put16(address + 14, enc_mem(1'b1, 3'd2, 3'd3, 8'd0));
            put_word(address + 16, RESULT_BYTE);
            put_word(address + 24, DONE_BYTE);
        end
    endtask

    task automatic initialize_program;
        begin
            if (XLEN == 16)
                put_rc16_alias();
            else if (test_case == 3)
                put_rc32_coherence();
            else
                put_rc32_alias();
        end
    endtask

    always @* begin
        if (stalled_last &&
            (backend_now_addr !== stalled_addr || mem_wdata !== stalled_wdata ||
             mem_wmask !== stalled_wmask || mem_we !== stalled_we ||
             !mem_cyc || !mem_stb))
            $fatal(1, "backing command changed while stalled");
    end

    always @(posedge clk) begin
        if (rst) begin
            backend_pending <= 1'b0;
            backend_delay <= 0;
            backend_addr <= 0;
            backend_data <= 0;
            cycle_count <= 0;
            backend_reads <= 0;
            backend_writes <= 0;
            response_count <= 0;
            target_line_reads <= 0;
            stalled_last <= 1'b0;
            stall_count <= 0;
            stall_release_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (stalled_last && !(mem_cyc && mem_stb && mem_stall))
                stall_release_count <= stall_release_count + 1;
            if (mem_cyc && mem_stb && mem_stall) begin
                stalled_last <= 1'b1;
                stalled_addr <= backend_now_addr;
                stalled_wdata <= mem_wdata;
                stalled_wmask <= mem_wmask;
                stalled_we <= mem_we;
                stall_count <= stall_count + 1;
            end else begin
                stalled_last <= 1'b0;
            end

            if (backend_response) response_count <= response_count + 1;

            if (!immediate_mode && backend_delay != 0 && backend_accept)
                $fatal(1, "backing accepted a second request during delay");
            if (!immediate_mode && (backend_pending || backend_delay != 0) &&
                !mem_cyc)
                $fatal(1, "backing request dropped CYC before completion");

            if (immediate_mode) begin
                backend_pending <= 1'b0;
                if (backend_accept) begin
                    if (!mem_we) backend_reads <= backend_reads + 1;
                    else begin
                        backend_writes <= backend_writes + 1;
                        apply_write(backend_now_addr, mem_wdata, mem_wmask);
                    end
                end
            end else if (backend_pending) begin
                backend_pending <= 1'b0;
                if (backend_accept) begin
                    backend_pending <= !wait_mode;
                    backend_delay <= wait_mode ? 3'd2 : 3'd0;
                    backend_addr <= backend_now_addr;
                    backend_data <= sparse_read(backend_now_addr);
                    if (!mem_we) backend_reads <= backend_reads + 1;
                    else begin
                        backend_writes <= backend_writes + 1;
                        apply_write(backend_now_addr, mem_wdata, mem_wmask);
                    end
                end
            end else if (backend_delay != 0) begin
                if (backend_delay == 1) begin
                    backend_delay <= 0;
                    backend_pending <= 1'b1;
                end
                else backend_delay <= backend_delay - 1'b1;
            end else if (backend_accept) begin
                backend_pending <= !wait_mode;
                backend_delay <= wait_mode ? 3'd2 : 3'd0;
                backend_addr <= backend_now_addr;
                backend_data <= sparse_read(backend_now_addr);
                if (!mem_we) backend_reads <= backend_reads + 1;
                else begin
                    backend_writes <= backend_writes + 1;
                    apply_write(backend_now_addr, mem_wdata, mem_wmask);
                end
            end
        end
    end

    task automatic apply_write(
        input [29:0] address, input [31:0] value, input [3:0] select);
        reg [31:0] old_word;
        reg [31:0] new_word;
        begin
            old_word = sparse_read(address);
            new_word = old_word;
            if (select[0]) new_word[7:0] = value[7:0];
            if (select[1]) new_word[15:8] = value[15:8];
            if (select[2]) new_word[23:16] = value[23:16];
            if (select[3]) new_word[31:24] = value[31:24];
            sparse_write(address, new_word);
        end
    endtask

    always @(posedge clk) begin
        if (!rst && backend_accept && !mem_we) begin
            if (XLEN == 16 &&
                mem_addr_word >= RC16_TARGET_WORD &&
                mem_addr_word < RC16_TARGET_WORD + ICACHE_LINE_WORDS_ADDR)
                target_line_reads <= target_line_reads + 1;
            if (XLEN == 32 &&
                mem_addr_word >= ((test_case == 3) ? RC32_COH_TARGET_WORD : RC32_HIGH_WORD) &&
                mem_addr_word < ((test_case == 3) ? RC32_COH_TARGET_WORD : RC32_HIGH_WORD) + ICACHE_LINE_WORDS_ADDR)
                target_line_reads <= target_line_reads + 1;
        end
    end

    task automatic fail(input [8*96-1:0] message);
        begin
            if (failed == 0) begin
                failed = 1;
                $fatal(1, "address CASE %0d XLEN=%0d: %0s", test_case,
                       XLEN, message);
            end
        end
    endtask

    initial begin
        test_case = 0;
        void'($value$plusargs("CASE=%d", test_case));
        immediate_mode = $test$plusargs("IMMEDIATE");
        wait_mode = $test$plusargs("WAIT");
        stall_mode = $test$plusargs("STALL");
        slot_count = 0;
        failed = 0;
        done_seen = 0;
        expected_writes = 0;
        for (i = 0; i < SLOT_COUNT; i = i + 1) begin
            slot_valid[i] = 1'b0;
            slot_addr[i] = 0;
            slot_data[i] = 0;
        end
        initialize_program();
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        forever begin
            @(posedge clk);
            if (backend_accept && mem_we &&
                backend_now_addr == DONE_WORD) begin
                done_seen = 1;
                repeat (12) @(posedge clk);
                if (backend_writes != expected_writes)
                    fail("backing write was duplicated or lost");
                if (XLEN == 16 &&
                    sparse_read(RESULT_WORD) !== 32'h0033_005a)
                    fail("RC16 alias/coherence result mismatch");
                if (XLEN == 32 &&
                    sparse_read(RESULT_WORD) !== 32'h0000_005a)
                    fail("RC32 high-address result mismatch");
                if (!immediate_mode && stall_mode &&
                    (stall_count == 0 || stall_release_count == 0))
                    fail("STALL mode did not hold and release a command");
                if (target_line_reads == 0)
                    fail("target instruction line was never fetched");
                if ((XLEN == 16 || (XLEN == 32 && test_case == 3)) &&
                    target_line_reads != (2 * ICACHE_LINE_WORDS))
                    fail("patched instruction line was not refilled exactly once");
                $display("PASS Cached address XLEN=%0d case=%0d reads=%0d writes=%0d target_line_reads=%0d stalls=%0d",
                         XLEN, test_case, backend_reads, backend_writes,
                         target_line_reads, stall_count);
                $finish;
            end
            if (cycle_count > 20000) begin
                fail("watchdog expired");
            end
        end
    end
endmodule

`default_nettype wire
