`timescale 1ns/1ps
// ============================================================
// sd_spi_master_tb  unit test for the SPI byte engine
// ============================================================
//
// A behavioural SPI slave plays the card's side of the wire and
// checks:
//   1. MOSI bit order: the slave receives exactly the byte sent,
//      MSB first
//   2. MISO sampling: the master reports exactly the byte the slave
//      drove
//   3. full duplex: one byte each way per transfer
//   4. sck idles low, is low between transfers, and produces
//      exactly 8 rising edges per byte
//   5. the divider sets the sck period: 397 kHz for the card's
//      wake-up phase and 13.5 MHz for the data phase, with a
//      zero divider clamped to 1
//   6. done pulses once per start, and start while busy is ignored
//   7. reset in the middle of a transfer returns sck to idle low
//      and leaves no done pulse behind
// ============================================================

module sd_spi_master_tb;

    // ---------------- clock / reset ----------------
    logic clk = 1'b0;
    always #18.518 clk = ~clk;              // 27 MHz, 37.036 ns

    localparam real CLK_NS = 37.036;

    logic rst = 1'b1;

    // ---------------- DUT ----------------
    logic        start;
    logic [7:0]  tx;
    logic [15:0] divider;
    logic        busy;
    logic        done;
    logic [7:0]  rx;
    logic        sck;
    logic        mosi;
    logic        miso;

    sd_spi_master dut (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .tx      (tx),
        .divider (divider),
        .busy    (busy),
        .done    (done),
        .rx      (rx),
        .sck     (sck),
        .mosi    (mosi),
        .miso    (miso)
    );

    int errors = 0;
    int checks = 0;

    // ========================================================
    // BEHAVIOURAL SPI SLAVE (the card's side of the wire)
    // ========================================================
    // mosi is sampled on the rising edge of sck and miso changes on
    // the falling edge, which is what a real card does. sl_load
    // presents the first bit while sck is idle - the moment a card
    // has had its chip select asserted and has a byte queued.
    // --------------------------------------------------------

    logic [7:0] sl_tx      = 8'h00;     // byte the slave returns
    logic [7:0] sl_rx;
    logic [7:0] sl_rx_hold;             // ... captured, after 8 bits
    logic       sl_got     = 1'b0;      // a whole byte arrived
    logic       sl_load    = 1'b0;      // pulse: present sl_tx[7]
    logic       sl_miso    = 1'b1;
    logic [2:0] sl_rx_bit;
    logic [2:0] sl_tx_bit;

    assign miso = sl_miso;

    always @(sck or posedge sl_load) begin
        if (sl_load) begin
            sl_miso   <= sl_tx[7];
            sl_tx_bit <= 3'd0;
            sl_rx     <= 8'h00;
            sl_rx_bit <= 3'd0;
            sl_got    <= 1'b0;
        end else if (sck) begin
            sl_rx <= {sl_rx[6:0], mosi};
            if (sl_rx_bit == 3'd7) begin
                sl_rx_hold <= {sl_rx[6:0], mosi};
                sl_got     <= 1'b1;
            end
            sl_rx_bit <= sl_rx_bit + 3'd1;
        end else begin
            sl_miso   <= (sl_tx_bit == 3'd7) ? 1'b1 : sl_tx[6 - sl_tx_bit];
            sl_tx_bit <= sl_tx_bit + 3'd1;
        end
    end

    // Every rising edge on the wire, counted for the checks below.
    int n_rises = 0;
    always @(posedge sck) n_rises++;


    // ========================================================
    // TRANSFER DRIVER
    // ========================================================
    // Issues one byte and checks every property of it.
    // --------------------------------------------------------

    task automatic xfer(input logic [7:0]  send,
                        input logic [7:0]  reply,
                        input logic [15:0] div,
                        input string       name);
        realtime t0, t1;
        real     expected;
        int      rises0;

        divider = div;
        tx      = send;
        sl_tx   = reply;
        rises0  = n_rises;
        sl_load = 1'b1;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        sl_load = 1'b0;

        checks++;
        if (!busy) begin
            errors++;
            $display("FAIL %s: busy is low after start", name);
        end

        // Eight rising edges, then the done pulse.
        @(posedge sck); t0 = $realtime;
        for (int i = 1; i < 8; i++) @(posedge sck);
        t1 = $realtime;

        while (!done) @(negedge clk);

        checks++;
        if (rx !== reply) begin
            errors++;
            $display("FAIL %s rx: got %02h expected %02h", name, rx, reply);
        end

        checks++;
        if (sl_rx_hold !== send) begin
            errors++;
            $display("FAIL %s mosi: slave received %02h expected %02h",
                     name, sl_rx_hold, send);
        end

        checks++;
        if (!sl_got) begin
            errors++;
            $display("FAIL %s: slave never saw a whole byte", name);
        end

        checks++;
        if (n_rises - rises0 != 8) begin
            errors++;
            $display("FAIL %s: %0d sck rising edges, expected 8",
                     name, n_rises - rises0);
        end

        // Seven bit periods between the first and the last rising
        // edge: 14 sck half periods of divider clk cycles each. A
        // zero divider must behave like 1 (see sd_spi_master).
        expected = 14.0 * real'(div == 0 ? 16'd1 : div) * CLK_NS;
        checks++;
        if ((t1 - t0) < expected - 3.0 || (t1 - t0) > expected + 3.0) begin
            errors++;
            $display("FAIL %s period: %0f ns for 7 bits, expected %0f ns (divider %0d)",
                     name, t1 - t0, expected, div);
        end

        // sck back to idle low, and not busy any more.
        repeat (2) @(negedge clk);
        checks++;
        if (sck !== 1'b0) begin
            errors++;
            $display("FAIL %s: sck is not idle low after the transfer", name);
        end
        checks++;
        if (busy !== 1'b0) begin
            errors++;
            $display("FAIL %s: busy is still high after the transfer", name);
        end
    endtask

    // ========================================================
    // SEQUENCE
    // ========================================================

    logic [31:0] lfsr   = 32'hC0DA_1234;
    logic [7:0]  rnd_s, rnd_r;
    int          rises0;

    // Deterministic bytes, so a failure can be reproduced exactly.
    function automatic logic [7:0] next_byte();
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        return lfsr[7:0];
    endfunction

    initial begin
        start   = 1'b0;
        tx      = 8'h00;
        divider = 16'd1;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        // 1. the line is idle after reset.
        checks++;
        if (sck !== 1'b0 || mosi !== 1'b1 || busy !== 1'b0 || done !== 1'b0) begin
            errors++;
            $display("FAIL idle after reset: sck=%0b mosi=%0b busy=%0b done=%0b",
                     sck, mosi, busy, done);
        end

        // 2. one byte at each speed: the data-phase divider, the
        //    card's wake-up divider, a zero divider that must be
        //    clamped to 1, and a middle divider.
        xfer(8'hA5, 8'h3C, 16'd1,  "13.5 MHz");
        xfer(8'h00, 8'hFF, 16'd34, "397 kHz");
        xfer(8'hFF, 8'h00, 16'd0,  "clamped divider");
        xfer(8'h5A, 8'h81, 16'd2,  "divider 2");

        // 3. back-to-back bytes with no gap between them.
        for (int i = 0; i < 8; i++) begin
            xfer(8'(8'h30 + i), 8'(8'hC0 - i), 16'd3, "back-to-back");
        end

        // 4. pseudo-random bytes in both directions.
        for (int i = 0; i < 64; i++) begin
            rnd_s = next_byte();
            rnd_r = next_byte();
            xfer(rnd_s, rnd_r, 16'(1 + (i % 8)), "random");
        end

        // 5. start while busy is ignored: a stray pulse in the
        //    middle of a byte must not disturb the byte stream.
        rises0  = n_rises;
        divider = 16'd4;
        tx      = 8'h3C;
        sl_tx   = 8'hC3;
        sl_load = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        sl_load = 1'b0;
        repeat (6) @(negedge clk);
        start = 1'b1;                       // stray pulse, mid-byte
        @(negedge clk);
        start = 1'b0;
        while (!done) @(negedge clk);
        checks++;
        if (rx !== 8'hC3 || sl_rx_hold !== 8'h3C || (n_rises - rises0) != 8) begin
            errors++;
            $display("FAIL start while busy: rx=%02h slave=%02h edges=%0d",
                     rx, sl_rx_hold, n_rises - rises0);
        end

        // 6. reset in the middle of a transfer: sck must come back
        //    to idle low with no done pulse left behind.
        divider = 16'd4;
        tx      = 8'hFF;
        sl_tx   = 8'hFF;
        sl_load = 1'b1;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        sl_load = 1'b0;
        repeat (3) @(posedge sck);
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        checks++;
        if (sck !== 1'b0 || mosi !== 1'b1 || busy !== 1'b0 || done !== 1'b0) begin
            errors++;
            $display("FAIL reset mid-transfer: sck=%0b mosi=%0b busy=%0b done=%0b",
                     sck, mosi, busy, done);
        end

        // 7. and the engine still works after that reset.
        xfer(8'h96, 8'h69, 16'd2, "after reset");

        if (errors == 0)
            $display("PASS: sd_spi_master %0d checks", checks);
        else
            $fatal(1, "FAIL: sd_spi_master %0d checks, %0d errors", checks, errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "sd_spi_master_tb timeout");
    end

endmodule

