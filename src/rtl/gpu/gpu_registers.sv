// ============================================================
// gpu_registers  GPU_MMIO slave (RPU slave port gpu_mmio)
// ============================================================
//
// Word-only register file at soc_pkg::MAP_GPU_BASE. One-cycle slave: a
// read is combinational, a write lands on the accepting edge.
//
//   RegId                 RO  GPU_ID_VALUE
//   RegControl            RW  [0] vis_enable, [2:1] mode
//   RegStatus             RO  bus activity snapshot, one byte per
//                             master: {tpu, gpu, cpu_d, cpu_i}
//   RegFramebufferBase    RW  scratch until the framebuffer GPU exists
//   RegFramebufferWidth   RW  scratch
//   RegFramebufferHeight  RW  scratch
//   RegClearColor         RW  [23:0] background colour
//
// mode selects what the display shows: 0 = bus visualiser, 1..3 = the
// pattern_gen test patterns.
//
// The RPU already guarantees an aligned, in-range, slave-local
// address, so this slave only compares the word index.
// ============================================================

module gpu_registers (
    input  logic clk,
    input  logic rst,

    input  soc_pkg::bus_req_s req,
    output soc_pkg::bus_rsp_s rsp,

    // Configuration out (clk domain, quasi-static).
    output logic        vis_enable,
    output logic [1:0]  mode,
    output logic        pattern_invert,
    output logic [1:0]  pattern_colour,
    output logic [23:0] clear_color,

    // Bus activity, one byte per master (master 0 = cpu_i).
    input  logic [31:0] status
);

    import gpu_pkg::*;

    localparam int WORD_IDX_W = GPU_ADDR_WIDTH - 2;

    // Word index of every register (byte address / WORD_BYTES).
    localparam logic [WORD_IDX_W-1:0] IDX_ID       = RegId[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_CONTROL  = RegControl[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_STATUS   = RegStatus[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_FB_BASE  = RegFramebufferBase[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_FB_WIDTH = RegFramebufferWidth[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_FB_HEIGHT= RegFramebufferHeight[GPU_ADDR_WIDTH-1:2];
    localparam logic [WORD_IDX_W-1:0] IDX_CLEAR    = RegClearColor[GPU_ADDR_WIDTH-1:2];

    logic [WORD_IDX_W-1:0] word;

    logic [31:0] control_q;
    logic [31:0] fb_base_q;
    logic [31:0] fb_width_q;
    logic [31:0] fb_height_q;
    logic [31:0] clear_color_q;

    logic write_hit;

    function automatic logic [31:0] merge_strobes(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strobes
    );
        logic [31:0] merged;
        merged = old_value;
        for (int i = 0; i < 4; i++) begin
            if (strobes[i]) merged[i*8 +: 8] = new_value[i*8 +: 8];
        end
        return merged;
    endfunction

    assign word = req.addr[GPU_ADDR_WIDTH-1:2];

    // Unknown word index: answer with a bus error, never hang.
    assign rsp.error = (word > (GPU_REG_COUNT - 1));

    // A one-cycle slave: ready in the same cycle as valid, so the RPU
    // completes immediately and the master drops req.valid.
    assign rsp.ready = req.valid;

    assign vis_enable     = control_q[0];
    assign mode           = control_q[2:1];
    assign pattern_invert = control_q[3];
    assign pattern_colour = control_q[5:4];
    assign clear_color    = clear_color_q[23:0];

    assign write_hit =
        req.valid && (req.op == soc_pkg::BusWrite) && !rsp.error;

    // ========================================================
    // READ
    // ========================================================
    // Struct output members are driven by continuous assigns (Icarus
    // cannot member-select a struct output inside a process).
    // --------------------------------------------------------

    logic [31:0] rdata_comb;

    always_comb begin
        rdata_comb = '0;

        case (word)
            IDX_ID:        rdata_comb = GPU_ID_VALUE;
            IDX_CONTROL:   rdata_comb = control_q;
            IDX_STATUS:    rdata_comb = status;
            IDX_FB_BASE:   rdata_comb = fb_base_q;
            IDX_FB_WIDTH:  rdata_comb = fb_width_q;
            IDX_FB_HEIGHT: rdata_comb = fb_height_q;
            IDX_CLEAR:     rdata_comb = clear_color_q;
            default:       rdata_comb = '0;
        endcase
    end

    assign rsp.rdata = rdata_comb;

    // ========================================================
    // WRITE
    // ========================================================

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            control_q     <= 32'h0;
            fb_base_q     <= 32'h0;
            fb_width_q    <= 32'h0;
            fb_height_q   <= 32'h0;
            clear_color_q <= 32'h0010_2040;
        end else if (write_hit) begin
            case (word)
                IDX_CONTROL:   control_q     <= merge_strobes(control_q, req.wdata, req.wstrb);
                IDX_FB_BASE:   fb_base_q     <= merge_strobes(fb_base_q, req.wdata, req.wstrb);
                IDX_FB_WIDTH:  fb_width_q    <= merge_strobes(fb_width_q, req.wdata, req.wstrb);
                IDX_FB_HEIGHT: fb_height_q   <= merge_strobes(fb_height_q, req.wdata, req.wstrb);
                IDX_CLEAR:     clear_color_q <= merge_strobes(clear_color_q, req.wdata, req.wstrb);
                default: ;
            endcase
        end
    end

endmodule
