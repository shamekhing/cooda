// ============================================================
// cpu_status_register  stored ALU condition flags
//
// Clears asynchronously on reset; updates on the rising edge only
// when flags_write_enable is asserted. A STATUS word, if ever
// needed, is {27'b0, flags} (see arch_pkg::flags_s).
//
// Gowin may flatten this into cpu_datapath and report NL0002
// ("module ... is swept in optimizing"); the flag bits remain.
// ============================================================

module cpu_status_register (
    input  logic             clk,
    input  logic             rst,
    input  logic             flags_write_enable,
    input  arch_pkg::flags_s flags_in,
    output arch_pkg::flags_s flags
);

    arch_pkg::flags_s flags_q;

    assign flags = flags_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)                     flags_q <= '0;
        else if (flags_write_enable) flags_q <= flags_in;
    end

endmodule
