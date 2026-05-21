# Vivado part validation for target matrix entries

set script_path [file dirname [file normalize [info script]]]
source "${script_path}/target_config.tcl"

set target custom_xczu47dr
if {[llength $argv] > 0} {
    set target [lindex $argv 0]
}

if {![target_config_exists $target]} {
    puts "ERROR: Unsupported TARGET=${target}. Allowed targets: [join [target_config_allowed_targets] {, }]"
    exit 1
}

set configured_part [target_config_get $target part]
set part_query [target_config_get $target part_query]

puts "INFO: Validating TARGET=${target}"
puts "INFO: Configured part: ${configured_part}"
puts "INFO: Part query: ${part_query}"

set candidates [get_parts ${part_query}]
if {[llength $candidates] == 0} {
    puts "\[DECISION NEEDED: Vivado get_parts returned no XCZU47DR FFVG1517 candidates for TARGET=${target}\]"
    exit 2
}

puts "PASS: Vivado returned [llength $candidates] candidate part(s) for TARGET=${target}"
foreach candidate $candidates {
    puts "INFO: Candidate part: ${candidate}"
}

if {$configured_part ne ""} {
    set exact_part [get_parts -quiet ${configured_part}]
    if {[llength $exact_part] == 0} {
        puts "ERROR: Configured part ${configured_part} is not available in this Vivado installation"
        exit 1
    }
    puts "PASS: Configured part ${configured_part} is available"
} else {
    puts "\[DECISION NEEDED: Select exact Vivado part spelling from candidates before using TARGET=${target} for project creation\]"
}
