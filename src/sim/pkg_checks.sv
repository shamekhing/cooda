// ============================================================
// pkg_checks  SIMULATION ONLY
//
// Elaboration-time sanity checks for the packages, kept out of
// the packages themselves so they stay free of $fatal.
// Instantiate once in a testbench.
// ============================================================

module pkg_checks;

    initial begin

        if (arch_pkg::WORD_BYTES * 8 != arch_pkg::WORD_WIDTH)
            $fatal(1, "WORD_BYTES * 8 != WORD_WIDTH");

        if (arch_pkg::REG_FILE_COUNT < 2)
            $fatal(1, "REG_FILE_COUNT must be at least 2");

        if ((1 << isa_pkg::OPCODE_WIDTH) <= isa_pkg::OPCODE_MAX)
            $fatal(1, "OPCODE_WIDTH cannot represent every opcode");

        if (isa_pkg::INSTRUCTION_BITS > arch_pkg::WORD_WIDTH)
            $fatal(1, "instruction_s exceeds WORD_WIDTH");

        if (soc_pkg::INSTRUCTION_ROM_BYTES % arch_pkg::WORD_BYTES != 0 ||
            soc_pkg::DATA_RAM_BYTES        % arch_pkg::WORD_BYTES != 0)
            $fatal(1, "ROM/RAM sizes must be word-divisible");

        if (!soc_pkg::map_validate())
            $fatal(1, "address map invalid (power-of-two size, alignment, overlap)");

        if ($bits(gpu_pkg::gpu_status_s) != arch_pkg::WORD_WIDTH)
            $fatal(1, "gpu_status_s must be exactly one word");

        if (gpu_pkg::GPU_REG_COUNT * arch_pkg::WORD_BYTES > soc_pkg::GPU_MMIO_BYTES)
            $fatal(1, "GPU registers do not fit in GPU_MMIO_BYTES");

    end

endmodule
