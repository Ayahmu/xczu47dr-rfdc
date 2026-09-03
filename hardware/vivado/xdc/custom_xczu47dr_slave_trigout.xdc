# Bench-measurement slave variant: XS20/TRIG_3 is a second Trigger OUTPUT that
# mirrors XS18, instead of the SYNC input.
#
# Cabling this build expects on a single board:
#   XS17 -> reference clock in
#   XS18 -> XS19   (the board triggers itself)
#   XS20 -> scope  (Trigger time reference for the latency measurement)
#   CH1  -> scope  (50 ohm terminated)
#
# There is no SYNC input in this build, so it only works in bypass mode.  Top.v
# also forces sync_in low when XS20_TRIG_OUT=1, so the pulse we drive here can
# never reach HMC7044 SYNC and reseed its output dividers.
#
# Pin and IOSTANDARD for TRIG_3 come from custom_xczu47dr_minimal.xdc, which
# also carries "set_false_path -to [get_ports TRIG_3]" for this output.

# Deliberately NOT set here, unlike custom_xczu47dr_slave.xdc:
#   - no PULLDOWN: the pin is actively driven, a pulldown would only fight it
#   - no set_max_delay from TRIG_3 to H7044_SYNC_0: that path does not exist in
#     this build because sync_in is tied low

# The scope measures Trigger-to-RF delay off this edge, so give it the fastest
# edge the bank can produce and enough drive for a 50 ohm load.  Edge rate here
# is a direct term in the measurement's own uncertainty.
set_property SLEW FAST [get_ports TRIG_3]
set_property DRIVE 12 [get_ports TRIG_3]

# XS18 carries the same pulse into XS19; match its drive so the residual
# XS18/XS20 skew stays IO+PCB only and does not gain a slew-rate difference.
set_property SLEW FAST [get_ports TRIG_1]
set_property DRIVE 12 [get_ports TRIG_1]
