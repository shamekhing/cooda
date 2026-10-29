`timescale 1ns/1ps
`ifndef ARCH_PKG_SV
`define ARCH_PKG_SV

// ============================================================
// arch_pkg  architectural foundation (no dependencies)
//
// Word type, register-file geometry, flags / STATUS.
// Compile first. This file also carries the project-wide
// `timescale: Icarus applies it to every file compiled after.
//
// Dependency order:  arch -> isa, alu, soc
// ============================================================

package arch_pkg;

    // ---------------- Word ----------------

    localparam int WORD_WIDTH = 32;
    localparam int WORD_BYTES = WORD_WIDTH / 8;

    typedef logic [WORD_WIDTH-1:0] word_t;

    // ---------------- Register file ----------------

    localparam int REG_FILE_COUNT      = 64;
    localparam int REG_FILE_ADDR_WIDTH = $clog2(REG_FILE_COUNT);

    typedef logic [REG_FILE_ADDR_WIDTH-1:0] reg_addr_t;

    // R0 is hardwired to zero.
    localparam reg_addr_t ZERO_REG = '0;

    // ---------------- Flags ----------------
    //
    // Packed structs list the MSB first, so this is the STATUS
    // layout directly (a STATUS word = {27'b0, flags_s}):
    //
    //     [4] DZ   [3] V   [2] C   [1] N   [0] Z
    // ----------------------------------------------------

    typedef struct packed {
        logic DZ;
        logic V;
        logic C;
        logic N;
        logic Z;
    } flags_s;

    // ---------------- Multi-cycle FSM states ----------------
    //
    // Declared here rather than locally in each module: both are
    // shared, and the project keeps state encodings in the packages.
    // ----------------------------------------------------

    typedef enum logic [3:0] {
        CtlIdle,       // No operation
        CtlValid,      // Valid instruction
        CtlWait,       // Waiting/stalled
        CtlCapture,    // Latch request/input
        CtlRead,       // Read/acquire data
        CtlRun,        // Process/compute
        CtlWrite,      // Write/produce data
        CtlRetire,     // Commit/finalize
        CtlDone,       // Completion handshake
        CtlError,      // Fault condition
        CtlAbort       // Explicit cancellation
    } control_state_e;

    function automatic flags_s arch_make_flags(
        input logic z,
        input logic n,
        input logic c,
        input logic v,
        input logic dz
    );
        flags_s f;
        f.Z  = z;
        f.N  = n;
        f.C  = c;
        f.V  = v;
        f.DZ = dz;
        return f;
    endfunction

endpackage

`endif
