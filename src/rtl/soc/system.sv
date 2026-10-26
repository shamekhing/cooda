// ============================================================
// system  CPU + RPU + memory
//
//   cpu (instr) --+
//   cpu (data)  --+--> RPU --+--> ROM
//   gpu  (idle) --+          +--> DATA RAM
//   tpu  (idle) --+          +--> GPU MMIO (stub: bus error)
//                            +--> DDR3 --> memory_ddr3_phy
//
// The CPU never touches memory directly; every access goes
// through the RPU. GPU/TPU masters are tied idle and the GPU MMIO
// slave answers with a bus error until those blocks are linked:
// replace the tie-offs below with the real modules.
//
// The DDR3 pins pass straight through to the top level.
// ============================================================

module system #(
    // Video raster this SoC renders into (800x480 for the RGB LCD).
    parameter int H_RES = 800,
    parameter int V_RES = 480,

    // Boot ROM contents, relative to the project root (where cooda.gprj
    // lives). That is both the directory the simulation runs from and the
    // directory GowinSynthesis resolves $readmemh against - verified with
    // a Gowin build, which reported EX3988 for a ../ path.
    parameter     ROM_INIT_FILE = "src/programs/boot_program.hex"
) (
    input  logic clk,
    input  logic rst,
    input  logic run,

    output logic retire_valid,
    output logic illegal_instr,
    output logic cpu_fault,

    // Video side: raster timing in, pixels out (pix_clk domain).
    input  logic        pix_clk,
    input  logic        pix_rst,
    input  logic        pix_de,
    input  logic [11:0] pix_x,
    input  logic [11:0] pix_y,
    output logic [7:0]  pix_r,
    output logic [7:0]  pix_g,
    output logic [7:0]  pix_b,

    // DDR3 pins
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
    // BUSES
    // ========================================================

    soc_pkg::bus_req_s p_req, cpu_req, gpu_req, tpu_req;
    soc_pkg::bus_rsp_s p_rsp, cpu_rsp, gpu_rsp, tpu_rsp;

    soc_pkg::bus_req_s rom_req, ram_req, gpu_mmio_req, ddr3_req;
    soc_pkg::bus_rsp_s rom_rsp, ram_rsp, gpu_mmio_rsp, ddr3_rsp;

    logic [3:0] mon_m, mon_s;

    // ========================================================
    // TIE-OFFS (until GPU / TPU masters are linked)
    // ========================================================

    assign gpu_req = '0;
    assign tpu_req = '0;

    // ========================================================
    // CPU
    // ========================================================

    cpu u_cpu (
        .clk           (clk),
        .rst           (rst),
        .run           (run),

        .instr_req     (p_req),
        .instr_rsp     (p_rsp),
        .data_req      (cpu_req),
        .data_rsp      (cpu_rsp),

        .retire_valid  (retire_valid),
        .illegal_instr (illegal_instr),
        .fault         (cpu_fault)
    );

    // ========================================================
    // RPU
    // ========================================================

    rpu u_rpu (
        .clk          (clk),
        .rst          (rst),

        .p_req    (p_req),
        .p_rsp    (p_rsp),
        .cpu_req    (cpu_req),
        .cpu_rsp    (cpu_rsp),
        .gpu_req      (gpu_req),
        .gpu_rsp      (gpu_rsp),
        .tpu_req      (tpu_req),
        .tpu_rsp      (tpu_rsp),

        .rom_req      (rom_req),
        .rom_rsp      (rom_rsp),
        .ram_req      (ram_req),
        .ram_rsp      (ram_rsp),
        .gpu_mmio_req (gpu_mmio_req),
        .gpu_mmio_rsp (gpu_mmio_rsp),
        .ddr3_req     (ddr3_req),
        .ddr3_rsp     (ddr3_rsp),

        .mon_m        (mon_m),
        .mon_s        (mon_s)
    );

    // ========================================================
    // GPU (GPU_MMIO slave + bus activity visualiser)
    // ========================================================

    gpu #(.H_RES(H_RES), .V_RES(V_RES)) u_gpu (
        .clk          (clk),
        .rst          (rst),

        .pix_clk      (pix_clk),
        .pix_rst      (pix_rst),

        .req          (gpu_mmio_req),
        .rsp          (gpu_mmio_rsp),

        .mon_m        (mon_m),
        .mon_s        (mon_s),

        .de           (pix_de),
        .x            (pix_x),
        .y            (pix_y),

        .r            (pix_r),
        .g            (pix_g),
        .b            (pix_b)
    );

    // ========================================================
    // MEMORY
    // ========================================================

    memory #(.ROM_INIT_FILE(ROM_INIT_FILE)) u_memory (
        .clk          (clk),
        .rst          (rst),

        .rom_req      (rom_req),
        .rom_rsp      (rom_rsp),
        .ram_req      (ram_req),
        .ram_rsp      (ram_rsp),
        .ddr3_req     (ddr3_req),
        .ddr3_rsp     (ddr3_rsp),

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
