# Shared build-time knobs for Vivado scripts.

proc build_option_get {name default_value} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_value
}
