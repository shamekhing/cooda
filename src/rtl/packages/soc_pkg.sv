`ifndef SOC_PKG_SV
`define SOC_PKG_SV

// Shared bus types and main-memory geometry for the CPU-only SoC.
package soc_pkg;
    import arch_pkg::word_t;
    import arch_pkg::WORD_BYTES;

    typedef enum logic { BusRead = 1'b0, BusWrite = 1'b1 } bus_op_e;
    typedef logic [WORD_BYTES-1:0] bus_strb_t;

    localparam bus_strb_t BUS_STRB_NONE = '0;
    localparam bus_strb_t BUS_STRB_ALL  = '1;

    typedef struct packed {
        logic valid;
        bus_op_e op;
        word_t addr;
        word_t wdata;
        bus_strb_t wstrb;
    } bus_req_s;

    typedef struct packed {
        logic ready;
        word_t rdata;
        logic error;
    } bus_rsp_s;

    localparam int MAIN_MEMORY_BYTES = 32 * 1024;
    localparam int MAIN_MEMORY_WORDS = MAIN_MEMORY_BYTES / WORD_BYTES;

    function automatic logic bus_is_aligned(input word_t addr);
        return (addr & word_t'(WORD_BYTES - 1)) == 0;
    endfunction
endpackage

`endif
