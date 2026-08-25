# Checked-In Programming Artifacts

This directory is the single source of files used by `make program`. A clone
does not need a Vivado project, synthesis/implementation run, or Vitis workspace
to program a board.

The formal 10 MHz release uses XS17 = 10 MHz and the HMC7044 DAC reference plan
of 128 MHz. Master and slave files must always be used as matching role groups:

```text
custom_xczu47dr_master.bit
custom_xczu47dr_master.xsa
custom_xczu47dr_master.elf
custom_xczu47dr_master_psu_init.tcl

custom_xczu47dr_slave.bit
custom_xczu47dr_slave.xsa
custom_xczu47dr_slave.elf
custom_xczu47dr_slave_psu_init.tcl

Verify the checked-in bytes with:

```bash
(cd artifacts && sha256sum -c SHA256SUMS)
```
```

The master bitstream drives XS20 as an output. The slave bitstream receives XS20
as an input. Never mix a master file with a slave file.

## Clone and Program

```bash
source /tools/Xilinx/Vitis/2024.2/settings64.sh
make program
```

The default target is `custom_xczu47dr_master`. For a slave board:

```bash
JTAG_CABLE_SERIAL=<serial> TARGET=custom_xczu47dr_slave make program
```

`make program` only checks and uses the four role-matched programming files. It
does not create a Vitis workspace or rebuild the firmware.

## Updating the Artifacts

After a hardware or firmware change, the normal commands write new files to this
same directory and atomically replace the old role-matched files:

```bash
make bitstream-dual
make xsa-master xsa-slave
make firmware TARGET=custom_xczu47dr_master
make firmware TARGET=custom_xczu47dr_slave
make artifacts TARGET=custom_xczu47dr_master
make artifacts TARGET=custom_xczu47dr_slave
```

Vivado work trees, reports, and Vitis workspaces remain generated and ignored.
`make artifacts-clean TARGET=...` is the explicit command for removing one
role's local programming files; normal `make clean` does not remove them.

The checked-in artifacts must be refreshed in the same commit as the RTL,
constraints, or firmware change that produced them. The 250 MHz XS17 variant is
kept on its separate branch and uses the same `artifacts/` paths there; it must
not be mixed into the 10 MHz main branch.
