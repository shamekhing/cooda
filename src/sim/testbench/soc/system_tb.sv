module system_tb;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic run = 1'b0;
    logic retire_valid, illegal_instr, cpu_fault;
    int retires;

    always #5 clk = ~clk;

    system dut (
        .clk(clk), .rst(rst), .run(run),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .cpu_fault(cpu_fault),
        // The microSD path is disabled here, so the card input only
        // needs a defined level rather than a wire.
        .sd_miso(1'b1)
    );

    always_ff @(posedge clk) begin
        if (rst) retires <= 0;
        else if (retire_valid) retires <= retires + 1;
    end

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0; run = 1'b1;
        repeat (5000) @(posedge clk);
        if (cpu_fault || illegal_instr)
            $fatal(1, "CPU faulted while running main-memory program");
        if (retires < 4)
            $fatal(1, "CPU did not retire enough instructions: %0d", retires);
        if (dut.u_memory.u_bsram.mem_q[64] !== 32'h1234_5678)
            $fatal(1, "STORE failed: mem[64]=%08h", dut.u_memory.u_bsram.mem_q[64]);
        if (dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_register_file.regfile_q[2] !== 32'h1234_5678)
            $fatal(1, "LOAD failed: r2=%08h", dut.u_cpu.u_cpu_core.u_cpu_datapath.u_cpu_register_file.regfile_q[2]);
        $display("PASS: CPU bus arbitration, BSRAM STORE/LOAD, %0d retirements", retires);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "system_tb timeout");
    end
endmodule
