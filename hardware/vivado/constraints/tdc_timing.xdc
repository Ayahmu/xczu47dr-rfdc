# Only the asynchronous measurement entrance is excluded from ordinary STA.
# Calibration-source selection changes while unarmed; its transition is not
# synchronous payload to be delivered through the entire delay line in 5 ns.
# Capture-FF outputs, encoding, calibration RAM, scheduling and FIR remain timed.
set_false_path -through [get_pins -hier -filter {NAME == top_i/u_tdc_capture/carry_block[0].u_carry8/CI}] -to [get_pins -hier -filter {NAME =~ top_i/u_tdc_capture/sample_bit*.u_sample_ff/D}]

# Asynchronous assertion / synchronous release of the independent DNA reset.
# Only reset synchronizer CLR pins are exempt; the reader reset tree is timed.
set_false_path -to [get_pins -hier -filter {NAME =~ top_i/network_config_pl_i/dna_reset_sync_reg*/CLR}]

# The event FIFO read side releases reset on the DAC clock. Only the reset
# synchronizer's asynchronous clear pins are excluded; rd_valid stays timed.
set_false_path -to [get_pins -hier -filter {NAME =~ top_i/u_tdc_events/rd_reset_sync_reg*/CLR}]
