# Build identity helpers shared by the Vivado project, implementation, and
# XSA export stages.  A manifest is deliberately kept in the generated
# project and embedded in the production XSA so an old checkpoint cannot be
# mistaken for the current source tree.

proc rf2_identity_repo_root {script_path} {
    return [file normalize [file join $script_path "../../.."]]
}

proc rf2_identity_source_commit {script_path} {
    set repo_root [rf2_identity_repo_root $script_path]
    if {[catch {exec git -C ${repo_root} rev-parse --verify HEAD} git_head] != 0} {
        return "00000000"
    }
    return [string tolower [string range [string trim ${git_head}] 0 7]]
}

proc rf2_identity_profile_id {target} {
    if {$target eq "custom_xczu47dr_bw"} {
        return 3
    }
    return 1
}

proc rf2_identity_write_manifest {manifest_file target source_commit build_profile_id trigger_path_version ila_enabled} {
    set parent [file dirname ${manifest_file}]
    file mkdir ${parent}
    set fd [open ${manifest_file} w]
    puts ${fd} [format {{"target":"%s","protocol_version":3,"build_profile_id":%d,"trigger_path_version":%d,"source_commit":"%s","ila_enabled":%d}} \
        ${target} ${build_profile_id} ${trigger_path_version} ${source_commit} ${ila_enabled}]
    close ${fd}
}

proc rf2_identity_manifest_value {manifest key} {
    set quoted_pattern [format {"%s"[[:space:]]*:[[:space:]]*"([^"]*)"} ${key}]
    if {[regexp ${quoted_pattern} ${manifest} -> value]} {
        return ${value}
    }
    set numeric_pattern [format {"%s"[[:space:]]*:[[:space:]]*(-?[0-9]+)} ${key}]
    if {[regexp ${numeric_pattern} ${manifest} -> value]} {
        return ${value}
    }
    return ""
}

proc rf2_identity_read_manifest {manifest_file} {
    if {![file exists ${manifest_file}]} {
        error "missing build manifest: ${manifest_file}"
    }
    set fd [open ${manifest_file} r]
    set manifest [read ${fd}]
    close ${fd}
    return ${manifest}
}

proc rf2_identity_validate_manifest {manifest_file target script_path} {
    set manifest [rf2_identity_read_manifest ${manifest_file}]
    set expected_source [rf2_identity_source_commit ${script_path}]
    set actual_target [rf2_identity_manifest_value ${manifest} target]
    set actual_protocol [rf2_identity_manifest_value ${manifest} protocol_version]
    set actual_profile [rf2_identity_manifest_value ${manifest} build_profile_id]
    set actual_trigger [rf2_identity_manifest_value ${manifest} trigger_path_version]
    set actual_source [string tolower [rf2_identity_manifest_value ${manifest} source_commit]]
    if {$actual_target ne ${target} || $actual_protocol ne "3" ||
        $actual_profile ne [rf2_identity_profile_id ${target}] ||
        $actual_trigger ne "3" || $actual_source ne ${expected_source}} {
        error "build identity mismatch in ${manifest_file}: target=${actual_target}, protocol=${actual_protocol}, profile=${actual_profile}, trigger=${actual_trigger}, source=${actual_source}; expected target=${target}, protocol=3, profile=[rf2_identity_profile_id ${target}], trigger=3, source=${expected_source}"
    }
    return ${manifest}
}

proc rf2_identity_validate_project {manifest_file target script_path} {
    set manifest [rf2_identity_validate_manifest ${manifest_file} ${target} ${script_path}]
    set defines [get_property verilog_define [current_fileset]]
    set expected_profile "RF2_BUILD_PROFILE_ID=32'd[rf2_identity_profile_id ${target}]"
    set expected_trigger "RF2_TRIGGER_PATH_VERSION=32'd3"
    set expected_source "RF2_SOURCE_COMMIT_ID=32'h[rf2_identity_source_commit ${script_path}]"
    foreach expected [list ${expected_profile} ${expected_trigger} ${expected_source}] {
        if {[lsearch -exact ${defines} ${expected}] < 0} {
            error "project Verilog defines do not match build manifest: missing ${expected}"
        }
    }
    return ${manifest}
}

proc rf2_identity_stamp {artifact manifest_file} {
    if {![file exists ${artifact}]} {
        error "cannot stamp missing artifact: ${artifact}"
    }
    file copy -force ${manifest_file} "${artifact}.manifest.json"
}

proc rf2_identity_embed_manifest {xsa_file manifest_file} {
    if {![file exists ${xsa_file}]} {
        error "cannot embed identity into missing XSA: ${xsa_file}"
    }
    if {[auto_execok zip] eq ""} {
        error "zip utility is required to embed build_manifest.json in ${xsa_file}"
    }
    if {[catch {exec zip -q -j -u ${xsa_file} ${manifest_file}} err]} {
        error "failed to embed build manifest in ${xsa_file}: ${err}"
    }
}

proc rf2_identity_verify_xsa_bit {xsa_file bit_file} {
    set members [list]
    foreach member [split [exec unzip -Z1 ${xsa_file}] "\n"] {
        if {[string match "*.tmp.bit" [string trim ${member}]]} {
            lappend members [string trim ${member}]
        }
    }
    if {[llength ${members}] != 1} {
        error "XSA must contain exactly one *.tmp.bit (found [llength ${members}])"
    }
    set extracted [file join [file dirname ${xsa_file}] ".verify_bit_[pid].bit"]
    set out [open ${extracted} w]
    fconfigure ${out} -translation binary
    puts -nonewline ${out} [exec unzip -p ${xsa_file} [lindex ${members} 0]]
    close ${out}
    set expected_hash [string trim [lindex [split [exec sha256sum ${bit_file}] "\n"] 0]]
    set actual_hash [string trim [lindex [split [exec sha256sum ${extracted}] "\n"] 0]]
    file delete -force ${extracted}
    if {[lindex [split ${expected_hash}] 0] ne [lindex [split ${actual_hash}] 0]} {
        error "XSA embedded bitstream does not match the identity-checked implementation bitstream"
    }
}
