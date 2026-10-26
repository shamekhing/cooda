
// ============================================================
// LACOODA cpu_fetch  instruction fetch
// ============================================================
//
// Owns cpu_pc and the instruction buffer.
//
// Fetch sequence:
//
//   1. Request instruction at PC.
//   2. Wait for I-BUS completion.
//   3. Fetch immediate word when required.
//   4. Buffer the complete instruction.
//   5. Wait for retirement.
//   6. Continue fetching.
//
// Once started, a fetch is not cancelled when run falls.
//
// The instruction bus is read-only.
//
// Fetch state machine:
//
//   StIdle   no request in flight; a buffered instruction may be
//            waiting to retire
//   StInstr  instruction word read in flight, at pc
//   StImm    immediate word read in flight, at pc + WORD_BYTES
//
// An instruction-bus error latches fault and stops fetch until reset.
// ============================================================

module cpu_fetch (

    input logic clk,
    input logic rst,
    input logic run,

    input logic retire,
    input logic redirect,
    input arch_pkg::word_t redirect_target,

    output soc_pkg::bus_req_s instr_req,
    input  soc_pkg::bus_rsp_s instr_rsp,

    output isa_pkg::instruction_t instruction,
    output arch_pkg::word_t immediate_word,
    output logic instruction_available,
    output logic fault

);

    // ========================================================
    // FETCH STATES
    // ========================================================

    typedef enum logic [1:0] {
        StIdle,
        StInstr,
        StImm
    } state_e;

    state_e state_q, state_d;

    // ========================================================
    // PROGRAM COUNTER
    // ========================================================

    logic has_imm;
    arch_pkg::word_t pc;

    cpu_pc u_cpu_pc (

        .clk             (clk),
        .rst             (rst),

        .enable          (retire),

        .redirect        (redirect),
        .redirect_target (redirect_target),

        .has_imm         (has_imm),
        .pc              (pc)

    );

    // ========================================================
    // INSTRUCTION BUFFER
    // ========================================================

    isa_pkg::instruction_t instruction_q, instruction_d;
    arch_pkg::word_t       immediate_word_q, immediate_word_d;
    logic                  instruction_available_q, instruction_available_d;
    logic                  fault_q, fault_d;

    assign instruction           = instruction_q;
    assign immediate_word        = immediate_word_q;
    assign instruction_available = instruction_available_q;
    assign fault                 = fault_q;

    // ========================================================
    // INSTRUCTION BUS REQUEST
    // ========================================================
    //
    // Fetch instruction at PC.
    //
    // Fetch immediate at PC + WORD_BYTES.
    //
    // No instruction-bus writes are permitted.
    //
    // Write data and strobes are always zero.
    // ========================================================

    assign instr_req.valid = (state_q != StIdle);

    assign instr_req.op = soc_pkg::BusRead;

    assign instr_req.addr =
        (state_q == StImm)
            ? pc + arch_pkg::word_t'(arch_pkg::WORD_BYTES)
            : pc;

    assign instr_req.wdata = '0;

    assign instr_req.wstrb = soc_pkg::BUS_STRB_NONE;

    // ========================================================
    // IMMEDIATE-WORD CLASSIFICATION
    // ========================================================

    assign has_imm =
        instruction_available_q &&
        isa_pkg::isa_has_imm_word(instruction_q);

    // ========================================================
    // NEXT-STATE VALUES
    // ========================================================

    always_comb begin
        // Hold by default; each state overrides what it changes.
        state_d                 = state_q;
        instruction_d           = instruction_q;
        immediate_word_d        = immediate_word_q;
        instruction_available_d = instruction_available_q;
        fault_d                 = fault_q;

        if (retire) begin

            // ------------------------------------------------
            // Retire the buffered instruction.
            //
            // Begin another fetch only when run is asserted.
            // ------------------------------------------------

            instruction_d           = '0;
            immediate_word_d        = '0;
            instruction_available_d = 1'b0;

            if (run) state_d = StInstr;
            else     state_d = StIdle;

        end else begin

            case (state_q)

                // ============================================
                // IDLE
                // ============================================

                StIdle: begin
                    if (run && !instruction_available_q)
                        state_d = StInstr;
                end

                // ============================================
                // FETCH INSTRUCTION
                // ============================================

                StInstr: begin
                    if (instr_rsp.ready) begin
                        if (instr_rsp.error) begin
                            fault_d = 1'b1;
                            state_d = StIdle;
                        end else begin
                            instruction_d =
                                isa_pkg::instruction_t'(instr_rsp.rdata);

                            if (isa_pkg::isa_has_imm_word(instr_rsp.rdata)) begin
                                state_d                 = StImm;
                                instruction_available_d = 1'b0;
                            end else begin
                                state_d                 = StIdle;
                                instruction_available_d = 1'b1;
                            end
                        end
                    end
                end

                // ============================================
                // FETCH IMMEDIATE
                // ============================================

                StImm: begin
                    if (instr_rsp.ready) begin
                        if (instr_rsp.error) begin
                            fault_d = 1'b1;
                            state_d = StIdle;
                        end else begin
                            immediate_word_d        = instr_rsp.rdata;
                            state_d                 = StIdle;
                            instruction_available_d = 1'b1;
                        end
                    end
                end

                // ============================================
                // INVALID STATE RECOVERY
                // ============================================

                default: begin
                    state_d                 = StIdle;
                    instruction_available_d = 1'b0;
                end

            endcase

        end
    end

    // ========================================================
    // STATE AND BUFFER REGISTERS
    // ========================================================

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state_q                 <= StIdle;
            instruction_q           <= '0;
            immediate_word_q        <= '0;
            instruction_available_q <= 1'b0;
            fault_q                 <= 1'b0;
        end else begin
            state_q                 <= state_d;
            instruction_q           <= instruction_d;
            immediate_word_q        <= immediate_word_d;
            instruction_available_q <= instruction_available_d;
            fault_q                 <= fault_d;
        end
    end

endmodule
