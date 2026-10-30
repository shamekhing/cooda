// ============================================================
// memory_sd  the microSD card as a boot-time DDR3 filler
// ============================================================
//
// Wraps the two halves of the microSD path:
//
//   sd_controller  speaks the card's protocol (sd_spi_master clocks
//                  the bytes below that)
//   sd_loader      turns block reads into bus writes into the DDR3
//                  window
//
// This is the module system.sv instantiates, the way it instantiates
// memory_ddr3. It owns the card pins, presents a bus master to the
// arbiter, and exports enough status for a board with nothing but
// LEDs to show how far a load got.
//
// The loader is a boot-time master: it runs once after reset and then
// holds its bus request low forever, so sharing an arbiter slot with
// a later compute block only needs a valid/done gate.
// ============================================================

module memory_sd #(
    parameter int               DIVIDER_WIDTH         = 16,
    parameter logic [DIVIDER_WIDTH-1:0] DIVIDER_INIT      = 16'd34,     // 397 kHz
    parameter logic [DIVIDER_WIDTH-1:0] DIVIDER_DATA      = 16'd1,      // 13.5 MHz at 27 MHz
    parameter logic [31:0]      DDR3_BASE     = 32'h0800_0000,
    parameter logic [31:0]      DDR3_SIZE     = 32'h0800_0000,
    parameter int               POWERUP_BYTES = 10,
    parameter int               R1_POLL_BYTES      = 16,
    parameter int               ACMD41_MAX_RETRIES     = 8000,
    parameter int               TOKEN_TIMEOUT_BYTES     = 4096,
    parameter int               MAX_BLOCKS    = 65536
) (
    input  logic             clk,
    input  logic             rst,

    // card pins
    output logic             sd_cs_n,
    output logic             sd_sck,
    output logic             sd_mosi,
    input  logic             sd_miso,

    // SoC bus master
    output soc_pkg::bus_req_s bus_req,
    input  soc_pkg::bus_rsp_s bus_rsp,

    // status
    output logic             sd_ready,
    output logic [1:0]       card_type,
    output logic             sd_error,
    output logic [3:0]       sd_err_code,
    output logic [4:0]       ctrl_state,
    output logic             load_done,
    output logic             load_error,
    output logic [3:0]       load_err_code,
    output logic [31:0]      blocks_loaded,
    output logic [31:0]      bytes_loaded
);

    logic        block_req;
    logic [31:0] block_addr;
    logic        block_busy;
    logic        block_done;
    logic [31:0] block_data;
    logic        block_valid;

    sd_controller #(
        .DIVIDER_WIDTH         (DIVIDER_WIDTH),
        .DIVIDER_INIT      (DIVIDER_INIT),
        .DIVIDER_DATA      (DIVIDER_DATA),
        .POWERUP_BYTES (POWERUP_BYTES),
        .R1_POLL_BYTES      (R1_POLL_BYTES),
        .ACMD41_MAX_RETRIES     (ACMD41_MAX_RETRIES),
        .TOKEN_TIMEOUT_BYTES     (TOKEN_TIMEOUT_BYTES)
    ) u_ctrl (
        .clk       (clk),
        .rst       (rst),
        .cs_n      (sd_cs_n),
        .sck       (sd_sck),
        .mosi      (sd_mosi),
        .miso      (sd_miso),
        .block_req   (block_req),
        .block_addr  (block_addr),
        .block_busy  (block_busy),
        .block_done  (block_done),
        .block_data  (block_data),
        .block_valid (block_valid),
        .ready     (sd_ready),
        .error     (sd_error),
        .err_code  (sd_err_code),
        .card_type (card_type),
        .state_dbg (ctrl_state)
    );

    sd_loader #(
        .DDR3_BASE  (DDR3_BASE),
        .DDR3_SIZE  (DDR3_SIZE),
        .MAX_BLOCKS (MAX_BLOCKS)
    ) u_loader (
        .clk           (clk),
        .rst           (rst),
        .block_req       (block_req),
        .block_addr      (block_addr),
        .block_done      (block_done),
        .block_data      (block_data),
        .block_valid     (block_valid),
        .sd_ready      (sd_ready),
        .sd_error      (sd_error),
        .bus_req       (bus_req),
        .bus_rsp       (bus_rsp),
        .done          (load_done),
        .error         (load_error),
        .err_code      (load_err_code),
        .blocks_loaded (blocks_loaded),
        .bytes_loaded  (bytes_loaded),
        .state_dbg     ()
    );

endmodule
