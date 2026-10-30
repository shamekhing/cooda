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
//   It is a port rather than a parameter because the card needs two
//   speeds: at most 400 kHz while it is waking up, and up to 25 MHz
//   once it is in SPI mode. At 27 MHz, divider 34 is 397 kHz and
//   divider 1 is 13.5 MHz, the fastest this clock can produce. The
//   protocol layer rewrites divider between phases.
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
    parameter int DIV_W = 16
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             start,
    input  logic [7:0]       tx,
    input  logic [DIV_W-1:0] divider,
    output logic             busy,
    output logic             done,
    output logic [7:0]       rx,
    output logic             sck,
    output logic             mosi,
    input  logic             miso
);

    typedef enum logic [1:0] {
        IDLE = 2'd0,
        RISE = 2'd1,        // driving sck high: sample miso
        FALL = 2'd2         // driving sck low: present the next mosi bit
    } state_e;

    state_e           state;
    logic [DIV_W-1:0] div_cnt;
    logic [2:0]       bit_idx;
    logic [7:0]       sh_out;
    logic [7:0]       sh_in;

    // A divider of zero would mean "toggle every cycle with no half
    // period at all", so clamp it to 1 (13.5 MHz at 27 MHz).
    logic [DIV_W-1:0] div_eff;

    always_comb begin
        div_eff = divider;
        if (divider == 0)
            div_eff = 1;
    end

    // busy covers the start cycle itself: a caller that launches a
    // byte and then waits for busy to drop cannot accidentally launch
    // a second one before this engine has picked the first up.
    assign busy = (state != IDLE) || done || start;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= IDLE;
            div_cnt <= '0;
            bit_idx <= 3'd0;
            sh_out  <= 8'hFF;
            sh_in   <= 8'h00;
            done    <= 1'b0;
            rx      <= 8'h00;
            sck     <= 1'b0;
            mosi    <= 1'b1;
        end else begin
            done <= 1'b0;

            case (state)
                // ------------------------------------------------
                // IDLE: sck low, mosi high (the card sees an idle
                // line, which is also what the 74-clock power-up
                // sequence needs).
                // ------------------------------------------------
                IDLE: begin
                    sck  <= 1'b0;
                    mosi <= 1'b1;

                    if (start) begin
                        div_cnt <= '0;
                        bit_idx <= 3'd0;
                        sh_out  <= tx;
                        sh_in   <= 8'h00;
                        mosi    <= tx[7];       // MSB first
                        state   <= RISE;
                    end
                end

                // ------------------------------------------------
                // RISE: one half period with sck low, then sck goes
                // high. mosi has been stable since the previous
                // falling edge, so the card can sample it, and this
                // is where we sample what the card drove.
                // ------------------------------------------------
                RISE: begin
                    if (div_cnt + 1 >= div_eff) begin
                        div_cnt <= '0;
                        sck     <= 1'b1;
                        sh_in   <= {sh_in[6:0], miso};
                        state   <= FALL;
                    end else begin
                        div_cnt <= div_cnt + 1;
                    end
                end

                // ------------------------------------------------
                // FALL: one half period with sck high, then sck goes
                // low and the next bit is presented.
                // ------------------------------------------------
                FALL: begin
                    if (div_cnt + 1 >= div_eff) begin
                        div_cnt <= '0;
                        sck     <= 1'b0;

                        if (bit_idx == 3'd7) begin
                            // sh_in holds all 8 sampled bits: the last
                            // one was taken on this bit's rising edge,
                            // one cycle or more ago.
                            state <= IDLE;
                            done  <= 1'b1;
                            rx    <= sh_in;
                            mosi  <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                            sh_out  <= {sh_out[6:0], 1'b0};
                            mosi    <= sh_out[6];
                            state   <= RISE;
                        end
                    end else begin
                        div_cnt <= div_cnt + 1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
