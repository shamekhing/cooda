// ============================================================
// async_fifo  small crossing between two unrelated clocks
// ============================================================
//
// The microSD path and the SoC bus live in clk27; a video pixel path
// runs faster and on its own clock. This FIFO is the bridge between
// them: the writer pushes bytes in its clock, the reader pulls them in
// its own, and the two sides never share a register.
//
// Pointer handling is the standard one: each side keeps its own free
// running counter, crosses only the counter's *gray* code (so a
// sampled mid-transition value is one step away from either end, never
// a wrong position), and compares after two synchroniser stages.
//
// DEPTH must be a power of two. WIDTH is the symbol width; the microSD
// path uses 8 (one image byte per symbol).
//
// full and empty are per-domain status: full means the writer may not
// push now, empty means the reader may not pull now.
// ============================================================

module async_fifo #(
    parameter int DEPTH = 1024,     // power of two
    parameter int WIDTH = 8
) (
    // write side
    input  logic             wr_clk,
    input  logic             wr_rst,
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,

    // read side
    input  logic             rd_clk,
    input  logic             rd_rst,
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty
);

    localparam int PTR_W = $clog2(DEPTH);

    logic [PTR_W:0] wr_ptr_q;
    logic [PTR_W:0] rd_ptr_q;

    // Gray codes cross; the binary values stay local.
    function automatic logic [PTR_W:0] gray(input logic [PTR_W:0] v);
        gray = v ^ (v >> 1);
    endfunction

    logic [PTR_W:0] wr_ptr_gray_q;
    logic [PTR_W:0] rd_ptr_gray_q;

    // Store
    logic [WIDTH-1:0] store [0:DEPTH-1];

    always_ff @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wr_ptr_q      <= '0;
            wr_ptr_gray_q <= '0;
        end else if (wr_en && !full) begin
            store[wr_ptr_q[PTR_W-1:0]] <= wr_data;
            wr_ptr_q      <= wr_ptr_q + 1'b1;
            wr_ptr_gray_q <= gray(wr_ptr_q + 1'b1);
        end
    end

    always_ff @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rd_ptr_q      <= '0;
            rd_ptr_gray_q <= '0;
        end else if (rd_en && !empty) begin
            rd_ptr_q      <= rd_ptr_q + 1'b1;
            rd_ptr_gray_q <= gray(rd_ptr_q + 1'b1);
        end
    end

    assign rd_data = store[rd_ptr_q[PTR_W-1:0]];

    // Crossings: two-flop synchronisers on the gray pointers.
    logic [PTR_W:0] rd_ptr_gray_wr1, rd_ptr_gray_wr2;
    logic [PTR_W:0] wr_ptr_gray_rd1, wr_ptr_gray_rd2;

    always_ff @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            rd_ptr_gray_wr1 <= '0;
            rd_ptr_gray_wr2 <= '0;
        end else begin
            rd_ptr_gray_wr1 <= rd_ptr_gray_q;
            rd_ptr_gray_wr2 <= rd_ptr_gray_wr1;
        end
    end

    always_ff @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            wr_ptr_gray_rd1 <= '0;
            wr_ptr_gray_rd2 <= '0;
        end else begin
            wr_ptr_gray_rd1 <= wr_ptr_gray_q;
            wr_ptr_gray_rd2 <= wr_ptr_gray_rd1;
        end
    end

    assign full  = (gray(wr_ptr_q + 1'b1) == rd_ptr_gray_wr2);
    assign empty = (rd_ptr_gray_q == wr_ptr_gray_rd2);

endmodule
