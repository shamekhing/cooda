// ============================================================
// cpu_core  execution core
//
// Executes one decoded instruction per handshake. The instruction
// arrives pre-decoded as isa_pkg::program_ctrl_s from cpu_program;
// the core never sees the raw instruction word and decodes nothing
// itself.
//
// LOAD/STORE completion:
//
//   - data_req.valid is asserted for every LOAD/STORE request.
//   - data_req.op distinguishes STORE from LOAD.
//   - address/write data remain stable while the instruction is held.
//   - a bus handshake captures read data.
//   - LOAD/STORE retire and write back on the following cycle.
//
// Normal ALU and branch instructions remain fixed-latency and do not
// use the bus handshake. The branch decision itself is made by
// cpu_branch in the instruction unit, which compares the operand
// values this core exposes as operand_a / operand_b.
//
// Execution state machine:
//
//   StIdle     waiting for a decoded instruction
//   StCapture  latch operand addresses and the ALU operands
//   StRun      multi-cycle ALU in flight
//   StWait     LOAD/STORE request waiting for the bus handshake
//   StRetire   memory instruction completing, one cycle
// ============================================================

module cpu_core (
    input  logic clk,
    input  logic rst,

    input  logic core_enable,
    input  isa_pkg::program_ctrl_s ctrl,

    // Kept external to preserve the existing cpu_datapath interface.
    input  logic carry_in,

    // --------------------------------------------------------
    // Data-bus master (RPU cpu_d).
    // --------------------------------------------------------
    output soc_pkg::bus_req_s data_req,
    input  soc_pkg::bus_rsp_s data_rsp,

    // --------------------------------------------------------
    // Operand values handed to cpu_branch.
    // --------------------------------------------------------
    output arch_pkg::word_t operand_a,
    output arch_pkg::word_t operand_b,

    output logic retire_valid,
    output logic carry_flag
);

    typedef enum logic [2:0] {
        StIdle,
        StCapture,
        StRun,
        StWait,
        StRetire
    } state_e;

    state_e state_q, state_d;

    arch_pkg::reg_addr_t rs1_q, rs1_d;
    arch_pkg::reg_addr_t rs2_q, rs2_d;
    arch_pkg::word_t     imm_operand_q, imm_operand_d;
    logic                imm_sel_q, imm_sel_d;
    arch_pkg::word_t     mem_rdata_q, mem_rdata_d;
    logic                alu_start_q, alu_start_d;

    // A decoded LOAD or STORE is a memory operation. cpu_decoder makes
    // these two controls mutually exclusive for every legal
    // instruction.
    logic memory_op;
    assign memory_op = ctrl.memory_re || ctrl.memory_we;

    arch_pkg::word_t store_data;
    arch_pkg::word_t alu_result;

    logic alu_done;
    logic mem_accept;
    logic capture_operands;

    logic effective_register_write;
    logic effective_flags_write;

    assign capture_operands =
        (state_q == StCapture) && core_enable && !rst;

    // ========================================================
    // DATA BUS REQUEST
    // ========================================================
    // core_enable remains asserted while cpu_program stalls cpu_pc,
    // therefore data_req and all request payload signals remain
    // asserted and stable until data_rsp.ready completes the
    // transaction. The request only starts once the ALU has produced
    // the effective address.
    // --------------------------------------------------------

    assign data_req.valid =
        (state_q == StWait) &&
        core_enable &&
        ctrl.decode_valid &&
        memory_op &&
        !rst;

    assign mem_accept = data_req.valid && data_rsp.ready;

    assign data_req.op = ctrl.memory_we ? soc_pkg::BusWrite
                                        : soc_pkg::BusRead;

    // LOAD/STORE decode to ALU OpAdd, so alu_result is the effective
    // byte address.
    assign data_req.addr  = alu_result;
    assign data_req.wdata = store_data;
    assign data_req.wstrb = soc_pkg::BUS_STRB_ALL;

    // ========================================================
    // ARCHITECTURAL WRITE ENABLES
    // ========================================================
    // retire_valid marks the single cycle on which the instruction
    // completes, so it also gates the register/flags writes. A LOAD
    // only retires after the bus handshake, a normal instruction on
    // alu_done.
    // --------------------------------------------------------

    assign effective_register_write =
        ctrl.register_write_enable && retire_valid;

    assign effective_flags_write =
        ctrl.flags_write_enable && retire_valid;

    assign retire_valid =
        core_enable &&
        ctrl.decode_valid &&
        !rst &&
        ( (!memory_op && alu_done) ||
          (state_q == StRetire) );

    // ========================================================
    // NEXT-STATE VALUES
    // ========================================================
    // Operands are captured before the ALU starts. Every decoded
    // instruction runs the multi-cycle ALU. A LOAD/STORE uses it to
    // form the effective address; a branch uses the result only as an
    // observable value. Memory operations then wait for the bus
    // before retiring on the following cycle.
    // --------------------------------------------------------

    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d       = state_q;
        rs1_d         = rs1_q;
        rs2_d         = rs2_q;
        imm_operand_d = imm_operand_q;
        imm_sel_d     = imm_sel_q;
        mem_rdata_d   = mem_rdata_q;
        alu_start_d   = 1'b0;

        case (state_q)

            StIdle: begin
                if (core_enable && ctrl.decode_valid && !rst) begin
                    rs1_d         = ctrl.rs1;
                    rs2_d         = ctrl.rs2;
                    imm_operand_d = ctrl.imm_operand;
                    imm_sel_d     = ctrl.imm_sel;
                    state_d       = StCapture;
                end
            end

            StCapture: begin
                alu_start_d = 1'b1;
                state_d     = StRun;
            end

            StRun: begin
                if (alu_done) begin
                    if (memory_op) state_d = StWait;
                    else           state_d = StIdle;
                end
            end

            StWait: begin
                if (mem_accept) begin
                    mem_rdata_d = data_rsp.rdata;
                    state_d     = StRetire;
                end else if (!core_enable) begin
                    state_d = StIdle;
                end
            end

            StRetire: state_d = StIdle;

            default: state_d = StIdle;

        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q       <= StIdle;
            rs1_q         <= '0;
            rs2_q         <= '0;
            imm_operand_q <= '0;
            imm_sel_q     <= 1'b0;
            mem_rdata_q   <= '0;
            alu_start_q   <= 1'b0;
        end else begin
            state_q       <= state_d;
            rs1_q         <= rs1_d;
            rs2_q         <= rs2_d;
            imm_operand_q <= imm_operand_d;
            imm_sel_q     <= imm_sel_d;
            mem_rdata_q   <= mem_rdata_d;
            alu_start_q   <= alu_start_d;
        end
    end

    // ========================================================
    // cpu_datapath
    // ========================================================

    cpu_datapath u_cpu_datapath (
        .clk(clk),
        .rst(rst),

        .rs1(rs1_q),
        .rs2(rs2_q),
        .rd(ctrl.rd),

        .op(ctrl.op),
        .carry_in(carry_in),
        .alu_start(alu_start_q),
        .capture_operands(capture_operands),
        .use_captured_operands(state_q != StIdle),

        .imm_operand(imm_operand_q),
        .imm_sel(imm_sel_q),

        .register_write_enable(effective_register_write),
        .flags_write_enable(effective_flags_write),

        .dmem_rdata(mem_rdata_q),
        .writeback_from_mem(ctrl.memory_re),

        .operand_a(operand_a),
        .operand_b(operand_b),
        .store_data(store_data),
        .alu_result(alu_result),
        .alu_done(alu_done),
        .carry_flag(carry_flag)
    );

endmodule
