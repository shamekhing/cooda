`timescale 1ns/1ps

// ============================================================
// pkg_checks testbench
// ============================================================
//
// Runs the elaboration-time package invariants that live in
// src/rtl/sim/pkg_checks.sv. Those checks used to sit inside the
// packages, where $fatal would have made them unsynthesizable; they
// were moved out so the packages stay clean and the checks can still
// be run.
//
// Covered: word geometry, register-file size, opcode width, instruction
// width, ROM/RAM word divisibility, the whole address map (power-of-two
// size, base alignment, no overlap), and GPU register geometry.
//
// No bus stimulus is needed - pkg_checks is pure.
// ============================================================

module pkg_checks_tb;

    pkg_checks u_pkg_checks ();

    initial begin

        $dumpfile("pkg_checks.vcd");
        $dumpvars(0, pkg_checks_tb);

        #1;

        $display("PASS: package invariants - word geometry, opcode width, ROM/RAM sizing, address map, GPU regs");

        $finish;

    end

    initial begin
        #1_000;
        $fatal(1, "timeout in pkg_checks");
    end

endmodule
