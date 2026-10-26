// ============================================================
// Register file
//
// Two asynchronous read ports and one synchronous write port.
// Register 0 is architecturally hardwired to zero: writes to it
// are ignored and reads from it always return zero. Reset is
// asynchronous and clears every register.
// Every word is the global word (arch_pkg::WORD_WIDTH).
// ============================================================

module cpu_register_file (
    input  logic             clk,
    input  logic             rst,
    input  arch_pkg::reg_addr_t rs1_addr,
    output arch_pkg::word_t      rs1_data,
    input  arch_pkg::reg_addr_t rs2_addr,
    output arch_pkg::word_t      rs2_data,
    input  logic             write_enable,
    input  arch_pkg::reg_addr_t write_addr,
    input  arch_pkg::word_t      write_data
);
    arch_pkg::word_t regfile_q [arch_pkg::REG_FILE_COUNT];

    // R0 is architecturally hardwired to zero.
    assign rs1_data = (rs1_addr == '0) ? '0 : regfile_q[rs1_addr];
    assign rs2_data = (rs2_addr == '0) ? '0 : regfile_q[rs2_addr];

    integer idx;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (idx = 0; idx < arch_pkg::REG_FILE_COUNT; idx = idx + 1)
                regfile_q[idx] <= '0;
        end else if (write_enable && (write_addr != '0)) begin
            regfile_q[write_addr] <= write_data;
        end
    end
endmodule
