# TDC 约束

构建通过 `hardware/vivado/scripts/target_config.tcl` 加载 `tdc_placement.xdc` 和
`tdc_timing.xdc`。`tdc_placement.xdc` 是交付设计里 2048 抽头延迟链的布局约束，由
`hardware/vivado/scripts/generate_tdc_capture_xdc.py` 生成，不要手工修改；有一项测试检查
两者保持一致。
