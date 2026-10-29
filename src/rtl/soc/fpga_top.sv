// ============================================================
// fpga_top  minimal Tang Primer 20K CPU board wrapper
// ============================================================
module fpga_top (
    input  logic clk27,
    input  logic btn_n0,
    input  logic btn_n1,
    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,
    output logic led5
);
    logic [1:0] rst_sync = 2'b11;
    logic [1:0] run_sync = 2'b00;
    logic rst, run;
    logic retire_valid, illegal_instr, cpu_fault;
    logic [19:0] activity_count;

    always_ff @(posedge clk27) begin
        rst_sync <= {rst_sync[0], ~btn_n0};
        run_sync <= {run_sync[0],  btn_n1};
    end

    assign rst = rst_sync[1];
    assign run = run_sync[1];

    system u_system (
        .clk(clk27), .rst(rst), .run(run),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .cpu_fault(cpu_fault)
    );

    always_ff @(posedge clk27) begin
        if (rst) activity_count <= '0;
        else if (retire_valid) activity_count <= '1;
        else if (activity_count != '0) activity_count <= activity_count - 1'b1;
    end

    // Dock LEDs are active-low.
    assign led0 = (activity_count == '0);
    assign led1 = ~cpu_fault;
    assign led2 = ~illegal_instr;
    assign led3 = 1'b1;
    assign led4 = 1'b1;
    assign led5 = 1'b1;
endmodule
