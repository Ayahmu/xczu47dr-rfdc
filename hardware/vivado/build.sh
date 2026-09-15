#!/bin/bash
# Vivado Complete Build Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-custom_xczu47dr_master}"
WORK_DIR="${VIVADO_WORK_DIR:-${SCRIPT_DIR}/work}"
OUTPUT_DIR="${VIVADO_OUTPUT_DIR:-${SCRIPT_DIR}/output}"
REPORT_DIR="${VIVADO_REPORT_DIR:-${SCRIPT_DIR}/reports}"

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

PROJECT_NAME="$(cd "${SCRIPT_DIR}/scripts" && tclsh target_config.tcl "${TARGET}" | awk -F': ' '/^project_basename:/ {print $2}')"
OUTPUT_BASENAME="$(cd "${SCRIPT_DIR}/scripts" && tclsh target_config.tcl "${TARGET}" | awk -F': ' '/^output_basename:/ {print $2}')"
if [ -z "${PROJECT_NAME}" ] || [ -z "${OUTPUT_BASENAME}" ]; then
    print_error "Unable to resolve target configuration for TARGET=${TARGET}"
    exit 1
fi

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

# A Vivado project records the source identity at creation time.  Reusing a
# project after checking out another revision would otherwise compile the new
# RTL with the old Verilog defines and can export a mixed-identity bitstream.
PROJECT_FILE="${WORK_DIR}/${PROJECT_NAME}.xpr"
MANIFEST_FILE="${WORK_DIR}/build_manifest.json"
SOURCE_COMMIT="$(git -C "${SCRIPT_DIR}/../.." rev-parse --verify HEAD 2>/dev/null | cut -c1-8 || true)"
if [ "$CLEAN_FIRST" = false ] && [ -f "${PROJECT_FILE}" ]; then
    manifest_matches=false
    if [ -s "${MANIFEST_FILE}" ] && [ -n "${SOURCE_COMMIT}" ] && command -v python3 >/dev/null 2>&1; then
        if python3 - "${MANIFEST_FILE}" "${TARGET}" "${SOURCE_COMMIT}" <<'PY'
import json
import sys

path, target, source = sys.argv[1:]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
ok = (
    data.get("target") == target
    and int(data.get("protocol_version", 0)) == 3
    and int(data.get("trigger_path_version", 0)) == 3
    and str(data.get("source_commit", "")).lower() == source.lower()
)
raise SystemExit(0 if ok else 1)
PY
        then
            manifest_matches=true
        fi
    fi
    if [ "$manifest_matches" != true ]; then
        print_warn "Existing Vivado project identity does not match ${SOURCE_COMMIT:-current HEAD}; recreating it"
        CLEAN_FIRST=true
    fi
fi

# Clean if requested
if [ "$CLEAN_FIRST" = true ]; then
    print_warn "Cleaning previous build..."
    rm -rf "${WORK_DIR}/${PROJECT_NAME}.xpr" \
           "${WORK_DIR}/${PROJECT_NAME}.srcs" \
           "${WORK_DIR}/${PROJECT_NAME}.gen" \
           "${WORK_DIR}/${PROJECT_NAME}.runs" \
           "${WORK_DIR}/${PROJECT_NAME}.cache" \
           "${WORK_DIR}/${PROJECT_NAME}.hw" \
           "${WORK_DIR}/${PROJECT_NAME}.ip_user_files" \
           "${WORK_DIR}/${PROJECT_NAME}.sim"
    # Final programming artifacts are written with temporary files and atomic
    # renames by the Vivado Tcl scripts. Keep the previous checked-in files
    # available until a replacement has completed successfully.
    rm -f "${OUTPUT_DIR}/${OUTPUT_BASENAME}_timing.rpt"
    mkdir -p "${OUTPUT_DIR}"
    print_info "Clean complete"
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
if [ "$CLEAN_FIRST" = false ] && [ -f "${PROJECT_FILE}" ]; then
    print_step "Step 2/5: Using existing Vivado project..."
    print_info "Found existing project: ${PROJECT_FILE}"
    print_info "To recreate project from scratch, use --clean option"
else
    print_step "Step 2/5: Creating Vivado project..."
    if [ "$CLEAN_FIRST" = true ]; then
        rm -rf "${PROJECT_FILE}" \
               "${WORK_DIR}/${PROJECT_NAME}.srcs" \
               "${WORK_DIR}/${PROJECT_NAME}.gen" \
               "${WORK_DIR}/${PROJECT_NAME}.runs" \
               "${WORK_DIR}/${PROJECT_NAME}.cache" \
               "${WORK_DIR}/${PROJECT_NAME}.hw" \
               "${WORK_DIR}/${PROJECT_NAME}.ip_user_files" \
               "${WORK_DIR}/${PROJECT_NAME}.sim"
    fi
    VIVADO_WORK_DIR="${WORK_DIR}" VIVADO_OUTPUT_DIR="${OUTPUT_DIR}" VIVADO_REPORT_DIR="${REPORT_DIR}" \
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
    VIVADO_WORK_DIR="${WORK_DIR}" VIVADO_OUTPUT_DIR="${OUTPUT_DIR}" VIVADO_REPORT_DIR="${REPORT_DIR}" \
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
    VIVADO_WORK_DIR="${WORK_DIR}" VIVADO_OUTPUT_DIR="${OUTPUT_DIR}" VIVADO_REPORT_DIR="${REPORT_DIR}" \
        vivado -mode batch -source scripts/run_impl_manual.tcl -tclargs "${TARGET}" -notrace
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
    VIVADO_WORK_DIR="${WORK_DIR}" VIVADO_OUTPUT_DIR="${OUTPUT_DIR}" VIVADO_REPORT_DIR="${REPORT_DIR}" \
        vivado -mode batch -source scripts/run_bitstream.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "Bitstream generation failed"
        exit 1
    fi

    VIVADO_WORK_DIR="${WORK_DIR}" VIVADO_OUTPUT_DIR="${OUTPUT_DIR}" VIVADO_REPORT_DIR="${REPORT_DIR}" \
        vivado -mode batch -source scripts/export_xsa.tcl -tclargs "${TARGET}" -notrace
    if [ $? -ne 0 ]; then
        print_error "XSA export failed"
        exit 1
    fi
    # XSA is the sole production hardware image.  The bitstream and probes
    # remain available inside the build tree for the export, but are not
    # published as duplicate artifacts.
    rm -f "${OUTPUT_DIR}/${OUTPUT_BASENAME}.bit" \
          "${OUTPUT_DIR}/${OUTPUT_BASENAME}.ltx" \
          "${OUTPUT_DIR}/${OUTPUT_BASENAME}_psu_init.tcl"
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

if [ -f "${OUTPUT_DIR}/${OUTPUT_BASENAME}.xsa" ]; then
    XSA_SIZE=$(du -h "${OUTPUT_DIR}/${OUTPUT_BASENAME}.xsa" | cut -f1)
    print_info "XSA: ${OUTPUT_DIR}/${OUTPUT_BASENAME}.xsa (${XSA_SIZE})"
fi

echo ""
print_info "Build complete!"
