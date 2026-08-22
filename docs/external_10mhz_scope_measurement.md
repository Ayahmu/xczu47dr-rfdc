# External 250 MHz Reference Measurement

This configuration uses a shared 250 MHz reference on XS17 for the custom
XCZU47DR board. It does not contain the multi-board master/slave synchronization
flow.

## Clock Path

The HMC7044 selects CLKIN1/XS17. PLL1 uses R1=25 and N1=10, so the 250 MHz
input is divided to a 10 MHz PLL1 PFD and locks the on-board 100 MHz VCXO.
PLL2 continues to run its 3.072 GHz VCO and generates the 128 MHz DAC
references and 2 MHz SYSREF. The RFDC configuration remains 6.4 GS/s with
16x interpolation and a 50 MHz AXIS fabric clock.

Register 0x0003 must select the High VCO core (`VCO Selection[4:3] = 01`, value
0x2F with RF reseeder, SYSREF timer, PLL2, and PLL1 enabled). Register 0x0021
must be 0x19 (R1=25), while 0x0026 remains 0x0A (N1=10). Value 0x37 in
0x0003 selects the reserved VCO code 11; with that value PLL2 autotune cannot
land on 3.072 GHz, the DAC REFCLK stays at 120 MHz, and every RF tone is scaled
by 15/16.

## Connections

Use two coherent outputs from the same reference source:

1. Reference OUT 1 (250 MHz) -> 50 ohm coax/adaptor -> board XS17 (SSMC).
2. Use a second coherent reference output as the oscilloscope timebase, or
   use the HMC7044 10 MHz monitor output where the scope requires 10 MHz.
3. Board RF output -> suitable attenuator/DC block -> 50 ohm scope channel.
4. Board XS18/TRIG_1 -> MMCX coax -> oscilloscope external trigger.

Start with a 250 MHz sine reference at the level specified by the board and
source documentation. Confirm the allowed input level before increasing it.
Verify that the source and the scope use the same frequency reference.

TRIG_1 is a 2.5 V LVCMOS pulse generated when DAC sample-valid becomes active.
Use a high-impedance external-trigger input, rising-edge trigger, and an
initial threshold near 1.25 V. Do not terminate TRIG_1 in 50 ohms unless an
appropriate external buffer is used.

## Power-up And Programming

1. Enable the 250 MHz reference output and let the source stabilize.
2. Select the coherent external timebase on the scope and verify lock.
3. Power the board, connect JTAG, and program the bitstream and ELF:

   ```bash
   make run
   ```

4. Check the UART log for the 250 MHz / 10 MHz PFD / 128 MHz clock policy,
   HMC7044 sequence completion, and normal RFDC PLL
   initialization. This target does not run DAC MTS.
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
hardware/vivado/output/custom_xczu47dr_rfdc.bit
hardware/vivado/output/custom_xczu47dr_rfdc.ltx
hardware/vivado/output/custom_xczu47dr_rfdc.xsa
firmware/workspace/custom_xczu47dr/rfdc_app/Debug/rfdc_app.elf
```

Artifact checksums for the 2026-08-09 build:

```text
bit  e57de5566e247702fbda4fcd0b453dccbb2029004a4dfe6025112fd493cd2e30
ltx  47626849e3764b55504420c2d6fe5c09a9104c071ba9f08f7d624a5bc37e456c
xsa  18e20594919478dcab2b5229da1d0bc6cb0f139f3636a1d4f2cf4969a7ef087c
elf  9c94ce597f7eda7c448a4ee89d1da36f5f2fbb7bdcf2f5ec2688e73301a2b50e
```

## Measurement Notes

Sharing the 250 MHz reference removes long-term frequency drift between the
board and the scope. TRIG_1 supplies a repeatable acquisition event. Residual
phase noise and timing uncertainty are still limited by the reference source,
the HMC7044/RFDC clock chain, cables, the analog RF path, and the scope itself.
