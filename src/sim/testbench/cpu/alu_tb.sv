`timescale 1ns/1ps
// ============================================================
// alu_tb  cpu_alu differential test
// ============================================================
//
// Drives cpu_alu directly with every ALU opcode and compares the
// result plus all five status flags against a reference model:
//
//   1. a directed sweep over 16 boundary operands (0, 1, -1, MIN,
//      MAX, ...) for every opcode, with carry_in both 0 and 1 on the
//      carry-consuming opcodes
//   2. shift and rotate amounts from 0 to 40, i.e. across and beyond
//      the word width
//   3. 3000 randomised operand pairs over every opcode
//
// The reference model is the specification, not a copy of the RTL:
// division truncates toward zero, division by zero yields 0 with DZ
// set, the signed MIN/-1 cases wrap, a shift amount >= 32 saturates
// and OpSbc is defined as a - b - carry_in.
//
// Only the packages and cpu_alu are needed, but filelist.f is used so
// the compile order stays in one place.
//
// Run from the project root:
//   iverilog -g2012 -s alu_tb -f filelist.f \
//       src/sim/testbench/cpu/alu_tb.sv -o sim.out
//   vvp sim.out
// ============================================================

module alu_tb;

    import arch_pkg::*;
    import isa_pkg::*;
    import alu_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    word_t a, b;
    opcode_t op;
    logic carry_in = 1'b0;
    word_t result;
    flags_s flags;
    logic valid, busy, done;

    int errors = 0;
    int checks = 0;

    always #5 clk = ~clk;

    cpu_alu dut (
        .clk(clk), .rst(rst), .start(start),
        .operand_a(a), .operand_b(b), .op(op), .carry_in(carry_in),
        .result(result), .flags(flags), .valid(valid), .busy(busy), .done(done)
    );

    // ------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------
    function automatic word_t ref_result(opcode_t o, word_t x, word_t y, logic cin);
        logic signed [WORD_WIDTH-1:0] sx, sy;
        logic [2*WORD_WIDTH-1:0]      prod;
        logic [WORD_WIDTH:0]          wa, wb, wcin, wsum, wsumc, wsub, wsubc;
        word_t                        zero;
        int                           k;
        zero  = '0;
        sx    = x;
        sy    = y;
        wa    = {1'b0, x};
        wb    = {1'b0, y};
        wcin  = {{WORD_WIDTH{1'b0}}, cin};
        wsum  = wa + wb;
        wsumc = wa + wb + wcin;
        wsub  = wa - wb;
        wsubc = wa - wb - wcin;
        prod  = {zero, x} * {zero, y};
        k     = y[4:0];

        case (o)
            OpAdd:  ref_result = wsum[WORD_WIDTH-1:0];
            OpAdc:  ref_result = wsumc[WORD_WIDTH-1:0];
            OpSub:  ref_result = wsub[WORD_WIDTH-1:0];
            OpSbc:  ref_result = wsubc[WORD_WIDTH-1:0];
            OpMul:  ref_result = prod[WORD_WIDTH-1:0];
            OpMulh: ref_result = prod[2*WORD_WIDTH-1:WORD_WIDTH];
            OpDivu: ref_result = (y == '0) ? '0 : (x / y);
            OpModu: ref_result = (y == '0) ? '0 : (x % y);
            OpDivs: ref_result = (y == '0) ? '0 :
                                 ((x == MSB_ONE && y == ALL_ONES) ? MSB_ONE :
                                  word_t'(sx / sy));
            OpMods: ref_result = (y == '0) ? '0 :
                                 ((x == MSB_ONE && y == ALL_ONES) ? '0 :
                                  word_t'(sx % sy));
            OpMinu: ref_result = (x < y) ? x : y;
            OpMaxu: ref_result = (x > y) ? x : y;
            OpMins: ref_result = (sx < sy) ? x : y;
            OpMaxs: ref_result = (sx > sy) ? x : y;
            OpAbs:  ref_result = (sx < 0) ? word_t'(-sx) : x;
            OpNeg:  ref_result = word_t'(-sx);
            OpNot:  ref_result = ~x;
            OpAnd:  ref_result = x & y;
            OpOr:   ref_result = x | y;
            OpXor:  ref_result = x ^ y;
            OpNand: ref_result = ~(x & y);
            OpNor:  ref_result = ~(x | y);
            OpXnor: ref_result = ~(x ^ y);
            OpPassA: ref_result = x;
            OpPassB: ref_result = y;
            OpShl:  ref_result = (y >= WORD_WIDTH) ? '0 : (x << k);
            OpShr:  ref_result = (y >= WORD_WIDTH) ? '0 : (x >> k);
            OpSar:  ref_result = (y >= WORD_WIDTH)
                                 ? (x[WORD_WIDTH-1] ? ALL_ONES : '0)
                                 : word_t'(sx >>> k);
            OpRol:  ref_result = (k == 0) ? x
                                       : ((x << k) | (x >> (WORD_WIDTH - k)));
            OpRor:  ref_result = (k == 0) ? x
                                       : ((x >> k) | (x << (WORD_WIDTH - k)));
            OpEq:   ref_result = {{WORD_WIDTH-1{1'b0}}, (x == y)};
            OpNe:   ref_result = {{WORD_WIDTH-1{1'b0}}, (x != y)};
            OpLtu:  ref_result = {{WORD_WIDTH-1{1'b0}}, (x <  y)};
            OpLeu:  ref_result = {{WORD_WIDTH-1{1'b0}}, (x <= y)};
            OpGtu:  ref_result = {{WORD_WIDTH-1{1'b0}}, (x >  y)};
            OpGeu:  ref_result = {{WORD_WIDTH-1{1'b0}}, (x >= y)};
            OpLts:  ref_result = {{WORD_WIDTH-1{1'b0}}, (sx <  sy)};
            OpLes:  ref_result = {{WORD_WIDTH-1{1'b0}}, (sx <= sy)};
            OpGts:  ref_result = {{WORD_WIDTH-1{1'b0}}, (sx >  sy)};
            OpGes:  ref_result = {{WORD_WIDTH-1{1'b0}}, (sx >= sy)};
            default: ref_result = '0;
        endcase
    endfunction

    function automatic logic ref_carry(opcode_t o, word_t x, word_t y, logic cin);
        logic [WORD_WIDTH:0] wa, wb, wcin, wsum, wsumc, wsub, wsubc;
        wa    = {1'b0, x};
        wb    = {1'b0, y};
        wcin  = {{WORD_WIDTH{1'b0}}, cin};
        wsum  = wa + wb;
        wsumc = wa + wb + wcin;
        wsub  = wa - wb;
        wsubc = wa - wb - wcin;
        case (o)
            OpAdd:        ref_carry = wsum[WORD_WIDTH];
            OpAdc:        ref_carry = wsumc[WORD_WIDTH];
            OpSub:        ref_carry = (wa >= wb);
            OpSbc:        ref_carry = (wa >= (wb + wcin));
            OpNeg:        ref_carry = (x == '0);
            default:      ref_carry = 1'b0;
        endcase
    endfunction

    function automatic logic ref_overflow(opcode_t o, word_t x, word_t y, word_t r, logic cin);
        logic signed [WORD_WIDTH:0] ws, wsc, wd, wdc;
        logic signed [WORD_WIDTH-1:0] sx, sy, sr;
        sx  = x; sy = y; sr = r;
        ws  = {x[WORD_WIDTH-1], x} + {y[WORD_WIDTH-1], y};
        wsc = ws + cin;
        wd  = {x[WORD_WIDTH-1], x} - {y[WORD_WIDTH-1], y};
        wdc = wd - {{WORD_WIDTH{1'b0}}, cin};
        case (o)
            OpAdd:        ref_overflow = ({sr[WORD_WIDTH-1], sr} != ws);
            OpAdc:        ref_overflow = ({sr[WORD_WIDTH-1], sr} != wsc);
            OpSub:        ref_overflow = ({sr[WORD_WIDTH-1], sr} != wd);
            OpSbc:        ref_overflow = ({sr[WORD_WIDTH-1], sr} != wdc);
            OpNeg, OpAbs: ref_overflow = (x == MSB_ONE);
            OpDivs:       ref_overflow = (x == MSB_ONE) && (y == ALL_ONES);
            default:      ref_overflow = 1'b0;
        endcase
    endfunction

    // ------------------------------------------------------------
    // Driver / checker
    // ------------------------------------------------------------
    task automatic run_check(opcode_t o, word_t x, word_t y, logic cin);
        word_t er;
        logic  eZ, eN, eC, eV, eDZ;
        logic  is_divop;

        @(negedge clk);
        a = x; b = y; op = o; carry_in = cin; start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        @(negedge clk);
        while (!done) @(negedge clk);

        er  = ref_result(o, x, y, cin);
        eZ  = (er == '0);
        eN  = er[WORD_WIDTH-1];
        eC  = ref_carry(o, x, y, cin);
        eV  = ref_overflow(o, x, y, er, cin);
        eDZ = 1'b0;

        is_divop = (o >= OpDivu) && (o <= OpMods);
        if (is_divop) eDZ = (y == '0);

        checks++;
        if (result !== er) begin
            errors++;
            $display("FAIL op=%0d a=%08h b=%08h cin=%b result=%08h expected=%08h",
                     o, x, y, cin, result, er);
        end
        if ({flags.Z, flags.N, flags.C, flags.V, flags.DZ} !==
            {eZ, eN, eC, eV, eDZ}) begin
            errors++;
            $display("FAIL op=%0d a=%08h b=%08h cin=%b flags ZNCVDZ=%b%b%b%b%b expected=%b%b%b%b%b",
                     o, x, y, cin, flags.Z, flags.N, flags.C, flags.V,
                     flags.DZ, eZ, eN, eC, eV, eDZ);
        end
        @(negedge clk);
    endtask

    word_t vals[16];

    initial begin
        vals[0]  = 32'h0000_0000;
        vals[1]  = 32'h0000_0001;
        vals[2]  = 32'hFFFF_FFFF;
        vals[3]  = 32'h8000_0000;
        vals[4]  = 32'h7FFF_FFFF;
        vals[5]  = 32'h1234_5678;
        vals[6]  = 32'hDEAD_BEEF;
        vals[7]  = 32'h0000_0010;
        vals[8]  = 32'h0000_0020;
        vals[9]  = 32'hFFFF_FFF0;
        vals[10] = 32'h0000_00FF;
        vals[11] = 32'h0000_0002;
        vals[12] = 32'hAAAA_5555;
        vals[13] = 32'h5555_AAAA;
        vals[14] = 32'h0001_0000;
        vals[15] = 32'hFFFF_0000;

        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // Directed sweep over every ALU opcode and value pair.
        for (int oi = 0; oi <= int'(OpGes); oi++) begin
            for (int i = 0; i < 16; i++) begin
                for (int j = 0; j < 16; j++) begin
                    run_check(opcode_t'(oi), vals[i], vals[j], 1'b0);
                    if (oi <= int'(OpSbc))
                        run_check(opcode_t'(oi), vals[i], vals[j], 1'b1);
                end
            end
        end

        // Shift/rotate amounts across and beyond the word width.
        for (int k = 0; k <= 40; k++) begin
            run_check(OpShl, 32'h8000_0001, word_t'(k), 1'b0);
            run_check(OpShr, 32'h8000_0001, word_t'(k), 1'b0);
            run_check(OpSar, 32'h8000_0001, word_t'(k), 1'b0);
            run_check(OpSar, 32'h4000_0001, word_t'(k), 1'b0);
            run_check(OpRol, 32'h8000_0001, word_t'(k), 1'b0);
            run_check(OpRor, 32'h8000_0001, word_t'(k), 1'b0);
        end

        // Randomised sweep.
        for (int t = 0; t < 3000; t++) begin
            opcode_t o;
            o = opcode_t'($urandom_range(0, int'(OpGes)));
            run_check(o, word_t'($urandom), word_t'($urandom),
                      logic'($urandom_range(0, 1)));
        end

        if (errors == 0)
            $display("PASS: cpu_alu %0d checks, 0 mismatches", checks);
        else
            $display("FAIL: cpu_alu %0d checks, %0d mismatches", checks, errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "alu_tb timeout");
    end

endmodule
