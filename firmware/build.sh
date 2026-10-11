#!/bin/bash
# Firmware Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="$(dirname "${FIRMWARE_DIR}")"
TARGET="${TARGET:-custom_xczu47dr_waveform}"
SRC_DIR="${FIRMWARE_DIR}/src"
DRY_RUN="${DRY_RUN:-0}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

TARGET_CONFIG="$(cd "${PROJECT_ROOT}/hardware/vivado/scripts" && tclsh target_config.tcl "${TARGET}")"
WORKSPACE_RELATIVE="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^firmware_workspace:/ {print $2}')"
TARGET_OUTPUT_BASENAME="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^output_basename:/ {print $2}')"
APP_NAME="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^firmware_app:/ {print $2}')"
ELF_RELATIVE="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^firmware_elf:/ {print $2}')"
if [ -z "${WORKSPACE_RELATIVE}" ] || [ -z "${TARGET_OUTPUT_BASENAME}" ] || [ -z "${APP_NAME}" ] || [ -z "${ELF_RELATIVE}" ]; then
    print_error "Unable to resolve target paths for TARGET=${TARGET}"
    exit 1
fi
WORKSPACE_DIR="${PROJECT_ROOT}/${WORKSPACE_RELATIVE}"
APP_SRC_DIR="${WORKSPACE_DIR}/${APP_NAME}/src"
ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_ROOT}/artifacts}"
XSA_FILE="${ARTIFACT_DIR}/${TARGET_OUTPUT_BASENAME}.xsa"
# The ELF path is taken from the target configuration so role-specific output
# names remain explicit while the XSA supplies the FPGA image and PS init data.
ELF_FILE="${ARTIFACT_DIR}/$(basename "${ELF_RELATIVE}")"
# Standalone boot: BOOT.BIN (FSBL + PMU firmware + bitstream + application) in
# the QSPI flash.  The FSBL and PMU firmware are the ones Vitis generates for
# the platform; the FSBL is published as well because program_flash needs it
# to bring the PS up before it can reach the flash.
BOOT_BIN_FILE="${ARTIFACT_DIR}/BOOT.BIN"
FSBL_FILE="${ARTIFACT_DIR}/${TARGET_OUTPUT_BASENAME}_fsbl.elf"
WORKSPACE_FSBL="${WORKSPACE_DIR}/hw_platform/zynqmp_fsbl/fsbl_a53.elf"
WORKSPACE_PMUFW="${WORKSPACE_DIR}/hw_platform/zynqmp_pmufw/pmufw.elf"
WORKSPACE_XSA="${WORKSPACE_DIR}/hw_platform/hw/${TARGET_OUTPUT_BASENAME}.xsa"
# The board carries two N25Q512A (512 Mbit each) in dual-parallel mode: 128 MiB.
QSPI_FLASH_TYPE="${QSPI_FLASH_TYPE:-qspi-x8-dual_parallel}"
QSPI_FLASH_DENSITY="${QSPI_FLASH_DENSITY:-512}"
HW_SERVER_URL="${HW_SERVER_URL:-tcp:localhost:3121}"

case "${TARGET}" in
    custom_xczu47dr_waveform)
        BOARD_DEFINE="BOARD_CUSTOM_XCZU47DR"
        ;;
    *)
        print_error "Unsupported TARGET=${TARGET} for firmware board define selection"
        exit 1
        ;;
esac

run_dry_run() {
    print_info "DRY_RUN=1; no XSCT, file existence, build, clean, or JTAG actions will be performed"
}

print_target_paths() {
    print_info "TARGET=${TARGET}"
    print_info "XSA=${XSA_FILE}"
    print_info "WORKSPACE=${WORKSPACE_DIR}"
    print_info "APP=${APP_NAME}"
    print_info "BOARD_DEFINE=-D${BOARD_DEFINE}"
    print_info "ELF=${ELF_FILE}"
}

print_boot_paths() {
    print_target_paths
    print_info "BOOT_BIN=${BOOT_BIN_FILE}"
    print_info "FSBL_OUT=${FSBL_FILE}"
}

install_artifact() {
	local source_file="$1"
	local destination_file="$2"
	if [ ! -f "${source_file}" ]; then
		print_error "Build artifact not found: ${source_file}"
		exit 1
	fi
	mkdir -p "$(dirname "${destination_file}")"
	local temporary_file="${destination_file}.tmp.$$"
	cp "${source_file}" "${temporary_file}"
	mv -f "${temporary_file}" "${destination_file}"
}

