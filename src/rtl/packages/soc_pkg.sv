`ifndef SOC_PKG_SV
`define SOC_PKG_SV

// ============================================================
// soc_pkg  bus protocol, memory sizes, address map, routing
//
// Depends on: arch_pkg
//
// BUS
//   - 32-bit words, byte-addressed, word-aligned
//   - Completion on a rising edge with req.valid && rsp.ready
//   - A master holds its whole request stable until completion
//   - A slave only ever sees requests that are valid, aligned,
//     in range, and already translated to a slave-local address
//     (the RPU guarantees this), so slaves need no checks of
//     their own. Exception: writes to the ROM, which the ROM
//     answers with an error.
//
// ADDRESS MAP
//
//  Region       Base         Size    Slave       Seen by
//  ----------   ----------   -----   ---------   ----------------
//  ROM          0x0000_0000  32 KiB  ROM         CPU instruction
//  DATA_RAM     0x0000_0000  32 KiB  DATA_RAM    CPU data, GPU, TPU
//  GPU_MMIO     0x1000_0000   4 KiB  GPU_MMIO    CPU data, GPU, TPU
//  (reserved)   0x1000_1000..0x1000_5000: TPU/DMA/SD/SYSTEM MMIO,
//               not implemented, decodes as a bus error
//  DDR3         0x8000_0000  128 MiB DDR3        CPU data, GPU, TPU
//
// Every region is a power-of-two size on a size-aligned base, so
// decode is a masked prefix compare and the slave-local address is
// just `addr & mask`. ROM/RAM overlap at 0 is intentional: the
// instruction master sees ROM, data masters see DATA_RAM.
//
// The RPU is a fixed 4 x 4 fabric (Icarus Verilog 12 cannot
// elaborate unpacked-array parameters or 2-D arrays). Adding a
// slave = one SLAVE_* index, one decode line, one mask, one
// slave port.
// ============================================================

