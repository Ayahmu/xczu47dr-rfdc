#!/bin/bash
# Firmware Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="$(dirname "${FIRMWARE_DIR}")"
TARGET="${TARGET:-zcu216}"
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
if [ -z "${WORKSPACE_RELATIVE}" ] || [ -z "${TARGET_OUTPUT_BASENAME}" ] || [ -z "${APP_NAME}" ] || [ -z "${ELF_RELATIVE}" ] || [ -z "${PSU_INIT_RELATIVE}" ]; then
    print_error "Unable to resolve target paths for TARGET=${TARGET}"
    exit 1
fi
WORKSPACE_DIR="${PROJECT_ROOT}/${WORKSPACE_RELATIVE}"
XSA_FILE="${PROJECT_ROOT}/hardware/vivado/output/${TARGET_OUTPUT_BASENAME}.xsa"
BIT_FILE="${PROJECT_ROOT}/hardware/vivado/output/${TARGET_OUTPUT_BASENAME}.bit"
ELF_FILE="${PROJECT_ROOT}/${ELF_RELATIVE}"
PSU_INIT_FILE="${PROJECT_ROOT}/${PSU_INIT_RELATIVE}"

case "${TARGET}" in
    zcu216)
        BOARD_DEFINE="BOARD_ZCU216"
        ;;
    custom_xczu47dr)
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
    print_info "BIT=${BIT_FILE}"
    print_info "ELF=${ELF_FILE}"
    print_info "PSU_INIT=${PSU_INIT_FILE}"
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
        print_info "Please build hardware first: cd ../hardware/vivado && ./build.sh xsa"
        exit 1
    fi
}

check_bit() {
    if [ ! -f "${BIT_FILE}" ]; then
        print_error "Bitstream file not found: ${BIT_FILE}"
        print_info "Please build hardware first: cd ../hardware/vivado && ./build.sh"
        exit 1
    fi
}

check_psu_init() {
    if [ ! -f "${PSU_INIT_FILE}" ]; then
        print_error "PS init script not found: ${PSU_INIT_FILE}"
        print_info "Please create the firmware platform first: $0 create"
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
        ;;

    build)
        print_info "Building application..."
        if [ ! -d "${WORKSPACE_DIR}/${APP_NAME}" ]; then
            print_error "Application not found. Run '$0 create' first."
            exit 1
        fi
        cd "${WORKSPACE_DIR}/${APP_NAME}/Debug"
        make clean
        make all
        print_info "Build complete: ${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf"
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
                print_info "Please build firmware first: $0 build"
                exit 1
            fi
        fi
        print_info "Programming FPGA and downloading ELF..."
        run_xsct "${SCRIPT_DIR}/scripts/program.tcl" "${BIT_FILE}" "${ELF_FILE}" "${PSU_INIT_FILE}"
        ;;

    clean)
        print_warn "Cleaning workspace..."
        rm -rf "${WORKSPACE_DIR}"
        print_info "Clean complete"
        ;;

    *)
        echo "Usage: $0 {create|build|rebuild|program|clean}"
        echo ""
        echo "Commands:"
        echo "  create   - Create Vitis application from XSA"
        echo "  build    - Build application (incremental)"
        echo "  rebuild  - Clean and rebuild from scratch"
        echo "  program  - Program FPGA and download ELF via JTAG"
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
