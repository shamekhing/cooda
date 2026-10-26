// ============================================================
// video_lcd  RGB LCD backend (parallel RGB565)
// ============================================================
//
// Takes the 24-bit pixel stream and the sync signals from
// video_timing and drives the Dock's RGB LCD connector. No serializer,
// no vendor IP: the panel takes parallel data and its own pixel clock.
//
// The pin map is the Dock's, documented in the examples README and in
// the .cst.
//
// lcd_dclk is the inverted pixel clock: the pixel data changes on the
// rising edge of pix_clk, and the panel samples on the rising edge of
// lcd_dclk, i.e. half a pixel period later. That is the usual way to
// buy setup/hold margin without an ODDR.
// ============================================================

module video_lcd (
    input  logic       pix_clk,

    input  logic       de,
    input  logic       hs,
    input  logic       vs,
    input  logic [7:0] r,
    input  logic [7:0] g,
    input  logic [7:0] b,

    output logic       lcd_dclk,
    output logic       lcd_de,
    output logic       lcd_hs,
    output logic       lcd_vs,

    output logic [4:0] lcd_r,
    output logic [5:0] lcd_g,
    output logic [4:0] lcd_b,

    output logic       lcd_bl
);

    // Panel clock, phase shifted half a pixel period from the data.
    assign lcd_dclk = ~pix_clk;

    assign lcd_de = de;
    // The Dock RGB panel uses active-low horizontal and vertical sync.
    assign lcd_hs = ~hs;
    assign lcd_vs = ~vs;

    // RGB888 -> RGB565.
    assign lcd_r = r[7:3];
    assign lcd_g = g[7:2];
    assign lcd_b = b[7:3];

    // Backlight on.
    assign lcd_bl = 1'b1;

endmodule
