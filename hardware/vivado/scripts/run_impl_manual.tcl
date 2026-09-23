# Compatibility entry point retained for the established Makefile/build.sh
# command. Implementation is project-managed now: the XXV Ethernet XCI is
# carried into impl_1 and Vivado binds its OOC checkpoint with the IP
# provenance intact. No hand-injected read_checkpoint -cell is allowed here.
set script_path [file dirname [file normalize [info script]]]
source "${script_path}/run_impl.tcl"
