#!/bin/bash
# Chisel Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/generated"

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

# Check if Mill is available
if ! command -v mill &> /dev/null; then
    print_error "Mill not found in PATH"
    print_info "Please install Mill: https://mill-build.com/mill/Intro_to_Mill.html"
    exit 1
fi

# Check Mill version
REQUIRED_VERSION=$(cat .mill-version)
print_info "Required Mill version: ${REQUIRED_VERSION}"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

case "$1" in
    led)
        print_info "Generating LED module..."
        mill chisel.runMain led.LedTop
        print_info "LED Verilog generated in ${OUTPUT_DIR}"
        ;;

    gpio)
        print_info "Generating GPIO module..."
        mill chisel.runMain gpio.GPIOTop
        print_info "GPIO Verilog generated in ${OUTPUT_DIR}"
        ;;

    all)
        print_info "Generating all modules..."
        mill chisel.runMain led.LedTop
        mill chisel.runMain gpio.GPIOTop
        print_info "All Verilog files generated in ${OUTPUT_DIR}"
        ;;

    clean)
        print_warn "Cleaning build artifacts..."
        rm -rf out/
        rm -rf "${OUTPUT_DIR}"/*.v "${OUTPUT_DIR}"/*.sv
        print_info "Clean complete"
        ;;

    *)
        echo "Usage: $0 {led|gpio|all|clean}"
        echo ""
        echo "Commands:"
        echo "  led    - Generate LED module Verilog"
        echo "  gpio   - Generate GPIO module Verilog"
        echo "  all    - Generate all modules"
        echo "  clean  - Remove build artifacts"
        echo ""
        echo "Output directory: ${OUTPUT_DIR}"
        exit 1
        ;;
esac

print_info "Build complete"
