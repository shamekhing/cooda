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
//   ACMD41 answers 0x01 until ready_after_tries attempts, then 0x00
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
// preloads directly (u_card.block_store[...]).
//
// Timing knobs: r1_idle_bytes 0xFF bytes before an R1, token_idle_bytes 0xFF
// bytes before the 0xFE token, ready_after_tries ACMD41 attempts.
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
    input  logic [7:0]  r1_idle_bytes,
    input  logic [7:0]  token_idle_bytes,
    input  logic [15:0] ready_after_tries,

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
    output logic [5:0]  last_opcode
);

    localparam int BYTES    = BLOCKS * 512;
    localparam int BLOCK_ADDR_WIDTH = $clog2(BLOCKS);

    logic [7:0] block_store [0:BYTES-1];

    // The card's own OCR: bit 31 power-up done, bit 30 CCS (SDHC),
    // bits 23:15 the 2.7-3.6 V window.
    logic [31:0] ocr;
    assign ocr = fault_sdsc ? 32'h80FF_8000 : 32'hC0FF_8000;

    // ========================================================
    // SPI SHIFT MACHINERY
    // ========================================================

    logic [7:0] mosi_shift_q;
    logic [2:0] rx_bit_index;
    logic [7:0] miso_shift_q;
    logic [2:0] tx_bit_index;

    // ========================================================
    // PROTOCOL STATE
    // ========================================================

    typedef enum logic [2:0] {
        CardCollectCmd   = 3'd0,   // collecting six command bytes
        CardDelayR1      = 3'd1,   // 0xFF bytes before the R1
        CardSendResponse = 3'd2,   // the response bytes
        CardDelayToken   = 3'd3,   // 0xFF bytes before the data token
        CardSendToken    = 3'd4,   // the 0xFE token
        CardSendData     = 3'd5,   // 512 data bytes
        CardSendCrc      = 3'd6    // two CRC bytes
    } card_state_e;

    card_state_e         state_q;
    logic [47:0] cmd_shift_q;
    logic [2:0]  cmd_byte_count;
    logic [7:0]  response_bytes [0:4];
    logic [2:0]  response_length, response_index;
    logic [7:0]  r1_delay_count;
    logic        acmd_pending;
    logic [15:0] acmd41_tries;
    logic [31:0] read_lba;
    logic        data_pending;
    logic [15:0] data_index;
    logic [1:0]  crc_index;
    logic [7:0]  token_delay_count;

    // Byte index into the block store: the low bits of the LBA (only
    // BLOCKS blocks are modelled) and the byte inside the block.
    logic [BLOCK_ADDR_WIDTH+9-1:0] block_index;
    assign block_index = {read_lba[BLOCK_ADDR_WIDTH-1:0], data_index[8:0]};

    // What the card should be shifting out right now.
    function automatic logic [7:0] next_tx();
        case (state_q)
            CardSendResponse:  next_tx = response_bytes[response_index];
            CardSendToken: next_tx = 8'hFE;
            CardSendData:  next_tx = block_store[block_index];
            default: next_tx = 8'hFF;
        endcase
    endfunction

    logic [7:0] tx_byte;
    always_comb tx_byte = next_tx();

    logic miso_q;
    assign miso = miso_q;

    // The byte just completed and the command frame it belongs to.
    logic [7:0]  rx_byte;
    logic [47:0] cmd_frame;
    assign rx_byte = {mosi_shift_q[6:0], mosi};
    assign cmd_frame    = {cmd_shift_q[39:0], rx_byte};

    logic [5:0]  cmd_opcode;
    logic [31:0] cmd_argument;
    assign cmd_opcode  = cmd_frame[45:40];
    assign cmd_argument = cmd_frame[39:8];

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
        state_q           = CardCollectCmd;
        cmd_shift_q       = 48'h0;
        cmd_byte_count      = 3'd0;
        mosi_shift_q        = 8'h00;
        rx_bit_index       = 3'd0;
        miso_shift_q        = 8'hFF;
        tx_bit_index       = 3'd0;
        response_index     = 3'd0;
        response_length     = 3'd1;
        r1_delay_count    = 8'd0;
        token_delay_count      = 8'd0;
        data_index     = 16'd0;
        crc_index      = 2'd0;
        acmd_pending    = 1'b0;
        acmd41_tries   = 16'd0;
        read_lba     = 32'd0;
        data_pending = 1'b0;
        miso_q       = 1'b1;
        cmd_count    = 16'd0;
        last_opcode      = 6'd0;
        for (int i = 0; i < BYTES; i++)
            block_store[i] = 8'h00;
    end

    always @(sck or posedge rst) begin
        if (rst) begin
            // Back to a card that has just been powered up. The block
            // store is deliberately left alone: the testbench loads
            // it once and expects it to survive a reset.
            state_q           <= CardCollectCmd;
            cmd_shift_q       <= 48'h0;
            cmd_byte_count      <= 3'd0;
            mosi_shift_q        <= 8'h00;
            rx_bit_index       <= 3'd0;
            miso_shift_q        <= 8'hFF;
            tx_bit_index       <= 3'd0;
            response_index     <= 3'd0;
            response_length     <= 3'd1;
            r1_delay_count    <= 8'd0;
            token_delay_count      <= 8'd0;
            data_index     <= 16'd0;
            crc_index      <= 2'd0;
            acmd_pending    <= 1'b0;
            acmd41_tries   <= 16'd0;
            read_lba     <= 32'd0;
            data_pending <= 1'b0;
            miso_q       <= 1'b1;
            cmd_count    <= 16'd0;
            last_opcode      <= 6'd0;
        end else if (cs_n) begin
            // Deselected: the card is not listening. The host's
            // power-up clocks and the idle byte after a command land
            // here, and this is also what re-frames the byte
            // boundaries before the next command.
            state_q           <= CardCollectCmd;
            cmd_byte_count      <= 3'd0;
            rx_bit_index       <= 3'd0;
            tx_bit_index       <= 3'd0;
            miso_shift_q        <= 8'hFF;
            miso_q       <= 1'b1;
            data_pending <= 1'b0;
        end else if (sck) begin
            // Rising edge: sample mosi.
            mosi_shift_q  <= {mosi_shift_q[6:0], mosi};
            rx_bit_index <= rx_bit_index + 3'd1;

            if (rx_bit_index == 3'd7) begin
                rx_bit_index <= 3'd0;

                if (fault_silent) begin
                    // A deaf card: nothing is ever answered.
                    cmd_byte_count <= 3'd0;
                    state_q      <= CardCollectCmd;
                end else begin
                    case (state_q)
                        // ------------------------------------
                        // Collecting a command. The sixth byte
                        // completes the frame.
                        // ------------------------------------
                        CardCollectCmd: begin
                            cmd_shift_q  <= {cmd_shift_q[39:0], rx_byte};
                            cmd_byte_count <= cmd_byte_count + 3'd1;

                            if (cmd_byte_count == 3'd5) begin
                                cmd_byte_count      <= 3'd0;
                                cmd_count    <= cmd_count + 16'd1;
                                last_opcode      <= cmd_opcode;
                                response_index     <= 3'd0;
                                response_length     <= 3'd1;
                                data_pending <= 1'b0;
                                r1_delay_count    <= r1_idle_bytes;

                                case (cmd_opcode)
                                    6'd0: begin     // CMD0
                                        response_bytes[0] <= 8'h01;
                                    end

                                    6'd8: begin     // CMD8
                                        if (fault_v1) begin
                                            response_bytes[0] <= 8'h05;
                                        end else begin
                                            response_bytes[0]  <= 8'h01;
                                            response_bytes[1]  <= 8'h00;
                                            response_bytes[2]  <= 8'h00;
                                            response_bytes[3]  <= 8'h01;
                                            response_bytes[4]  <= fault_bad_echo ? 8'h55
                                                                       : 8'hAA;
                                            response_length <= 3'd5;
                                        end
                                    end

                                    6'd55: begin    // CMD55
                                        acmd_pending <= 1'b1;
                                        response_bytes[0]   <= 8'h01;
                                    end




                                    6'd41: begin    // ACMD41
                                        acmd_pending <= 1'b0;
                                        if (!acmd_pending) begin
                                            response_bytes[0] <= 8'h04;
                                        end else if (fault_never_ready ||
                                                     (acmd41_tries < ready_after_tries)) begin
                                            acmd41_tries <= acmd41_tries + 16'd1;
                                            response_bytes[0]    <= 8'h01;
                                        end else begin
                                            response_bytes[0] <= 8'h00;
                                        end
                                    end

                                    6'd58: begin    // CMD58
                                        response_bytes[0]  <= 8'h00;
                                        response_bytes[1]  <= ocr[31:24];
                                        response_bytes[2]  <= ocr[23:16];
                                        response_bytes[3]  <= ocr[15:8];
                                        response_bytes[4]  <= ocr[7:0];
                                        response_length <= 3'd5;
                                    end

                                    6'd16: begin    // CMD16
                                        response_bytes[0] <= 8'h00;
                                    end

                                    6'd17: begin    // CMD17
                                        // SDHC takes a sector number, an
                                        // SDSC card a byte address.
                                        read_lba <= ocr[30] ? cmd_argument : (cmd_argument >> 9);
                                        data_index <= 16'd0;
                                        if (fault_bad_cmd17) begin
                                            response_bytes[0] <= 8'h04;
                                        end else begin
                                            response_bytes[0]      <= 8'h00;
                                            data_pending <= 1'b1;
                                        end
                                    end

                                    default: response_bytes[0] <= 8'h05;  // illegal
                                endcase

                                state_q <= (r1_idle_bytes == 0) ? CardSendResponse : CardDelayR1;
                            end
                        end

                        // ------------------------------------
                        // 0xFF bytes before the R1.
                        // ------------------------------------
                        CardDelayR1: begin
                            if (r1_delay_count <= 8'd1) begin
                                response_index <= 3'd0;
                                state_q       <= CardSendResponse;
                            end else begin
                                r1_delay_count <= r1_delay_count - 8'd1;
                            end
                        end

                        // ------------------------------------
                        // The response bytes, then either the block
                        // data or back to listening.
                        // ------------------------------------
                        CardSendResponse: begin
                            if (response_index == response_length - 3'd1) begin
                                response_index <= 3'd0;
                                if (data_pending) begin
                                    token_delay_count <= token_idle_bytes;
                                    state_q      <= CardDelayToken;
                                end else begin
                                    state_q <= CardCollectCmd;
                                end
                            end else begin
                                response_index <= response_index + 3'd1;
                            end
                        end

                        // ------------------------------------
                        // 0xFF bytes while the card "works", then the
                        // data token.
                        // ------------------------------------
                        CardDelayToken: begin
                            if (fault_no_token) begin
                                state_q <= CardDelayToken;
                            end else if (token_delay_count == 8'd0) begin
                                state_q <= CardSendToken;
                            end else begin
                                token_delay_count <= token_delay_count - 8'd1;
                            end
                        end

                        CardSendToken: begin
                            data_index <= 16'd0;
                            state_q       <= CardSendData;
                        end

                        // ------------------------------------
                        // The 512 data bytes.
                        // ------------------------------------
                        CardSendData: begin
                            if (data_index == 16'd511) begin
                                crc_index <= 2'd0;
                                state_q      <= CardSendCrc;
                            end else begin
                                data_index <= data_index + 16'd1;
                            end
                        end

                        // ------------------------------------
                        // Two CRC bytes, then done.
                        // ------------------------------------
                        CardSendCrc: begin
                            if (crc_index == 2'd1) begin
                                data_pending <= 1'b0;
                                state_q           <= CardCollectCmd;
                            end else begin
                                crc_index <= crc_index + 2'd1;
                            end
                        end

                        default: state_q <= CardCollectCmd;
                    endcase
                end
            end
        end else begin
            // Falling edge: the card presents the next bit. Bit 7 of a
            // byte goes out on the eighth falling edge of the previous
            // byte, which is the bit the host samples on the next
            // rising edge, and the rest follow one per falling edge.
            if (tx_bit_index == 3'd7) begin
                miso_shift_q  <= {tx_byte[6:0], 1'b1};
                miso_q <= tx_byte[7];
            end else begin
                miso_shift_q  <= {miso_shift_q[6:0], 1'b1};
                miso_q <= miso_shift_q[7];
            end
            tx_bit_index <= tx_bit_index + 3'd1;
        end
    end

endmodule

