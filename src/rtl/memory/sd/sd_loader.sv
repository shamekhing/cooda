// ============================================================
// sd_loader  microSD card image -> DDR3, with no CPU program
// ============================================================
//
// The point of this module is that the SoC has no assembler yet, so
// there is no software that could copy a dataset off a card. Instead
// this is a small machine that does it in hardware, once, after
// reset:
//
//   1. wait for sd_controller to report the card ready
//   2. read the DDR3 window once. This is a warm-up, not a check:
//      memory_ddr3 holds requests until the PHY has calibrated, and
//      a request that is held for milliseconds would let payload
//      words stream past and be lost. One harmless read first means
//      the payload never starts while the DRAM is still coming up.
//   3. read block 0, the header (see the README for the layout)
//   4. check the header: magic, block count, and that the
//      destination lies inside the DDR3 window
//   5. stream blocks 1..N into DDR3 as bus writes
//
// The bus contract is the one the rest of the SoC uses: one
// outstanding request, valid held with a stable payload until
// ready. sd_controller emits a word every 4 byte times, which at the
// data-phase divider is about 68 clk cycles, while a DDR3 write takes
// roughly 13 - so a write always finishes before the next word. The
// overrun trap below exists so that if that margin is ever lost the
// load fails loudly instead of quietly dropping data.
//
// ERRORS (sticky, with a code for the board LEDs)
//   1 the card reported an error (or a read failed)
//   2 the header magic is wrong
//   3 the block count is zero, too large, or inconsistent with the
//     byte count
//   4 the destination does not fit in the DDR3 window
//   5 a payload word arrived while the bus was still busy
// ============================================================

