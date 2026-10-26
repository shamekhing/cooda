// ============================================================
// hdmi_prim_sim  SIMULATION ONLY stubs for Gowin hard primitives
// ============================================================
//
// OSER10 and CLKDIV are fabric hard macros that only exist in the
// Gowin device library. These behavioural stubs let the RTL elaborate
// and simulate outside the Gowin tools; they are NOT part of the Gowin
// project file list (cooda.gprj).
//
// OSER10: loads D9..D0 on PCLK and shifts them out on FCLK, D0 first.
// CLKDIV: divides HCLKIN by DIV_MODE.
// ============================================================

module OSER10 (
    output Q,

    input  D0, D1, D2, D3, D4, D5, D6, D7, D8, D9,

    input  PCLK,
    input  FCLK,
    input  RESET
);

    parameter GSREN        = "false";
    parameter LSREN        = "true";

    reg [9:0] shift_q;

    always @(posedge PCLK or posedge RESET) begin
        if (RESET) shift_q <= 10'b0;
        else       shift_q <= {D9, D8, D7, D6, D5, D4, D3, D2, D1, D0};
    end

    // D0 goes out first.
    assign Q = shift_q[0];

    // The shift itself happens on the fast clock in the real primitive.
    always @(posedge FCLK) begin
        if (!RESET) shift_q <= {1'b0, shift_q[9:1]};
    end

endmodule

module CLKDIV (
    input  RESETN,
    input  HCLKIN,
    output CLKOUT,
    input  CALIB
);

    parameter DIV_MODE = "5";
    parameter GSREN    = "false";

    integer div;
    integer cnt;

    initial begin
        div = 5;
        cnt = 0;
    end

    reg clkout_r;

    always @(posedge HCLKIN or negedge RESETN) begin
        if (!RESETN) begin
            cnt      <= 0;
            clkout_r <= 1'b0;
        end else if (cnt == (div / 2 - 1)) begin
            cnt      <= 0;
            clkout_r <= ~clkout_r;
        end else begin
            cnt <= cnt + 1;
        end
    end

    assign CLKOUT = clkout_r;

endmodule
