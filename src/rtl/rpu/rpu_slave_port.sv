// ============================================================
// rpu_slave_port  per-slave round-robin arbiter and request mux
//
// One per slave. Four masters in, one request out.
//
//   sel[i]    master i is requesting this slave (already includes
//             valid, alignment and routing)
//   grant     one-hot owner this cycle
//   ADDR_MASK keeps the slave-local offset (region size - 1)
//
// A grant is held until the slave completes (slave_rsp.ready),
// so a late high-priority master cannot steal a transaction in
// flight. Masters hold their request until completion.
//
// Round-robin: after a master finishes, masters above it are
// preferred, wrapping to the lowest requester.
// ============================================================

module rpu_slave_port #(
    parameter logic [arch_pkg::WORD_WIDTH-1:0] ADDR_MASK = '1
) (
    input  logic clk,
    input  logic rst,

    input  soc_pkg::bus_req_s req0,
    input  soc_pkg::bus_req_s req1,
    input  soc_pkg::bus_req_s req2,
    input  soc_pkg::bus_req_s req3,
    input  logic [3:0]        sel,

    output logic [3:0]        grant,

    output soc_pkg::bus_req_s slave_req,
    input  soc_pkg::bus_rsp_s slave_rsp
);

    localparam int REQ_W = $bits(soc_pkg::bus_req_s);

    logic [3:0] lock_q;   // owner while a transaction is in flight, else 0
    logic [3:0] above_q;  // masters above the last winner
    logic [3:0] hi;
    logic [3:0] pick;
    logic       done;

    // ---------------- Arbitration ----------------

    assign hi    = sel & above_q;
    assign pick  = (hi != 4'b0) ? (hi  & (~hi  + 4'b1))
                                : (sel & (~sel + 4'b1));
    assign grant = (lock_q != 4'b0) ? lock_q : pick;

    assign done  = (grant != 4'b0) && slave_rsp.ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            lock_q  <= 4'b0;
            above_q <= 4'b1111;
        end else if (done) begin
            lock_q  <= 4'b0;
            above_q <= ~(grant | (grant - 4'b1));
        end else if (grant != 4'b0) begin
            lock_q  <= grant;
        end
    end

    // ---------------- Request mux (AND-OR on one-hot grant) ----------------

    always_comb begin
        slave_req = soc_pkg::bus_req_s'(
              ({REQ_W{grant[0]}} & req0)
            | ({REQ_W{grant[1]}} & req1)
            | ({REQ_W{grant[2]}} & req2)
            | ({REQ_W{grant[3]}} & req3)
        );
        slave_req.addr = slave_req.addr & ADDR_MASK;
    end

endmodule
