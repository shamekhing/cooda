// ============================================================
// memory_bsram  one on-chip block RAM, as an RPU slave
// ============================================================
//
// PHYSICAL LAYER. A plain read/write block RAM and nothing else:
// no notion of "instruction" or "data", and no read-only mode.
// A BSRAM is read/write by nature. Whether a region is writable is
// decided by which master the address map routes to it, not by the
// memory: the instruction master only ever reads, and the map never
// points a data master at the initialised block, so the code region
// is read-only by construction rather than by a flag here.
//
// INIT_FILE optionally preloads the array at configuration time.
//
// TIMING
//   cycle N   : request presented            (busy_q = 0)
//   cycle N+1 : ready = 1, rdata valid       (busy_q = 1)
//
// The master holds its request through N+1, so the array is sampled
// every cycle with no read enable. A write executes once, at the
// accepting edge, and that cycle returns the old word (read-first);
// masters ignore rdata on writes.
//
// mem_q is written per byte lane, so it has no single next-state
// value; rdata_q and busy_q follow the usual _q / _d pattern.
// ============================================================

module memory_bsram #(
    parameter int WORDS     = 8192,
    // Untyped on purpose: Icarus 12 cannot bind a `parameter string` when it
    // is overridden from a parent's parameter ("Unable to bind variable").
    // The rest of the project uses untyped string parameters for this reason.
    parameter     INIT_FILE = ""
) (
    input  logic clk,
    input  logic rst,

    input  soc_pkg::bus_req_s req,
    output soc_pkg::bus_rsp_s rsp
);

    localparam int INDEX_WIDTH  = $clog2(WORDS);
    localparam int OFFSET_WIDTH = $clog2(arch_pkg::WORD_BYTES);

    arch_pkg::word_t mem_q [0:WORDS-1];

    // The init file must define EVERY word.
    //
    // GowinSynthesis will not infer a BSRAM from a partially-initialised
    // array: with only a short program listed it folded the whole 32 KiB
    // array into 42 LUTs and the data never reached the netlist. Filling the
    // remainder with a loop is not an option either - synthesis stops with
    //   ERROR (EX3934) : Loop count limit of 2000 exceeded
    // because GwSyn_Loop_Limit is 2000 and the array is 8192 words. So the
    // file itself is padded, and this is a plain complete $readmemh.
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem_q);

    logic [INDEX_WIDTH-1:0] index;
    logic                   access;
    logic                   busy_q,  busy_d;
    arch_pkg::word_t        rdata_q, rdata_d;

    assign index  = req.addr[OFFSET_WIDTH +: INDEX_WIDTH];
    // Suppress acceptance as well as writes during reset. This keeps the
    // physical array unchanged even if a master leaves valid asserted.
    assign access = req.valid && !busy_q && !rst;

    // One write process per byte lane: the standard byte-enable pattern for
    // block-RAM inference.
    for (genvar b = 0; b < arch_pkg::WORD_BYTES; b++) begin : g_lane
        always_ff @(posedge clk)
            if (access && req.op == soc_pkg::BusWrite && req.wstrb[b])
                mem_q[index][8*b +: 8] <= req.wdata[8*b +: 8];
    end

    always_comb begin
        rdata_d = mem_q[index];
        busy_d  = !rst && access;
    end

    // The response flops are deliberately NOT reset: an async reset on the
    // output register stops GowinSynthesis inferring a BSRAM. Hardware
    // powers them up at 0, but simulation would see X and never complete a
    // read, so give them a defined power-up value here. Synthesis ignores
    // this initial block for flops.
    initial begin
        rdata_q = '0;
        busy_q  = 1'b0;
    end

    always_ff @(posedge clk) begin
        rdata_q <= rdata_d;
        busy_q  <= busy_d;
    end

    assign rsp.ready = busy_q;
    assign rsp.rdata = rdata_q;
    assign rsp.error = 1'b0;

endmodule
