"""Decode an hmc7044_readback.tcl dump (read from stdin or a file argument).

First the configuration registers are compared with the values the PL sequencer
writes: if they match, the SPI readback itself is trustworthy.  Then the
PLL1/PLL2 status readback registers (0x7C..0x9F) are printed raw, with the
PLL1 FSM field of reg 0x82 decoded the way ADI's Linux hmc7044 driver does.
"""
import re
import sys

EXPECTED = {
    0x03: 0x2F, 0x05: 0x5A, 0x0B: 0x07, 0x14: 0x36, 0x1C: 0x01, 0x1D: 0x01,
    0x20: 0x0A, 0x21: 0x01, 0x22: 0x00, 0x26: 0x0A, 0x27: 0x00, 0x29: 0x05,
    0x33: 0x19, 0x35: 0x00, 0x36: 0x03, 0x54: 0x01,
}
PLL1_FSM = ["reset", "acquisition", "locked", "invalid", "holdover",
            "DAC-assisted holdover exit", "invalid", "invalid"]


def main():
    text = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
    status = re.search(r"STATUS 0x([0-9a-fA-F]+)", text)
    regs = {int(a, 16): int(v, 16)
            for a, v in re.findall(r"REG 0x([0-9a-f]+) 0x([0-9a-f]+)", text)}
    if status:
        word = int(status.group(1), 16)
        print(f"sweeps {word & 0xFFFF}, GPIO1 pin {word >> 31}")
    mismatches = 0
    for addr, want in sorted(EXPECTED.items()):
        got = regs.get(addr)
        flag = "ok" if got == want else "MISMATCH"
        mismatches += got != want
        print(f"  cfg 0x{addr:02X}: wrote 0x{want:02X} read 0x{got:02X} {flag}"
              if got is not None else f"  cfg 0x{addr:02X}: missing")
    print("config readback:", "all match" if not mismatches else f"{mismatches} mismatches")
    print("status registers 0x78..0x9F:")
    for row in range(0x78, 0xA0, 8):
        print(f"  0x{row:02X}: " + " ".join(f"{regs.get(a, 0):02X}" for a in range(row, row + 8)))
    pll1 = regs.get(0x82)
    if pll1 is not None:
        print(f"reg 0x82 = 0x{pll1:02X}: PLL1 FSM {PLL1_FSM[pll1 & 7]}, "
              f"active CLKIN{(pll1 >> 3) & 3} (ADI driver field layout)")
    alarm = regs.get(0x7D)
    if alarm is not None:
        print(f"reg 0x7D (alarm readback) = 0x{alarm:02X}, reg 0x7C = 0x{regs.get(0x7C, 0):02X}")


if __name__ == "__main__":
    main()
