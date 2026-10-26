// ============================================================
// memory  the physical memories behind the RPU
// ============================================================
//
//   Two memory_bsram blocks and memory_ddr3, which bridges the RPU to
//   the open-source DDR3 controller memory_ddr3_phy. All three are RPU
//   slaves and receive slave-local byte addresses.
//
//   The instruction/data split is NOT expressed here. It lives in
//   soc_pkg's address map and the RPU's route_instr / route_data.
//   u_memory_bsram_rom happens to hold code and u_memory_bsram_ram
//   happens to hold data only because of which master each one is
//   routed to.
//
// The DDR3 pins leave the die through this module, so the top level
// only has to constrain them.
// ============================================================

module memory #(
    parameter ROM_INIT_FILE = "src/programs/boot_program.hex",
    parameter RAM_INIT_FILE = ""
) (
    input  logic clk,
    input  logic rst,

    input  soc_pkg::bus_req_s rom_req,
    output soc_pkg::bus_rsp_s rom_rsp,

    input  soc_pkg::bus_req_s ram_req,
    output soc_pkg::bus_rsp_s ram_rsp,

    input  soc_pkg::bus_req_s ddr3_req,
    output soc_pkg::bus_rsp_s ddr3_rsp,

    // DDR3 pins, straight through to the top level.
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

    // Physical blocks. The instruction/data split is NOT here - it is in
    // soc_pkg's address map and the RPU's route_instr / route_data.
    memory_bsram #(.WORDS(soc_pkg::INSTRUCTION_ROM_WORDS),
                   .INIT_FILE(ROM_INIT_FILE)) u_memory_bsram_rom (
        .clk(clk), .rst(rst), .req(rom_req), .rsp(rom_rsp)
    );

    memory_bsram #(.WORDS(soc_pkg::DATA_RAM_WORDS),
                   .INIT_FILE(RAM_INIT_FILE)) u_memory_bsram_ram (
        .clk(clk), .rst(rst), .req(ram_req), .rsp(ram_rsp)
    );

    memory_ddr3 u_memory_ddr3 (
        .clk(clk), .rst(rst),
        .req(ddr3_req), .rsp(ddr3_rsp),

        .ddr3_addr    (ddr3_addr),
        .ddr3_bank    (ddr3_bank),
        .ddr3_ras     (ddr3_ras),
        .ddr3_cas     (ddr3_cas),
        .ddr3_we      (ddr3_we),
        .ddr3_ck_p    (ddr3_ck_p),
        .ddr3_ck_n    (ddr3_ck_n),
        .ddr3_cke     (ddr3_cke),
        .ddr3_odt     (ddr3_odt),
        .ddr3_rst_n   (ddr3_rst_n),
        .ddr3_cs      (ddr3_cs),
        .ddr3_dm      (ddr3_dm),
        .ddr3_dq      (ddr3_dq),
        .ddr3_dqs_p   (ddr3_dqs_p),
        .ddr3_dqs_n   (ddr3_dqs_n)
    );

endmodule
