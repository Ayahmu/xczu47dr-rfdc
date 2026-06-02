#!/bin/bash
# Vivado Complete Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-zcu216}"
WORK_DIR="${SCRIPT_DIR}/work"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
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

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if Vivado is available
if ! command -v vivado &> /dev/null; then
    print_error "Vivado not found in PATH"
    print_info "Please source Vivado settings: source /tools/Xilinx/Vivado/2024.2/settings64.sh"
    exit 1
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Parse command line arguments
SKIP_CHISEL=false
SKIP_SYNTH=false
SKIP_IMPL=false
SKIP_BITSTREAM=false
CLEAN_FIRST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-chisel)
            SKIP_CHISEL=true
            shift
            ;;
        --skip-synth)
            SKIP_SYNTH=true
            shift
            ;;
        --skip-impl)
            SKIP_IMPL=true
            shift
            ;;
        --skip-bitstream)
            SKIP_BITSTREAM=true
            shift
            ;;
        --clean)
            CLEAN_FIRST=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-chisel      Skip Chisel Verilog generation"
            echo "  --skip-synth       Skip synthesis"
            echo "  --skip-impl        Skip implementation"
            echo "  --skip-bitstream   Skip bitstream generation"
            echo "  --clean            Clean before build"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                           # Full build"
            echo "  $0 --clean                   # Clean and full build"
            echo "  $0 --skip-chisel             # Build without regenerating Chisel"
            echo "  $0 --skip-synth --skip-impl  # Only create project"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Clean if requested
if [ "$CLEAN_FIRST" = true ]; then
    print_warn "Cleaning previous build..."
    rm -rf "${WORK_DIR}"
    rm -rf "${OUTPUT_DIR}"/*.bit "${OUTPUT_DIR}"/*.ltx "${OUTPUT_DIR}"/*.xsa "${OUTPUT_DIR}"/*.rpt
    mkdir -p "${OUTPUT_DIR}"
    print_info "Clean complete"
fi

PROJECT_NAME="$(cd "${SCRIPT_DIR}/scripts" && tclsh target_config.tcl "${TARGET}" | awk -F': ' '/^project_basename:/ {print $2}')"
if [ -z "${PROJECT_NAME}" ]; then
    print_error "Unable to resolve project name for TARGET=${TARGET}"
    exit 1
fi

# Step 1: Generate Chisel Verilog
if [ "$SKIP_CHISEL" = false ]; then
    print_step "Step 1/5: Generating Chisel Verilog..."
    cd "${SCRIPT_DIR}/../chisel"
    ./build.sh all
    print_info "Chisel Verilog generation complete"
else
    print_warn "Skipping Chisel Verilog generation"
fi

cd "${SCRIPT_DIR}"

# Step 2: Create Vivado Project (or use existing)
PROJECT_FILE="${WORK_DIR}/${PROJECT_NAME}.xpr"
if [ -f "${PROJECT_FILE}" ]; then
    print_step "Step 2/5: Using existing Vivado project..."
    print_info "Found existing project: ${PROJECT_FILE}"
    print_info "To recreate project from scratch, use --clean option"
else
    print_step "Step 2/5: Creating Vivado project..."
    vivado -mode batch -source scripts/create_project.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "Project creation failed"
        exit 1
    fi
    print_info "Project created successfully"
fi

# Step 3: Run Synthesis
if [ "$SKIP_SYNTH" = false ]; then
    print_step "Step 3/5: Running synthesis..."
    vivado -mode batch -source scripts/run_synth.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "Synthesis failed"
        exit 1
    fi
    print_info "Synthesis complete"
else
    print_warn "Skipping synthesis"
fi

# Step 4: Run Implementation
if [ "$SKIP_IMPL" = false ] && [ "$SKIP_SYNTH" = false ]; then
    print_step "Step 4/5: Running implementation..."
    vivado -mode batch -source scripts/run_impl.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "Implementation failed"
        exit 1
    fi
    print_info "Implementation complete"
else
    print_warn "Skipping implementation"
fi

# Step 5: Generate Bitstream and Export XSA
if [ "$SKIP_BITSTREAM" = false ] && [ "$SKIP_IMPL" = false ] && [ "$SKIP_SYNTH" = false ]; then
    print_step "Step 5/5: Generating bitstream and exporting XSA..."
    vivado -mode batch -source scripts/run_bitstream.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "Bitstream generation failed"
        exit 1
    fi

    vivado -mode batch -source scripts/export_xsa.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "XSA export failed"
        exit 1
    fi
    print_info "Bitstream and XSA generation complete"
else
    print_warn "Skipping bitstream generation"
fi

# Summary
echo ""
print_info "=========================================="
print_info "Build Summary"
print_info "=========================================="
print_info "Project: ${PROJECT_NAME}"
print_info "Work directory: ${WORK_DIR}"
print_info "Output directory: ${OUTPUT_DIR}"
echo ""

if [ -f "${OUTPUT_DIR}/${PROJECT_NAME}.bit" ]; then
    BIT_SIZE=$(du -h "${OUTPUT_DIR}/${PROJECT_NAME}.bit" | cut -f1)
    print_info "Bitstream: ${OUTPUT_DIR}/${PROJECT_NAME}.bit (${BIT_SIZE})"
fi

if [ -f "${OUTPUT_DIR}/${PROJECT_NAME}.xsa" ]; then
    XSA_SIZE=$(du -h "${OUTPUT_DIR}/${PROJECT_NAME}.xsa" | cut -f1)
    print_info "XSA: ${OUTPUT_DIR}/${PROJECT_NAME}.xsa (${XSA_SIZE})"
fi

echo ""
print_info "Build complete!"
