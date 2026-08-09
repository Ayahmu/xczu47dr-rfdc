# External 10 MHz Scope Measurement

This branch configures the board as a single-board RFDC playback target whose
HMC7044 uses the external 10 MHz reference on XS17. It does not contain the
multi-board master/slave synchronization flow.

## Clock Path

The HMC7044 selects CLKIN1/XS17. PLL1 locks the on-board 100 MHz VCXO to the
external 10 MHz source. PLL2 continues to run its 3.072 GHz VCO and generates
the existing 128 MHz DAC references and 2 MHz SYSREF. The RFDC configuration
remains 6.4 GS/s with 16x interpolation and a 50 MHz AXIS fabric clock.

Register 0x0003 must select the High VCO core (`VCO Selection[4:3] = 01`, value
0x2F with RF reseeder, SYSREF timer, PLL2, and PLL1 enabled). Value 0x37 sets
VCO Selection = 11, which is reserved; with that value PLL2 autotune cannot
land on 3.072 GHz, the DAC REFCLK stays at 120 MHz, and every RF tone is scaled
by 15/16.

## Connections

Use two coherent outputs from the same reference source:

1. Reference OUT 1 -> 50 ohm coax/adaptor -> board XS17 (SSMC).
2. Reference OUT 2 -> 50 ohm coax -> oscilloscope 10 MHz REF IN.
3. Board RF output -> suitable attenuator/DC block -> 50 ohm scope channel.
4. Board XS18/TRIG_1 -> MMCX coax -> oscilloscope external trigger.

Start with a 10 MHz sine reference near 0 dBm at XS17. Confirm the exact
allowed level against the source, scope, and board specifications before
increasing it. Configure the scope to use its external 10 MHz reference and
verify that its reference-lock indicator is asserted.

TRIG_1 is a 2.5 V LVCMOS pulse generated when DAC sample-valid becomes active.
Use a high-impedance external-trigger input, rising-edge trigger, and an
initial threshold near 1.25 V. Do not terminate TRIG_1 in 50 ohms unless an
appropriate external buffer is used.

## Power-up And Programming

1. Enable both 10 MHz reference outputs and let the source stabilize.
2. Select the external 10 MHz timebase on the scope and verify lock.
3. Power the board, connect JTAG, and program the bitstream and ELF:

   ```bash
   make run
   ```

4. Check the UART log for HMC7044 sequence completion and normal RFDC PLL
   initialization. This target does not run DAC MTS.
5. Before changing any NCO or waveform frequency calculation, measure an
   accessible DAC REFCLK test point and confirm 128 MHz rather than 120 MHz.
6. Load and trigger 1 GHz, 4.5 GHz, and 5 GHz sine waveforms in turn. The scope
   should measure approximately the requested frequencies, within the reference
   source and scope accuracy, with no common 15/16 scale factor.
7. Verify the RF period, spectrum, and repeat-trigger stability using TRIG_1.

If the DAC REFCLK is still 120 MHz, stop frequency-algorithm changes and inspect
the physical HMC7044 SPI writes, reset polarity, external-reference level, and
PLL lock behavior.

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

Sharing the 10 MHz reference removes long-term frequency drift between the
board and the scope. TRIG_1 supplies a repeatable acquisition event. Residual
phase noise and timing uncertainty are still limited by the reference source,
the HMC7044/RFDC clock chain, cables, the analog RF path, and the scope itself.
