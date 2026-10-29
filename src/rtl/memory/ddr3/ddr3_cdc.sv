// ============================================================
// ddr3_cdc  one bus transaction across clk27 <-> pclk
// ============================================================
//
// The SoC bus runs on clk27; the DDR3 controller runs on pclk
// (99.56 MHz, see ddr3_pll.sv). This module moves one
// transaction at a time between the two domains.
//
// PROTOCOL
//   SoC side : assert req with addr/wr/wdata and hold it until
//              ack pulses. ack is one clk_s cycle, and rdata/err
//              are valid on that cycle. One outstanding request:
//              req is ignored while a transaction is in flight.
//   cmd side : cmd_req rises with a stable payload and stays up
//              until cmd_done pulses. The engine may take any
//              number of clk_c cycles. cmd_rdata/cmd_err are
//              sampled on the cmd_done cycle.
//
// HOW THE CROSSING IS SAFE
//   Only two toggle bits cross, each through a two-flop
//   synchroniser. Both payloads are captured in their own domain
//   *before* the corresponding toggle moves and are held until
//   the handshake finishes, so no payload bit is ever sampled
//   while it is changing:
//     - the SoC side latches addr/wr/wdata and only then flips
//       req_tgl; the cmd side samples that payload at least two
//       clk_c cycles later, and the SoC side cannot start another
//       transaction until ack returns;
//     - the cmd side latches rdata/err and only then flips
//       resp_tgl; the SoC side samples them two clk_s cycles
//       later.
//   The two clocks are unrelated (27 MHz and 99.56 MHz are not
//   multiples), which is exactly the case this handles.
//
// Latency is roughly two clk_c cycles plus two clk_s cycles plus
// the transaction itself; a few hundred nanoseconds.
// ============================================================

module ddr3_cdc #(
    parameter int ADDR_W = 27
) (
    // SoC domain
    input  logic              clk_s,
    input  logic              rst_s,
    input  logic              req,
    input  logic [ADDR_W-1:0] addr,
    input  logic              wr,
    input  logic [31:0]       wdata,
    output logic              ack,
    output logic [31:0]       rdata,
    output logic              err,

    // DDR3 controller domain
    input  logic              clk_c,
    input  logic              rst_c,
    output logic              cmd_req,
    output logic [ADDR_W-1:0] cmd_addr,
    output logic              cmd_wr,
    output logic [31:0]       cmd_wdata,
    input  logic              cmd_done,
    input  logic [31:0]       cmd_rdata,
    input  logic              cmd_err
);

    // ========================================================
    // CROSSING BITS AND PAYLOADS
    // ========================================================

    // SoC side state.
    logic              busy_s;
    logic              req_tgl_s;
    logic              resp_tgl_s;

    // SoC side payload, held for the whole transaction.
    logic [ADDR_W-1:0] addr_s;
    logic              wr_s;
    logic [31:0]       wdata_s;

    // Controller side state.
    logic              req_tgl_c;
    logic              resp_tgl_c;

    // Controller side payload, held for the whole transaction.
    logic [ADDR_W-1:0] addr_c;
    logic              wr_c;
    logic [31:0]       wdata_c;
    logic [31:0]       rdata_c;
    logic              err_c;

    // Two-flop synchronisers.
    logic req_tgl_c_s1, req_tgl_c_s2;
    logic resp_tgl_s_s1, resp_tgl_s_s2;



    // ========================================================
    // SoC DOMAIN
    // ========================================================
    // Acknowledge the response, then accept the next request.
    // busy_s blocks a second request until the first is answered.
    // --------------------------------------------------------

    always_ff @(posedge clk_s or posedge rst_s) begin
        if (rst_s) begin
            busy_s     <= 1'b0;
            req_tgl_s  <= 1'b0;
            resp_tgl_s <= 1'b0;
            addr_s     <= '0;
            wr_s       <= 1'b0;
            wdata_s    <= '0;
            ack        <= 1'b0;
            rdata      <= '0;
            err        <= 1'b0;
        end else begin
            ack <= 1'b0;

            // Response arrives: latch it and free the request slot.
            // rdata_c/err_c have been stable since resp_tgl_c moved.
            if (resp_tgl_s_s2 != resp_tgl_s) begin
                resp_tgl_s <= resp_tgl_s_s2;
                rdata      <= rdata_c;
                err        <= err_c;
                ack        <= 1'b1;
                busy_s     <= 1'b0;
            end

            // New request: capture the payload first, then flip the
            // toggle that tells the other side it is there.
            if (req && !busy_s && !ack) begin
                addr_s    <= addr;
                wr_s      <= wr;
                wdata_s   <= wdata;
                busy_s    <= 1'b1;
                req_tgl_s <= ~req_tgl_s;
            end
        end
    end

    // ========================================================
    // CONTROLLER DOMAIN
    // ========================================================
    // cmd_req is a level: it stays up until the engine reports
    // done, so the engine never has to worry about a one-cycle
    // request being missed.
    // --------------------------------------------------------

    always_ff @(posedge clk_c or posedge rst_c) begin
        if (rst_c) begin
            req_tgl_c  <= 1'b0;
            resp_tgl_c <= 1'b0;
            addr_c     <= '0;
            wr_c       <= 1'b0;
            wdata_c    <= '0;
            rdata_c    <= '0;
            err_c      <= 1'b0;
            cmd_req    <= 1'b0;
        end else begin
            // Request arrives: the payload has been stable in the
            // clk_s domain since before the toggle moved.
            if (req_tgl_c_s2 != req_tgl_c) begin
                req_tgl_c <= req_tgl_c_s2;
                addr_c    <= addr_s;
                wr_c      <= wr_s;
                wdata_c   <= wdata_s;
                cmd_req   <= 1'b1;
            end

            // Engine finished: latch the result, then tell the SoC.
            if (cmd_req && cmd_done) begin
                cmd_req    <= 1'b0;
                rdata_c    <= cmd_rdata;
                err_c      <= cmd_err;
                resp_tgl_c <= ~resp_tgl_c;
            end
        end
    end

    // ========================================================
    // SYNCHRONISERS
    // ========================================================

    always_ff @(posedge clk_c or posedge rst_c) begin
        if (rst_c) begin
            req_tgl_c_s1 <= 1'b0;
            req_tgl_c_s2 <= 1'b0;
        end else begin
            req_tgl_c_s1 <= req_tgl_s;
            req_tgl_c_s2 <= req_tgl_c_s1;
        end
    end

    always_ff @(posedge clk_s or posedge rst_s) begin
        if (rst_s) begin
            resp_tgl_s_s1 <= 1'b0;
            resp_tgl_s_s2 <= 1'b0;
        end else begin
            resp_tgl_s_s1 <= resp_tgl_c;
            resp_tgl_s_s2 <= resp_tgl_s_s1;
        end
    end

    // ========================================================
    // ENGINE-FACING OUTPUTS
    // ========================================================

    assign cmd_addr  = addr_c;
    assign cmd_wr    = wr_c;
    assign cmd_wdata = wdata_c;

endmodule
