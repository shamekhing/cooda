`ifndef GPU_PKG_SV
`define GPU_PKG_SV

// ============================================================
// gpu_pkg  GPU registers, configuration, status, pixel types
//
// Depends on: arch_pkg, soc_pkg (MMIO size only)
//
// soc_pkg owns the absolute GPU base address and routing; the
// interconnect hands the GPU a GPU-local byte address.
// The GPU talks to memory with soc_pkg::bus_req_s / bus_rsp_s
// directly; there is no separate GPU memory request type.
// ============================================================

package gpu_pkg;

    import arch_pkg::word_t;
    import arch_pkg::WORD_BYTES;

    // ---------------- GPU-local MMIO address ----------------

    localparam int GPU_ADDR_WIDTH = $clog2(soc_pkg::GPU_MMIO_BYTES);

    typedef logic [GPU_ADDR_WIDTH-1:0] gpu_addr_t;

    // ---------------- Register map ----------------
    //
    // Every register occupies one full word (stride WORD_BYTES).
    // Writes are full-word; byte strobes are not used.
    // ----------------------------------------------------------

    typedef enum gpu_addr_t {
        RegId                 = gpu_addr_t'(0 * WORD_BYTES),
        RegControl            = gpu_addr_t'(1 * WORD_BYTES),
        RegStatus             = gpu_addr_t'(2 * WORD_BYTES),
        RegFramebufferBase   = gpu_addr_t'(3 * WORD_BYTES),
        RegFramebufferWidth  = gpu_addr_t'(4 * WORD_BYTES),
        RegFramebufferHeight = gpu_addr_t'(5 * WORD_BYTES),
        RegClearColor        = gpu_addr_t'(6 * WORD_BYTES)
    } gpu_reg_addr_e;

    localparam int GPU_REG_COUNT = 7;

    localparam word_t GPU_ID_VALUE = 32'h4750_5530;   // ASCII "GPU0"

    // ---------------- CPU-writable configuration ----------------
    // Owned by gpu_register_block, passed to gpu_core as one struct.

    typedef struct packed {
        word_t control;
        word_t framebuffer_base;
        word_t framebuffer_width;
        word_t framebuffer_height;
        word_t clear_color;
    } gpu_config_s;

    // ---------------- Status (CPU-readable, read-only) ----------------
    //
    //     [0] enabled        [4] command_done
    //     [1] idle           [5] framebuffer_valid
    //     [2] busy           [6] display_active
    //     [3] error          [31:7] reserved
    // ----------------------------------------------------------------

    typedef struct packed {
        logic [24:0] reserved;
        logic        display_active;
        logic        framebuffer_valid;
        logic        command_done;
        logic        error;
        logic        busy;
        logic        idle;
        logic        enabled;
    } gpu_status_s;

    localparam int GPU_STATUS_WIDTH = $bits(gpu_status_s);

    // ---------------- Pixels ----------------
    //
    // 32-bit RGBA: [31:24] R, [23:16] G, [15:8] B, [7:0] A.
    // ----------------------------------------------------------

    localparam int GPU_PIXEL_WIDTH = 32;
    localparam int GPU_PIXEL_BYTES = GPU_PIXEL_WIDTH / 8;

    typedef logic [GPU_PIXEL_WIDTH-1:0] gpu_pixel_t;

    localparam int GPU_COORD_WIDTH = 16;

    typedef logic [GPU_COORD_WIDTH-1:0] gpu_coord_t;

    // Graphics operation sent to the pixel engine (not a bus transaction).
    typedef struct packed {
        logic       valid;
        gpu_coord_t x;
        gpu_coord_t y;
        gpu_pixel_t color;
    } gpu_pixel_req_s;

    // Result of pixel address generation; becomes a bus write later.
    typedef struct packed {
        logic       valid;
        word_t      addr;
        gpu_pixel_t data;
    } gpu_pixel_write_s;

endpackage

`endif
