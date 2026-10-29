// ============================================================
// memory  shared BSRAM and DDR3 memory subsystem
// ============================================================
module memory #(
    parameter INIT_FILE = "src/programs/boot_program.hex",
    parameter logic [31:0] DDR3_BASE = 32'h0800_0000,
    parameter logic [31:0] DDR3_SIZE = 32'h0800_0000
) (
    input  logic clk,
    input  logic rst,
    input  soc_pkg::bus_req_s target_req,
    output soc_pkg::bus_rsp_s target_rsp,
    output soc_pkg::bus_req_s ddr_req,
    input  soc_pkg::bus_rsp_s ddr_rsp
);
    logic bsram_range, ddr_range, aligned;
    soc_pkg::bus_req_s bsram_req;
    soc_pkg::bus_rsp_s bsram_rsp;

    assign bsram_range = (target_req.addr < soc_pkg::MAIN_MEMORY_BYTES);
    assign ddr_range   = (target_req.addr >= DDR3_BASE) &&
                         (target_req.addr < DDR3_BASE + DDR3_SIZE);
    assign aligned = soc_pkg::bus_is_aligned(target_req.addr);

    assign bsram_req = {
        target_req.valid && bsram_range && aligned,
        target_req.op, target_req.addr, target_req.wdata, target_req.wstrb
    };
    assign ddr_req = {
        target_req.valid && ddr_range,
        target_req.op, target_req.addr - DDR3_BASE,
        target_req.wdata, target_req.wstrb
    };

    memory_bsram #(
        .WORDS(soc_pkg::MAIN_MEMORY_WORDS),
        .INIT_FILE(INIT_FILE)
    ) u_bsram (
        .clk(clk), .rst(rst), .req(bsram_req), .rsp(bsram_rsp)
    );

    always_comb begin
        target_rsp = '0;
        if (ddr_range) begin
            target_rsp = ddr_rsp;
        end else if (bsram_range && aligned) begin
            target_rsp = bsram_rsp;
        end else begin
            target_rsp = '0;
            if (target_req.valid) begin
                target_rsp.ready = 1'b1;
                target_rsp.rdata = '0;
                target_rsp.error = 1'b1;
            end
        end
    end
endmodule
