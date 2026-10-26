// ============================================================
// gpu_bus_mon  bus activity levels for the visualiser
// ============================================================
//
// Watches the RPU's passive monitor taps and keeps one saturating
// 8-bit "pixel area" level per block:
//
//   levels 0..3  masters: cpu_i, cpu_d, gpu, tpu
//   levels 4..7  slaves : rom, ram, gpu_mmio, ddr3
//
// Every tick (~2.4 ms) a block that was active since the last tick
// gains one unit of area and an idle block loses one, so active blocks
// grow and idle blocks drain: the tiles visibly lose and gain pixel
// area as the program runs.
//
// Sampling once per tick rather than once per transaction is what
// keeps the display alive: a program that hammers the bus would pin
// every touched block at full if each transaction added a unit.
//
// The levels are exported Gray coded, so the pixel-domain synchroniser
// sees at most one bit change per level per tick.
// ============================================================

module gpu_bus_mon #(
    // Tick interval in clk cycles. 2^16 at 27 MHz is about 2.4 ms.
    parameter int TICK_DIV = 1 << 16
) (
    input  logic        clk,
    input  logic        rst,

    input  logic [3:0]  mon_m,      // master owning a slave this cycle
    input  logic [3:0]  mon_s,      // slave being served this cycle

    output logic [63:0] level_gray, // {8 x 8-bit} Gray-coded levels
    output logic [31:0] level_master // {tpu, gpu, cpu_d, cpu_i} binary
);

    localparam int TICK_W = $clog2(TICK_DIV);

    logic [63:0] level_q;
    logic [7:0]  active_q, active_d;
    logic [TICK_W-1:0] tick_q, tick_d;
    logic tick;

    assign tick = (tick_q == TICK_W'(TICK_DIV - 1));

    always_comb begin
        // Bit i of {mon_s, mon_m} is block i: masters 0..3, slaves 4..7.
        active_d = active_q | {mon_s, mon_m};
        tick_d   = tick ? '0 : tick_q + 1'b1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            level_q  <= '0;
            active_q <= '0;
            tick_q   <= '0;
        end else begin
            tick_q <= tick_d;

            if (tick) begin
                active_q <= '0;

                for (int i = 0; i < 8; i++) begin
                    if (active_d[i]) begin
                        if (level_q[8*i +: 8] != 8'hFF)
                            level_q[8*i +: 8] <= level_q[8*i +: 8] + 8'd1;
                    end else begin
                        if (level_q[8*i +: 8] != 8'h00)
                            level_q[8*i +: 8] <= level_q[8*i +: 8] - 8'd1;
                    end
                end
            end else begin
                active_q <= active_d;
            end
        end
    end

    // ========================================================
    // GRAY CODE AND SNAPSHOT
    // ========================================================

    always_comb begin
        for (int i = 0; i < 8; i++)
            level_gray[8*i +: 8] = level_q[8*i +: 8] ^
                                   (level_q[8*i +: 8] >> 1);
    end

    assign level_master = level_q[31:0];

endmodule