# Published ELF files carry no symbols and no debug sections: those name every
# source file and the directory the build ran in.  The unstripped files stay in
# the Vitis workspace for debugging.
install_stripped_elf() {
	local source_file="$1"
	local destination_file="$2"
	if [ ! -f "${source_file}" ]; then
		print_error "Build artifact not found: ${source_file}"
		exit 1
	fi
	if ! command -v aarch64-none-elf-strip &> /dev/null; then
		print_error "aarch64-none-elf-strip not found in PATH"
		print_info "Please source Vitis settings: source /tools/Xilinx/Vitis/2024.2/settings64.sh"
		exit 1
	fi
	mkdir -p "$(dirname "${destination_file}")"
	local temporary_file="${destination_file}.tmp.$$"
	aarch64-none-elf-strip --strip-all -o "${temporary_file}" "${source_file}"
	mv -f "${temporary_file}" "${destination_file}"
}

publish_firmware_artifacts() {
	install_stripped_elf "${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf" "${ELF_FILE}"
	print_info "Published ELF (stripped): ${ELF_FILE}"
	print_info "Unstripped ELF for debugging: ${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf"
}

sync_app_sources() {
    if [ "${DRY_RUN}" = "1" ]; then
        print_info "Source sync: ${SRC_DIR}/ -> ${APP_SRC_DIR}/"
        return 0
    fi
    if [ ! -d "${APP_SRC_DIR}" ]; then
        print_error "Application source directory not found. Run '$0 create' first."
        exit 1
    fi
    if command -v rsync &> /dev/null; then
        rsync -a "${SRC_DIR}/" "${APP_SRC_DIR}/"
    else
        cp -a "${SRC_DIR}/." "${APP_SRC_DIR}/"
    fi

}

build_app() {
    print_info "Building application..."
    if [ ! -d "${WORKSPACE_DIR}/${APP_NAME}" ]; then
        print_error "Application not found. Run '$0 create' first."
        exit 1
    fi
    sync_app_sources
	cd "${WORKSPACE_DIR}/${APP_NAME}/Debug"
	make clean
	make all
	publish_firmware_artifacts
	print_info "Build complete: ${ELF_FILE}"
}

run_xsct() {
    if [ "${DRY_RUN}" = "1" ]; then
        print_info "XSCT command: xsct $*"
        return 0
    fi

    if ! command -v xsct &> /dev/null; then
        print_error "XSCT not found in PATH"
        print_info "Please source Vitis settings: source /tools/Xilinx/Vitis/2024.2/settings64.sh"
        exit 1
    fi

    xsct "$@"
}

# Boot order: the BootROM loads the FSBL and the PMU firmware, the FSBL
# configures the PL and then hands over to the application at EL3.
write_boot_bif() {
    cat <<BIF
the_ROM_image:
{
    [bootloader, destination_cpu=a53-0] ${WORKSPACE_FSBL}
    [pmufw_image] ${WORKSPACE_PMUFW}
    [destination_device=pl] $1
    [destination_cpu=a53-0, exception_level=el-3] ${ELF_FILE}
}
BIF
}

