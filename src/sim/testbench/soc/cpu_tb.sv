`timescale 1ns/1ps
// ============================================================
// cpu_tb  program-level functional test of the CPU + bus + BSRAM
// ============================================================
//
// Loads small hand-assembled programs straight into the BSRAM and
// checks architectural state through hierarchical references.
//
//   program A  integration: MOVI/ADD/SUB/SBC/MOV with register and
//              immediate operands, STORE/LOAD with r0 and with a
//              register base, a taken BEQ (which must skip both the
//              instruction and its immediate word), a not-taken BEQ
//              whose target is deliberately out of range (so a
//              spurious take would fault), a forward JMP, and the
//              status-register rules (a SUB sets C, the following
//              flag-write-disabled ALU ops must leave it alone)
//   program B  a LOAD outside main memory must latch fault and must
//              not write back or execute the next instruction
//   program C  an encoding with a reserved bit set must raise
//              illegal_instr and latch fault
//   program D  run low must stop retirement and run high must
//              resume it
//
// Data lives at byte 1024 so the program image cannot overwrite
// itself; the program is word-indexed from 0.
//
// Run from the project root:
//   iverilog -g2012 -s cpu_tb -f filelist.f \
//       src/sim/testbench/soc/cpu_tb.sv -o sim.out
//   vvp sim.out
// ============================================================

module cpu_tb;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic run = 1'b0;
    logic retire_valid, illegal_instr, cpu_fault;
    int   retires;
    int   errors = 0;

    always #5 clk = ~clk;

    system dut (
        .clk(clk), .rst(rst), .run(run),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .cpu_fault(cpu_fault)
    );

    always_ff @(posedge clk) begin
        if (rst) retires <= 0;
        else if (retire_valid) retires <= retires + 1;
    end

    // ------------------------------------------------------------
    // Program image + encoding helpers (mirror isa_pkg layout)
    // ------------------------------------------------------------
    logic [31:0] prog [0:255];
    int          wi;
    int          patch_beq1, patch_jmp1, patch_jmp2;

    function automatic logic [31:0] enc(input logic [5:0] op, input logic [5:0] rd,
                                        input logic [5:0] rs1, input logic [5:0] rs2,
                                        input logic im, input logic us);
        enc = {6'b0, us, im, op, rd, rs1, rs2};
    endfunction

    task automatic emit(input logic [31:0] w);
        prog[wi] = w;
        wi = wi + 1;
    endtask

    task automatic emit_imm(input logic [31:0] i);
        prog[wi] = i;
        wi = wi + 1;
    endtask

    task automatic load_prog();
        for (int i = 0; i < 8192; i = i + 1)
            dut.u_memory.u_bsram.mem_q[i] = '0;
        for (int i = 0; i < wi; i = i + 1)
            dut.u_memory.u_bsram.mem_q[i] = prog[i];
    endtask

    // ------------------------------------------------------------
    // Observation helpers
    // ------------------------------------------------------------
    function automatic logic [31:0] mem_get(input int w);
        return dut.u_memory.u_bsram.mem_q[w];
    endfunction

    function automatic logic [31:0] reg_get(input int r);
        return dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_register_file.regfile_q[r];
    endfunction

    task automatic check_word(input string name, input logic [31:0] got,
                              input logic [31:0] exp);
        if (got !== exp) begin
            errors++;
            $display("FAIL %s: got %08h expected %08h", name, got, exp);
        end
    endtask

    task automatic reset_cpu();
        @(negedge clk);
        rst = 1'b1; run = 1'b0;
        repeat (4) @(negedge clk);
        @(negedge clk);
        rst = 1'b0; run = 1'b1;
    endtask


    // ============================================================
    // Program A  ALU / memory / branch / jump integration
    // ============================================================
    task automatic build_prog_main();
        int lab_a, lab_c;
        wi = 0;

        emit(enc(6'h18, 1, 0, 0, 1'b1, 1'b0)); emit_imm(32'd5);      // 0  MOVI r1,5
        emit(enc(6'h18, 2, 0, 0, 1'b1, 1'b0)); emit_imm(32'd7);      // 2  MOVI r2,7
        emit(enc(6'h00, 3, 1, 2, 1'b0, 1'b1));                       // 4  ADD r3,r1,r2
        emit(enc(6'h30, 0, 0, 3, 1'b0, 1'b0)); emit_imm(32'd1024);   // 5  STORE r3,[r0+1024]
        emit(enc(6'h18, 4, 0, 0, 1'b1, 1'b0)); emit_imm(32'd100);    // 7  MOVI r4,100
        emit(enc(6'h30, 0, 0, 4, 1'b0, 1'b0)); emit_imm(32'd1028);   // 9  STORE r4,[r0+1028]
        emit(enc(6'h2F, 5, 0, 0, 1'b0, 1'b0)); emit_imm(32'd1024);   // 11 LOAD r5,[r0+1024]
        emit(enc(6'h00, 6, 5, 4, 1'b0, 1'b0));                       // 13 ADD r6,r5,r4
        emit(enc(6'h30, 0, 0, 6, 1'b0, 1'b0)); emit_imm(32'd1032);   // 14 STORE r6,[r0+1032]
        patch_beq1 = wi + 1;                                         // 16 BEQ r1,r1
        emit(enc(6'h29, 0, 1, 1, 1'b0, 1'b0)); emit_imm(32'd0);
        emit(enc(6'h18, 7, 0, 0, 1'b1, 1'b0)); emit_imm(32'd1);      // 18 skipped
        emit(enc(6'h28, 0, 0, 0, 1'b0, 1'b0)); emit_imm(32'h7FFF_FFFC); // 20 skipped
        lab_a = wi;
        emit(enc(6'h18, 7, 0, 0, 1'b1, 1'b0)); emit_imm(32'hAB);     // 22 MOVI r7,0xAB
        emit(enc(6'h30, 0, 0, 7, 1'b0, 1'b0)); emit_imm(32'd1036);   // 24 STORE r7,[r0+1036]
        emit(enc(6'h29, 0, 1, 2, 1'b0, 1'b0)); emit_imm(32'h7FFF_FFFC); // 26 BEQ r1,r2 not taken
        emit(enc(6'h18, 8, 0, 0, 1'b1, 1'b0)); emit_imm(32'hCD);     // 28 MOVI r8,0xCD
        emit(enc(6'h30, 0, 0, 8, 1'b0, 1'b0)); emit_imm(32'd1040);   // 30 STORE r8,[r0+1040]
        patch_jmp1 = wi + 1;                                         // 32 JMP lab_c
        emit(enc(6'h28, 0, 0, 0, 1'b0, 1'b0)); emit_imm(32'd0);
        emit(enc(6'h18, 7, 0, 0, 1'b1, 1'b0)); emit_imm(32'h99);     // 34 skipped
        lab_c = wi;
        emit(enc(6'h18, 9, 0, 0, 1'b1, 1'b0)); emit_imm(32'hEF);     // 36 MOVI r9,0xEF
        emit(enc(6'h30, 0, 0, 9, 1'b0, 1'b0)); emit_imm(32'd1044);   // 38 STORE r9,[r0+1044]
        emit(enc(6'h02, 10, 9, 1, 1'b0, 1'b1));                      // 40 SUB r10,r9,r1 (C=1)
        emit(enc(6'h03, 16, 9, 1, 1'b0, 1'b0));                      // 41 SBC r16,r9,r1 (C=1)
        emit(enc(6'h30, 0, 0, 16, 1'b0, 1'b0)); emit_imm(32'd1060);  // 42 STORE r16,[r0+1060]
        emit(enc(6'h30, 0, 0, 10, 1'b0, 1'b0)); emit_imm(32'd1048);  // 44 STORE r10,[r0+1048]
        emit(enc(6'h2F, 11, 0, 0, 1'b0, 1'b0)); emit_imm(32'd1036);  // 46 LOAD r11,[r0+1036]
        emit(enc(6'h00, 12, 11, 0, 1'b0, 1'b0));                     // 48 ADD r12,r11,r0
        emit(enc(6'h30, 0, 0, 12, 1'b0, 1'b0)); emit_imm(32'd1052);  // 49 STORE r12,[r0+1052]
        emit(enc(6'h00, 13, 1, 0, 1'b1, 1'b0)); emit_imm(32'd3);     // 51 ADD r13,r1,#3
        emit(enc(6'h17, 14, 1, 0, 1'b0, 1'b0));                      // 53 MOV r14,r1
        emit(enc(6'h18, 15, 0, 0, 1'b1, 1'b0)); emit_imm(32'd1056);  // 54 MOVI r15,1056
        emit(enc(6'h30, 0, 15, 14, 1'b0, 1'b0)); emit_imm(32'd0);    // 56 STORE r14,[r15+0]
        patch_jmp2 = wi + 1;                                         // 58 JMP self
        emit(enc(6'h28, 0, 0, 0, 1'b0, 1'b0)); emit_imm(32'd0);

        prog[patch_beq1] = 4 * lab_a;
        prog[patch_jmp1] = 4 * lab_c;
        prog[patch_jmp2] = 4 * (wi - 1);
    endtask


    // ============================================================
    // Program B  out-of-range data access must fault, not write back
    // ============================================================
    task automatic build_prog_data_fault();
        wi = 0;
        emit(enc(6'h18, 1, 0, 0, 1'b1, 1'b0)); emit_imm(32'd5);       // 0 MOVI r1,5
        emit(enc(6'h2F, 2, 0, 0, 1'b0, 1'b0)); emit_imm(32'h8000);    // 2 LOAD r2,[r0+0x8000]
        emit(enc(6'h18, 3, 0, 0, 1'b1, 1'b0)); emit_imm(32'd7);       // 4 MOVI r3,7
    endtask

    // ============================================================
    // Program C  reserved-bit encoding must be an illegal instruction
    // ============================================================
    task automatic build_prog_illegal();
        wi = 0;
        emit(enc(6'h18, 1, 0, 0, 1'b1, 1'b0)); emit_imm(32'd5);       // 0 MOVI r1,5
        emit(32'h0400_0000);                                          // 2 reserved bit 26 set
        emit(enc(6'h18, 3, 0, 0, 1'b1, 1'b0)); emit_imm(32'd7);       // 3 MOVI r3,7
    endtask

    // ============================================================
    // Program D  run/pause behaviour
    // ============================================================
    task automatic build_prog_spin();
        wi = 0;
        emit(enc(6'h18, 1, 0, 0, 1'b1, 1'b0)); emit_imm(32'd1);       // 0 MOVI r1,1
        emit(enc(6'h00, 2, 1, 1, 1'b0, 1'b0));                        // 2 ADD r2,r1,r1
        patch_jmp1 = wi + 1;                                          // 3 JMP self
        emit(enc(6'h28, 0, 0, 0, 1'b0, 1'b0)); emit_imm(32'd0);
        prog[patch_jmp1] = 4 * (wi - 1);
    endtask

    int retires_at_pause;


    // ============================================================
    // Main sequence
    // ============================================================
    initial begin
        // ---------------- Program A ----------------
        build_prog_main();
        load_prog();
        reset_cpu();
        repeat (60000) @(negedge clk);

        check_word("cpu_fault",      {31'b0, cpu_fault},     32'd0);
        check_word("illegal_instr",  {31'b0, illegal_instr}, 32'd0);

        check_word("mem[256] r3",  mem_get(256), 32'd12);
        check_word("mem[257] r4",  mem_get(257), 32'd100);
        check_word("mem[258] r6",  mem_get(258), 32'd112);
        check_word("mem[259] r7",  mem_get(259), 32'hAB);
        check_word("mem[260] r8",  mem_get(260), 32'hCD);
        check_word("mem[261] r9",  mem_get(261), 32'hEF);
        check_word("mem[262] r10", mem_get(262), 32'hEA);
        check_word("mem[263] r12", mem_get(263), 32'hAB);
        check_word("mem[264] r14", mem_get(264), 32'd5);
        check_word("mem[265] r16", mem_get(265), 32'hE9);

        check_word("r1",  reg_get(1),  32'd5);
        check_word("r2",  reg_get(2),  32'd7);
        check_word("r3",  reg_get(3),  32'd12);
        check_word("r4",  reg_get(4),  32'd100);
        check_word("r5",  reg_get(5),  32'd12);
        check_word("r6",  reg_get(6),  32'd112);
        check_word("r7",  reg_get(7),  32'hAB);
        check_word("r8",  reg_get(8),  32'hCD);
        check_word("r9",  reg_get(9),  32'hEF);
        check_word("r10", reg_get(10), 32'hEA);
        check_word("r11", reg_get(11), 32'hAB);
        check_word("r12", reg_get(12), 32'hAB);
        check_word("r13", reg_get(13), 32'd8);
        check_word("r14", reg_get(14), 32'd5);
        check_word("r15", reg_get(15), 32'd1056);
        check_word("r0 hardwired", reg_get(0), 32'd0);

        check_word("flags ZNCVDZ",
                   {27'b0,
                    dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_status_register.flags_q.DZ,
                    dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_status_register.flags_q.V,
                    dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_status_register.flags_q.C,
                    dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_status_register.flags_q.N,
                    dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_status_register.flags_q.Z},
                   32'b0_0100);

        if (retires < 20) begin
            errors++;
            $display("FAIL retire count: %0d", retires);
        end
        $display("program A: %0d retirements", retires);


        // ---------------- Program B (data bus error) ----------------
        build_prog_data_fault();
        load_prog();
        reset_cpu();
        repeat (4000) @(negedge clk);

        check_word("data-fault flag", {31'b0, cpu_fault}, 32'd1);
        check_word("r2 not written",  reg_get(2), 32'd0);
        check_word("r3 not executed", reg_get(3), 32'd0);
        $display("program B: fault=%0b r2=%08h r3=%08h", cpu_fault,
                 reg_get(2), reg_get(3));

        // ---------------- Program C (illegal instruction) ----------------
        build_prog_illegal();
        load_prog();
        reset_cpu();
        repeat (4000) @(negedge clk);

        check_word("illegal flag",   {31'b0, illegal_instr}, 32'd1);
        check_word("illegal fault",  {31'b0, cpu_fault},     32'd1);
        check_word("r1 before fault", reg_get(1), 32'd5);
        check_word("r3 not executed", reg_get(3), 32'd0);
        $display("program C: fault=%0b illegal=%0b r3=%08h", cpu_fault,
                 illegal_instr, reg_get(3));

        // ---------------- Program D (run/pause) ----------------
        build_prog_spin();
        load_prog();
        reset_cpu();
        repeat (2000) @(negedge clk);

        @(negedge clk);
        run = 1'b0;
        repeat (40) @(negedge clk);
        retires_at_pause = retires;
        repeat (400) @(negedge clk);
        if (retires !== retires_at_pause) begin
            errors++;
            $display("FAIL pause: retires moved %0d -> %0d",
                     retires_at_pause, retires);
        end
        @(negedge clk);
        run = 1'b1;
        repeat (400) @(negedge clk);
        if (retires <= retires_at_pause) begin
            errors++;
            $display("FAIL resume: retires stuck at %0d", retires);
        end
        $display("program D: paused at %0d, resumed to %0d",
                 retires_at_pause, retires);

        if (errors == 0) $display("PASS: cpu_tb - all program checks matched");
        else             $display("FAIL: cpu_tb - %0d checks failed", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "cpu_tb timeout");
    end

endmodule
