// ============================================================
// sd_controller  microSD card protocol, SPI mode
// ============================================================
//
// Sits on top of sd_spi_master (which clocks bytes) and speaks
// the card's language. It owns cs_n, because chip select has to
// stay low for a whole command and its response, not for a byte.
//
// WAKE-UP SEQUENCE (once, after reset)
//   power-up   80 clocks with cs_n high and mosi high. A card
//              wants at least 74 idle clocks before it will
//              listen, and it wants them slow: everything until
//              the card reports ready runs at ~400 kHz.
//   CMD0       enter SPI mode. The card answers R1 = 0x01 (idle).
//   CMD8       "are you a v2 card?" with the check pattern 0x1AA
//              and a valid CRC (0x87). A v2 card echoes 0xAA back;
//              an older card rejects the command, which is how the
//              two generations are told apart.
//   CMD55+41   ACMD41 "are you ready?" with HCS set, repeated
//              until the card answers 0x00. A card can take up to
//              a second to finish its internal power-up, so this
//              is a bounded retry loop, not a wait.
//   CMD58      read the OCR register. Bit 30 (CCS) says whether
//              the card is SDHC (addressed in 512-byte sectors) or
//              an older byte-addressed card. Skipped for v1 cards,
//              which have no OCR.
//   CMD16      set the block length to 512, which older cards need
//              and SDHC ignores.
//
// READ SEQUENCE (per block)
//   CMD17      read one block. R1 = 0x00 means accepted; anything
//              else is an error and the read stops.
//   token      the card sends 0xFF bytes while it works, then
//              0xFE to say "data follows". Bounded by TOKEN_MAX so
//              a card that never answers cannot hang the SoC.
//   data       512 bytes = 128 bus words, MSB byte first on the
//              wire, assembled little endian (the first byte of a
//              word is its least significant byte) to match the
//              SoC bus.
//   CRC        2 bytes, clocked out and ignored.
//   tail       cs_n high and one idle byte, so the card is ready
//              for the next command.
//
// ADDRESSING
//   SDHC cards take a sector number (LBA). SDv1/v2 cards take a
//   byte address, so the LBA is shifted left by 9. card_type
//   remembers which one this card wants.
//
// ERRORS
//   Every wait in this file is bounded. When a bound is hit the
//   controller stops, raises error (sticky until reset) and puts a
//   code in err_code so a board with nothing but LEDs can still
//   say what went wrong:
//     1 CMD0    no valid R1, or R1 was not 0x01
//     2 CMD8    the card did not echo the check pattern
//     3 ACMD41  no valid R1, or the card never came ready
//     4 CMD58   no valid R1, or R1 was not 0x00
//     5 CMD16   no valid R1, or R1 was not 0x00
//     6 CMD17   no valid R1, or R1 was not 0x00
//     7 token   no 0xFE data token within TOKEN_MAX bytes
//
// SPEED
//   DIV_INIT for everything up to and including CMD16, DIV_DATA
//   from CMD17 onwards.
//
// HANDSHAKE
//   blk_req is a pulse with blk_addr stable; it is only looked at
//   in the idle state, so one request is in flight at a time.
//   blk_busy is high from the request until the block is finished.
//   Each of the 128 words arrives as a one-cycle blk_valid pulse
//   with blk_data, in order. blk_done ends the block. error and
//   err_code are sticky and mean the request failed.
// ============================================================

