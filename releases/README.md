# Checked-In Hardware Releases

The repository keeps generated Vivado/Vitis workspaces out of Git, but checked-in
release bundles contain the files needed to program and run a board without
rerunning synthesis or implementation.

Each release is self-contained and includes, for both formal roles:

- `.bit`: FPGA configuration image;
- `.xsa`: role-matched hardware handoff, including the bitstream and PS init data;
- `.elf`: firmware built against that role's XSA;
- `*_psu_init.tcl`: JTAG programming initialization script;
- `SHA256SUMS`: integrity and role-matching record.

The `.xsa` files are intentionally published. They are not required to configure
an already-built FPGA, but they are required to reproduce a matching Vitis
platform/firmware build without rerunning Vivado synthesis and implementation.
The XSA also carries the embedded bitstream and PS hardware metadata.

## Release Workflow

After changing RTL, constraints, clock policy, or firmware:

```bash
make bitstream-dual
make xsa-master xsa-slave
make firmware TARGET=custom_xczu47dr_master
make firmware TARGET=custom_xczu47dr_slave
make release-dual RELEASE_NAME=10mhz-YYYYMMDD
(cd releases/10mhz-YYYYMMDD && sha256sum -c SHA256SUMS)
git add releases/10mhz-YYYYMMDD
git commit -m "release: publish 10 MHz master and slave artifacts"
git push origin main
```

`release-dual` only packages existing outputs; it does not silently start a
Vivado or Vitis build. The generated `hardware/vivado/output/`, Vivado project
trees, reports, and Vitis workspaces remain ignored. Do not add those directories
with `git add -f`.

Program from a clone using the role-matched trio, for example:

```bash
xsct firmware/scripts/program.tcl \
  releases/10mhz-YYYYMMDD/custom_xczu47dr_master.bit \
  releases/10mhz-YYYYMMDD/custom_xczu47dr_master.elf \
  releases/10mhz-YYYYMMDD/custom_xczu47dr_master_psu_init.tcl
```

Never mix a master `.bit`/`.xsa`/`.elf` with a slave file. The 250 MHz XS17
variant must be published in a separately named release directory and branch;
it must not overwrite the 10 MHz artifacts.
