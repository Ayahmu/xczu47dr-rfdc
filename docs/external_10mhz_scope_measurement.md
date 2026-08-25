# External 10 MHz XS17 Profile

This document describes the mainline 10 MHz XS17 reference configuration for
the custom XCZU47DR board. It is the current lab-validation baseline. A future
250 MHz XS17 configuration is maintained and validated separately; do not mix
its artifacts or clock plan with this procedure.

## Clock Path

The HMC7044 selects CLKIN1/XS17. PLL1 uses R1=1 and N1=10, so the 10 MHz
input directly supplies the 10 MHz PLL1 PFD and locks the on-board 100 MHz VCXO.
PLL2 continues to run its 3.072 GHz VCO and generates the 128 MHz DAC
references and 2 MHz SYSREF. The RFDC configuration remains 6.4 GS/s with
16x interpolation and a 50 MHz AXIS fabric clock.

Register 0x0003 must select the High VCO core (`VCO Selection[4:3] = 01`, value
0x2F with RF reseeder, SYSREF timer, PLL2, and PLL1 enabled). Register 0x0021
must be 0x01 (R1=1), while 0x0026 remains 0x0A (N1=10). Value 0x37 in
0x0003 selects the reserved VCO code 11; with that value PLL2 autotune cannot
land on 3.072 GHz, the DAC REFCLK stays at 120 MHz, and every RF tone is scaled
by 15/16.

## Connections

Use two coherent outputs from the same reference source:

1. Reference OUT 1 (10 MHz) -> 50 ohm coax/adaptor -> board XS17 (SSMC).
2. Use a second coherent reference output as the oscilloscope timebase, or
   use the HMC7044 10 MHz monitor output where the scope requires 10 MHz.
3. Board RF output -> suitable attenuator/DC block -> 50 ohm scope channel.
4. Board XS18/TRIG_1 -> MMCX coax -> oscilloscope external trigger.

Start with a 10 MHz sine reference at the level specified by the board and
source documentation. Confirm the allowed input level before increasing it.
Verify that the source and the scope use the same frequency reference.

TRIG_1 is a 2.5 V LVCMOS pulse generated when DAC sample-valid becomes active.
Use a high-impedance external-trigger input, rising-edge trigger, and an
initial threshold near 1.25 V. Do not terminate TRIG_1 in 50 ohms unless an
appropriate external buffer is used.

## Power-up And Programming

1. Enable the 10 MHz reference output and let the source stabilize.
2. Select the coherent external timebase on the scope and verify lock.
3. Power the board, connect JTAG, and program the bitstream and ELF:

   ```bash
   make run
   ```

4. Check the UART log for the 10 MHz / 10 MHz PFD / 128 MHz clock policy,
   HMC7044 sequence completion, RFDC PLL initialization, DAC MTS, and NCO
   SYSREF readiness. XS20 synchronization does not block this boot sequence.
5. Before changing any NCO or waveform frequency calculation, measure an
   accessible DAC REFCLK test point and confirm 128 MHz rather than 120 MHz.
6. Load and trigger 1 GHz, 4.5 GHz, and 5 GHz sine waveforms in turn. The scope
   should measure approximately the requested frequencies, within the reference
   source and scope accuracy, with no common 15/16 scale factor.
7. Verify the RF period, spectrum, and repeat-trigger stability using TRIG_1.

If the DAC REFCLK is still 120 MHz, stop frequency-algorithm changes and inspect
the physical HMC7044 SPI writes (especially 0x0003, 0x0021, and 0x0026), reset
polarity, external-reference level, and PLL lock behavior.

The generated artifacts are:

```text
artifacts/custom_xczu47dr_master.bit
artifacts/custom_xczu47dr_master.ltx
artifacts/custom_xczu47dr_master.xsa
artifacts/custom_xczu47dr_master.elf
```

Record the generated role, bitstream SHA256, firmware ELF SHA256, source
serial number, and instrument configuration in the test record. Do not reuse
historical checksums after rebuilding.


## Measurement Notes

Sharing the same 10 MHz reference source between the board and the scope
removes long-term frequency drift. TRIG_1 supplies a repeatable acquisition
event. Residual
phase noise and timing uncertainty are still limited by the reference source,
the HMC7044/RFDC clock chain, cables, the analog RF path, and the scope itself.
