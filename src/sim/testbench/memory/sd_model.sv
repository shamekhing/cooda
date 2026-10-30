`timescale 1ns/1ps
// ============================================================
// sd_model  behavioural microSD card, SPI mode (simulation only)
// ============================================================
//
// A real card cannot be simulated here, so this is the card's side
// of the wire: it samples mosi on the rising edge of sck, drives
// miso on the falling edge, and answers the command frames that
// sd_controller sends.
//
// SUPPORTED
//   CMD0   reset, R1 = 0x01
//   CMD8   check pattern echo (R7), R1 = 0x01
//   CMD55  prefix for ACMD41, R1 = 0x01
//   ACMD41 answers 0x01 until ready_after attempts, then 0x00
//   CMD58  OCR (R3), bit 30 set on an SDHC card
//   CMD16  set block length, R1 = 0x00
//   CMD17  read one block: R1, some 0xFF bytes, 0xFE, 512 bytes, CRC
//   anything else answers 0x05 (illegal command), which is also
//   what an old card does with CMD8
//
// FAULT INJECTION
//   The knobs below let a testbench make the card misbehave, so the
//   controller's error paths are exercised instead of assumed:
//     fault_silent      never answers any command
//     fault_bad_echo    CMD8 echoes 0x55 instead of 0xAA
//     fault_never_ready ACMD41 never reports ready
//     fault_no_token    CMD17 is accepted but no 0xFE ever comes
//     fault_bad_cmd17   CMD17 answers 0x04 instead of 0x00
//     fault_sdsc        an SDSC card: OCR bit 30 clear, so the host
//                       has to address in bytes rather than sectors
//     fault_v1          an old card: CMD8 is rejected
//
// The block store is 8 blocks of 512 bytes, which the testbench
// preloads directly (u_card.blk[...]).
//
// Timing knobs: ncr_ff 0xFF bytes before an R1, token_delay 0xFF
// bytes before the 0xFE token, ready_after ACMD41 attempts.
// ============================================================

module sd_model #(
    parameter int BLOCKS = 8
) (
    input  logic        rst,
    input  logic        cs_n,
    input  logic        sck,
    input  logic        mosi,
    output logic        miso,

    // timing knobs
    input  logic [7:0]  ncr_ff,
    input  logic [7:0]  token_delay,
    input  logic [15:0] ready_after,

    // fault injection
    input  logic        fault_silent,
    input  logic        fault_bad_echo,
    input  logic        fault_never_ready,
    input  logic        fault_no_token,
    input  logic        fault_bad_cmd17,
    input  logic        fault_sdsc,
    input  logic        fault_v1,

    // what the card saw, for the testbench to check
    output logic [15:0] cmd_count,
    output logic [5:0]  last_op
);

    localparam int BYTES    = BLOCKS * 512;
    localparam int BLK_BITS = $clog2(BLOCKS);

    logic [7:0] blk [0:BYTES-1];

    // The card's own OCR: bit 31 power-up done, bit 30 CCS (SDHC),
    // bits 23:15 the 2.7-3.6 V window.
    logic [31:0] ocr;
    assign ocr = fault_sdsc ? 32'h80FF_8000 : 32'hC0FF_8000;

    // ========================================================
    // SPI SHIFT MACHINERY
    // ========================================================

    logic [7:0] rx_sh;
    logic [2:0] rx_bit;
    logic [7:0] tx_sh;
    logic [2:0] tx_bit;

    // ========================================================
    // PROTOCOL STATE
    // ========================================================

    typedef enum logic [2:0] {
        S_CMD   = 3'd0,     // collecting six command bytes
        S_DELAY = 3'd1,     // 0xFF bytes before the R1
        S_RESP  = 3'd2,     // the response bytes
        S_NCR   = 3'd3,     // 0xFF bytes before the data token
        S_TOKEN = 3'd4,     // the 0xFE token
        S_DATA  = 3'd5,     // 512 data bytes
        S_CRC   = 3'd6      // two CRC bytes
    } st_e;

    st_e         st;
    logic [47:0] cmd_sh;
    logic [2:0]  cmd_cnt;
    logic [7:0]  resp [0:4];
    logic [2:0]  resp_len, resp_idx;
    logic [7:0]  delay_cnt;
    logic        acmd_flag;
    logic [15:0] acmd_tries;
    logic [31:0] read_lba;
    logic        data_pending;
    logic [15:0] data_idx;
    logic [1:0]  crc_idx;
    logic [7:0]  tok_cnt;

    // Byte index into the block store: the low bits of the LBA (only
    // BLOCKS blocks are modelled) and the byte inside the block.
    logic [BLK_BITS+9-1:0] blk_idx;
    assign blk_idx = {read_lba[BLK_BITS-1:0], data_idx[8:0]};

    // What the card should be shifting out right now.
    function automatic logic [7:0] next_tx();
        case (st)
            S_RESP:  next_tx = resp[resp_idx];
            S_TOKEN: next_tx = 8'hFE;
            S_DATA:  next_tx = blk[blk_idx];
            default: next_tx = 8'hFF;
        endcase
    endfunction

    logic [7:0] tx_byte;
    always_comb tx_byte = next_tx();

    logic miso_r;
    assign miso = miso_r;

    // The byte just completed and the command frame it belongs to.
    logic [7:0]  rx_byte;
    logic [47:0] full;
    assign rx_byte = {rx_sh[6:0], mosi};
    assign full    = {cmd_sh[39:0], rx_byte};

    logic [5:0]  op;
    logic [31:0] arg;
    assign op  = full[45:40];
    assign arg = full[39:8];

    // ========================================================
    // THE CARD
    // ========================================================
    // One block, driven by the sck edges: mosi is sampled on the
    // rising edge, the next miso bit is presented on the falling
    // edge, and the protocol moves on at the end of each byte.
    //
    // cs_n is not in the sensitivity list on purpose. A change of
    // cs_n on its own is not a bit time, and acting on one would
    // shift the byte framing by a bit. Every deselected stretch the
    // host produces (the 74 power-up clocks and the idle byte after
    // a command) contains sck edges, and each of those resets the
    // framing through the branch below.
    // --------------------------------------------------------

    initial begin
        st           = S_CMD;
        cmd_sh       = 48'h0;
        cmd_cnt      = 3'd0;
        rx_sh        = 8'h00;
        rx_bit       = 3'd0;
        tx_sh        = 8'hFF;
        tx_bit       = 3'd0;
        resp_idx     = 3'd0;
        resp_len     = 3'd1;
        delay_cnt    = 8'd0;
        tok_cnt      = 8'd0;
        data_idx     = 16'd0;
        crc_idx      = 2'd0;
        acmd_flag    = 1'b0;
        acmd_tries   = 16'd0;
        read_lba     = 32'd0;
        data_pending = 1'b0;
        miso_r       = 1'b1;
        cmd_count    = 16'd0;
        last_op      = 6'd0;
        for (int i = 0; i < BYTES; i++)
            blk[i] = 8'h00;
    end

    always @(sck or posedge rst) begin
        if (rst) begin
            // Back to a card that has just been powered up. The block
            // store is deliberately left alone: the testbench loads
            // it once and expects it to survive a reset.
            st           <= S_CMD;
            cmd_sh       <= 48'h0;
            cmd_cnt      <= 3'd0;
            rx_sh        <= 8'h00;
            rx_bit       <= 3'd0;
            tx_sh        <= 8'hFF;
            tx_bit       <= 3'd0;
            resp_idx     <= 3'd0;
            resp_len     <= 3'd1;
            delay_cnt    <= 8'd0;
            tok_cnt      <= 8'd0;
            data_idx     <= 16'd0;
            crc_idx      <= 2'd0;
            acmd_flag    <= 1'b0;
            acmd_tries   <= 16'd0;
            read_lba     <= 32'd0;
            data_pending <= 1'b0;
            miso_r       <= 1'b1;
            cmd_count    <= 16'd0;
            last_op      <= 6'd0;
        end else if (cs_n) begin
            // Deselected: the card is not listening. The host's
            // power-up clocks and the idle byte after a command land
            // here, and this is also what re-frames the byte
            // boundaries before the next command.
            st           <= S_CMD;
            cmd_cnt      <= 3'd0;
            rx_bit       <= 3'd0;
            tx_bit       <= 3'd0;
            tx_sh        <= 8'hFF;
            miso_r       <= 1'b1;
            data_pending <= 1'b0;
        end else if (sck) begin
            // Rising edge: sample mosi.
            rx_sh  <= {rx_sh[6:0], mosi};
            rx_bit <= rx_bit + 3'd1;

            if (rx_bit == 3'd7) begin
                rx_bit <= 3'd0;

                if (fault_silent) begin
                    // A deaf card: nothing is ever answered.
                    cmd_cnt <= 3'd0;
                    st      <= S_CMD;
                end else begin
                    case (st)
                        // ------------------------------------
                        // Collecting a command. The sixth byte
                        // completes the frame.
                        // ------------------------------------
                        S_CMD: begin
                            cmd_sh  <= {cmd_sh[39:0], rx_byte};
                            cmd_cnt <= cmd_cnt + 3'd1;

                            if (cmd_cnt == 3'd5) begin
                                cmd_cnt      <= 3'd0;
                                cmd_count    <= cmd_count + 16'd1;
                                last_op      <= op;
                                resp_idx     <= 3'd0;
                                resp_len     <= 3'd1;
                                data_pending <= 1'b0;
                                delay_cnt    <= ncr_ff;

                                case (op)
                                    6'd0: begin     // CMD0
                                        resp[0] <= 8'h01;
                                    end

                                    6'd8: begin     // CMD8
                                        if (fault_v1) begin
                                            resp[0] <= 8'h05;
                                        end else begin
                                            resp[0]  <= 8'h01;
                                            resp[1]  <= 8'h00;
                                            resp[2]  <= 8'h00;
                                            resp[3]  <= 8'h01;
                                            resp[4]  <= fault_bad_echo ? 8'h55
                                                                       : 8'hAA;
                                            resp_len <= 3'd5;
                                        end
                                    end

                                    6'd55: begin    // CMD55
                                        acmd_flag <= 1'b1;
                                        resp[0]   <= 8'h01;
                                    end




                                    6'd41: begin    // ACMD41
                                        acmd_flag <= 1'b0;
                                        if (!acmd_flag) begin
                                            resp[0] <= 8'h04;
                                        end else if (fault_never_ready ||
                                                     (acmd_tries < ready_after)) begin
                                            acmd_tries <= acmd_tries + 16'd1;
                                            resp[0]    <= 8'h01;
                                        end else begin
                                            resp[0] <= 8'h00;
                                        end
                                    end

                                    6'd58: begin    // CMD58
                                        resp[0]  <= 8'h00;
                                        resp[1]  <= ocr[31:24];
                                        resp[2]  <= ocr[23:16];
                                        resp[3]  <= ocr[15:8];
                                        resp[4]  <= ocr[7:0];
                                        resp_len <= 3'd5;
                                    end

                                    6'd16: begin    // CMD16
                                        resp[0] <= 8'h00;
                                    end

                                    6'd17: begin    // CMD17
                                        // SDHC takes a sector number, an
                                        // SDSC card a byte address.
                                        read_lba <= ocr[30] ? arg : (arg >> 9);
                                        data_idx <= 16'd0;
                                        if (fault_bad_cmd17) begin
                                            resp[0] <= 8'h04;
                                        end else begin
                                            resp[0]      <= 8'h00;
                                            data_pending <= 1'b1;
                                        end
                                    end

                                    default: resp[0] <= 8'h05;  // illegal
                                endcase

                                st <= (ncr_ff == 0) ? S_RESP : S_DELAY;
                            end
                        end

                        // ------------------------------------
                        // 0xFF bytes before the R1.
                        // ------------------------------------
                        S_DELAY: begin
                            if (delay_cnt <= 8'd1) begin
                                resp_idx <= 3'd0;
                                st       <= S_RESP;
                            end else begin
                                delay_cnt <= delay_cnt - 8'd1;
                            end
                        end

                        // ------------------------------------
                        // The response bytes, then either the block
                        // data or back to listening.
                        // ------------------------------------
                        S_RESP: begin
                            if (resp_idx == resp_len - 3'd1) begin
                                resp_idx <= 3'd0;
                                if (data_pending) begin
                                    tok_cnt <= token_delay;
                                    st      <= S_NCR;
                                end else begin
                                    st <= S_CMD;
                                end
                            end else begin
                                resp_idx <= resp_idx + 3'd1;
                            end
                        end

                        // ------------------------------------
                        // 0xFF bytes while the card "works", then the
                        // data token.
                        // ------------------------------------
                        S_NCR: begin
                            if (fault_no_token) begin
                                st <= S_NCR;
                            end else if (tok_cnt == 8'd0) begin
                                st <= S_TOKEN;
                            end else begin
                                tok_cnt <= tok_cnt - 8'd1;
                            end
                        end

                        S_TOKEN: begin
                            data_idx <= 16'd0;
                            st       <= S_DATA;
                        end

                        // ------------------------------------
                        // The 512 data bytes.
                        // ------------------------------------
                        S_DATA: begin
                            if (data_idx == 16'd511) begin
                                crc_idx <= 2'd0;
                                st      <= S_CRC;
                            end else begin
                                data_idx <= data_idx + 16'd1;
                            end
                        end

                        // ------------------------------------
                        // Two CRC bytes, then done.
                        // ------------------------------------
                        S_CRC: begin
                            if (crc_idx == 2'd1) begin
                                data_pending <= 1'b0;
                                st           <= S_CMD;
                            end else begin
                                crc_idx <= crc_idx + 2'd1;
                            end
                        end

                        default: st <= S_CMD;
                    endcase
                end
            end
        end else begin
            // Falling edge: the card presents the next bit. Bit 7 of a
            // byte goes out on the eighth falling edge of the previous
            // byte, which is the bit the host samples on the next
            // rising edge, and the rest follow one per falling edge.
            if (tx_bit == 3'd7) begin
                tx_sh  <= {tx_byte[6:0], 1'b1};
                miso_r <= tx_byte[7];
            end else begin
                tx_sh  <= {tx_sh[6:0], 1'b1};
                miso_r <= tx_sh[7];
            end
            tx_bit <= tx_bit + 3'd1;
        end
    end

endmodule