module sd_controller #(
    parameter int DIV_W         = 16,
    parameter logic [DIV_W-1:0] DIV_INIT = 16'd34,  // 397 kHz at 27 MHz
    parameter logic [DIV_W-1:0] DIV_DATA = 16'd1,   // 13.5 MHz at 27 MHz
    parameter int POWERUP_BYTES = 10,       // 80 clocks with cs_n high
    parameter int POLL_MAX      = 16,       // bytes to wait for an R1
    parameter int RETRY_MAX     = 8000,     // ACMD41 attempts, ~2 s
    parameter int TOKEN_MAX     = 4096      // bytes to wait for 0xFE
) (
    input  logic        clk,
    input  logic        rst,

    // card pins
    output logic        cs_n,
    output logic        sck,
    output logic        mosi,
    input  logic        miso,

    // block read request
    input  logic        blk_req,
    input  logic [31:0] blk_addr,
    output logic        blk_busy,
    output logic        blk_done,
    output logic [31:0] blk_data,
    output logic        blk_valid,

    // status
    output logic        ready,
    output logic        error,
    output logic [3:0]  err_code,
    output logic [1:0]  card_type,
    output logic [4:0]  state_dbg
);
    // ========================================================
    // COMMAND FRAMES
    // ========================================================
    // A command is 6 bytes: 0x40|opcode, a 32-bit argument, and a
    // CRC. The CRC is only checked by a card for CMD0 and CMD8, so
    // those two carry the real value (0x95 and 0x87) and every
    // other command sends 0xFF, which cards accept in SPI mode.
    // --------------------------------------------------------

    localparam logic [47:0] CMD0_FRAME   = {8'h40, 32'h0000_0000, 8'h95};
    localparam logic [47:0] CMD8_FRAME   = {8'h48, 32'h0000_01AA, 8'h87};
    localparam logic [47:0] CMD55_FRAME  = {8'h77, 32'h0000_0000, 8'hFF};
    localparam logic [47:0] ACMD41_FRAME = {8'h69, 32'h4000_0000, 8'hFF};
    localparam logic [47:0] CMD58_FRAME  = {8'h7A, 32'h0000_0000, 8'hFF};
    localparam logic [47:0] CMD16_FRAME  = {8'h50, 32'h0000_0200, 8'hFF};

    localparam logic [2:0] CID_CMD0   = 3'd0,
                           CID_CMD8   = 3'd1,
                           CID_CMD55  = 3'd2,
                           CID_ACMD41 = 3'd3,
                           CID_CMD58  = 3'd4,
                           CID_CMD16  = 3'd5,
                           CID_CMD17  = 3'd6;

    localparam logic [3:0] ERR_NONE   = 4'd0,
                           ERR_CMD0   = 4'd1,
                           ERR_CMD8   = 4'd2,
                           ERR_ACMD41 = 4'd3,
                           ERR_CMD58  = 4'd4,
                           ERR_CMD16  = 4'd5,
                           ERR_CMD17  = 4'd6,
                           ERR_TOKEN  = 4'd7;

    localparam logic [1:0] CT_UNKNOWN = 2'd0,
                           CT_SD1     = 2'd1,
                           CT_SD2     = 2'd2,
                           CT_SDHC    = 2'd3;

    typedef enum logic [4:0] {
        ST_POWERUP = 5'd0,      // idle clocks with cs_n high
        ST_SEND    = 5'd1,      // six command bytes from cmd_sh
        ST_R1      = 5'd2,      // poll for R1, then act on it
        ST_R7      = 5'd3,      // CMD8's four extra bytes
        ST_R3      = 5'd4,      // CMD58's four OCR bytes
        ST_TOKEN   = 5'd5,      // wait for the 0xFE data token
        ST_DATA    = 5'd6,      // 512 bytes of block data
        ST_CRC     = 5'd7,      // two CRC bytes, ignored
        ST_TAIL    = 5'd8,      // cs_n high, one idle byte
        ST_IDLE    = 5'd9,      // ready for a block request
        ST_ERROR   = 5'd10      // sticky error
    } state_e;

    state_e state;

    // ========================================================
    // BYTE ENGINE
    // ========================================================

    logic             spi_start, spi_done, spi_busy;
    logic [7:0]       spi_tx, spi_rx;
    logic [DIV_W-1:0] div_reg;

    sd_spi_master #(.DIV_W(DIV_W)) u_spi (
        .clk     (clk),
        .rst     (rst),
        .start   (spi_start),
        .tx      (spi_tx),
        .divider (div_reg),
        .busy    (spi_busy),
        .done    (spi_done),
        .rx      (spi_rx),
        .sck     (sck),
        .mosi    (mosi),
        .miso    (miso)
    );

    // ========================================================
    // SEQUENCER STATE
    // ========================================================

    logic [47:0] cmd_sh;        // command frame, shifted out MSB first
    logic [31:0] resp_sh;       // response bytes, shifted in
    logic [2:0]  cmd_id;        // which command is in flight
    logic [15:0] cnt;           // byte counter inside a state
    logic [15:0] retry;         // ACMD41 attempts so far
    logic [31:0] word;          // block word being assembled
    logic [6:0]  word_idx;      // 0..127 inside a block
    logic [1:0]  byte_idx;      // 0..3 inside a word
    logic        busy_r;        // a block request is in flight

    assign state_dbg = state;
    assign blk_busy  = busy_r;

    // The response bytes with the byte just clocked in included, so a
    // multi-byte response can be judged on the cycle its last byte
    // arrives (resp_sh itself only sees that byte on the next edge).
    logic [31:0] resp_next;
    assign resp_next = {resp_sh[23:0], spi_rx};

    // Which error code a failed R1 poll belongs to.
    function automatic logic [3:0] err_for(input logic [2:0] id);
        case (id)
            CID_CMD0:   err_for = ERR_CMD0;
            CID_CMD8:   err_for = ERR_CMD8;
            CID_CMD55:  err_for = ERR_ACMD41;
            CID_ACMD41: err_for = ERR_ACMD41;
            CID_CMD58:  err_for = ERR_CMD58;
            CID_CMD16:  err_for = ERR_CMD16;
            CID_CMD17:  err_for = ERR_CMD17;
            default:    err_for = ERR_CMD0;
        endcase
    endfunction




    // ========================================================
    // SEQUENCER
    // ========================================================
    // Every state has the same shape: if the byte engine has just
    // finished, look at the byte and decide what happens next;
    // otherwise, if the engine is idle, hand it the next byte.
    // --------------------------------------------------------

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= ST_POWERUP;
            cs_n      <= 1'b1;
            div_reg   <= DIV_INIT;
            spi_start <= 1'b0;
            spi_tx    <= 8'hFF;
            cmd_sh    <= CMD0_FRAME;
            resp_sh   <= 32'h0;
            cmd_id    <= CID_CMD0;
            cnt       <= 16'd0;
            retry     <= 16'd0;
            word      <= 32'h0;
            word_idx  <= 7'd0;
            byte_idx  <= 2'd0;
            busy_r    <= 1'b0;
            blk_done  <= 1'b0;
            blk_valid <= 1'b0;
            blk_data  <= 32'h0;
            ready     <= 1'b0;
            error     <= 1'b0;
            err_code  <= ERR_NONE;
            card_type <= CT_UNKNOWN;
        end else begin
            spi_start <= 1'b0;
            blk_done  <= 1'b0;
            blk_valid <= 1'b0;

            case (state)
                // --------------------------------------------
                // ST_POWERUP: at least 74 clocks with cs_n high
                // and mosi high, at the slow divider.
                // --------------------------------------------
                ST_POWERUP: begin
                    cs_n    <= 1'b1;
                    div_reg <= DIV_INIT;

                    if (spi_done) begin
                        if (cnt + 16'd1 == POWERUP_BYTES) begin
                            cnt    <= 16'd0;
                            cmd_sh <= CMD0_FRAME;
                            cmd_id <= CID_CMD0;
                            cs_n   <= 1'b0;         // select the card
                            state  <= ST_SEND;
                        end else begin
                            cnt <= cnt + 16'd1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_SEND: the six command bytes, MSB first.
                // --------------------------------------------
                ST_SEND: begin
                    if (spi_done) begin
                        if (cnt == 16'd5) begin
                            cnt   <= 16'd0;
                            state <= ST_R1;
                        end else begin
                            cnt <= cnt + 16'd1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= cmd_sh[47:40];
                        cmd_sh    <= {cmd_sh[39:0], 8'hFF};
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_R1: poll for R1. The card may send a few
                // 0xFF bytes first; R1 is the first byte with
                // bit 7 clear. What happens next depends on
                // which command this R1 answers.
                // --------------------------------------------
                ST_R1: begin
                    if (spi_done) begin
                        if (spi_rx[7] == 1'b0) begin
                            case (cmd_id)
                                CID_CMD0: begin
                                    if (spi_rx != 8'h01) begin
                                        error <= 1'b1; err_code <= ERR_CMD0;
                                        state <= ST_ERROR;
                                    end else begin
                                        cmd_sh <= CMD8_FRAME; cmd_id <= CID_CMD8;
                                        cnt <= 16'd0; state <= ST_SEND;
                                    end
                                end

                                CID_CMD8: begin
                                    if (spi_rx == 8'h01) begin
                                        // v2 card: read the four
                                        // bytes that follow R1.
                                        cnt <= 16'd0; state <= ST_R7;
                                    end else if (spi_rx[2]) begin
                                        // Illegal command, so this is
                                        // an older card: byte
                                        // addressing and no OCR.
                                        card_type <= CT_SD1;
                                        cmd_sh <= CMD55_FRAME; cmd_id <= CID_CMD55;
                                        cnt <= 16'd0; state <= ST_SEND;
                                    end else begin
                                        error <= 1'b1; err_code <= ERR_CMD8;
                                        state <= ST_ERROR;
                                    end
                                end

                                CID_CMD55: begin
                                    if (spi_rx != 8'h01) begin
                                        error <= 1'b1; err_code <= ERR_ACMD41;
                                        state <= ST_ERROR;
                                    end else begin
                                        cmd_sh <= ACMD41_FRAME; cmd_id <= CID_ACMD41;
                                        cnt <= 16'd0; state <= ST_SEND;
                                    end
                                end



                                CID_ACMD41: begin
                                    if (spi_rx == 8'h00) begin
                                        // Card is ready. Older cards
                                        // have no OCR to read, so they
                                        // go straight to CMD16.
                                        if (card_type == CT_SD1) begin
                                            cmd_sh <= CMD16_FRAME; cmd_id <= CID_CMD16;
                                        end else begin
                                            cmd_sh <= CMD58_FRAME; cmd_id <= CID_CMD58;
                                        end
                                        cnt <= 16'd0; state <= ST_SEND;
                                    end else if (spi_rx == 8'h01) begin
                                        // Still waking up: ask again,
                                        // but not forever.
                                        if (retry >= RETRY_MAX) begin
                                            error <= 1'b1; err_code <= ERR_ACMD41;
                                            state <= ST_ERROR;
                                        end else begin
                                            retry  <= retry + 16'd1;
                                            cmd_sh <= CMD55_FRAME; cmd_id <= CID_CMD55;
                                            cnt <= 16'd0; state <= ST_SEND;
                                        end
                                    end else begin
                                        error <= 1'b1; err_code <= ERR_ACMD41;
                                        state <= ST_ERROR;
                                    end
                                end

                                CID_CMD58: begin
                                    if (spi_rx != 8'h00) begin
                                        error <= 1'b1; err_code <= ERR_CMD58;
                                        state <= ST_ERROR;
                                    end else begin
                                        cnt <= 16'd0; state <= ST_R3;
                                    end
                                end

                                CID_CMD16: begin
                                    if (spi_rx != 8'h00) begin
                                        error <= 1'b1; err_code <= ERR_CMD16;
                                        state <= ST_ERROR;
                                    end else begin
                                        ready <= 1'b1;
                                        cs_n  <= 1'b1;
                                        state <= ST_IDLE;
                                    end
                                end

                                CID_CMD17: begin
                                    if (spi_rx != 8'h00) begin
                                        error <= 1'b1; err_code <= ERR_CMD17;
                                        state <= ST_ERROR;
                                    end else begin
                                        cnt <= 16'd0; state <= ST_TOKEN;
                                    end
                                end

                                default: begin
                                    error <= 1'b1; err_code <= ERR_CMD0;
                                    state <= ST_ERROR;
                                end
                            endcase
                        end else if (cnt >= POLL_MAX) begin
                            // No R1 at all: the card is not talking.
                            error <= 1'b1; err_code <= err_for(cmd_id);
                            state <= ST_ERROR;
                        end else begin
                            cnt       <= cnt + 16'd1;
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end
                // --------------------------------------------
                // ST_R7: CMD8's four extra bytes. The last one is
                // the check pattern coming back, and that echo is
                // what proves the card understood the command.
                // --------------------------------------------
                ST_R7: begin
                    if (spi_done) begin
                        resp_sh <= resp_next;
                        if (cnt == 16'd3) begin
                            cnt <= 16'd0;
                            if (resp_next[7:0] == 8'hAA) begin
                                cmd_sh <= CMD55_FRAME; cmd_id <= CID_CMD55;
                                state <= ST_SEND;
                            end else begin
                                error <= 1'b1; err_code <= ERR_CMD8;
                                state <= ST_ERROR;
                            end
                        end else begin
                            cnt       <= cnt + 16'd1;
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_R3: CMD58's four OCR bytes. Bit 30 (CCS) is
                // set on SDHC cards, which is the difference
                // between sector addressing and byte addressing.
                // --------------------------------------------
                ST_R3: begin
                    if (spi_done) begin
                        resp_sh <= resp_next;
                        if (cnt == 16'd3) begin
                            cnt <= 16'd0;
                            card_type <= resp_next[30] ? CT_SDHC : CT_SD2;
                            cmd_sh <= CMD16_FRAME; cmd_id <= CID_CMD16;
                            state <= ST_SEND;
                        end else begin
                            cnt       <= cnt + 16'd1;
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_TOKEN: the card answers 0xFF while it works,
                // then 0xFE. Bounded, so a card that never answers
                // fails instead of hanging the SoC.
                // --------------------------------------------
                ST_TOKEN: begin
                    if (spi_done) begin
                        if (spi_rx == 8'hFE) begin
                            cnt      <= 16'd0;
                            word_idx <= 7'd0;
                            byte_idx <= 2'd0;
                            state    <= ST_DATA;
                        end else if (cnt >= TOKEN_MAX) begin
                            error <= 1'b1; err_code <= ERR_TOKEN;
                            state <= ST_ERROR;
                        end else begin
                            cnt       <= cnt + 16'd1;
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_DATA: 512 bytes = 128 bus words. The card sends
                // the most significant byte of a word first, and the
                // word is assembled little endian (first byte =
                // least significant) to match the SoC bus.
                // --------------------------------------------
                ST_DATA: begin
                    if (spi_done) begin
                        word <= {spi_rx, word[31:8]};
                        if (byte_idx == 2'd3) begin
                            blk_data  <= {spi_rx, word[31:8]};
                            blk_valid <= 1'b1;
                            byte_idx  <= 2'd0;
                            if (word_idx == 7'd127) begin
                                cnt   <= 16'd0;
                                state <= ST_CRC;
                            end else begin
                                word_idx <= word_idx + 7'd1;
                            end
                        end else begin
                            byte_idx <= byte_idx + 2'd1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_CRC: the two CRC16 bytes, clocked out and
                // ignored. The SPI CRC is optional and a card that
                // has been fine for 512 bytes is not worth failing
                // over at the last two.
                // --------------------------------------------
                ST_CRC: begin
                    if (spi_done) begin
                        if (cnt == 16'd1) begin
                            cnt   <= 16'd0;
                            state <= ST_TAIL;
                        end else begin
                            cnt <= cnt + 16'd1;
                        end
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_TAIL: cs_n high and one idle byte, so the card
                // is released cleanly before the next command.
                // --------------------------------------------
                ST_TAIL: begin
                    cs_n <= 1'b1;
                    if (spi_done) begin
                        blk_done <= 1'b1;
                        busy_r   <= 1'b0;
                        state    <= ST_IDLE;
                    end else if (!spi_busy) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // --------------------------------------------
                // ST_IDLE: initialised and waiting for work.
                // --------------------------------------------
                ST_IDLE: begin
                    cs_n <= 1'b1;

                    if (blk_req && !error) begin
                        // SDHC takes a sector number; older cards
                        // take a byte address, so the LBA is shifted
                        // left by 9 to make it one.
                        cmd_sh <= {8'h51,
                                   (card_type == CT_SDHC) ? blk_addr
                                                          : (blk_addr << 9),
                                   8'hFF};
                        cmd_id  <= CID_CMD17;
                        cnt     <= 16'd0;
                        div_reg <= DIV_DATA;
                        cs_n    <= 1'b0;
                        busy_r  <= 1'b1;
                        state   <= ST_SEND;
                    end
                end

                // --------------------------------------------
                // ST_ERROR: sticky. The card is left deselected and
                // no further request is served until reset.
                // --------------------------------------------
                ST_ERROR: begin
                    cs_n  <= 1'b1;
                    busy_r <= 1'b0;
                end

                default: state <= ST_ERROR;
            endcase
        end
    end

endmodule



