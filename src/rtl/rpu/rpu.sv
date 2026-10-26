// ============================================================
// rpu  routing processing unit: 4 masters x 4 slaves
//
//   masters : cpu_i (instruction fetch), cpu_d (data), gpu, tpu
//   slaves  : rom, ram, gpu_mmio, ddr3
//
// Routing policy and address map live in soc_pkg.
//
// Each slave has its own arbiter (rpu_slave_port), so transfers
// to different slaves run in parallel. A request that is
// unaligned, unmapped, reserved, or not visible to its master
// never reaches a slave: the master gets an immediate error.
//
// The four masters are written out explicitly because Icarus
// Verilog 12 cannot elaborate arrays of ports.
// ============================================================

module rpu (
    input  logic clk,
    input  logic rst,

    // Masters
    input  soc_pkg::bus_req_s p_req,
    input  soc_pkg::bus_req_s cpu_req,
    input  soc_pkg::bus_req_s gpu_req,
    input  soc_pkg::bus_req_s tpu_req,

    output soc_pkg::bus_rsp_s p_rsp,
    output soc_pkg::bus_rsp_s cpu_rsp,
    output soc_pkg::bus_rsp_s gpu_rsp,
    output soc_pkg::bus_rsp_s tpu_rsp,

    // Slaves
    input  soc_pkg::bus_rsp_s rom_rsp,
    input  soc_pkg::bus_rsp_s ram_rsp,
    input  soc_pkg::bus_rsp_s gpu_mmio_rsp,
    input  soc_pkg::bus_rsp_s ddr3_rsp,

    output soc_pkg::bus_req_s rom_req,
    output soc_pkg::bus_req_s ram_req,
    output soc_pkg::bus_req_s gpu_mmio_req,
    output soc_pkg::bus_req_s ddr3_req,

    // --------------------------------------------------------
    // Passive monitor taps for the GPU bus visualiser.
    //   mon_m[i] master i owns a slave this cycle
    //   mon_s[j] slave j is being served this cycle
    // Slave order is rom, ram, gpu_mmio, ddr3 (the SLAVE_* order).
    // --------------------------------------------------------
    output logic [3:0] mon_m,
    output logic [3:0] mon_s
);

    import soc_pkg::SLAVE_ROM;
    import soc_pkg::SLAVE_DATA_RAM;
    import soc_pkg::SLAVE_GPU_MMIO;
    import soc_pkg::SLAVE_DDR3;

    localparam int RSP_W = $bits(soc_pkg::bus_rsp_s);

    // ========================================================
    // ROUTE: one-hot slave select per master (0 = no slave)
    // ========================================================

    soc_pkg::slave_sel_t sel0, sel1, sel2, sel3;

    // The instruction port is read-only. Treat a write like any other
    // unroutable request so it gets an immediate bus error and never
    // reaches the physical ROM BSRAM.
    assign sel0 = (p_req.valid && p_req.op == soc_pkg::BusRead &&
                   soc_pkg::bus_is_aligned(p_req.addr))
                ? soc_pkg::route_instr(p_req.addr) : '0;
    assign sel1 = (cpu_req.valid && soc_pkg::bus_is_aligned(cpu_req.addr))
                ? soc_pkg::route_data(cpu_req.addr)  : '0;
    assign sel2 = (gpu_req.valid   && soc_pkg::bus_is_aligned(gpu_req.addr))
                ? soc_pkg::route_data(gpu_req.addr)    : '0;
    assign sel3 = (tpu_req.valid   && soc_pkg::bus_is_aligned(tpu_req.addr))
                ? soc_pkg::route_data(tpu_req.addr)    : '0;

    // A valid request that selects nothing is answered with an error.
    logic err0, err1, err2, err3;

    assign err0 = p_req.valid && (sel0 == '0);
    assign err1 = cpu_req.valid && (sel1 == '0);
    assign err2 = gpu_req.valid   && (sel2 == '0);
    assign err3 = tpu_req.valid   && (sel3 == '0);

    // ========================================================
    // SLAVE PORTS
    // ========================================================

    logic [3:0] g_rom, g_ram, g_gpu, g_ddr3;   // grant[i] = master i owns the slave

    rpu_slave_port #(.ADDR_MASK(soc_pkg::MAP_ROM_MASK)) u_rom (
        .clk(clk), .rst(rst),
        .req0(p_req), .req1(cpu_req), .req2(gpu_req), .req3(tpu_req),
        .sel({sel3[SLAVE_ROM], sel2[SLAVE_ROM], sel1[SLAVE_ROM], sel0[SLAVE_ROM]}),
        .grant(g_rom), .slave_req(rom_req), .slave_rsp(rom_rsp)
    );

    rpu_slave_port #(.ADDR_MASK(soc_pkg::MAP_RAM_MASK)) u_ram (
        .clk(clk), .rst(rst),
        .req0(p_req), .req1(cpu_req), .req2(gpu_req), .req3(tpu_req),
        .sel({sel3[SLAVE_DATA_RAM], sel2[SLAVE_DATA_RAM], sel1[SLAVE_DATA_RAM], sel0[SLAVE_DATA_RAM]}),
        .grant(g_ram), .slave_req(ram_req), .slave_rsp(ram_rsp)
    );

    rpu_slave_port #(.ADDR_MASK(soc_pkg::MAP_GPU_MASK)) u_gpu_mmio (
        .clk(clk), .rst(rst),
        .req0(p_req), .req1(cpu_req), .req2(gpu_req), .req3(tpu_req),
        .sel({sel3[SLAVE_GPU_MMIO], sel2[SLAVE_GPU_MMIO], sel1[SLAVE_GPU_MMIO], sel0[SLAVE_GPU_MMIO]}),
        .grant(g_gpu), .slave_req(gpu_mmio_req), .slave_rsp(gpu_mmio_rsp)
    );

    rpu_slave_port #(.ADDR_MASK(soc_pkg::MAP_DDR3_MASK)) u_ddr3 (
        .clk(clk), .rst(rst),
        .req0(p_req), .req1(cpu_req), .req2(gpu_req), .req3(tpu_req),
        .sel({sel3[SLAVE_DDR3], sel2[SLAVE_DDR3], sel1[SLAVE_DDR3], sel0[SLAVE_DDR3]}),
        .grant(g_ddr3), .slave_req(ddr3_req), .slave_rsp(ddr3_rsp)
    );

    // ========================================================
    // RESPONSES
    // ========================================================
    //
    // A master sees a slave's response only while it owns that
    // slave (one-hot AND-OR), so `ready` can never reach the wrong
    // master. An unroutable request gets ready + error.
    // ========================================================

    // --------------------------------------------------------
    // Response mux.
    //
    // Every input is an ARGUMENT on purpose: a function that reads
    // module-level signals directly is not re-evaluated when those
    // signals change (Icarus derives the sensitivity list from the
    // arguments), so a slave's ready would never reach the master.
    // Struct members are widened to plain vectors for the AND-OR.
    // --------------------------------------------------------

    function automatic soc_pkg::bus_rsp_s rsp_mux(
        input soc_pkg::bus_rsp_s rom_rsp_i,
        input soc_pkg::bus_rsp_s ram_rsp_i,
        input soc_pkg::bus_rsp_s gpu_rsp_i,
        input soc_pkg::bus_rsp_s ddr3_rsp_i,
        input logic g_rom_i, g_ram_i, g_gpu_i, g_ddr3_i,
        input logic err
    );
        soc_pkg::bus_rsp_s r;
        logic [RSP_W-1:0] muxed;

        muxed = ({RSP_W{g_rom_i }} & RSP_W'(rom_rsp_i))
              | ({RSP_W{g_ram_i }} & RSP_W'(ram_rsp_i))
              | ({RSP_W{g_gpu_i }} & RSP_W'(gpu_rsp_i))
              | ({RSP_W{g_ddr3_i}} & RSP_W'(ddr3_rsp_i));

        r = soc_pkg::bus_rsp_s'(muxed);

        r.ready = r.ready | err;
        r.error = r.error | err;

        return r;
    endfunction

    assign p_rsp = rsp_mux(rom_rsp, ram_rsp, gpu_mmio_rsp, ddr3_rsp,
                           g_rom[0], g_ram[0], g_gpu[0], g_ddr3[0], err0);

    assign cpu_rsp = rsp_mux(rom_rsp, ram_rsp, gpu_mmio_rsp, ddr3_rsp,
                             g_rom[1], g_ram[1], g_gpu[1], g_ddr3[1], err1);

    assign gpu_rsp = rsp_mux(rom_rsp, ram_rsp, gpu_mmio_rsp, ddr3_rsp,
                             g_rom[2], g_ram[2], g_gpu[2], g_ddr3[2], err2);

    assign tpu_rsp = rsp_mux(rom_rsp, ram_rsp, gpu_mmio_rsp, ddr3_rsp,
                             g_rom[3], g_ram[3], g_gpu[3], g_ddr3[3], err3);

    // ========================================================
    // MONITOR TAPS
    // ========================================================
    // Pure observation: a slave is "served" while any master owns it,
    // and a master is "active" while it owns any slave. The visualiser
    // turns each transaction into a pixel-area transfer.
    // --------------------------------------------------------

    assign mon_s = {
        (g_ddr3 != 4'd0),   // slave 3 = ddr3
        (g_gpu  != 4'd0),   // slave 2 = gpu_mmio
        (g_ram  != 4'd0),   // slave 1 = ram
        (g_rom  != 4'd0)    // slave 0 = rom
    };

    assign mon_m = {
        (g_ddr3[3] | g_gpu[3] | g_ram[3] | g_rom[3]),   // master 3 = tpu
        (g_ddr3[2] | g_gpu[2] | g_ram[2] | g_rom[2]),   // master 2 = gpu
        (g_ddr3[1] | g_gpu[1] | g_ram[1] | g_rom[1]),   // master 1 = cpu_d
        (g_ddr3[0] | g_gpu[0] | g_ram[0] | g_rom[0])    // master 0 = cpu_i
    };

endmodule