build_boot_bin() {
    check_xsa
    local required
    for required in "${ELF_FILE}" "${WORKSPACE_FSBL}" "${WORKSPACE_PMUFW}" "${WORKSPACE_XSA}"; do
        if [ ! -f "${required}" ]; then
            print_error "Not found: ${required}"
            print_info "Run 'make firmware' first; it builds the ELF, the FSBL and the PMU firmware."
            exit 1
        fi
    done
    # The FSBL carries the PS configuration of the XSA it was generated from.
    if ! cmp -s "${XSA_FILE}" "${WORKSPACE_XSA}"; then
        print_error "The Vitis workspace was created from another XSA than ${XSA_FILE}"
        print_info "Run 'make firmware' to regenerate the FSBL and the ELF for this XSA."
        exit 1
    fi
    if ! command -v bootgen &> /dev/null; then
        print_error "bootgen not found in PATH"
        print_info "Please source Vitis settings: source /tools/Xilinx/Vitis/2024.2/settings64.sh"
        exit 1
    fi
    local bit_member
    bit_member="$(unzip -Z1 "${XSA_FILE}" | grep '\.tmp\.bit$' || true)"
    if [ "$(printf '%s\n' "${bit_member}" | grep -c .)" != "1" ]; then
        print_error "XSA must contain exactly one *.tmp.bit"
        exit 1
    fi
    local work_dir="${ARTIFACT_DIR}/.bootbin_$$"
    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"
    # work_dir is local, so expand it here: the trap runs after this function.
    trap "rm -rf '${work_dir}'" EXIT
    unzip -o -q "${XSA_FILE}" "${bit_member}" -d "${work_dir}"
    write_boot_bif "${work_dir}/${bit_member}" > "${work_dir}/boot.bif"
    bootgen -arch zynqmp -image "${work_dir}/boot.bif" -o "${work_dir}/BOOT.BIN" -w on
    install_artifact "${work_dir}/BOOT.BIN" "${BOOT_BIN_FILE}"
    install_stripped_elf "${WORKSPACE_FSBL}" "${FSBL_FILE}"
    print_info "Published boot image: ${BOOT_BIN_FILE}"
    print_info "Published FSBL: ${FSBL_FILE}"
}

# program_flash addresses a board by the name of its arm_dap JTAG device.
resolve_flash_target() {
    local listing names
    if ! listing="$(program_flash -jtagtargets -url "${HW_SERVER_URL}" 2>&1)"; then
        print_error "program_flash could not list the JTAG targets"
        printf '%s\n' "${listing}"
        exit 1
    fi
    names="$(printf '%s\n' "${listing}" | awk '/name arm_dap/ {print $2}')"
    if [ -n "${JTAG_CABLE_SERIAL:-}" ]; then
        names="$(printf '%s\n' "${names}" | grep -- "-${JTAG_CABLE_SERIAL}-" || true)"
    fi
    if [ "$(printf '%s\n' "${names}" | grep -c .)" != "1" ]; then
        print_error "Expected exactly one board on JTAG (set JTAG_CABLE_SERIAL to choose one); found:"
        printf '%s\n' "${listing}"
        exit 1
    fi
    FLASH_TARGET_NAME="${names}"
}

flash_boot_bin() {
    local command=(program_flash -f "${BOOT_BIN_FILE}" -offset 0
                   -flash_type "${QSPI_FLASH_TYPE}" -flash_density "${QSPI_FLASH_DENSITY}"
                   -fsbl "${FSBL_FILE}" -verify -url "${HW_SERVER_URL}")
    if [ "${DRY_RUN}" = "1" ]; then
        print_info "Flash command: ${command[*]} -target_name <arm_dap of the selected cable>"
        return 0
    fi
    resolve_flash_target
    command+=(-target_name "${FLASH_TARGET_NAME}")
    print_info "Flash command: ${command[*]}"
    local log_file attempt status
    log_file="$(mktemp)"
    for attempt in 1 2 3; do
        set +e
        "${command[@]}" 2>&1 | tee "${log_file}"
        status=${PIPESTATUS[0]}
        set -e
        if [ "${status}" -eq 0 ] && grep -q "Flash Operation Successful" "${log_file}"; then
            break
        fi
        # program_flash starts its flash helper after a fixed wait and now and
        # then finds it not answering (about one start in ten on this board).
        # Nothing has been erased or written at that point, so the start can
        # be repeated.  A failure during erase, program or verify is final.
        if [ "${attempt}" -lt 3 ] && grep -q "Flash programming initialization failed" "${log_file}"; then
            print_warn "The flash tool could not start its helper (attempt ${attempt} of 3); trying again"
            continue
        fi
        rm -f "${log_file}"
        print_error "Writing the QSPI flash failed"
        exit 1
    done
    rm -f "${log_file}"
    print_info "QSPI flash written and verified: ${BOOT_BIN_FILE}"
}

# Check if XSA exists
check_xsa() {
    if [ ! -f "${XSA_FILE}" ]; then
        print_error "XSA file not found: ${XSA_FILE}"
        print_info "Please build hardware first: make xsa TARGET=${TARGET}"
        exit 1
    fi
}

