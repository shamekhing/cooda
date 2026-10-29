module pkg_checks;
    initial begin
        if (arch_pkg::WORD_BYTES * 8 != arch_pkg::WORD_WIDTH)
            $fatal(1, "word geometry invalid");
        if (soc_pkg::MAIN_MEMORY_BYTES % arch_pkg::WORD_BYTES != 0)
            $fatal(1, "main-memory size must be word divisible");
        if (soc_pkg::MAIN_MEMORY_WORDS * arch_pkg::WORD_BYTES != soc_pkg::MAIN_MEMORY_BYTES)
            $fatal(1, "main-memory word count mismatch");
    end
endmodule
