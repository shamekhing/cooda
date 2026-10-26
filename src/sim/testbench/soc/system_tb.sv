// ============================================================
// system_tb  boot program smoke test
// ============================================================
//
// Runs the SoC (CPU + RPU + memory + GPU + video) against the real
// boot ROM (src/programs/boot_program.hex) and checks that the boot
// program actually executes:
//
//   1. no CPU fault (no bus error, no illegal instruction)
//   2. the program reaches its setup block and enables the visualiser
//      (RegControl[0] = 1)
//   3. it writes the first clear colour (RegClearColor = 0x00336699)
//   4. it stores to data RAM (mem_q[4] = 1, from the loop's STORE)
//   5. retire_valid keeps pulsing (the program is still running)
//
// The window is deliberately short: the delay loop is ~160k iterations
// long, so the full two-phase colour cycle is far out of reach. What
// this proves is that the encoding is right and the first loop
// iteration works, which is what a stale .hex file would break.
// ============================================================

module system_tb;

    localparam int CYCLES = 30000;

    logic clk = 1'b0;
    logic pix_clk = 1'b0;

    always #18.518 clk = ~clk;          // 27 MHz
    always #12.345 pix_clk = ~pix_clk;  // ~40.5 MHz

    logic rst = 1'b1;
    logic run = 1'b0;

    logic retire_valid;
    logic illegal_instr;
    logic cpu_fault;

    logic [11:0] pix_x, pix_y;
    logic        pix_de;

    logic [7:0]  pix_r, pix_g, pix_b;

    // DDR3 pins, not exercised here.
    wire  [13:0] ddr3_addr;
    wire  [2:0]  ddr3_bank;
    wire         ddr3_ras, ddr3_cas, ddr3_we;
    wire         ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_odt, ddr3_rst_n, ddr3_cs;
    wire  [1:0]  ddr3_dm;
    wire  [15:0] ddr3_dq;
    wire  [1:0]  ddr3_dqs_p, ddr3_dqs_n;

    system dut (
        .clk           (clk),
        .rst           (rst),
        .run           (run),

        .retire_valid  (retire_valid),
        .illegal_instr (illegal_instr),
        .cpu_fault     (cpu_fault),

        .pix_clk       (pix_clk),
        .pix_rst       (rst),
        .pix_de        (pix_de),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .pix_r         (pix_r),
        .pix_g         (pix_g),
        .pix_b         (pix_b),

        .ddr3_addr     (ddr3_addr),
        .ddr3_bank     (ddr3_bank),
        .ddr3_ras      (ddr3_ras),
        .ddr3_cas      (ddr3_cas),
        .ddr3_we       (ddr3_we),
        .ddr3_ck_p     (ddr3_ck_p),
        .ddr3_ck_n     (ddr3_ck_n),
        .ddr3_cke      (ddr3_cke),
        .ddr3_odt      (ddr3_odt),
        .ddr3_rst_n    (ddr3_rst_n),
        .ddr3_cs       (ddr3_cs),
        .ddr3_dm       (ddr3_dm),
        .ddr3_dq       (ddr3_dq),
        .ddr3_dqs_p    (ddr3_dqs_p),
        .ddr3_dqs_n    (ddr3_dqs_n)
    );

    int retires;

    always_ff @(posedge clk) begin
        if (rst) retires <= 0;
        else if (retire_valid) retires <= retires + 1;
    end

    initial begin
        $dumpfile("system.vcd");
        $dumpvars(0, system_tb);

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        run = 1'b1;

        repeat (CYCLES) @(posedge clk);

        // ---- checks ----

        if (cpu_fault)
            $fatal(1, "CPU fault: bus error or illegal instruction");

        if (retires < 200)
            $fatal(1, "only %0d instructions retired - the program is not running",
                   retires);

        if (dut.u_gpu.u_gpu_registers.control_q[0] !== 1'b1)
            $fatal(1, "boot program did not enable the visualiser (RegControl = %08h)",
                   dut.u_gpu.u_gpu_registers.control_q);

        if (dut.u_gpu.u_gpu_registers.clear_color_q[23:0] !== 24'h00336699)
            $fatal(1, "boot program did not write the clear colour (RegClearColor = %06h)",
                   dut.u_gpu.u_gpu_registers.clear_color_q[23:0]);

        if (dut.u_memory.u_memory_bsram_ram.mem_q[4] !== 32'h0000_0001)
            $fatal(1, "boot program did not store to data RAM (mem[4] = %08h)",
                   dut.u_memory.u_memory_bsram_ram.mem_q[4]);

        $display("PASS: boot program - %0d instructions retired, visualiser on, clear colour %06h, RAM[4] = %0d",
                 retires,
                 dut.u_gpu.u_gpu_registers.clear_color_q[23:0],
                 dut.u_memory.u_memory_bsram_ram.mem_q[4]);

        $finish;
    end

endmodule
