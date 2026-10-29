// ============================================================
// bus_arbiter  reusable round-robin arbiter for one shared target
// ============================================================
//
// Instantiate one arbiter for each target in a multi-master fabric.
// A grant is locked until the target completes the request, then the
// next arbitration starts after the last winner. This keeps payloads
// stable during stalls and prevents starvation.
//
// Client slots are generic. The CPU-only SoC uses clients 0..3 for
// instruction fetch, data access, future GPU traffic, and future TPU
// traffic. A future target such as DDR3 can use the same arbiter.
// ============================================================
module bus_arbiter (
    input  logic clk,
    input  logic rst,
    input  soc_pkg::bus_req_s req0,
    input  soc_pkg::bus_req_s req1,
    input  soc_pkg::bus_req_s req2,
    input  soc_pkg::bus_req_s req3,
    output soc_pkg::bus_rsp_s rsp0,
    output soc_pkg::bus_rsp_s rsp1,
    output soc_pkg::bus_rsp_s rsp2,
    output soc_pkg::bus_rsp_s rsp3,
    output soc_pkg::bus_req_s target_req,
    input  soc_pkg::bus_rsp_s target_rsp
);
    localparam int REQ_W = $bits(soc_pkg::bus_req_s);
    localparam int RSP_W = $bits(soc_pkg::bus_rsp_s);

    logic [3:0] valid_vec;
    logic [3:0] grant, grant_next;
    logic [1:0] last_q, owner_q;
    integer candidate;
    logic locked_q;
    logic accepted;
    logic [REQ_W-1:0] req_bits;

    assign valid_vec = {req3.valid, req2.valid, req1.valid, req0.valid};
    assign grant = locked_q ? (4'b0001 << owner_q) : grant_next;

    always_comb begin
        grant_next = 4'b0;
        for (int offset = 1; offset <= 4; offset++) begin
            candidate = (int'(last_q) + offset) % 4;
            if ((grant_next == 4'b0) && valid_vec[candidate])
                grant_next[candidate] = 1'b1;
        end
    end

    always_comb begin
        req_bits = ({REQ_W{grant[0]}} & REQ_W'(req0))
                 | ({REQ_W{grant[1]}} & REQ_W'(req1))
                 | ({REQ_W{grant[2]}} & REQ_W'(req2))
                 | ({REQ_W{grant[3]}} & REQ_W'(req3));
        target_req = soc_pkg::bus_req_s'(req_bits);

        rsp0 = grant[0] ? target_rsp : '0;
        rsp1 = grant[1] ? target_rsp : '0;
        rsp2 = grant[2] ? target_rsp : '0;
        rsp3 = grant[3] ? target_rsp : '0;
    end

    assign accepted = (grant != 4'b0) && target_rsp.ready;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            locked_q <= 1'b0;
            owner_q  <= '0;
            last_q   <= 2'd3;
        end else if (accepted) begin
            for (int i = 0; i < 4; i++)
                if (grant[i]) last_q <= 2'(i);
            locked_q <= 1'b0;
        end else if (grant != 4'b0 && target_req.valid) begin
            locked_q <= 1'b1;
            for (int i = 0; i < 4; i++)
                if (grant[i]) owner_q <= 2'(i);
        end
    end
endmodule
