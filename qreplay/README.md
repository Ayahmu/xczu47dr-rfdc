# QReplay bench build

Branch `qreplay-dac2027` holds the board changes that only the QReplay
replay-HIL experiments (DAC 2027 paper) need.  General fixes go to
`100g-migration` in the main repository and are merged in from there.

On top of `100g-migration`:

- XS18 marker held for 1 us (`marker_pulse_stretcher.v`, 50 cycles of the
  50 MHz DAC fabric clock) so it can start the ZCU216 readout through a
  level shifter and a cable (XS18 -> ZCU216 PMOD1_0).
- `artifacts/10mhz/`: the image used on the bench, built with
  `make hardware-10mhz` (HMC7044 locked to a 10 MHz reference on XS17,
  shared with ZCU216 J11).  Built from this RTL, with the CMAC equalization
  of `15ab5fc`; the firmware reports source commit 0x318ec38d because the
  hardware RTL is unchanged since 318ec38.  Timing WNS +0.002 ns,
  WHS +0.010 ns.  Rebuild with `qreplay/build_10mhz.sh`.

Load into RAM only (QSPI is not written; a power cycle brings the QSPI
image back):

    JTAG_CABLE_SERIAL=<cable> ARTIFACT_DIR=$PWD/artifacts/10mhz make program

The host-side experiment code lives in `../qreplay` (see its BENCH.md) and
must run against this branch's `software/` (dr47 0.4.0).
