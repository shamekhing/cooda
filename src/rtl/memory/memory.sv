// ============================================================
// memory  single shared von Neumann BSRAM target
// ============================================================
module memory #(
    parameter INIT_FILE = "src/programs/boot_program.hex"
) (
    input  logic clk,
    input  logic rst,
    input  soc_pkg::bus_req_s req,
    output soc_pkg::bus_rsp_s rsp
);
    logic in_range;
    logic aligned;
    soc_pkg::bus_req_s bsram_req;
    soc_pkg::bus_rsp_s bsram_rsp;

    assign in_range = (req.addr < soc_pkg::MAIN_MEMORY_BYTES);
    assign aligned = soc_pkg::bus_is_aligned(req.addr);
    assign bsram_req = (in_range && aligned) ? req : '0;

    memory_bsram #(
        .WORDS(soc_pkg::MAIN_MEMORY_WORDS),
        .INIT_FILE(INIT_FILE)
    ) u_bsram (
        .clk(clk), .rst(rst), .req(bsram_req), .rsp(bsram_rsp)
    );

    always_comb begin
        rsp = bsram_rsp;
        if (req.valid && (!in_range || !aligned)) begin
            rsp.ready = 1'b1;
            rsp.rdata = '0;
            rsp.error = 1'b1;
        end
    end
endmodule
