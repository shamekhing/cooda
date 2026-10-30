// ============================================================
// fpga_top  minimal Tang Primer 20K CPU board wrapper
// ============================================================
module fpga_top (
    input  logic clk27,
    input  logic btn_n0,
    input  logic btn_n1,
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    output wire [12:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire [1:0]  DDR3_DM,
    output wire        DDR3_ODT,
    output wire        sd_cs_n,
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output logic led0,
    output logic led1,
    output logic led2,
    output logic led3,
    output logic led4,
    output logic led5
);
    logic [1:0] rst_sync = 2'b11;
    logic [1:0] run_sync = 2'b00;
    logic rst, user_rst, run;
    logic retire_valid, illegal_instr, cpu_fault;
    logic ddr_write_level_done, ddr_read_calib_done, ddr_err;
    logic sd_ready, sd_error, load_done, load_error;
    logic [1:0] sd_card_type;
    logic [3:0] sd_err_code, load_err_code;
    logic [19:0] activity_count;
    logic ddr_pclk, ddr_fclk, ddr_ck, ddr_pll_lock;
    logic ddr_reset_async;
    logic ddr_rst;
    logic [1:0] ddr_rst_sync = 2'b11;

    ddr3_pll pll (
        .clkin(clk27), .pclk(ddr_pclk), .fclk(ddr_fclk),
        .ck(ddr_ck), .lock(ddr_pll_lock)
    );

    // Assert DDR reset immediately with the system reset or loss of
    // PLL lock. Release it synchronously in the DDR command domain.
    assign ddr_reset_async = rst;

    always_ff @(posedge ddr_pclk or posedge ddr_reset_async) begin
        if (ddr_reset_async) ddr_rst_sync <= 2'b11;
        else ddr_rst_sync <= {ddr_rst_sync[0], 1'b0};
    end
    assign ddr_rst = ddr_rst_sync[1] | !ddr_pll_lock;

    always_ff @(posedge clk27) begin
        rst_sync <= {rst_sync[0], ~btn_n0};
        run_sync <= {run_sync[0],  btn_n1};
    end

    // Reset both CDC domains together if the DDR clock stops. This
    // prevents a half-completed toggle handshake from being stranded.
    assign user_rst = rst_sync[1];
    assign rst = user_rst || !ddr_pll_lock;
    assign run = run_sync[1];

    system #(.DDR3_ENABLE(1'b1), .SD_ENABLE(1'b1)) u_system (
        .clk(clk27), .rst(rst), .run(run),
        .ddr_pclk(ddr_pclk), .ddr_fclk(ddr_fclk), .ddr_ck(ddr_ck),
        .ddr_rst(ddr_rst),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS),
        .DDR3_nWE(DDR3_nWE), .DDR3_CK(DDR3_CK),
        .DDR3_CKE(DDR3_CKE), .DDR3_nRESET(DDR3_nRESET),
        .DDR3_DM(DDR3_DM), .DDR3_ODT(DDR3_ODT),
        .retire_valid(retire_valid),
        .illegal_instr(illegal_instr), .cpu_fault(cpu_fault),
        .ddr_write_level_done(ddr_write_level_done),
        .ddr_read_calib_done(ddr_read_calib_done),
        .ddr_err(ddr_err),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_ready(sd_ready), .sd_card_type(sd_card_type),
        .sd_error(sd_error), .sd_err_code(sd_err_code),
        .load_done(load_done), .load_error(load_error),
        .load_err_code(load_err_code)
    );

    always_ff @(posedge clk27) begin
        if (rst) activity_count <= '0;
        else if (retire_valid) activity_count <= '1;
        else if (activity_count != '0) activity_count <= activity_count - 1'b1;
    end

    // Dock LEDs are active-low. led0..led2 are the CPU and DDR3
    // bring-up indicators; led3..led5 are the microSD path, which is
    // what a board with a card in it shows:
    //   led3  the card answered the wake-up sequence
    //   led4  the image is in DDR3
    //   led5  something failed (DDR3, the card, or the image)
    // Six LEDs cannot show everything: cpu_fault, illegal_instr and the
    // four-bit error codes stay in simulation, and system exports them.
    assign led0 = (activity_count == '0);
    assign led1 = ~ddr_write_level_done;
    assign led2 = ~ddr_read_calib_done;
    assign led3 = ~sd_ready;
    assign led4 = ~load_done;
    assign led5 = ~(ddr_err | sd_error | load_error);
endmodule
