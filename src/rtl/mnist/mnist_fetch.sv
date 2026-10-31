// ============================================================
// image_fetch  one MNIST record per tick: DDR3, then BSRAM, then the
//              pixel side's fifo
// ============================================================
//
// Runs in clk27 and owns one arbiter slot. A fetch_tick starts a copy
// of one image record:
//
//   1. read the record's bytes out of DDR3 (the microSD loader put
//      them there) and write them into BSRAM - the "transfer to
//      BSRAM" hop, and a real bus copy on both sides;
//   2. read those same bytes back out of BSRAM and push them, byte by
//      byte, into the fifo that feeds the pixel clock's side of the
//      display;
//   3. push the record's label byte after them.
//
// A new record is only fetched once the pixel side has taken the
// previous one, so the fifo never holds more than one image. Record
// order wraps at RECORDS, so the display runs forever.
//
// Bytes leave here in the order the card image has them: byte 0 of the
// record first, and within a bus word the least significant byte
// first.
// ============================================================

module mnist_fetch #(
    parameter logic [31:0] DDR3_BASE    = 32'h0800_0000,
    parameter logic [31:0] DEST_OFFSET  = 32'h0,
    parameter logic [31:0] BSRAM_OFFSET = 32'h1000,
    parameter int          RECORD_BYTES = 784,     // 28x28
    parameter int          RECORDS      = 60000
) (
    input  logic             clk,
    input  logic             rst,

    // rate controller
    input  logic             fetch_tick,
    output logic             fetch_busy,

    // handoff to the pixel side
    output logic             frame_pushed,  // toggle: a new image is in
    input  logic             frame_taken,   // toggle: the pixel side took it

    // bus master
    output soc_pkg::bus_req_s bus_req,
    input  soc_pkg::bus_rsp_s bus_rsp,

    // image byte stream into the pixel side's fifo
    input  logic             fifo_full,
    output logic             fifo_wr,
    output logic [7:0]       fifo_data
);

    localparam int WORDS_PER_RECORD = RECORD_BYTES / 4;

    // Where the record's label byte lives: after every record's image
    // bytes, per the card image format.
    localparam logic [31:0] ddr_record_base = DDR3_BASE + DEST_OFFSET;
    localparam logic [31:0] label_base = ddr_record_base +
                                         RECORDS * RECORD_BYTES;

    typedef enum logic [2:0] {
        FetchIdle        = 3'd0,   // waiting for a tick
        FetchDdrRead     = 3'd1,   // DDR3 -> adapter
        FetchBsramWrite  = 3'd2,   // adapter -> BSRAM
        FetchBsramRead   = 3'd3,   // BSRAM -> adapter
        FetchPushBytes   = 3'd4,   // adapter -> fifo, four bytes
        FetchLabelRead   = 3'd5,   // the record's label byte
        FetchLabelPush   = 3'd6,   // label byte into the fifo
        FetchPushed      = 3'd7    // waiting for the pixel side
    } image_fetch_state_e;

    image_fetch_state_e state_q;

    logic [31:0] record_index_q;
    logic [31:0] word_index_q;
    logic [31:0] read_data_q;
    logic [31:0] ddr_addr_q;
    logic [31:0] bsram_addr_q;
    logic [7:0]  label_byte_q;
    logic [1:0]  byte_lane_q;
    logic        frame_pushed_q;
    logic        frame_taken_sync1, frame_taken_sync2;

    assign fetch_busy  = (state_q != FetchIdle);
    assign frame_pushed = frame_pushed_q;
    // Bus master: one outstanding request, held until ready.
    always_comb begin
        bus_req       = '0;
        bus_req.valid = (state_q == FetchDdrRead) ||
                        (state_q == FetchBsramWrite) ||
                        (state_q == FetchBsramRead) ||
                        (state_q == FetchLabelRead);
        bus_req.op    = (state_q == FetchBsramWrite) ? soc_pkg::BusWrite
                                                     : soc_pkg::BusRead;
        // The label byte sits at label_base + record_index, but the bus
        // is word-granular: read the covering aligned word and pick the
        // byte lane. label_base is word aligned (RECORD_BYTES is 784),
        // so the lane is just the record index's low bits.
        bus_req.addr  = (state_q == FetchDdrRead)   ? ddr_addr_q  :
                        (state_q == FetchLabelRead) ? (label_base
                                                       + {record_index_q[31:2], 2'b00}) :
                                                      bsram_addr_q;
        bus_req.wdata = read_data_q;
        bus_req.wstrb = soc_pkg::BUS_STRB_ALL;
    end

    // The pixel side has taken the last image when the two toggles
    // agree again.
    wire fifo_may_push = (frame_pushed_q == frame_taken_sync2);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q           <= FetchIdle;
            record_index_q    <= '0;
            word_index_q      <= '0;
            read_data_q       <= '0;
            ddr_addr_q        <= ddr_record_base;
            bsram_addr_q      <= BSRAM_OFFSET;
            label_byte_q      <= 8'hFF;
            byte_lane_q       <= '0;
            frame_pushed_q    <= 1'b0;
            frame_taken_sync1 <= 1'b0;
            frame_taken_sync2 <= 1'b0;
            fifo_wr           <= 1'b0;
            fifo_data         <= 8'hFF;
        end else begin
            frame_taken_sync1 <= frame_taken;
            frame_taken_sync2 <= frame_taken_sync1;
            fifo_wr           <= 1'b0;

            case (state_q)
                FetchIdle: begin
                    if (fetch_tick && fifo_may_push) begin
                        word_index_q <= '0;
                        byte_lane_q  <= '0;
                        state_q      <= FetchDdrRead;
                    end
                end

                FetchDdrRead: begin
                    if (bus_rsp.ready) begin
                        read_data_q <= bus_rsp.rdata;
                        state_q     <= FetchBsramWrite;
                    end
                end

                FetchBsramWrite: begin
                    if (bus_rsp.ready) begin
                        state_q <= FetchBsramRead;
                    end
                end

                // Read the word back out of BSRAM and push its four
                // bytes into the fifo, least significant byte first.
                FetchBsramRead: begin
                    if (bus_rsp.ready) begin
                        read_data_q <= bus_rsp.rdata;
                        byte_lane_q <= '0;
                        state_q     <= FetchPushBytes;
                    end
                end

                FetchPushBytes: begin
                    if (!fifo_full) begin
                        fifo_wr   <= 1'b1;
                        fifo_data <= read_data_q[8*byte_lane_q +: 8];
                        if (byte_lane_q == 2'd3) begin
                            byte_lane_q <= '0;
                            if (word_index_q + 1'b1 == WORDS_PER_RECORD) begin
                                state_q <= FetchLabelRead;
                            end else begin
                                word_index_q <= word_index_q + 1'b1;
                                ddr_addr_q   <= ddr_addr_q + 4;
                                bsram_addr_q <= bsram_addr_q + 4;
                                state_q      <= FetchDdrRead;
                            end
                        end else begin
                            byte_lane_q <= byte_lane_q + 1'b1;
                        end
                    end
                end

                FetchLabelRead: begin
                    if (bus_rsp.ready) begin
                        label_byte_q <= 8'(bus_rsp.rdata >> (8 * record_index_q[1:0]));
                        state_q      <= FetchLabelPush;
                    end
                end

                FetchLabelPush: begin
                    if (!fifo_full) begin
                        fifo_wr   <= 1'b1;
                        fifo_data <= label_byte_q;
                        state_q   <= FetchPushed;
                    end
                end

                // The image is in the fifo: tell the pixel side, and
                // advance to the next record, wrapping so the display
                // runs forever. The word loop above already stepped the
                // addresses over the record's first 195 words, so only
                // the last word's four bytes remain.
                FetchPushed: begin
                    if (fifo_may_push) begin
                        frame_pushed_q <= ~frame_pushed_q;
                        if (record_index_q + 1'b1 == RECORDS) begin
                            record_index_q <= '0;
                            ddr_addr_q     <= ddr_record_base;
                            bsram_addr_q   <= BSRAM_OFFSET;
                        end else begin
                            record_index_q <= record_index_q + 1'b1;
                            ddr_addr_q     <= ddr_addr_q + 4;
                            bsram_addr_q   <= bsram_addr_q + 4;
                        end
                        state_q <= FetchIdle;
                    end
                end

                default: state_q <= FetchIdle;
            endcase
        end
    end

endmodule
