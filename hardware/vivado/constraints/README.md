# TDC Constraints

The active custom XCZU47DR builds load `tdc_placement.xdc` and `tdc_timing.xdc`
through `hardware/vivado/scripts/target_config.tcl`. `tdc_placement.xdc` is the
2048-tap placement generated for the delivered design.

`tdc_capture_placement.xdc` is retained as an early placement experiment for
the original 1024-tap capture window. It is not loaded by any current target
and must not be used for the delivered bitstream.
