// ============================================================
// sd_spi_master  one SPI byte on the microSD pins
// ============================================================
//
// The lowest layer of the microSD stack. It turns "send this byte,
// give me the byte that came back" into edges on sck and mosi,
// and samples miso.
//
// SPI MODE 0 (CPOL=0, CPHA=0), which is the mode the SD card
// specification requires in SPI mode:
//   - sck idles low, and is low whenever no transfer is running
//   - mosi changes while sck is low (on the falling edge of the
//     previous bit) and is stable across the rising edge
//   - the card samples mosi on the rising edge
//   - this master samples miso on that same rising edge, which is
//     where the card puts it after the previous falling edge
//
// FULL DUPLEX
//   Every transfer is 8 clocks out and 8 clocks in at once. A card
//   only shifts data out while it is being clocked, so the
//   protocol layer sends 0xFF when it wants to receive something.
//
// SPEED
//   divider is the number of clk cycles in one sck half period:
//
//     sck = clk / (2 * divider)
//
//   Divider 34 with clk=27 MHz is about 397 kHz for initialization.
//   Divider 1 is only correct when clk is at or below 50 MHz, since
//   SPI mode cards are limited to 25 MHz. For a faster source clock,
//   choose a larger divider; the protocol layer can change it between
//   phases. The formula rounds down, so callers should select a divider
//   that keeps SCK within the card's maximum.
//
// CHIP SELECT
//   Not here. cs_n is a protocol concern - it has to stay low for a
//   whole command and its response, not for a single byte - so
//   sd_controller owns that pin and this module only clocks.
//
// HANDSHAKE
//   start is a one-cycle pulse with tx and divider stable. done is
//   one cycle with rx valid. busy is high whenever the engine cannot
//   accept a new start: from the cycle start is seen (so a caller
//   that watches busy, rather than counting cycles, cannot launch a
//   second byte on top of the first) through the done cycle. One
//   transfer at a time: start is ignored while busy, so a stray
//   pulse cannot desynchronise the byte stream.
// ============================================================

module sd_spi_master #(
    parameter int DIVIDER_WIDTH = 16
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             start,
    input  logic [7:0]       tx,
    input  logic [DIVIDER_WIDTH-1:0] divider,
    output logic             busy,
    output logic             done,
    output logic [7:0]       rx,
    output logic             sck,
    output logic             mosi,
    input  logic             miso
);

    typedef enum logic [1:0] {
        SpiIdle  = 2'd0,
        SpiSample = 2'd1,        // driving sck high: sample miso
        SpiShift  = 2'd2         // driving sck low: present the next mosi bit
    } spi_master_state_e;

    spi_master_state_e state_q;
    logic [DIVIDER_WIDTH-1:0] half_period_count;
    logic [2:0]       bit_index;
    logic [7:0]       tx_shift_q;
    logic [7:0]       rx_shift_q;

    // A divider of zero would mean "toggle every cycle with no half
    // period at all", so clamp it to 1.
    logic [DIVIDER_WIDTH-1:0] divider_eff;

    always_comb begin
        divider_eff = divider;
        if (divider == 0)
            divider_eff = 1;
    end

    // busy covers the start cycle itself: a caller that launches a
    // byte and then waits for busy to drop cannot accidentally launch
    // a second one before this engine has picked the first up.
    assign busy = (state_q != SpiIdle) || done || start;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q   <= SpiIdle;
            half_period_count <= '0;
            bit_index <= 3'd0;
            tx_shift_q  <= 8'hFF;
            rx_shift_q   <= 8'h00;
            done    <= 1'b0;
            rx      <= 8'h00;
            sck     <= 1'b0;
            mosi    <= 1'b1;
        end else begin
            done <= 1'b0;

            case (state_q)
                // ------------------------------------------------
                // SpiIdle: sck low, mosi high (the card sees an idle
                // line, which is also what the 74-clock power-up
                // sequence needs).
                // ------------------------------------------------
                SpiIdle: begin
                    sck  <= 1'b0;
                    mosi <= 1'b1;

                    if (start) begin
                        half_period_count <= '0;
                        bit_index <= 3'd0;
                        tx_shift_q  <= tx;
                        rx_shift_q   <= 8'h00;
                        mosi    <= tx[7];       // MSB first
                        state_q   <= SpiSample;
                    end
                end

                // ------------------------------------------------
                // SpiSample: one half period with sck low, then sck goes
                // high. mosi has been stable since the previous
                // falling edge, so the card can sample it, and this
                // is where we sample what the card drove.
                // ------------------------------------------------
                SpiSample: begin
                    if (half_period_count + 1 >= divider_eff) begin
                        half_period_count <= '0;
                        sck     <= 1'b1;
                        rx_shift_q   <= {rx_shift_q[6:0], miso};
                        state_q   <= SpiShift;
                    end else begin
                        half_period_count <= half_period_count + 1;
                    end
                end

                // ------------------------------------------------
                // SpiShift: one half period with sck high, then sck goes
                // low and the next bit is presented.
                // ------------------------------------------------
                SpiShift: begin
                    if (half_period_count + 1 >= divider_eff) begin
                        half_period_count <= '0;
                        sck     <= 1'b0;

                        if (bit_index == 3'd7) begin
                            // rx_shift_q holds all 8 sampled bits: the last
                            // one was taken on this bit's rising edge,
                            // one cycle or more ago.
                            state_q <= SpiIdle;
                            done  <= 1'b1;
                            rx    <= rx_shift_q;
                            mosi  <= 1'b1;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                            tx_shift_q  <= {tx_shift_q[6:0], 1'b0};
                            mosi    <= tx_shift_q[6];
                            state_q   <= SpiSample;
                        end
                    end else begin
                        half_period_count <= half_period_count + 1;
                    end
                end

                default: state_q <= SpiIdle;
            endcase
        end
    end

endmodule
