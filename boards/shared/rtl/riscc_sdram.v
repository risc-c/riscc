// Queued 32-bit bus controller for four-bank x16 or x32 SDR SDRAM.
// Commands launch on rising clk edges. Board wrappers supply the device clock
// and I/O capture; INPUT_REGISTERED=0 instead uses the internal falling-edge
// sampler. READ_DELAY aligns acknowledgments with the board's input pipeline.
`timescale 1ns/1ps
`default_nettype none

module riscc_sdram #(
    parameter integer DATA_BITS = 16,
    parameter integer ROW_BITS = 13,
    parameter integer COL_BITS = 9,
    parameter integer ADDR_BITS = ROW_BITS + COL_BITS + 2 - (DATA_BITS == 16 ? 1 : 0),
    parameter integer CLK_MHZ = 50,
    parameter integer INIT_CYCLES = CLK_MHZ * 200,
    // Refresh early enough to include draining the bounded command pipeline.
    parameter integer REFRESH_CYCLES = (CLK_MHZ * 64000 / (1 << ROW_BITS)) - 32,
    parameter integer CAS = 3,
    parameter integer TRCD = (20 * CLK_MHZ + 999) / 1000,
    parameter integer TRP = (20 * CLK_MHZ + 999) / 1000,
    parameter integer TRFC = (80 * CLK_MHZ + 999) / 1000,
    parameter integer TRAS = (45 * CLK_MHZ + 999) / 1000,
    parameter integer TWR = ((15 * CLK_MHZ + 999) / 1000 < 2) ?
                            2 : (15 * CLK_MHZ + 999) / 1000,
    parameter integer INPUT_REGISTERED = 0,
    parameter integer PIN_PIPELINE = 0,
    // Additional complete clock periods in the board read-return path.
    parameter integer READ_DELAY = 0,
    parameter integer FIFO_BITS = 3
) (
    input wire clk, rst,
    input wire [ADDR_BITS-1:0] mem_addr,
    input wire [31:0] mem_wdata,
    input wire [3:0] mem_wmask,
    input wire mem_we, mem_cyc, mem_stb,
    output wire mem_stall,
    output reg mem_ack,
    output reg [31:0] mem_rdata,
    output reg ready,
    output wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
    output reg [12:0] sd_addr,
    output reg [1:0] sd_ba,
    output reg [DATA_BITS/8-1:0] sd_dqm,
    input wire [DATA_BITS-1:0] sd_dq_i,
    output reg [DATA_BITS-1:0] sd_dq_o,
    output reg sd_dq_oe
);
    localparam integer HALF = (DATA_BITS == 16 ? 1 : 0);
    localparam integer DEPTH = 1 << FIFO_BITS;
    localparam [FIFO_BITS:0] FIFO_FULL = {1'b1, {FIFO_BITS{1'b0}}};
    localparam [12:0] MODE_VALUE = {3'b000, 1'b0, 2'b00, CAS[2:0], 1'b0, 2'b00, HALF[0]};
    localparam [3:0] NOP = 4'b0111, ACTIVE = 4'b0011,
        READ = 4'b0101, WRITE = 4'b0100, PRE = 4'b0010,
        REFRESH = 4'b0001, MODE = 4'b0000;
    localparam [3:0] POWERUP = 0, INIT_PRE = 1, INIT_REFRESH = 2,
        INIT_MODE = 4, RUN = 5, REF_PRE = 6, REF_CMD = 7,
        ROW_PRE = 8, ROW_ACTIVE = 9;
    reg [3:0] state_q, command_q;
    reg [2:0] init_refresh_q;
    localparam integer DELAY_BITS = $clog2(TRFC + TRCD + TRP + 4);
    localparam integer INIT_BITS = $clog2(INIT_CYCLES + 1);
    localparam integer REFRESH_BITS = $clog2(REFRESH_CYCLES + 1);
    localparam integer RECOVERY_BITS = $clog2(TWR + CAS + HALF + PIN_PIPELINE + READ_DELAY + 5);
    localparam integer ACTIVE_BITS = $clog2(TRAS + 1);
    localparam integer INIT_WAIT = INIT_CYCLES - 1, REFRESH_WAIT = REFRESH_CYCLES - 1;
    localparam integer RP_WAIT = TRP - 1, RFC_WAIT = TRFC - 1, RCD_WAIT = TRCD - 1;
    localparam integer RAS_WAIT = TRAS - 1;
    localparam integer WRITE_WAIT = TWR + HALF + PIN_PIPELINE + 1,
        READ_WAIT = CAS + HALF + PIN_PIPELINE + READ_DELAY + 3;
    reg [DELAY_BITS-1:0] delay_q;
    reg delay_done_q, init_done_q;
    reg [INIT_BITS-1:0] init_count_q;
    reg [REFRESH_BITS-1:0] refresh_q;
    reg refresh_due_q;
    reg [RECOVERY_BITS-1:0] recovery_q;
    reg [ACTIVE_BITS-1:0] active_age_q;
    reg [3:0] open_q;
    reg [ROW_BITS-1:0] rows_q [0:3];
    reg [ADDR_BITS-1:0] addr_fifo [0:DEPTH-1];
    reg [31:0] data_fifo [0:DEPTH-1];
    reg [3:0] mask_fifo [0:DEPTH-1];
    reg we_fifo [0:DEPTH-1];
    reg [FIFO_BITS-1:0] rd_q, wr_q;
    reg [FIFO_BITS:0] count_q;
    reg full_q, empty_q;
    // Two prefetch slots absorb a cycle of backpressure without routing
    // command issue back through the request FIFO's occupancy counter.
    reg [ADDR_BITS-1:0] pref_addr [0:1];
    reg [31:0] pref_data [0:1];
    reg [3:0] pref_mask [0:1];
    reg pref_we [0:1];
    reg pref_rd_q, pref_wr_q;
    reg [1:0] pref_count_q;
    wire pref_valid_q = pref_count_q != 0;
    wire [ADDR_BITS-1:0] pref_addr_q = pref_addr[pref_rd_q];
    wire [31:0] pref_data_q = pref_data[pref_rd_q];
    wire [3:0] pref_mask_q = pref_mask[pref_rd_q];
    wire pref_we_q = pref_we[pref_rd_q];
    reg lookup_valid_q;
    reg [ADDR_BITS-1:0] lookup_addr_q;
    reg [31:0] lookup_data_q;
    reg [3:0] lookup_mask_q;
    reg lookup_we_q;
    reg head_valid_q;
    reg [ADDR_BITS-1:0] head_addr_q;
    reg [31:0] head_data_q;
    reg [3:0] head_mask_q;
    reg head_we_q;
    wire [DATA_BITS-1:0] dq_sample_q;
    generate if (INPUT_REGISTERED != 0) begin : g_external_capture
        assign dq_sample_q = sd_dq_i;
    end else begin : g_fabric_capture
        reg [DATA_BITS-1:0] sample_q;
        always @(negedge clk) sample_q <= sd_dq_i;
        assign dq_sample_q = sample_q;
    end endgenerate
    reg [CAS+HALF+PIN_PIPELINE+READ_DELAY:0] read_pipe_q;
    reg [HALF+PIN_PIPELINE:0] write_pipe_q;
    reg [15:0] read_low_q, write_high_q;
    reg [1:0] mask_high_q;
    reg burst_q, head_same_direction_q, run_ready_q, recovered_q, bank_safe_q;

    wire [ADDR_BITS+HALF-1:0] physical_addr = {head_addr_q, {HALF{1'b0}}};
    wire [COL_BITS-1:0] column = physical_addr[COL_BITS-1:0];
    wire [1:0] bank = physical_addr[COL_BITS +: 2];
    wire [ROW_BITS-1:0] row = physical_addr[COL_BITS+2 +: ROW_BITS];
    wire writing = head_we_q;
    reg [3:0] head_hits_q;
    wire row_hit = |head_hits_q;
    wire [ADDR_BITS+HALF-1:0] next_physical = {lookup_addr_q, {HALF{1'b0}}};
    wire [1:0] next_bank = next_physical[COL_BITS +: 2];
    wire [ROW_BITS-1:0] next_row = next_physical[COL_BITS+2 +: ROW_BITS];
    wire [3:0] next_hits;
    genvar row_bank;
    generate for (row_bank = 0; row_bank < 4; row_bank = row_bank + 1) begin : g_row_hit
        assign next_hits[row_bank] = open_q[row_bank] && (next_bank == row_bank[1:0]) &&
                                    (rows_q[row_bank] == next_row);
    end endgenerate
    wire direction_ok = head_same_direction_q || recovered_q;
    wire issue = run_ready_q && row_hit && direction_ok;
    wire load_head = (!head_valid_q || issue) && lookup_valid_q;
    wire load_lookup = (!lookup_valid_q || !head_valid_q || issue) && pref_valid_q;
    wire pop = !pref_count_q[1] && !empty_q;
    wire write_first = issue && writing;
    wire accept = mem_cyc && mem_stb && !mem_stall;
    reg blocked_q;
    assign mem_stall = blocked_q;
    always @(posedge clk) begin
        blocked_q <= !ready || (!pop &&
            (full_q || (accept && count_q == FIFO_FULL - 1'b1)));
        if (rst) blocked_q <= 1;
    end
    assign sd_cke = 1'b1;
    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = command_q;

    initial begin
        if ((DATA_BITS != 16 && DATA_BITS != 32) || ROW_BITS > 13 ||
            COL_BITS > 10 || COL_BITS < 2 || CAS < 2 || CAS > 3 ||
            ADDR_BITS != ROW_BITS + COL_BITS + 2 - HALF || FIFO_BITS < 1 ||
            TRCD < 1 || TRP < 1 || TRFC < 1 || TRAS < 1 || TWR < 1 ||
            REFRESH_CYCLES < 1 || INIT_CYCLES < 1 || READ_DELAY < 0)
            $error("riscc_sdram: invalid geometry or timing");
    end

    always @(posedge clk) begin
        command_q <= NOP;
        // Register the long state/timer eligibility decode. Recovery is long
        // enough to include every read/write pipeline stage, so a separate
        // reduction of those pipelines is unnecessary on the issue path.
        run_ready_q <= state_q == RUN && !(|(delay_q >> 1)) && (|(refresh_q >> 1)) &&
                       !(issue && HALF != 0);
        recovered_q <= !(|(recovery_q >> 1));
        bank_safe_q <= !(|(recovery_q >> 1)) && !(|(active_age_q >> 1));
        // DQ is meaningful only while OE is asserted. Keep its pipeline
        // unconditional instead of routing command eligibility through data enables.
        sd_dq_oe <= write_first || burst_q;
        sd_dq_o <= burst_q ? {{(DATA_BITS-16){1'b0}}, write_high_q} :
                              head_data_q[DATA_BITS-1:0];
        sd_dqm <= {DATA_BITS/8{!ready}} |
                  (~head_mask_q[DATA_BITS/8-1:0] & {DATA_BITS/8{write_first}}) |
                  ({{(DATA_BITS/8-2){1'b0}}, mask_high_q} & {DATA_BITS/8{burst_q}});
        write_high_q <= head_data_q[31:16];
        mask_high_q <= ~head_mask_q[3:2];
        mem_ack <= 1'b0;
        read_pipe_q <= read_pipe_q << 1;
        write_pipe_q <= write_pipe_q << 1;
        burst_q <= 1'b0;
        if (!init_done_q) begin
            init_count_q <= init_count_q - 1'b1;
            init_done_q <= !(|(init_count_q >> 1));
        end
        delay_done_q <= !(|(delay_q >> 1));
        if (delay_q != 0) delay_q <= delay_q - 1'b1;
        if (recovery_q != 0) recovery_q <= recovery_q - 1'b1;
        if (active_age_q != 0) active_age_q <= active_age_q - 1'b1;
        if (ready) refresh_due_q <= !(|(refresh_q >> 1));
        if (ready && !refresh_due_q) refresh_q <= refresh_q - 1'b1;

        // The unoccupied tail may sample speculatively. Only acceptance
        // advances the pointer and makes that payload visible to the reader.
        if (!full_q) begin
            addr_fifo[wr_q] <= mem_addr;
            data_fifo[wr_q] <= mem_wdata;
            mask_fifo[wr_q] <= mem_wmask;
            we_fifo[wr_q] <= mem_we;
        end
        if (accept) wr_q <= wr_q + 1'b1;
        if (pop) begin
            pref_addr[pref_wr_q] <= addr_fifo[rd_q];
            pref_data[pref_wr_q] <= data_fifo[rd_q];
            pref_mask[pref_wr_q] <= mask_fifo[rd_q];
            pref_we[pref_wr_q] <= we_fifo[rd_q];
            pref_wr_q <= !pref_wr_q;
            rd_q <= rd_q + 1'b1;
        end
        if (load_lookup) pref_rd_q <= !pref_rd_q;
        pref_count_q[0] <= pref_count_q[0] ^ pop ^ load_lookup;
        pref_count_q[1] <= !load_lookup && (pref_count_q[1] || (pref_count_q[0] && pop));
        if (!lookup_valid_q || !head_valid_q || issue) begin
            lookup_addr_q <= pref_addr_q;
            lookup_data_q <= pref_data_q;
            lookup_mask_q <= pref_mask_q;
            lookup_we_q <= pref_we_q;
        end
        lookup_valid_q <= pref_valid_q || (lookup_valid_q && head_valid_q && !issue);
        // Head hits also encode validity, so command issue needs no separate
        // head-valid decode. A vacant head tracks the next prefetched row.
        head_hits_q <= (head_hits_q & {4{!(run_ready_q && direction_ok)}}) |
                       (next_hits & {4{load_head}});
        if (!head_valid_q || issue) begin
            head_addr_q <= lookup_addr_q;
            head_data_q <= lookup_data_q;
            head_mask_q <= lookup_mask_q;
        end
        if (load_head) begin
            head_we_q <= lookup_we_q;
            head_same_direction_q <= lookup_we_q == head_we_q;
        end
        head_valid_q <= lookup_valid_q || (head_valid_q && !issue);
        // Explicit next-state flags avoid a serial pop/accept clock-enable
        // mux on the FIFO-to-command backpressure path.
        full_q <= !pop && (full_q || (accept && count_q == FIFO_FULL - 1'b1));
        empty_q <= !accept && (empty_q || (pop && count_q == 1));
        case ({accept, pop})
            2'b10: count_q <= count_q + 1'b1;
            2'b01: count_q <= count_q - 1'b1;
            default: ;
        endcase

        // SDR data launches CAS-1 edges after READ and is captured at the
        // following device edge (CAS). Assemble on the next fabric edge.
        if (HALF != 0 && read_pipe_q[CAS+PIN_PIPELINE+READ_DELAY]) read_low_q <= dq_sample_q[15:0];
        if (read_pipe_q[CAS+HALF+PIN_PIPELINE+READ_DELAY]) begin
            mem_rdata <= HALF != 0 ? {dq_sample_q[15:0], read_low_q} : {{(32-DATA_BITS){1'b0}}, dq_sample_q};
            mem_ack <= 1'b1;
        end
        if (write_pipe_q[HALF+PIN_PIPELINE]) mem_ack <= 1'b1;

        if (issue) begin
            recovered_q <= 0;
            bank_safe_q <= 0;
            command_q <= writing ? WRITE : READ;
            sd_addr <= {{(13-COL_BITS){1'b0}}, column};
            sd_ba <= bank;
            burst_q <= HALF != 0 && writing;
            if (writing) begin
                write_pipe_q[0] <= 1'b1;
                recovery_q <= WRITE_WAIT[RECOVERY_BITS-1:0];
            end else begin
                read_pipe_q[0] <= 1'b1;
                recovery_q <= READ_WAIT[RECOVERY_BITS-1:0];
            end
        end

        if (delay_done_q) begin
            case (state_q)
                POWERUP: if (init_done_q) state_q <= INIT_PRE;
                INIT_PRE: begin
                    command_q <= PRE;
                    sd_addr <= 13'h400;
                    delay_q <= RP_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RP_WAIT == 0;
                    state_q <= INIT_REFRESH;
                end
                INIT_REFRESH: begin
                    command_q <= REFRESH;
                    delay_q <= RFC_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RFC_WAIT == 0;
                    init_refresh_q <= init_refresh_q + 1'b1;
                    state_q <= (&init_refresh_q) ? INIT_MODE : INIT_REFRESH;
                end
                INIT_MODE: begin
                    command_q <= MODE;
                    sd_addr <= MODE_VALUE; // sequential BL1/BL2, burst writes
                    sd_ba <= 0;
                    delay_q <= 2;
                    delay_done_q <= 0;
                    state_q <= RUN;
                end
                RUN: begin
                    ready <= 1'b1;
                    if (refresh_due_q) begin
                        if (bank_safe_q)
                            state_q <= REF_PRE;
                    end else if (head_valid_q && !row_hit && bank_safe_q) begin
                        state_q <= open_q[bank] ? ROW_PRE : ROW_ACTIVE;
                        run_ready_q <= 0;
                    end
                end
                ROW_PRE: begin
                    command_q <= PRE;
                    sd_ba <= bank;
                    sd_addr <= 0;
                    open_q[bank] <= 0;
                    delay_q <= RP_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RP_WAIT == 0;
                    state_q <= RUN;
                end
                ROW_ACTIVE: begin
                    command_q <= ACTIVE;
                    sd_ba <= bank;
                    sd_addr <= {{(13-ROW_BITS){1'b0}}, row};
                    open_q[bank] <= 1;
                    head_hits_q <= 4'b1111;
                    rows_q[bank] <= row;
                    bank_safe_q <= 0;
                    run_ready_q <= (TRCD == 1) && (|(refresh_q >> 1));
                    delay_q <= RCD_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RCD_WAIT == 0;
                    active_age_q <= RAS_WAIT[ACTIVE_BITS-1:0];
                    state_q <= RUN;
                end
                REF_PRE: begin
                    command_q <= PRE;
                    sd_addr <= 13'h400;
                    open_q <= 0;
                    head_hits_q <= 0;
                    delay_q <= RP_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RP_WAIT == 0;
                    state_q <= REF_CMD;
                end
                REF_CMD: begin
                    command_q <= REFRESH;
                    delay_q <= RFC_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RFC_WAIT == 0;
                    refresh_q <= REFRESH_WAIT[REFRESH_BITS-1:0];
                    refresh_due_q <= REFRESH_WAIT == 0;
                    state_q <= RUN;
                end
                default: state_q <= POWERUP;
            endcase
        end

        if (rst) begin
            command_q <= NOP;
            state_q <= POWERUP;
            init_refresh_q <= 0;
            delay_q <= 0;
            delay_done_q <= 1;
            init_count_q <= INIT_WAIT[INIT_BITS-1:0];
            init_done_q <= INIT_WAIT == 0;
            refresh_q <= REFRESH_WAIT[REFRESH_BITS-1:0];
                    refresh_due_q <= REFRESH_WAIT == 0;
            recovery_q <= 0;
            active_age_q <= 0;
            open_q <= 0;
            ready <= 1'b0;
            rd_q <= 0;
            wr_q <= 0;
            count_q <= 0;
            full_q <= 0; empty_q <= 1;
            run_ready_q <= 0;
            recovered_q <= 1;
            bank_safe_q <= 1;
            head_valid_q <= 0;
            lookup_valid_q <= 0;
            pref_count_q <= 0; pref_rd_q <= 0; pref_wr_q <= 0;
            head_hits_q <= 0;
            read_pipe_q <= 0;
            write_pipe_q <= 0;
            burst_q <= 0;
            head_same_direction_q <= 1; head_we_q <= 0;
            sd_dqm <= {DATA_BITS/8{1'b1}};
            sd_dq_oe <= 0;
            mem_ack <= 0;
        end
    end
endmodule

`default_nettype wire
