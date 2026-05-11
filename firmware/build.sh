#!/bin/bash
# Firmware Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}"
PROJECT_ROOT="$(dirname "${FIRMWARE_DIR}")"
WORKSPACE_DIR="${FIRMWARE_DIR}/workspace"
SRC_DIR="${FIRMWARE_DIR}/src"
XSA_FILE="${PROJECT_ROOT}/hardware/vivado/output/zcu216_rfdc.xsa"
APP_NAME="rfdc_app"

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

# Check if Vitis is available
if ! command -v xsct &> /dev/null; then
    print_error "XSCT not found in PATH"
    print_info "Please source Vitis settings: source /tools/Xilinx/Vitis/2024.2/settings64.sh"
    exit 1
fi

# Check if XSA exists
check_xsa() {
    if [ ! -f "${XSA_FILE}" ]; then
        print_error "XSA file not found: ${XSA_FILE}"
        print_info "Please build hardware first: cd ../hardware/vivado && ./build.sh xsa"
        exit 1
    fi
}

case "$1" in
    create)
        check_xsa
        print_info "Creating Vitis application..."
        xsct "${SCRIPT_DIR}/scripts/create_app.tcl" "${XSA_FILE}" "${APP_NAME}" "${SRC_DIR}"
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
        check_xsa
        ELF_FILE="${WORKSPACE_DIR}/${APP_NAME}/Debug/${APP_NAME}.elf"
        if [ ! -f "${ELF_FILE}" ]; then
            print_error "ELF file not found: ${ELF_FILE}"
            print_info "Please build firmware first: $0 build"
            exit 1
        fi
        print_info "Programming FPGA and downloading ELF..."
        xsct "${SCRIPT_DIR}/scripts/program.tcl" "${XSA_FILE}" "${ELF_FILE}"
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
        echo "Typical workflow:"
        echo "  1. $0 create   # First time setup"
        echo "  2. $0 build    # After source code changes"
        echo "  3. $0 program  # Deploy to hardware"
        exit 1
        ;;
esac
