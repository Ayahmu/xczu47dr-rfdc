# Restore the reference bitstream-capable XXV Ethernet DCP for custom XCZU47DR.
# Vivado can regenerate this IP as Design_Linking-only, which later blocks write_bitstream.
proc restore_reference_xxv_dcp {vivado_dir target} {
    if {$target ne "custom_xczu47dr"} {
        return
    }

    set ref_dcp [file normalize "${vivado_dir}/../../../fpga_rfsoc_zjdx_20260503_jiaofu/test/test.gen/sources_1/ip/xxv_ethernet/xxv_ethernet.dcp"]
    set local_dcp [file normalize "${vivado_dir}/../../test.gen/sources_1/ip/xxv_ethernet_1/xxv_ethernet.dcp"]

    if {![file exists ${ref_dcp}]} {
        puts "ERROR: Reference XXV Ethernet DCP not found: ${ref_dcp}"
        exit 1
    }

    file mkdir [file dirname ${local_dcp}]
    file copy -force ${ref_dcp} ${local_dcp}
    puts "INFO: Restored reference XXV Ethernet DCP: ${local_dcp}"
}
