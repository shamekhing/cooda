// ============================================================
// memory_ddr3  RPU slave <-> memory_ddr3_phy
// ============================================================
//
// Protocol and width adapter. The RPU bus is 32-bit and byte
// addressed; memory_ddr3_phy moves one 16-bit halfword per beat with
// no byte mask and no burst, so every 32-bit access becomes two beats:
//
//   write : wdata[15:0] at halfword A, then wdata[31:16] at A+1
//   read  : halfword A then A+1, assembled as {high, low}
//
// Little-endian, so the low halfword of the word is the lower address.
//
// ONE CLOCK DOMAIN. memory_ddr3_phy runs on the same clk and generates
// its own DDR clock (clk/2) inside, so there is no crossing here.
//
// BEHAVIOUR
//   - The RPU already guarantees valid, aligned, slave-local
//     addresses.
//   - Until the controller reports init done, every access gets a bus
//     error instead of hanging the fabric.
//   - Only full-word writes are supported: the controller has no
//     sub-halfword write mask. A partial strobe is answered with a bus
//     error. The CPU always writes BUS_STRB_ALL.
//   - One outstanding transaction, no pipelining.
//   - rsp.ready is a single-cycle pulse, so the master must drop
//     req.valid after completion. The RPU and CPU do.
// ============================================================

