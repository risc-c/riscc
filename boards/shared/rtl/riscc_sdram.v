// Queued 32-bit bus controller for four-bank x16 or x32 SDR SDRAM.
// Commands launch on rising clk edges. Board wrappers supply the device clock
// and I/O capture; INPUT_REGISTERED=0 instead uses the internal falling-edge
// sampler. READ_DELAY aligns acknowledgments with the board's input pipeline.
`timescale 1ns/1ps
`default_nettype none

module riscc_sdram #(
    parameter integer DATA_BITS = 16,
    // Match a registered I/O tristate input without an output-side inverter.
    parameter integer OE_ACTIVE_LOW = 0,
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
    localparam [12:0] MODE_VALUE = {3'b000, 1'b0, 2'b00, CAS[2:0], 1'b0, 2'b00, HALF[0]};
    localparam [3:0] NOP = 4'b0111, ACTIVE = 4'b0011,
        READ = 4'b0101, WRITE = 4'b0100, PRE = 4'b0010,
        REFRESH = 4'b0001, MODE = 4'b0000;
    localparam [3:0] POWERUP = 0, INIT_PRE = 1, INIT_REFRESH = 2,
        INIT_MODE = 4, RUN = 5, REF_PRE = 6, REF_CMD = 7,
        ROW_PRE = 8, ROW_ACTIVE = 9;
    reg [3:0] state_q, command_q;
    reg [2:0] init_refresh_q;
    localparam integer ROW_DELAY = TRCD > TRP ? TRCD : TRP;
    localparam integer MAX_DELAY = TRFC > ROW_DELAY ? TRFC : ROW_DELAY;
    localparam integer DELAY_BITS = $clog2(MAX_DELAY > 3 ? MAX_DELAY : 3);
    localparam integer INIT_BITS = $clog2(INIT_CYCLES + 1);
    localparam integer REFRESH_BITS = $clog2(REFRESH_CYCLES + 1);
    localparam integer RECOVERY_BITS = $clog2(TWR + CAS + HALF + PIN_PIPELINE + READ_DELAY + 5);
    localparam integer ACTIVE_BITS = TRAS > 1 ? $clog2(TRAS) : 1;
    localparam integer INIT_WAIT = INIT_CYCLES - 1, REFRESH_WAIT = REFRESH_CYCLES - 1;
    localparam integer RP_WAIT = TRP - 1, RFC_WAIT = TRFC - 1, RCD_WAIT = TRCD - 1;
    localparam integer RAS_WAIT = TRAS - 1;
    localparam integer WRITE_WAIT = TWR + HALF + PIN_PIPELINE + 1,
        READ_WAIT = CAS + HALF + PIN_PIPELINE + READ_DELAY + 3;
    reg [DELAY_BITS-1:0] delay_q;
    reg delay_done_q, init_done_q;
    localparam integer TIMER_BITS = INIT_BITS > REFRESH_BITS ? INIT_BITS : REFRESH_BITS;
    // This timer covers power-up delay first, then periodic refresh.
    reg [TIMER_BITS-1:0] timer_q;
    wire [TIMER_BITS-1:0] timer_next = timer_q - 1'b1;
    wire [REFRESH_BITS-1:0] refresh_q = timer_q[REFRESH_BITS-1:0];
    reg refresh_due_q;
    reg [RECOVERY_BITS-1:0] recovery_q;
    reg [ACTIVE_BITS-1:0] active_age_q;
    reg [3:0] open_q;
    (* ram_style = "distributed", ramstyle = "MLAB" *)
    reg [ROW_BITS-1:0] rows_q [0:3];
    // Keep commands in RAM until lookup or issue needs them. Address and
    // payload readers advance independently in acceptance order.
    // Capacity covers DEPTH queued commands, two admission slots, lookup,
    // and the active head. Rounding up leaves room for unread payloads.
    localparam integer PAYLOAD_BITS = $clog2(DEPTH + 4);
    reg [35:0] payload [0:(1 << PAYLOAD_BITS)-1];
    reg [PAYLOAD_BITS-1:0] payload_wr_q;
    reg [PAYLOAD_BITS-1:0] payload_head_q;
    reg [ADDR_BITS:0] request_mem [0:(1 << PAYLOAD_BITS)-1];
    reg [PAYLOAD_BITS-1:0] request_lookup_q;
    reg [FIFO_BITS-1:0] rd_q;
    wire [FIFO_BITS-1:0] wr_q = payload_wr_q[FIFO_BITS-1:0];
    reg full_q, empty_q;
    // Two admission credits absorb a cycle of backpressure without routing
    // command issue back through the request FIFO's full/empty logic.
    // Payloads stay in RAM; these credits carry no copied address or data.
    reg [1:0] pref_count_q;
    wire pref_valid_q = pref_count_q != 0;
    reg lookup_valid_q;
    reg [ADDR_BITS-1:0] lookup_addr_q;
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
    localparam integer ROW_SLICE_BITS = 3;
    localparam integer ROW_PARTS = (ROW_BITS + ROW_SLICE_BITS - 1) / ROW_SLICE_BITS;
    reg [ROW_PARTS-1:0] head_hit_q;
    // ACTIVATE satisfies this head without rewriting the saved comparisons.
    reg head_open_q, head_activated_q;
    wire row_hit = head_valid_q &&
                   (head_activated_q || (head_open_q && (&head_hit_q)));
    wire [ADDR_BITS+HALF-1:0] next_physical = {lookup_addr_q, {HALF{1'b0}}};
    wire [1:0] next_bank = next_physical[COL_BITS +: 2];
    wire [ROW_BITS-1:0] next_row = next_physical[COL_BITS+2 +: ROW_BITS];
    wire [ROW_BITS-1:0] next_open_row = rows_q[next_bank];
    // Compare short row slices in parallel at the existing head boundary.
    // This keeps the RAM lookup off the full-row compare's critical path.
    wire [ROW_PARTS-1:0] next_hit;
    genvar part;
    generate
        for (part = 0; part < ROW_PARTS; part = part + 1) begin : g_row_hit
            localparam integer OFFSET = part * ROW_SLICE_BITS;
            localparam integer BITS = ROW_BITS - OFFSET < ROW_SLICE_BITS ?
                                      ROW_BITS - OFFSET : ROW_SLICE_BITS;
            assign next_hit[part] = next_open_row[OFFSET +: BITS] == next_row[OFFSET +: BITS];
        end
    endgenerate
    wire direction_ok = head_same_direction_q || recovered_q;
    wire issue = run_ready_q && row_hit && direction_ok;
    wire load_head = (!head_valid_q || issue) && lookup_valid_q;
    wire load_lookup = (!lookup_valid_q || !head_valid_q || issue) && pref_valid_q;
    wire pop = !pref_count_q[1] && !empty_q;
    wire write_first = issue && writing;
    wire accept = mem_cyc && mem_stb && !mem_stall;
    // FIFO credits count accepted commands not yet promoted to lookup.
    // Full and empty flags distinguish equal pointers after wraparound.
    wire [FIFO_BITS-1:0] next_wr = wr_q + 1'b1;
    wire [FIFO_BITS-1:0] next_rd = rd_q + 1'b1;
    wire last_free = next_wr == rd_q;
    wire last_used = next_rd == wr_q;
    reg blocked_q;
    assign mem_stall = blocked_q;
    always @(posedge clk) begin
        // With one slot left, a ready controller accepts the offered command.
        // Keep STALL feedback out of the fullness prediction.
        blocked_q <= !ready || (!pop &&
            (full_q || (mem_cyc && mem_stb && last_free)));
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
        // Track when timing, refresh, and direction permit a new command.
        run_ready_q <= state_q == RUN && !(|(delay_q >> 1)) && (|(refresh_q >> 1)) &&
                       !(issue && HALF != 0);
        recovered_q <= !(|(recovery_q >> 1));
        bank_safe_q <= !(|(recovery_q >> 1)) && !(|(active_age_q >> 1));
        // DQ updates continuously; only sd_dq_oe enables its output drivers.
        sd_dq_oe <= (write_first || burst_q) ^ (OE_ACTIVE_LOW != 0);
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
            timer_q <= timer_next;
            init_done_q <= !(|(timer_q >> 1));
            if (!(|(timer_q >> 1))) timer_q <= REFRESH_WAIT[TIMER_BITS-1:0];
        end
        delay_done_q <= !(|(delay_q >> 1));
        if (delay_q != 0) delay_q <= delay_q - 1'b1;
        if (recovery_q != 0) recovery_q <= recovery_q - 1'b1;
        if (active_age_q != 0) active_age_q <= active_age_q - 1'b1;
        if (ready) refresh_due_q <= !(|(refresh_q >> 1));
        if (ready && !refresh_due_q) timer_q <= timer_next;

        // Sample the free tail speculatively; only acceptance advances it.
        if (!full_q) begin
            request_mem[payload_wr_q] <= {mem_we, mem_addr};
            payload[payload_wr_q] <= {mem_wmask, mem_wdata};
        end
        if (accept) payload_wr_q <= payload_wr_q + 1'b1;
        if (pop) begin
            rd_q <= next_rd;
        end
        if (load_lookup) request_lookup_q <= request_lookup_q + 1'b1;
        pref_count_q[0] <= pref_count_q[0] ^ pop ^ load_lookup;
        pref_count_q[1] <= !load_lookup && (pref_count_q[1] || (pref_count_q[0] && pop));
        if (!lookup_valid_q || !head_valid_q || issue) begin
            {lookup_we_q, lookup_addr_q} <= request_mem[request_lookup_q];
        end
        lookup_valid_q <= pref_valid_q || (lookup_valid_q && head_valid_q && !issue);
        if (load_head) begin
            head_hit_q <= next_hit;
            head_open_q <= open_q[next_bank];
            head_activated_q <= 0;
        end
        if (!head_valid_q || issue) begin
            head_addr_q <= lookup_addr_q;
            {head_mask_q, head_data_q} <= payload[payload_head_q];
        end
        if (load_head) begin
            payload_head_q <= payload_head_q + 1'b1;
            head_we_q <= lookup_we_q;
            head_same_direction_q <= lookup_we_q == head_we_q;
        end
        head_valid_q <= lookup_valid_q || (head_valid_q && !issue);
        // Advance FIFO flags after acceptance and promotion.
        full_q <= !pop && (full_q || (accept && last_free));
        empty_q <= !accept && (empty_q || (pop && last_used));

        // SDR data launches CAS-1 edges after READ and is captured at the
        // following device edge (CAS). Assemble on the next fabric edge.
        if (HALF != 0 && read_pipe_q[CAS+PIN_PIPELINE+READ_DELAY])
            read_low_q <= dq_sample_q[15:0];
        if (read_pipe_q[CAS+HALF+PIN_PIPELINE+READ_DELAY]) begin
            mem_rdata <= HALF != 0 ? {dq_sample_q[15:0], read_low_q} :
                         {{(32-DATA_BITS){1'b0}}, dq_sample_q};
            mem_ack <= 1'b1;
        end
        if (write_pipe_q[HALF+PIN_PIPELINE])
            mem_ack <= 1'b1;

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
                    head_activated_q <= 1;
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
                    head_open_q <= 1'b0;
                    head_activated_q <= 0;
                    delay_q <= RP_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RP_WAIT == 0;
                    state_q <= REF_CMD;
                end
                REF_CMD: begin
                    command_q <= REFRESH;
                    delay_q <= RFC_WAIT[DELAY_BITS-1:0];
                    delay_done_q <= RFC_WAIT == 0;
                    timer_q <= REFRESH_WAIT[TIMER_BITS-1:0];
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
            init_done_q <= INIT_WAIT == 0;
            timer_q <= INIT_WAIT == 0 ? REFRESH_WAIT[TIMER_BITS-1:0] : INIT_WAIT[TIMER_BITS-1:0];
            refresh_due_q <= REFRESH_WAIT == 0;
            recovery_q <= 0;
            active_age_q <= 0;
            open_q <= 0;
            ready <= 1'b0;
            rd_q <= 0;
            payload_wr_q <= 0;
            payload_head_q <= 0;
            full_q <= 0;
            empty_q <= 1;
            run_ready_q <= 0;
            recovered_q <= 1;
            bank_safe_q <= 1;
            head_valid_q <= 0;
            lookup_valid_q <= 0;
            pref_count_q <= 0;
            request_lookup_q <= 0;
            head_open_q <= 1'b0;
            head_activated_q <= 0;
            read_pipe_q <= 0;
            write_pipe_q <= 0;
            burst_q <= 0;
            head_same_direction_q <= 1;
            head_we_q <= 0;
            sd_dqm <= {DATA_BITS/8{1'b1}};
            sd_dq_oe <= (OE_ACTIVE_LOW != 0);
            mem_ack <= 0;
        end
    end
endmodule

`default_nettype wire
