#!/bin/bash
# Vivado Build Automation Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
PROJECT_NAME="zcu216_rfdc"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Vivado is available
if ! command -v vivado &> /dev/null; then
    print_error "Vivado not found in PATH"
    print_info "Please source Vivado settings: source /tools/Xilinx/Vivado/2024.2/settings64.sh"
    exit 1
fi

case "$1" in
    create)
        print_info "Creating Vivado project..."
        vivado -mode batch -source "${SCRIPT_DIR}/build.tcl"
        ;;

    synth)
        print_info "Running synthesis..."
        vivado -mode batch -source "${SCRIPT_DIR}/run_synth.tcl"
        ;;

    impl)
        print_info "Running implementation..."
        vivado -mode batch -source "${SCRIPT_DIR}/run_impl.tcl"
        ;;

    bitstream)
        print_info "Generating bitstream..."
        vivado -mode batch -source "${SCRIPT_DIR}/run_bitstream.tcl"
        ;;

    xsa)
        print_info "Exporting XSA..."
        vivado -mode batch -source "${SCRIPT_DIR}/export_xsa.tcl"
        ;;

    all)
        print_info "Running complete build flow..."
        $0 create
        $0 synth
        $0 impl
        $0 bitstream
        $0 xsa
        print_info "Build complete!"
        ;;

    clean)
        print_warn "Cleaning work directory..."
        rm -rf "${WORK_DIR}"
        print_info "Clean complete"
        ;;

    gui)
        print_info "Opening Vivado GUI..."
        if [ -f "${WORK_DIR}/${PROJECT_NAME}.xpr" ]; then
            vivado "${WORK_DIR}/${PROJECT_NAME}.xpr" &
        else
            print_error "Project not found. Run '$0 create' first."
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 {create|synth|impl|bitstream|xsa|all|clean|gui}"
        echo ""
        echo "Commands:"
        echo "  create     - Create Vivado project from TCL scripts"
        echo "  synth      - Run synthesis"
        echo "  impl       - Run implementation"
        echo "  bitstream  - Generate bitstream"
        echo "  xsa        - Export hardware specification (XSA)"
        echo "  all        - Run complete build flow"
        echo "  clean      - Remove work directory"
        echo "  gui        - Open project in Vivado GUI"
        exit 1
        ;;
esac
