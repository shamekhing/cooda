`timescale 1ns/1ps

module memory_map_tb;
    import soc_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    bus_req_s target_req, ddr_req;
    bus_rsp_s target_rsp, ddr_rsp;
    int errors = 0;
    int checks = 0;

    memory #(.INIT_FILE("")) dut (
        .clk(clk), .rst(rst), .target_req(target_req),
        .target_rsp(target_rsp),
        .ddr_req(ddr_req), .ddr_rsp(ddr_rsp)
    );

    // Stand-in for the DDR3 target. The real target is separately
    // covered by ddr3_target_tb.
    assign ddr_rsp = {
        ddr_req.valid,
        32'hDD33_0000 | ddr_req.addr,
        1'b0
    };

    task automatic access(input logic [31:0] address,
                          input logic expected_ddr,
                          input logic [31:0] expected_local,
                          input logic expected_error,
                          input logic [31:0] expected_data,
                          input logic check_data,
                          input string name);
        @(negedge clk);
        target_req = '0;
        target_req.valid = 1'b1;
        target_req.addr = address;
        #1;
        checks++;

        if (ddr_req.valid !== expected_ddr) begin
            errors++;
            $display("FAIL %s route: DDR request valid=%b", name,
                     ddr_req.valid);
        end
        if (expected_ddr && ddr_req.addr !== expected_local) begin
            errors++;
            $display("FAIL %s local address: got %08h expected %08h", name,
                     ddr_req.addr, expected_local);
        end

        while (!target_rsp.ready) @(negedge clk);
        if (target_rsp.error !== expected_error ||
            (check_data && target_rsp.rdata !== expected_data)) begin
            errors++;
            $display("FAIL %s response: ready=%b error=%b data=%08h", name,
                     target_rsp.ready, target_rsp.error, target_rsp.rdata);
        end

        @(negedge clk);
        target_req.valid = 1'b0;
    endtask

    initial begin
        target_req = '0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        access(32'h0000_0100, 1'b0, 32'h0000_0100, 1'b0,
               32'h0, 1'b0, "BSRAM boot region");
        access(32'h0800_0000, 1'b1, 32'h0000_0000, 1'b0,
               32'hDD33_0000, 1'b1, "DDR3 first word");
        access(32'h0800_1234, 1'b1, 32'h0000_1234, 1'b0,
               32'hDD33_1234, 1'b1, "DDR3 offset translation");
        access(32'h0FFF_FFFC, 1'b1, 32'h07FF_FFFC, 1'b0,
               32'hDFFF_FFFC, 1'b1, "DDR3 final word");
        access(32'h1000_0000, 1'b0, 32'h1000_0000, 1'b1,
               32'h0, 1'b1, "unmapped gap");
        access(32'h0000_0102, 1'b0, 32'h0000_0102, 1'b1,
               32'h0, 1'b1, "misaligned access");

        if (errors == 0)
            $display("PASS: memory_map %0d checks", checks);
        else
            $fatal(1, "FAIL: memory_map %0d checks, %0d errors",
                   checks, errors);
        $finish;
    end
endmodule