package soc_pkg;

    import arch_pkg::word_t;
    import arch_pkg::WORD_BYTES;

    // ========================================================
    // BUS PROTOCOL
    // ========================================================

    typedef enum logic {
        BusRead  = 1'b0,
        BusWrite = 1'b1
    } bus_op_e;

    // Strobe bit n enables byte n of wdata.
    typedef logic [WORD_BYTES-1:0] bus_strb_t;

    localparam bus_strb_t BUS_STRB_NONE = '0;
    localparam bus_strb_t BUS_STRB_ALL  = '1;

    typedef struct packed {
        logic      valid;
        bus_op_e   op;
        word_t     addr;
        word_t     wdata;
        bus_strb_t wstrb;
    } bus_req_s;

    typedef struct packed {
        logic  ready;
        word_t rdata;
        logic  error;
    } bus_rsp_s;

    function automatic logic bus_is_aligned(input word_t addr);
        return (addr & word_t'(WORD_BYTES - 1)) == 0;
    endfunction

    // ========================================================
    // MEMORY SIZES
    // ========================================================

    localparam int INSTRUCTION_ROM_BYTES = 32 * 1024;
    localparam int DATA_RAM_BYTES        = 32 * 1024;
    localparam int GPU_MMIO_BYTES        = 4 * 1024;           // register space, not framebuffer
    localparam int DDR3_BYTES            = 128 * 1024 * 1024;  // CPU-visible window

    localparam int INSTRUCTION_ROM_WORDS = INSTRUCTION_ROM_BYTES / WORD_BYTES;
    localparam int DATA_RAM_WORDS        = DATA_RAM_BYTES        / WORD_BYTES;

    // ========================================================
    // ADDRESS MAP
    // ========================================================
    //
    // MAP_*_MASK = size - 1: the in-region offset bits.

    localparam word_t MAP_ROM_BASE  = 32'h0000_0000;
    localparam word_t MAP_RAM_BASE  = 32'h0000_0000;
    localparam word_t MAP_GPU_BASE  = 32'h1000_0000;
    localparam word_t MAP_DDR3_BASE = 32'h8000_0000;

    localparam word_t MAP_ROM_MASK  = word_t'(INSTRUCTION_ROM_BYTES - 1);
    localparam word_t MAP_RAM_MASK  = word_t'(DATA_RAM_BYTES - 1);
    localparam word_t MAP_GPU_MASK  = word_t'(GPU_MMIO_BYTES - 1);
    localparam word_t MAP_DDR3_MASK = word_t'(DDR3_BYTES - 1);

    // ========================================================
    // ROUTING
    // ========================================================
    //
    // A route is a one-hot slave select; all-zero = no slave
    // (unmapped, reserved, or not visible to that master), which
    // the RPU answers with a bus error.
    // ========================================================

    localparam int SLAVE_COUNT     = 4;
    localparam int SLAVE_ROM       = 0;
    localparam int SLAVE_DATA_RAM  = 1;
    localparam int SLAVE_GPU_MMIO  = 2;
    localparam int SLAVE_DDR3      = 3;

    typedef logic [SLAVE_COUNT-1:0] slave_sel_t;

    function automatic bit map_hit(
        input word_t addr,
        input word_t base,
        input word_t mask
    );
        return (addr & ~mask) == base;
    endfunction

    // CPU instruction master: ROM only.
    function automatic slave_sel_t route_instr(input word_t addr);
        slave_sel_t s;
        s                  = '0;
        s[SLAVE_ROM]       = map_hit(addr, MAP_ROM_BASE, MAP_ROM_MASK);
        return s;
    endfunction

    // Data masters (CPU data, GPU, TPU): RAM, GPU MMIO, DDR3.
    function automatic slave_sel_t route_data(input word_t addr);
        slave_sel_t s;
        s                  = '0;
        s[SLAVE_DATA_RAM]  = map_hit(addr, MAP_RAM_BASE,  MAP_RAM_MASK);
        s[SLAVE_GPU_MMIO]  = map_hit(addr, MAP_GPU_BASE,  MAP_GPU_MASK);
        s[SLAVE_DDR3]      = map_hit(addr, MAP_DDR3_BASE, MAP_DDR3_MASK);
        return s;
    endfunction

    // ========================================================
    // STATIC MAP VALIDATION (pure; called by sim/pkg_checks.sv)
    // ========================================================

    // Size = mask + 1 must be a power of two; base aligned to size.
    function automatic bit map_region_ok(
        input word_t base,
        input word_t mask
    );
        return (mask != 0) && ((mask & (mask + word_t'(1))) == 0) && ((base & mask) == 0);
    endfunction

    function automatic bit map_overlap(
        input word_t base_a, input word_t mask_a,
        input word_t base_b, input word_t mask_b
    );
        return (base_a <= (base_b | mask_b)) && (base_b <= (base_a | mask_a));
    endfunction

    function automatic bit map_validate();
        bit ok;
        ok = 1'b1;

        ok = ok && map_region_ok(MAP_ROM_BASE,  MAP_ROM_MASK);
        ok = ok && map_region_ok(MAP_RAM_BASE,  MAP_RAM_MASK);
        ok = ok && map_region_ok(MAP_GPU_BASE,  MAP_GPU_MASK);
        ok = ok && map_region_ok(MAP_DDR3_BASE, MAP_DDR3_MASK);

        // ROM/RAM overlap each other on purpose; nothing else may overlap.
        ok = ok && !map_overlap(MAP_ROM_BASE, MAP_ROM_MASK, MAP_GPU_BASE,  MAP_GPU_MASK);
        ok = ok && !map_overlap(MAP_ROM_BASE, MAP_ROM_MASK, MAP_DDR3_BASE, MAP_DDR3_MASK);
        ok = ok && !map_overlap(MAP_RAM_BASE, MAP_RAM_MASK, MAP_GPU_BASE,  MAP_GPU_MASK);
        ok = ok && !map_overlap(MAP_RAM_BASE, MAP_RAM_MASK, MAP_DDR3_BASE, MAP_DDR3_MASK);
        ok = ok && !map_overlap(MAP_GPU_BASE, MAP_GPU_MASK, MAP_DDR3_BASE, MAP_DDR3_MASK);

        return ok;
    endfunction

endpackage

`endif
