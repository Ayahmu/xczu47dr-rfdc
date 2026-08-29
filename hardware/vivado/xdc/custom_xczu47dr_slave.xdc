# Slave-only role constraints for the custom XCZU47DR synchronization link.

# XS18/XS19/XS20 are constrained in custom_xczu47dr_minimal.xdc. The slave
# receives standalone SYNC on XS20 and Trigger on XS19.

# XS20 is forwarded combinationally from the pad to HMC7044 SYNC.  Bound that
# passthrough so the FPGA contribution is short, fixed, and repeatable; the
# reference retime inside HMC7044 then absorbs it without a cycle ambiguity.
set_max_delay -datapath_only -from [get_ports TRIG_3] -to [get_ports H7044_SYNC_0] 15.000

# Hold the slave SYNC input low when XS20 is not externally driven, keeping
# HMC7044 SYNC quiet during configuration and standalone/bypass operation.
set_property PULLDOWN true [get_ports TRIG_3]
