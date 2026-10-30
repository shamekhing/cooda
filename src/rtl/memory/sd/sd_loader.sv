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
// ready. A new payload word is emitted every 4 byte transfers. At
// 13.5 MHz SPI that is at least 4 * 8 * 2 / 27 MHz = 2.37 us per
// word, ignoring byte-engine gaps. The DDR write path takes two
// halfword commands and a CDC round-trip, so its rate must be measured
// end to end; the overrun trap catches a bus path that cannot keep up.
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
    output logic             block_req,
    output logic [31:0]      block_addr,
    input  logic             block_done,
    input  logic [31:0]      block_data,
    input  logic             block_valid,

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
        LoaderWait         = 4'd0,   // waiting for the card
        LoaderWarmRead     = 4'd1,   // one read of the DDR3 window
        LoaderReadHeader   = 4'd2,   // reading block 0
        LoaderCheckHeader  = 4'd3,   // validating the header
        LoaderNextBlock    = 4'd4,   // asking for the next payload block
        LoaderWritePayload = 4'd5,   // streaming a block's words to the bus
        LoaderDone         = 4'd6,
        LoaderError        = 4'd7
    } loader_state_e;

    loader_state_e      state_q;

    logic [31:0] header_words [0:3];     // magic, blocks, dest offset, bytes
    logic [2:0]  header_index;
    logic        header_complete;      // all four header words are in
    logic [31:0] payload_blocks;
    logic [31:0] block_index;
    logic [31:0] dest_offset;

    // One bus transaction at a time.
    logic        bus_pending;
    logic        bus_is_wr;
    logic [31:0] bus_addr;
    logic [31:0] bus_wdata;

    assign state_dbg = state_q;

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
    assign dest_end = {1'b0, header_words[2]} + {1'b0, header_words[3]};

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q         <= LoaderWait;
            header_index       <= 3'd0;
            header_complete      <= 1'b0;
            payload_blocks  <= 32'd0;
            block_index       <= 32'd0;
            dest_offset       <= 32'd0;
            block_req       <= 1'b0;
            block_addr      <= 32'd0;
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
            block_req <= 1'b0;

            // The bus finishes in the background: a write counts the
            // bytes it moved, and either kind clears the pending flag.
            if (bus_pending && bus_rsp.ready) begin
                bus_pending <= 1'b0;
                if (bus_is_wr) begin
                    bytes_loaded <= bytes_loaded + 32'd4;
                    dest_offset      <= dest_offset + 32'd4;
                end
            end

            case (state_q)
                // --------------------------------------------
                // Waiting for the card's wake-up sequence.
                // --------------------------------------------
                LoaderWait: begin
                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state_q    <= LoaderError;
                    end else if (sd_ready) begin
                        bus_addr    <= DDR3_BASE;
                        bus_is_wr   <= 1'b0;
                        bus_pending <= 1'b1;
                        state_q       <= LoaderWarmRead;
                    end
                end

                // --------------------------------------------
                // The warm-up read. It is finished when the bus
                // answers, which cannot happen until the DDR3 PHY has
                // calibrated and memory_ddr3 stops holding requests.
                // --------------------------------------------
                LoaderWarmRead: begin
                    if (!bus_pending) begin
                        block_addr <= HDR_LBA;
                        block_req  <= 1'b1;
                        header_index  <= 3'd0;
                        header_complete <= 1'b0;
                        state_q    <= LoaderReadHeader;
                    end
                end

                // --------------------------------------------
                // Block 0: the header. Only the first four words
                // matter, but the whole block has to be clocked in.
                // --------------------------------------------
                LoaderReadHeader: begin
                    // The block is 128 words; only the first four are
                    // the header, and the capture has to stop there
                    // rather than wrap round and overwrite itself.
                    if (block_valid && !header_complete) begin
                        header_words[header_index] <= block_data;
                        if (header_index == 3'd3)
                            header_complete <= 1'b1;
                        else
                            header_index <= header_index + 3'd1;
                    end

                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state_q    <= LoaderError;
                    end else if (block_done) begin
                        state_q <= LoaderCheckHeader;
                    end
                end

                // --------------------------------------------
                // Validate the header before trusting a single byte of
                // it: magic, a sane block count, a payload that matches
                // that count, and a destination inside the window.
                // --------------------------------------------
                LoaderCheckHeader: begin
                    if (header_words[0] != MAGIC) begin
                        error    <= 1'b1;
                        err_code <= ERR_MAGIC;
                        state_q    <= LoaderError;
                    end else if ((header_words[1] == 32'd0) ||
                                 (header_words[1] > 32'(MAX_BLOCKS)) ||
                                 (header_words[3] > (header_words[1] << 9))) begin
                        error    <= 1'b1;
                        err_code <= ERR_COUNT;
                        state_q    <= LoaderError;
                    end else if (dest_end > {1'b0, DDR3_SIZE}) begin
                        error    <= 1'b1;
                        err_code <= ERR_RANGE;
                        state_q    <= LoaderError;
                    end else begin
                        payload_blocks <= header_words[1];
                        dest_offset      <= header_words[2];
                        block_index      <= 32'd1;
                        state_q        <= LoaderNextBlock;
                    end
                end

                // --------------------------------------------
                // Ask for the next payload block, once the bus has
                // drained: that is the only back-pressure the card side
                // needs, and it makes an overrun impossible.
                // --------------------------------------------
                LoaderNextBlock: begin
                    if (block_index > payload_blocks) begin
                        if (!bus_pending)
                            state_q <= LoaderDone;
                    end else if (!bus_pending) begin
                        block_addr <= HDR_LBA + block_index;
                        block_req  <= 1'b1;
                        state_q    <= LoaderWritePayload;
                    end
                end

                // --------------------------------------------
                // One block: every word becomes a bus write at
                // DDR3_BASE + the destination offset.
                // --------------------------------------------
                LoaderWritePayload: begin
                    if (block_valid) begin
                        if (bus_pending) begin
                            // Would mean the bus is slower than the
                            // card, which the margins say cannot
                            // happen. Fail loudly if it ever does.
                            error    <= 1'b1;
                            err_code <= ERR_OVERRUN;
                            state_q    <= LoaderError;
                        end else begin
                            bus_addr    <= DDR3_BASE + dest_offset;
                            bus_wdata   <= block_data;
                            bus_is_wr   <= 1'b1;
                            bus_pending <= 1'b1;
                        end
                    end

                    if (sd_error) begin
                        error    <= 1'b1;
                        err_code <= ERR_SD;
                        state_q    <= LoaderError;
                    end else if (block_done) begin
                        block_index       <= block_index + 32'd1;
                        blocks_loaded <= blocks_loaded + 32'd1;
                        state_q         <= LoaderNextBlock;
                    end
                end

                // --------------------------------------------
                // The whole image is in DDR3.
                // --------------------------------------------
                LoaderDone: begin
                    done <= 1'b1;
                end

                // --------------------------------------------
                // Sticky failure.
                // --------------------------------------------
                LoaderError: begin
                    error <= 1'b1;
                end

                default: state_q <= LoaderError;
            endcase
        end
    end

endmodule

