#!/usr/bin/env python3
"""Decode + validate the boot program against the current ISA encoding.

word = (upd<<25) | (imm_mode<<24) | (op<<18) | (rd<<12) | (rs1<<6) | rs2
bits [31:26] must be zero.
"""
import sys

OP = {
    0x00: "ADD", 0x01: "ADC", 0x02: "SUB", 0x03: "SBC", 0x04: "MUL", 0x05: "MULH",
    0x06: "DIVU", 0x07: "MODU", 0x08: "DIVS", 0x09: "MODS", 0x0A: "MINU",
    0x0B: "MAXU", 0x0C: "MINS", 0x0D: "MAXS", 0x0E: "ABS", 0x0F: "NEG",
    0x10: "NOT", 0x11: "AND", 0x12: "OR", 0x13: "XOR", 0x14: "NAND",
    0x15: "NOR", 0x16: "XNOR", 0x17: "PASSA(MOV)", 0x18: "PASSB(MOVI)",
    0x19: "SHL", 0x1A: "SHR", 0x1B: "SAR", 0x1C: "ROL", 0x1D: "ROR",
    0x1E: "EQ", 0x1F: "NE", 0x20: "LTU", 0x21: "LEU", 0x22: "GTU", 0x23: "GEU",
    0x24: "LTS", 0x25: "LES", 0x26: "GTS", 0x27: "GES",
    0x28: "JMP", 0x29: "BEQ", 0x2A: "BNE", 0x2B: "BLT", 0x2C: "BGE",
    0x2D: "BLTU", 0x2E: "BGEU", 0x2F: "LOAD", 0x30: "STORE",
}
BRANCH = set(range(0x28, 0x2F))
MEM    = {0x2F, 0x30}
UNARY  = {0x0E, 0x0F, 0x10}
REG_COUNT = 64

def decode(w, imm, pc):
    upd = (w >> 25) & 1
    im  = (w >> 24) & 1
    op  = (w >> 18) & 0x3F
    rd  = (w >> 12) & 0x3F
    rs1 = (w >> 6) & 0x3F
    rs2 = w & 0x3F

    errs = []
    if (w >> 26) != 0:
        errs.append("reserved bits [31:26] set")
    if op not in OP:
        errs.append("unknown opcode 0x%02X" % op)
        return None, errs

    if op in BRANCH:
        if rd:  errs.append("branch with rd != 0")
        if im:  errs.append("branch with immediate_mode set")
        if upd: errs.append("branch with update_status set")
        if op == 0x28 and (rs1 or rs2):
            errs.append("JMP with rs1/rs2 != 0")
        name = OP[op]
        tgt = "0x%04X" % imm if op == 0x28 else "r%d, r%d -> 0x%04X" % (rs1, rs2, imm)
        return "%-12s %s" % (name, tgt), errs

    if op in MEM:
        if im:  errs.append("memory op with immediate_mode set")
        if upd: errs.append("memory op with update_status set")
        if op == 0x2F and rs2:
            errs.append("LOAD with rs2 != 0")
        if op == 0x30 and rd:
            errs.append("STORE with rd != 0")
        if op == 0x2F:
            return "%-12s r%d, [r%d + %d]" % ("LOAD", rd, rs1, imm), errs
        return "%-12s r%d, [r%d + %d]" % ("STORE", rs2, rs1, imm), errs

    if op in (0x17, 0x18):
        if upd:
            errs.append("MOV/MOVI with update_status set")
        if op == 0x17:
            if im: errs.append("MOV with immediate_mode set")
            if rs2: errs.append("MOV with rs2 != 0")
            return "%-12s r%d, r%d" % ("MOV", rd, rs1), errs
        if not im: errs.append("MOVI without immediate_mode")
        if rs1: errs.append("MOVI with rs1 != 0")
        if rs2: errs.append("MOVI with rs2 != 0")
        return "%-12s r%d, 0x%08X" % ("MOVI", rd, imm), errs

    if op in UNARY:
        if im:  errs.append("unary with immediate_mode set")
        if rs2: errs.append("unary with rs2 != 0")
        return "%-12s r%d, r%d" % (OP[op], rd, rs1), errs

    # binary ALU
    if im and rs2:
        errs.append("immediate ALU op with rs2 != 0")
    src = "#%d" % imm if im else "r%d" % rs2
    return "%-12s r%d, r%d, %s" % (OP[op], rd, rs1, src), errs

def main(path):
    with open(path) as f:
        words = [int(l.strip(), 16) for l in f if l.strip()]
    pc = 0
    bad = 0
    n = 0
    while pc // 4 < len(words):
        w = words[pc // 4]
        if w == 0:
            break
        imm = words[pc // 4 + 1] if pc // 4 + 1 < len(words) else 0
        text, errs = decode(w, imm, pc)
        has_imm = (text or "").startswith(("LOAD", "STORE", "JMP", "BEQ", "BNE",
                                          "BLT", "BGE", "BLTU", "BGEU", "MOVI")) or \
                  ("#" in (text or ""))
        print("0x%04X  %08X  %s%s" % (pc, w, text, "   <== " + "; ".join(errs) if errs else ""))
        if errs:
            bad += 1
        n += 1
        pc += 8 if has_imm else 4
    print("\n%0d instructions, %0d invalid" % (n, bad))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "src/programs/boot_program.hex"))
