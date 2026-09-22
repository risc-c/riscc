// CPU clock crossing and fair CPU/video arbitration in the SDRAM domain.
`timescale 1ns/1ps
`default_nettype none
module riscc_sdram_fabric (
    input wire cpu_clk, cpu_rst, memory_clk, memory_rst,
    input wire [23:0] cpu_addr,
    input wire [31:0] cpu_wdata,
    input wire [3:0] cpu_wmask,
    input wire cpu_we, cpu_cyc, cpu_stb,
    output wire cpu_stall, cpu_ack, cpu_ready,
    output wire [31:0] cpu_rdata,
    // Video fetch requests use memory_clk; pixel clock crossing is in scanout.
    input wire [23:0] video_addr,
    input wire video_cyc, video_stb,
    output wire video_stall, video_ack,
    output wire [31:0] video_rdata,
    output wire [23:0] memory_addr,
    output wire [31:0] memory_wdata,
    output wire [3:0] memory_wmask,
    output wire memory_we,
    output wire memory_cyc,
    output wire memory_stb,
    input wire memory_stall, memory_ack, memory_ready,
    input wire [31:0] memory_rdata
);
    wire [23:0] host_addr;
    wire [31:0] host_wdata;
    wire [3:0] host_wmask;
    wire host_we, host_cyc, host_stb, host_stall, host_ack;
    riscc_sdram_bridge #(
        .ADDR_BITS(24),
        .READ_WORD_BITS(4)
    ) crossing (
        .host_clk(cpu_clk),
        .host_rst(cpu_rst),
        .memory_clk(memory_clk),
        .memory_rst(memory_rst),
        .host_addr(cpu_addr),
        .host_wdata(cpu_wdata),
        .host_wmask(cpu_wmask),
        .host_we(cpu_we),
        .host_cyc(cpu_cyc),
        .host_stb(cpu_stb),
        .host_stall(cpu_stall),
        .host_ready(cpu_ready),
        .host_ack(cpu_ack),
        .host_rdata(cpu_rdata),
        .memory_addr(host_addr),
        .memory_wdata(host_wdata),
        .memory_wmask(host_wmask),
        .memory_we(host_we),
        .memory_cyc(host_cyc),
        .memory_stb(host_stb),
        .memory_stall(host_stall),
        .memory_ack(host_ack),
        .memory_ready(memory_ready),
        .memory_rdata(memory_rdata)
    );
    // One-hot state bits select idle, CPU, video, or drain phases.
    localparam [3:0] IDLE = 4'b0001;
    reg [3:0] state_q;
    reg owner_video_q, owner_write_q, last_video_q;
    // Read grants cap at 16 words; write grants drain before changing owner.
    // Fewer than 32 commands can be pending, so counter wrap is unambiguous.
    reg [3:0] issued_q;
    reg [4:0] pending_q;
    wire host_request = host_stb;
    // Both internal producers deassert STB whenever they have no command.
    wire video_request = video_stb;
    wire choose_video = video_request && (!host_request || !last_video_q);

    // Command storage is shared with the crossing.
    wire host_direction_matches = !owner_write_q || host_we;
    assign host_stall = !state_q[1] || !host_direction_matches || memory_stall;
    assign video_stall = !state_q[2] || memory_stall;
    wire cpu_accept = host_request && !host_stall;
    wire video_accept = video_request && !video_stall;
    wire accept = cpu_accept || video_accept;
    assign memory_addr = owner_video_q ? video_addr : host_addr;
    assign memory_wdata = host_wdata;
    assign memory_wmask = owner_video_q ? 4'hf : host_wmask;
    assign memory_we = !owner_video_q && host_we;
    // The controller uses STB for admission; CYC need not delimit grants.
    assign memory_cyc = 1'b1;
    assign memory_stb = (state_q[1] && host_request && host_direction_matches) ||
                        (state_q[2] && video_request);
    wire response = memory_ack;
    // Writes are acknowledged when the controller captures their command;
    // later memory replies only drain the grant.
    assign host_ack = (host_request && host_we && state_q[1] && !memory_stall) ||
                      (response && !owner_video_q && !owner_write_q);
    assign video_ack = response && owner_video_q;
    assign video_rdata = memory_rdata;

    wire start = state_q[0] && memory_ready && (host_request || video_request);
    // End a read grant after its sixteenth acceptance.
    wire read_limit = (&issued_q[3:0]) && !memory_stall;
    wire finish_cpu = owner_write_q ?
        (video_request || (host_request && !host_we)) :
        (!host_request || read_limit);
    wire finish_video = !video_request || read_limit;
    wire drained = pending_q == 0;
    always @(posedge memory_clk) begin
        if (accept) begin
            issued_q <= issued_q + 1'b1;
        end
        if (accept != response)
            pending_q <= pending_q + (response ? -5'd1 : 5'd1);
        state_q[0] <= (state_q[0] && !start) || (state_q[3] && drained);
        state_q[1] <= (start && !choose_video) || (state_q[1] && !finish_cpu);
        state_q[2] <= (start && choose_video) || (state_q[2] && !finish_video);
        state_q[3] <= (state_q[1] && finish_cpu) || (state_q[2] && finish_video) ||
                      (state_q[3] && !drained);
        if (start) begin
            owner_video_q <= choose_video;
            owner_write_q <= !choose_video && host_we;
            last_video_q <= choose_video;
            issued_q <= 0;
            pending_q <= 0;
        end
        if (memory_rst) begin
            state_q <= IDLE;
            owner_video_q <= 0;
            owner_write_q <= 0;
            last_video_q <= 0;
            issued_q <= 0;
            pending_q <= 0;
        end
    end
endmodule
`default_nettype wire
