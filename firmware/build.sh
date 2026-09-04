#!/bin/bash
# Firmware Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="$(dirname "${FIRMWARE_DIR}")"
TARGET="${TARGET:-custom_xczu47dr_master}"
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
PSU_INIT_RELATIVE="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^psu_init:/ {print $2}')"
WORKSPACE_PSU_INIT_RELATIVE="$(printf '%s\n' "${TARGET_CONFIG}" | awk -F': ' '/^workspace_psu_init:/ {print $2}')"
if [ -z "${WORKSPACE_RELATIVE}" ] || [ -z "${TARGET_OUTPUT_BASENAME}" ] || [ -z "${APP_NAME}" ] || [ -z "${ELF_RELATIVE}" ] || [ -z "${PSU_INIT_RELATIVE}" ] || [ -z "${WORKSPACE_PSU_INIT_RELATIVE}" ]; then
    print_error "Unable to resolve target paths for TARGET=${TARGET}"
    exit 1
fi
WORKSPACE_DIR="${PROJECT_ROOT}/${WORKSPACE_RELATIVE}"
APP_SRC_DIR="${WORKSPACE_DIR}/${APP_NAME}/src"
ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_ROOT}/artifacts}"
XSA_FILE="${ARTIFACT_DIR}/${TARGET_OUTPUT_BASENAME}.xsa"
BIT_FILE="${ARTIFACT_DIR}/${TARGET_OUTPUT_BASENAME}.bit"
# The ELF and PS init script come from the target's own firmware_elf/psu_init
# keys, NOT from output_basename.  A variant target can have its own bitstream
# while sharing another target's firmware: custom_xczu47dr_slave_trigout differs
# from custom_xczu47dr_slave only in PL generics (XS20 as a second Trigger output),
# so it has its own .bit but reuses the slave's workspace, ELF and psu_init.
# Deriving these from output_basename pointed at custom_xczu47dr_slave_trigout.elf
# and ..._psu_init.tcl, which are never produced.  Only the basename is taken so
# an ARTIFACT_DIR override still works.
ELF_FILE="${ARTIFACT_DIR}/$(basename "${ELF_RELATIVE}")"
PSU_INIT_FILE="${ARTIFACT_DIR}/$(basename "${PSU_INIT_RELATIVE}")"
WORKSPACE_PSU_INIT_FILE="${PROJECT_ROOT}/${WORKSPACE_PSU_INIT_RELATIVE}"

case "${TARGET}" in
    custom_xczu47dr_master|custom_xczu47dr_slave|custom_xczu47dr_slave_trigout)
        BOARD_DEFINE="BOARD_CUSTOM_XCZU47DR"
        ;;
    custom_xczu47dr_bw)
        BOARD_DEFINE="BOARD_CUSTOM_XCZU47DR_BW"
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
    print_info "BIT=${BIT_FILE}"
    print_info "ELF=${ELF_FILE}"
	print_info "PSU_INIT=${PSU_INIT_FILE}"
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

publish_firmware_artifacts() {
	install_artifact "${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf" "${ELF_FILE}"
	install_artifact "${WORKSPACE_PSU_INIT_FILE}" "${PSU_INIT_FILE}"
	print_info "Published ELF: ${ELF_FILE}"
	print_info "Published PS init: ${PSU_INIT_FILE}"
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

# Check if XSA exists
check_xsa() {
    if [ ! -f "${XSA_FILE}" ]; then
        print_error "XSA file not found: ${XSA_FILE}"
        print_info "Please build hardware first: make xsa TARGET=${TARGET}"
        exit 1
    fi
}

check_bit() {
    if [ ! -f "${BIT_FILE}" ]; then
        print_error "Bitstream file not found: ${BIT_FILE}"
        print_info "Please build hardware first: make bitstream TARGET=${TARGET}"
        exit 1
    fi
}

check_psu_init() {
    if [ ! -f "${PSU_INIT_FILE}" ]; then
        print_error "PS init script not found: ${PSU_INIT_FILE}"
        print_info "Please run 'make firmware-create TARGET=${TARGET}' or restore the checked-in artifacts/ files"
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
		if [ "${DRY_RUN}" != "1" ]; then
			install_artifact "${WORKSPACE_PSU_INIT_FILE}" "${PSU_INIT_FILE}"
		fi
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
            check_bit
            check_psu_init
            if [ ! -f "${ELF_FILE}" ]; then
                print_error "ELF file not found: ${ELF_FILE}"
                print_info "Run '$0 create' and '$0 build' to rebuild firmware, or restore the checked-in artifacts directory."
                exit 1
            fi
        fi
        print_info "Programming FPGA and downloading ELF..."
        run_xsct "${SCRIPT_DIR}/scripts/program.tcl" "${BIT_FILE}" "${ELF_FILE}" "${PSU_INIT_FILE}"
        ;;

    download)
        if [ "${DRY_RUN}" = "1" ]; then
            run_dry_run
            print_target_paths
        else
            check_bit
            if [ ! -f "${ELF_FILE}" ]; then
                print_error "ELF file not found: ${ELF_FILE}"
                exit 1
            fi
        fi
        print_info "Downloading ELF only; the FPGA bitstream will not be reprogrammed"
        DOWNLOAD_ELF_ONLY=1 run_xsct "${SCRIPT_DIR}/scripts/program.tcl" "${BIT_FILE}" "${ELF_FILE}" "${PSU_INIT_FILE}"
        ;;

    clean)
        print_warn "Cleaning workspace..."
        rm -rf "${WORKSPACE_DIR}"
        print_info "Clean complete"
        ;;

    *)
        echo "Usage: $0 {create|build|rebuild|program|download|clean}"
        echo ""
        echo "Commands:"
        echo "  create   - Create Vitis application from XSA"
        echo "  build    - Build application (incremental)"
        echo "  rebuild  - Clean and rebuild from scratch"
        echo "  program  - Program FPGA and download ELF via JTAG"
        echo "  download - Download ELF only; preserve the programmed FPGA bitstream"
        echo "  clean    - Remove workspace"
        echo ""
        echo "Set DRY_RUN=1 to print resolved target paths and XSCT commands without requiring artifacts."
        echo ""
        echo "Typical workflow:"
        echo "  1. $0 create   # First time setup"
        echo "  2. $0 build    # After source code changes"
        echo "  3. $0 program  # Deploy to hardware"
        exit 1
        ;;
esac