module sd_loader #(
    parameter logic [31:0] DDR3_BASE  = 32'h0800_0000,
    parameter logic [31:0] DDR3_SIZE  = 32'h0800_0000,
    parameter logic [31:0] MAGIC      = 32'h434F_4F44,  // "COOD"
    parameter logic [31:0] HDR_LBA    = 32'd0,
    parameter int          MAX_BLOCKS = 65536
) (
    input  logic             clk,
    input  logic             rst,

    // block reader
    output logic             blk_req,
    output logic [31:0]      blk_addr,
    input  logic             blk_done,
    input  logic [31:0]      blk_data,
    input  logic             blk_valid,

    // card status
    input  logic             sd_ready,
    input  logic             sd_error,

    // SoC bus master
    output soc_pkg::bus_req_s bus_req,
    input  soc_pkg::bus_rsp_s bus_rsp,

    // status
    output logic             done,
    output logic             error,
    output logic [3:0]       err_code,
    output logic [31:0]      blocks_loaded,
    output logic [31:0]      bytes_loaded,
    output logic [3:0]       state_dbg
);

    localparam logic [3:0] ERR_NONE    = 4'd0,
                           ERR_SD      = 4'd1,
                           ERR_MAGIC   = 4'd2,
                           ERR_COUNT   = 4'd3,
                           ERR_RANGE   = 4'd4,
                           ERR_OVERRUN = 4'd5;

    typedef enum logic [3:0] {
        ST_WAIT  = 4'd0,    // waiting for the card
        ST_WARM  = 4'd1,    // one read of the DDR3 window
        ST_HDR   = 4'd2,    // reading block 0
        ST_CHECK = 4'd3,    // validating the header
        ST_NEXT  = 4'd4,    // asking for the next payload block
        ST_DATA  = 4'd5,    // streaming a block's words to the bus
        ST_DONE  = 4'd6,
        ST_ERROR = 4'd7
    } state_e;

    state_e      state;

    logic [31:0] hdr [0:3];     // magic, blocks, dest offset, bytes
    logic [2:0]  hdr_idx;
    logic        hdr_full;      // all four header words are in
    logic [31:0] blocks_total;
    logic [31:0] blk_idx;
    logic [31:0] dst_off;

    // One bus transaction at a time.
    logic        bus_pending;
    logic        bus_is_wr;
    logic [31:0] bus_addr;
    logic [31:0] bus_wdata;

    assign state_dbg = state;

    always_comb begin
        bus_req       = '0;
        bus_req.valid = bus_pending;
        bus_req.op    = bus_is_wr ? soc_pkg::BusWrite : soc_pkg::BusRead;
        bus_req.addr  = bus_addr;
        bus_req.wdata = bus_wdata;
        bus_req.wstrb = soc_pkg::BUS_STRB_ALL;
    end

    // The end of the payload, one bit wider so the compare cannot wrap.
    logic [32:0] dest_end;
    assign dest_end = {1'b0, hdr[2]} + {1'b0, hdr[3]};

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= ST_WAIT;
            hdr_idx       <= 3'd0;
            hdr_full      <= 1'b0;
            blocks_total  <= 32'd0;
            blk_idx       <= 32'd0;
            dst_off       <= 32'd0;
            blk_req       <= 1'b0;
            blk_addr      <= 32'd0;
            bus_pending   <= 1'b0;
            bus_is_wr     <= 1'b0;
            bus_addr      <= 32'd0;
            bus_wdata     <= 32'd0;
            done          <= 1'b0;
            error         <= 1'b0;
            err_code      <= ERR_NONE;
            blocks_loaded <= 32'd0;
            bytes_loaded  <= 32'd0;
        end else begin
            blk_req <= 1'b0;

            // The bus finishes in the background: a write counts the
            // bytes it moved, and either kind clears the pending flag.
            if (bus_pending && bus_rsp.ready) begin
                bus_pending <= 1'b0;
                if (bus_is_wr) begin
                    bytes_loaded <= bytes_loaded + 32'd4;
                    dst_off      <= dst_off + 32'd4;
                end
            end

            case (state)
                // --------------------------------------------
                // Waiting for the card's wake-up sequence.
                // --------------------------------------------
                ST_WAIT: begin
                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state    <= ST_ERROR;
                    end else if (sd_ready) begin
                        bus_addr    <= DDR3_BASE;
                        bus_is_wr   <= 1'b0;
                        bus_pending <= 1'b1;
                        state       <= ST_WARM;
                    end
                end

                // --------------------------------------------
                // The warm-up read. It is finished when the bus
                // answers, which cannot happen until the DDR3 PHY has
                // calibrated and memory_ddr3 stops holding requests.
                // --------------------------------------------
                ST_WARM: begin
                    if (!bus_pending) begin
                        blk_addr <= HDR_LBA;
                        blk_req  <= 1'b1;
                        hdr_idx  <= 3'd0;
                        hdr_full <= 1'b0;
                        state    <= ST_HDR;
                    end
                end

                // --------------------------------------------
                // Block 0: the header. Only the first four words
                // matter, but the whole block has to be clocked in.
                // --------------------------------------------
                ST_HDR: begin
                    // The block is 128 words; only the first four are
                    // the header, and the capture has to stop there
                    // rather than wrap round and overwrite itself.
                    if (blk_valid && !hdr_full) begin
                        hdr[hdr_idx] <= blk_data;
                        if (hdr_idx == 3'd3)
                            hdr_full <= 1'b1;
                        else
                            hdr_idx <= hdr_idx + 3'd1;
                    end

                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state    <= ST_ERROR;
                    end else if (blk_done) begin
                        state <= ST_CHECK;
                    end
                end

                // --------------------------------------------
                // Validate the header before trusting a single byte of
                // it: magic, a sane block count, a payload that matches
                // that count, and a destination inside the window.
                // --------------------------------------------
                ST_CHECK: begin
                    if (hdr[0] != MAGIC) begin
                        error    <= 1'b1;
                        err_code <= ERR_MAGIC;
                        state    <= ST_ERROR;
                    end else if ((hdr[1] == 32'd0) ||
                                 (hdr[1] > 32'(MAX_BLOCKS)) ||
                                 (hdr[3] > (hdr[1] << 9))) begin
                        error    <= 1'b1;
                        err_code <= ERR_COUNT;
                        state    <= ST_ERROR;
                    end else if (dest_end > {1'b0, DDR3_SIZE}) begin
                        error    <= 1'b1;
                        err_code <= ERR_RANGE;
                        state    <= ST_ERROR;
                    end else begin
                        blocks_total <= hdr[1];
                        dst_off      <= hdr[2];
                        blk_idx      <= 32'd1;
                        state        <= ST_NEXT;
                    end
                end

                // --------------------------------------------
                // Ask for the next payload block, once the bus has
                // drained: that is the only back-pressure the card side
                // needs, and it makes an overrun impossible.
                // --------------------------------------------
                ST_NEXT: begin
                    if (blk_idx > blocks_total) begin
                        if (!bus_pending)
                            state <= ST_DONE;
                    end else if (!bus_pending) begin
                        blk_addr <= HDR_LBA + blk_idx;
                        blk_req  <= 1'b1;
                        state    <= ST_DATA;
                    end
                end

                // --------------------------------------------
                // One block: every word becomes a bus write at
                // DDR3_BASE + the destination offset.
                // --------------------------------------------
                ST_DATA: begin
                    if (blk_valid) begin
                        if (bus_pending) begin
                            // Would mean the bus is slower than the
                            // card, which the margins say cannot
                            // happen. Fail loudly if it ever does.
                            error    <= 1'b1;
                            err_code <= ERR_OVERRUN;
                            state    <= ST_ERROR;
                        end else begin
                            bus_addr    <= DDR3_BASE + dst_off;
                            bus_wdata   <= blk_data;
                            bus_is_wr   <= 1'b1;
                            bus_pending <= 1'b1;
                        end
                    end

                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state    <= ST_ERROR;
                    end else if (blk_done) begin
                        blk_idx       <= blk_idx + 32'd1;
                        blocks_loaded <= blocks_loaded + 32'd1;
                        state         <= ST_NEXT;
                    end
                end

                // --------------------------------------------
                // The whole image is in DDR3.
                // --------------------------------------------
                ST_DONE: begin
                    done <= 1'b1;
                end

                // --------------------------------------------
                // Sticky failure.
                // --------------------------------------------
                ST_ERROR: begin
                    error <= 1'b1;
                end

                default: state <= ST_ERROR;
            endcase
        end
    end

endmodule