case "$1" in
    create)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_target_paths
        else
            check_xsa
        fi
        print_info "Creating Vitis application for TARGET=${TARGET} with -D${BOARD_DEFINE}..."
        run_xsct "${SCRIPT_DIR}/scripts/create_app.tcl" "${XSA_FILE}" "${APP_NAME}" "${SRC_DIR}" "${WORKSPACE_DIR}" "${BOARD_DEFINE}"
        # psu_init.tcl is embedded in the XSA and is extracted by program.tcl.
        ;;

    build)
        build_app
        ;;

    rebuild)
        check_xsa
        print_info "Rebuilding application from scratch..."
        rm -rf "${WORKSPACE_DIR}"
        $0 create
        ;;

    program)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_target_paths
        else
            check_xsa
            if [ ! -f "${ELF_FILE}" ]; then
                print_error "ELF file not found: ${ELF_FILE}"
                print_info "Run '$0 create' and '$0 build' to rebuild firmware, or restore the checked-in artifacts directory."
                exit 1
            fi
        fi
        print_info "Programming FPGA and downloading ELF..."
        run_xsct "${SCRIPT_DIR}/scripts/program.tcl" "${XSA_FILE}" "${ELF_FILE}"
        ;;

    download)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_target_paths
        else
            check_xsa
            if [ ! -f "${ELF_FILE}" ]; then
                print_error "ELF file not found: ${ELF_FILE}"
                exit 1
            fi
        fi
        print_info "Downloading ELF only; the FPGA bitstream will not be reprogrammed"
        DOWNLOAD_ELF_ONLY=1 run_xsct "${SCRIPT_DIR}/scripts/program.tcl" "${XSA_FILE}" "${ELF_FILE}"
        ;;

    bootbin)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_boot_paths
            print_info "Boot image description:"
            write_boot_bif "<bitstream embedded in the XSA>"
        else
            print_info "Building BOOT.BIN for TARGET=${TARGET}..."
            build_boot_bin
        fi
        ;;

    flash)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_boot_paths
        else
            for required in "${BOOT_BIN_FILE}" "${FSBL_FILE}"; do
                if [ ! -f "${required}" ]; then
                    print_error "Not found: ${required}"
                    print_info "Run '$0 bootbin' (after 'make firmware'), or restore the checked-in artifacts directory."
                    exit 1
                fi
            done
            if ! command -v program_flash &> /dev/null; then
                print_error "program_flash not found in PATH"
                print_info "Please source Vitis settings: source /tools/Xilinx/Vitis/2024.2/settings64.sh"
                exit 1
            fi
        fi
        print_info "Writing BOOT.BIN to the QSPI flash (${QSPI_FLASH_TYPE}, ${QSPI_FLASH_DENSITY} Mbit per device)..."
        # An image already in the flash must not be running while it is replaced.
        run_xsct "${SCRIPT_DIR}/scripts/boot_mode.tcl" jtag
        flash_boot_bin
        ;;

    boot-qspi)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
        fi
        print_info "Restarting the board from the QSPI flash; the mode pins are not changed"
        run_xsct "${SCRIPT_DIR}/scripts/boot_mode.tcl" qspi
        ;;

    clean)
        print_warn "Cleaning workspace..."
        rm -rf "${WORKSPACE_DIR}"
        print_info "Clean complete"
        ;;

    *)
        echo "Usage: $0 {create|build|rebuild|program|download|bootbin|flash|boot-qspi|clean}"
        echo ""
        echo "Commands:"
        echo "  create   - Create Vitis application from XSA"
        echo "  build    - Build application (incremental)"
        echo "  rebuild  - Clean and rebuild from scratch"
        echo "  program  - Program FPGA and download ELF via JTAG"
        echo "  download - Download ELF only; preserve the programmed FPGA bitstream"
        echo "  bootbin  - Pack FSBL, PMU firmware, bitstream and ELF into BOOT.BIN"
        echo "  flash    - Write BOOT.BIN to the QSPI flash via JTAG and verify it"
        echo "  boot-qspi - Restart the board from the QSPI flash without moving the mode pins"
        echo "  clean    - Remove workspace"
        echo ""
        echo "Set DRY_RUN=1 to print resolved target paths and XSCT commands without requiring artifacts."
        echo ""
        echo "Typical workflow:"
        echo "  1. $0 create   # First time setup"
        echo "  2. $0 build    # After source code changes"
        echo "  3. $0 program  # Deploy to hardware (volatile, over JTAG)"
        echo "  4. $0 bootbin && $0 flash   # Make the board boot by itself"
        exit 1
        ;;
esac
