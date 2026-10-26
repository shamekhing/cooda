`ifndef ALU_PKG_SV
`define ALU_PKG_SV

// ============================================================
// alu_pkg  constants and helpers shared by the bit-serial
// ALU sub-units
//
// Depends on: arch_pkg
//
// The per-cycle serialiser steps (shift/rotate/push) are
// written inline in the sub-units, not as functions here:
// iverilog mis-schedules some package-function calls used
// inside always_comb across instances. The helpers below are
// load-time only.
// ============================================================

package alu_pkg;

    import arch_pkg::word_t;
    import arch_pkg::WORD_WIDTH;

    // Serial index / shift-amount width.
    localparam int SERIAL_WIDTH = $clog2(WORD_WIDTH);

    localparam word_t MSB_ONE   = {1'b1, {(WORD_WIDTH-1){1'b0}}};
    localparam word_t ALL_ONES  = {WORD_WIDTH{1'b1}};

    // Bit-reverse a word (load time, to stream MSB-first).
    function automatic word_t alu_reverse(input word_t x);
        word_t  r;
        integer i;
        for (i = 0; i < WORD_WIDTH; i = i + 1)
            r[i] = x[WORD_WIDTH-1-i];
        return r;
    endfunction

    // Two's-complement negation.
    function automatic word_t alu_negate(input word_t x);
        return (~x) + word_t'(1);
    endfunction

endpackage

`endif
