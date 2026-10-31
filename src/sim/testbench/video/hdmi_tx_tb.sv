`timescale 1ns/1ps

module hdmi_tx_tb;
    logic pix_clk = 1'b0;
    logic serial_clk = 1'b0;
    logic rst = 1'b0;
    wire tmds_clk_p;
    wire tmds_clk_n;
    wire [2:0] tmds_data_p;
    wire [2:0] tmds_data_n;

    GSR GSR (.GSRI(1'b1));

    always #5 pix_clk = ~pix_clk;
    always #0.5 serial_clk = ~serial_clk;

    hdmi_tx dut (
        .pix_clk(pix_clk),
        .serial_clk(serial_clk),
        .rst(rst),
        .de(1'b1),
        .hs(1'b0),
        .vs(1'b0),
        .r(8'h96),
        .g(8'h3c),
        .b(8'hc3),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(tmds_data_n)
    );

    initial begin
        #1 rst = 1'b1;
        #10 rst = 1'b0;
        repeat (40) @(posedge serial_clk);
        #0.1;

        if (tmds_clk_p !== ~tmds_clk_n)
            $fatal(1, "TMDS clock outputs are not complementary");
        for (int lane = 0; lane < 3; lane++) begin
            if (tmds_data_p[lane] !== ~tmds_data_n[lane])
                $fatal(1, "TMDS data lane %0d outputs are not complementary", lane);
        end

        $display("PASS: all TMDS outputs are complementary differential pairs");
        $finish;
    end
endmodule
