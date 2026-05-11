# build_project.tcl

# 1. 设置工程名和路径
set script_path [file dirname [file normalize [info script]]]
set proj_dir [file dirname $script_path]
set proj_name "zcu216_loopback"

# 2. 创建工程 (在根目录下创建 work 文件夹存放 Vivado 临时文件)
create_project -force $proj_name ${proj_dir}/work -part xczu49dr-ffvf1760-2-e

# 3. 设置 Board
#    ZCU216 的 Board Part 名称
set_property board_part xilinx.com:zcu216:part0:2.0 [current_project]

# 4. 添加源文件
if {[glob -nocomplain ${proj_dir}/src/*.v] != ""} {
    add_files ${proj_dir}/src/
}
if {[glob -nocomplain ${proj_dir}/src/*.sv] != ""} {
    add_files ${proj_dir}/src/
}

# 5. 添加约束文件
if {[glob -nocomplain ${proj_dir}/xdc/*.xdc] != ""} {
    add_files -fileset constrs_1 ${proj_dir}/xdc/
}

# 6. 重建 Block Design
source ${proj_dir}/bd/design_1.tcl
source ${proj_dir}/scripts/axis_data_fifo_1.tcl
source ${proj_dir}/scripts/axi_datamover_0.tcl
source ${proj_dir}/scripts/axis_async_fifo_128.tcl

# 7. 生成 Wrapper (顶层文件)
make_wrapper -files [get_files *design_1.bd] -top
add_files -norecurse ${proj_dir}/work/${proj_name}.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "The project reconstruction is complete! The new project is located in the work/ directory."