module memory_ddr3 (
    input  logic clk,
    input  logic rst,

    input  soc_pkg::bus_req_s req,
    output soc_pkg::bus_rsp_s rsp,

    // DDR3 pins (see the .cst). ddr3_ck_p/n are the differential DDR
    // clock, ddr3_dq/dqs the SSTL15 data group.
    output logic [13:0]  ddr3_addr,
    output logic [2:0]   ddr3_bank,
    output logic         ddr3_ras,
    output logic         ddr3_cas,
    output logic         ddr3_we,
    output logic         ddr3_ck_p,
    output logic         ddr3_ck_n,
    output logic         ddr3_cke,
    output logic         ddr3_odt,
    output logic         ddr3_rst_n,
    output logic         ddr3_cs,
    output logic [1:0]   ddr3_dm,
    inout  wire  [15:0]  ddr3_dq,
    inout  wire  [1:0]   ddr3_dqs_p,
    inout  wire  [1:0]   ddr3_dqs_n
);

    // ========================================================
    // BRIDGE STATE
    // ========================================================

    typedef enum logic [2:0] {
        StIdle,
        StWrLo,
        StWrHi,
        StRdLo,
        StRdHi,
        StDone
    } state_e;

    state_e state_q, state_d;

    // Controller (memory_ddr3_phy) user interface.
    logic         phy_init_fin;
    logic [26:0]  phy_addr_q,     phy_addr_d;
    logic         phy_wr_valid_q, phy_wr_valid_d;
    logic [15:0]  phy_wr_data_q,  phy_wr_data_d;
    logic         phy_wr_ready;
    logic         phy_rd_ready_q, phy_rd_ready_d;
    logic         phy_rd_valid;
    logic [15:0]  phy_rd_data;

    logic         err_q,   err_d;
    logic [31:0]  rdata_q, rdata_d;

    logic inv_clk;
    assign inv_clk = ~clk;

    // ========================================================
    // RESPONSE
    // ========================================================
    // ready is high for exactly one cycle (StDone), carrying the
    // assembled read data or the error bit.
    // --------------------------------------------------------

    assign rsp.ready = (state_q == StDone);
    assign rsp.rdata = rdata_q;
    assign rsp.error = err_q;

    // ========================================================
    // NEXT-STATE VALUES
    // ========================================================
    // The controller samples sysIO_address during the row-activate and
    // CAS phases of the beat in flight, so the address is held for the
    // whole beat and stepped only once the beat is accepted
    // (wr_ready / rd_valid).
    // --------------------------------------------------------

    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d        = state_q;
        phy_addr_d     = phy_addr_q;
        phy_wr_valid_d = phy_wr_valid_q;
        phy_wr_data_d  = phy_wr_data_q;
        phy_rd_ready_d = phy_rd_ready_q;
        err_d          = err_q;
        rdata_d        = rdata_q;

        case (state_q)

            StIdle: begin
                err_d   = 1'b0;
                rdata_d = '0;

                if (req.valid) begin
                    // Halfword address: byte address / 2. The RPU
                    // region mask is 27 bits, so bit 27 is already 0.
                    phy_addr_d = req.addr[27:1];

                    if (!phy_init_fin) begin
                        // DDR3 not initialised: error, never hang.
                        err_d   = 1'b1;
                        state_d = StDone;

                    end else if (req.op == soc_pkg::BusRead) begin
                        phy_rd_ready_d = 1'b1;
                        state_d        = StRdLo;

                    end else if (req.wstrb == soc_pkg::BUS_STRB_ALL) begin
                        phy_wr_valid_d = 1'b1;
                        phy_wr_data_d  = req.wdata[15:0];
                        state_d        = StWrLo;

                    end else begin
                        // No sub-halfword write mask in the controller.
                        err_d   = 1'b1;
                        state_d = StDone;
                    end
                end
            end

            // ---------------- write: low halfword, then high ------

            StWrLo: begin
                if (phy_wr_ready) begin
                    phy_addr_d    = phy_addr_q + 27'd1;
                    phy_wr_data_d = req.wdata[31:16];
                    state_d       = StWrHi;
                end
            end

            StWrHi: begin
                if (phy_wr_ready) begin
                    phy_wr_valid_d = 1'b0;
                    state_d        = StDone;
                end
            end

            // ---------------- read: low halfword, then high -------

            StRdLo: begin
                if (phy_rd_valid) begin
                    rdata_d    = {rdata_q[31:16], phy_rd_data};
                    phy_addr_d = phy_addr_q + 27'd1;
                    state_d    = StRdHi;
                end
            end

            StRdHi: begin
                if (phy_rd_valid) begin
                    rdata_d        = {phy_rd_data, rdata_q[15:0]};
                    phy_rd_ready_d = 1'b0;
                    state_d        = StDone;
                end
            end

            StDone: state_d = StIdle;

            default: state_d = StIdle;

        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q        <= StIdle;
            phy_addr_q     <= '0;
            phy_wr_valid_q <= 1'b0;
            phy_wr_data_q  <= '0;
            phy_rd_ready_q <= 1'b0;
            err_q          <= 1'b0;
            rdata_q        <= '0;
        end else begin
            state_q        <= state_d;
            phy_addr_q     <= phy_addr_d;
            phy_wr_valid_q <= phy_wr_valid_d;
            phy_wr_data_q  <= phy_wr_data_d;
            phy_rd_ready_q <= phy_rd_ready_d;
            err_q          <= err_d;
            rdata_q        <= rdata_d;
        end
    end

    // ========================================================
    // DDR3 CONTROLLER (vendored, see memory_ddr3_phy.sv)
    // ========================================================

    memory_ddr3_phy u_memory_ddr3_phy (
        .inv_clk (inv_clk),

        .phyIO_address (ddr3_addr),
        .phyIO_bank    (ddr3_bank),
        .phyIO_cs      (ddr3_cs),
        .phyIO_cas     (ddr3_cas),
        .phyIO_ras     (ddr3_ras),
        .phyIO_we      (ddr3_we),
        .phyIO_clk_p   (ddr3_ck_p),
        .phyIO_clk_n   (ddr3_ck_n),
        .phyIO_cke     (ddr3_cke),
        .phyIO_odt     (ddr3_odt),
        .phyIO_rst_n   (ddr3_rst_n),
        .phyIO_dm      (ddr3_dm),
        .phyIO_dq      (ddr3_dq),
        .phyIO_dqs_p   (ddr3_dqs_p),
        .phyIO_dqs_n   (ddr3_dqs_n),

        .sysIO_dataRd_valid   (phy_rd_valid),
        .sysIO_dataRd_ready   (phy_rd_ready_q),
        .sysIO_dataRd_payload (phy_rd_data),

        .sysIO_dataWr_valid   (phy_wr_valid_q),
        .sysIO_dataWr_ready   (phy_wr_ready),
        .sysIO_dataWr_payload (phy_wr_data_q),

        .sysIO_address (phy_addr_q),
        .sysIO_initFin (phy_init_fin),

        .clk    (clk),
        .resetn (~rst)
    );

endmodule
