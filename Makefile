SHELL := /bin/bash

TARGET ?= custom_xczu47dr_waveform
ALLOWED_TARGETS := custom_xczu47dr_waveform
ifneq ($(filter $(TARGET),$(ALLOWED_TARGETS)),$(TARGET))
$(error unsupported TARGET=$(TARGET). Allowed targets: $(ALLOWED_TARGETS))
endif

# External XS17 reference frequency (MHz). One RTL source tree builds both
# profiles; REFERENCE_MHZ picks the HMC7044 R1 divider generic at project
# creation (250 -> R1=25, 10 -> R1=1; PLL1 always closes on a 10 MHz PFD).
REFERENCE_MHZ ?= 250
ifeq ($(filter $(REFERENCE_MHZ),10 250),)
$(error unsupported REFERENCE_MHZ=$(REFERENCE_MHZ). Allowed: 10 or 250)
endif
# Passed to Vivado/tclsh children (target_config.tcl reads it for the generic).
export REFERENCE_MHZ
REF_TAG := $(REFERENCE_MHZ)mhz

ROOT := $(CURDIR)

VIVADO_DIR := $(ROOT)/hardware/vivado
ARTIFACT_DIR ?= $(ROOT)/artifacts
# Keep the waveform Vivado state isolated from any older local build tree.
VIVADO_WORK_DIR ?= $(VIVADO_DIR)/work/$(TARGET)
VIVADO_OUTPUT_DIR ?= $(ARTIFACT_DIR)
VIVADO_REPORT_DIR ?= $(VIVADO_DIR)/reports/$(TARGET)
CHISEL_DIR := $(ROOT)/hardware/chisel
FIRMWARE_DIR := $(ROOT)/firmware
SOFTWARE_DIR := $(ROOT)/software

# --- Xilinx licensing for the XXV Ethernet MAC ------------------------------
# write_bitstream needs the "Bought" xxv_eth_mac_pcs feature.  The committed
# reference XXV DCP was produced under an expired evaluation license and is NOT
# bitstream-capable, so hardware builds re-synthesize the XXV IP fresh
# (XXV_SYNTHESIZE_FRESH=1) under the Bought license below.  Set
# XXV_SYNTHESIZE_FRESH=0 to reuse the reference DCP for license-free RTL
# iteration (synth/impl only; the final write_bitstream will not be permitted).
XILINX_BOUGHT_LICENSE ?= $(abspath $(ROOT)/../Xilinx_new.lic)
XXV_SYNTHESIZE_FRESH ?= 1
export XXV_SYNTHESIZE_FRESH
ifneq ($(wildcard $(XILINX_BOUGHT_LICENSE)),)
export XILINXD_LICENSE_FILE := $(XILINX_BOUGHT_LICENSE)$(if $(XILINXD_LICENSE_FILE),:$(XILINXD_LICENSE_FILE),)
endif

TARGET_PROJECT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^project_basename:/ {print $$2}')
TARGET_OUTPUT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^output_basename:/ {print $$2}')
TARGET_FIRMWARE_WORKSPACE := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^firmware_workspace:/ {print $$2}')
XSA ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).xsa
ELF ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).elf

IP ?= 10.87.5.241
PORT ?= 7
TIMEOUT ?= 5
HOST_OUTPUT_DIR ?= $(ROOT)/software/output

# The docs tell you to install the test dependencies into ./.venv, but every
# Python target used a bare python3, so a correctly set up repo still ran the
# tests against the system interpreter - where matplotlib/fastapi are missing
# and 13 test modules die on import.  Prefer the repo venv when it exists.
PYTHON ?= $(if $(wildcard $(ROOT)/.venv/bin/python),$(ROOT)/.venv/bin/python,python3)

.PHONY: help all test driver-wheel driver-smoke driver-release hardware hardware-fast hardware-10mhz hardware-250mhz hardware-both hardware-clean chisel chisel-clean vivado-project preflight synth xdc-check impl bitstream xsa firmware firmware-create firmware-build firmware-clean artifacts artifacts-hash artifacts-clean host host-dry-run run program check-tools clean

help:
	@echo "XCZU47DR RFDC top-level build"
	@echo ""
	@echo "Build targets:"
	@echo "  make all              Build hardware and firmware"
	@echo "  make test             Run software/unit and script syntax checks"
	@echo "  make hardware         Build one version (REFERENCE_MHZ, default 250) into ARTIFACT_DIR"
	@echo "  make hardware-fast    Reuse the current Vivado project for RTL/constraint iterations"
	@echo "  make firmware         Create/rebuild firmware app and ELF from current XSA"
	@echo "  make artifacts        Verify the selected role's checked-in artifacts"
	@echo "  make artifacts-hash   Refresh artifacts/SHA256SUMS atomically"
	@echo "  make artifacts-clean  Remove local checked-in artifacts explicitly"
	@echo "  make driver-release   Build and verify the distributable Python SDK bundle"
	@echo ""
	@echo "Dual-version (10 MHz / 250 MHz XS17 reference) bitstreams:"
	@echo "  make hardware-10mhz   Build the 10 MHz version  -> artifacts/10mhz/"
	@echo "  make hardware-250mhz  Build the 250 MHz version -> artifacts/250mhz/"
	@echo "  make hardware-both    Build BOTH versions in parallel (isolated work/artifacts)"
	@echo "  make hardware REFERENCE_MHZ=10   Single build with an explicit reference"
	@echo ""
	@echo "Step targets:"
	@echo "  make chisel           Generate Chisel Verilog"
	@echo "  make vivado-project   Create Vivado project"
	@echo "  make preflight        Elaborate RTL and run structural checks without synthesis"
	@echo "  make synth            Run Vivado synthesis"
	@echo "  make impl             Run Vivado implementation"
	@echo "  make bitstream        Generate the selected production bitstream internally"
	@echo "  make xdc-check        Verify XDC get_pins constraints against the synthesized netlist"
	@echo "  make xsa              Export the waveform XSA"
	@echo "  make firmware-create  Create Vitis platform/application"
	@echo "  make firmware-build   Build firmware ELF"
	@echo ""
	@echo "Board/host targets:"
	@echo "  make program          Program XSA and download the matching ELF over JTAG"
	@echo "  make run              Alias for make program"
	@echo "  make host             Run host.py against board IP/PORT"
	@echo "  make host IP=10.87.5.241 PORT=7"
	@echo "  make host-dry-run     Generate host artifacts without board access"
	@echo ""
	@echo "Maintenance:"
	@echo "  make hardware-clean   Clean Vivado work, reports, and ignored output"
	@echo "  make chisel-clean     Remove Chisel/Mill generated state"
	@echo "  make firmware-clean   Remove Vitis workspace"
	@echo "  make clean            Clean all generated build state except artifacts"
	@echo ""
	@echo "Defaults:"
	@echo "  PROJECT=$(TARGET_PROJECT_BASENAME)"
	@echo "  XSA=$(XSA)"
	@echo "  ELF=$(ELF)"
	@echo "  FW_WORKSPACE=$(ROOT)/$(TARGET_FIRMWARE_WORKSPACE)"
	@echo "  TARGET=$(TARGET) (allowed: $(ALLOWED_TARGETS))"
	@echo "  REFERENCE_MHZ=$(REFERENCE_MHZ) (allowed: 10 or 250)"
	@echo "  XXV_SYNTHESIZE_FRESH=$(XXV_SYNTHESIZE_FRESH) (1=fresh XXV synth under the Bought license; needed for write_bitstream)"
	@echo "  XILINXD_LICENSE_FILE=$(XILINXD_LICENSE_FILE)"
	@echo "  ARTIFACT_DIR=$(ARTIFACT_DIR)"
	@echo "  PROGRAM=cd firmware && TARGET=$(TARGET) ./build.sh program"
	@echo "  IP=$(IP) PORT=$(PORT) TIMEOUT=$(TIMEOUT)"

all: hardware firmware artifacts

test:
	@$(PYTHON) -c "import numpy, matplotlib, fastapi" 2>/dev/null || { \
	  echo "ERROR: 测试依赖缺失（numpy / matplotlib / fastapi）。"; \
	  echo "       先执行: $(PYTHON) -m pip install -r software/requirements.txt"; \
	  echo "       当前解释器: $(PYTHON)"; exit 1; }
	$(PYTHON) -m unittest discover -s tests
	bash -n software/capture_uart.sh
	bash -n firmware/build.sh

driver-wheel:
	mkdir -p "$(ROOT)/dist"
	$(PYTHON) -m pip wheel --no-deps -w "$(ROOT)/dist" "$(SOFTWARE_DIR)/dr47"

driver-smoke: driver-wheel
	$(PYTHON) -c "import glob, runpy, sys; wheels=glob.glob('$(ROOT)/dist/47dr_driver-*-py3-none-any.whl'); assert wheels, 'driver wheel missing'; wheel=sorted(wheels)[-1]; sys.path.insert(0, wheel); import dr47 as d; assert '.whl/' in d.__file__, d.__file__; print('wheel version', d.__version__, 'from', d.__file__); runpy.run_module('dr47.examples.simulator_quickstart', run_name='__main__')"

driver-release: driver-smoke
	$(PYTHON) software/build_driver_release.py

check-tools:
	@command -v vivado >/dev/null || { echo "ERROR: vivado not found. Source Vivado settings first."; exit 1; }
	@command -v xsct >/dev/null || { echo "ERROR: xsct not found. Source Vitis settings first."; exit 1; }
	@command -v python3 >/dev/null || { echo "ERROR: python3 not found."; exit 1; }

chisel:
	cd $(CHISEL_DIR) && ./build.sh all

vivado-project: $(if $(SKIP_CHISEL),,chisel)
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/create_project.tcl -tclargs $(TARGET)

preflight: vivado-project
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/preflight.tcl -tclargs $(TARGET)

synth: vivado-project
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/run_synth.tcl -tclargs $(TARGET)

# Verify every "-quiet" XDC object query (get_pins and get_clocks) still matches
# the synthesized netlist.  Six get_pins constraints had silently rotted after
# signal renames - including the hmc_pl_clk -> dac_axis_clk Trigger CDC - and one
# get_clocks name outlived its clk_wiz, because -quiet makes an empty match
# indistinguishable from success.  Fails the build by default; set
# XDC_CHECK_STRICT=0 to downgrade it to a warning.
xdc-check: synth
	@log=$$(mktemp); cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" vivado -mode batch -notrace \
	  -source scripts/check_xdc_pins.tcl -tclargs $(TARGET) > $$log 2>&1; rc=$$?; \
	grep -E "XDC (pin|clock) check:|dead XDC (pin pattern|clock name)|unparsable XDC" $$log || true; \
	if [ $$rc -ne 0 ]; then \
	  echo "--- last lines of the check log (a Tcl error shows up here) ---"; \
	  tail -5 $$log; \
	  if [ "$(XDC_CHECK_STRICT)" = "0" ]; then \
	    echo "WARNING: dead XDC constraints present (XDC_CHECK_STRICT=0, continuing)"; \
	  else \
	    echo "ERROR: dead XDC constraints - fix them, or rebuild with XDC_CHECK_STRICT=0"; \
	    echo "       full log: $$log"; exit 1; \
	  fi; \
	fi; rm -f $$log

impl: xdc-check
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/run_impl_manual.tcl -tclargs $(TARGET)

bitstream: impl
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/run_bitstream.tcl -tclargs $(TARGET)

xsa: bitstream
	@echo "INFO: Exporting TARGET=$(TARGET) PROJECT=$(TARGET_PROJECT_BASENAME)"
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs $(TARGET)
	@for stale in "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).bit" "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).ltx" "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME)_psu_init.tcl"; do test ! -e "$$stale" || { echo "Removing non-production artifact $$stale"; unlink "$$stale"; }; done
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

hardware:
	@echo "INFO: TARGET=$(TARGET) REFERENCE_MHZ=$(REFERENCE_MHZ) PROJECT=$(TARGET_PROJECT_BASENAME) XSA=$(XSA)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) REFERENCE_MHZ=$(REFERENCE_MHZ) VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" ./build.sh --clean
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

hardware-fast:
	@echo "INFO: Fast hardware build reusing PROJECT=$(TARGET_PROJECT_BASENAME) (keeps the project's existing REFERENCE_MHZ)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) REFERENCE_MHZ=$(REFERENCE_MHZ) VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" ./build.sh
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

# Dual-version builds.  Each reference frequency gets its own Vivado work tree,
# reports and artifacts directory so the two never collide and can run at once.
hardware-10mhz:
	+$(MAKE) --no-print-directory hardware REFERENCE_MHZ=10 \
	  ARTIFACT_DIR="$(ROOT)/artifacts/10mhz" \
	  VIVADO_WORK_DIR="$(VIVADO_DIR)/work/$(TARGET)-10mhz" \
	  VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports/$(TARGET)-10mhz"

hardware-250mhz:
	+$(MAKE) --no-print-directory hardware REFERENCE_MHZ=250 \
	  ARTIFACT_DIR="$(ROOT)/artifacts/250mhz" \
	  VIVADO_WORK_DIR="$(VIVADO_DIR)/work/$(TARGET)-250mhz" \
	  VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports/$(TARGET)-250mhz"

# Build the 10 MHz and 250 MHz bitstreams concurrently.  Each sub-build streams
# to its own log; both must succeed for this target to succeed.
hardware-both:
	@echo "==> 并行构建 10 MHz 与 250 MHz 双版本 bitstream(各自独立 work/artifacts 目录)"
	@log10="$$(mktemp)"; log250="$$(mktemp)"; \
	echo "    10MHz  日志: $$log10"; \
	echo "    250MHz 日志: $$log250"; \
	$(MAKE) --no-print-directory hardware-10mhz  > "$$log10"  2>&1 & p10=$$!; \
	$(MAKE) --no-print-directory hardware-250mhz > "$$log250" 2>&1 & p250=$$!; \
	rc10=0; rc250=0; \
	wait $$p10  || rc10=$$?; \
	wait $$p250 || rc250=$$?; \
	echo "===== 10 MHz 构建输出(末尾 25 行) ====="; tail -25 "$$log10"; \
	echo "===== 250 MHz 构建输出(末尾 25 行) ====="; tail -25 "$$log250"; \
	if [ $$rc10 -ne 0 ] || [ $$rc250 -ne 0 ]; then \
	  echo "ERROR: 双版本构建失败 (10MHz rc=$$rc10, 250MHz rc=$$rc250; 完整日志见上述路径)"; exit 1; \
	fi; \
	rm -f "$$log10" "$$log250"; \
	echo "OK: 两个版本已生成 -> $(ROOT)/artifacts/10mhz/  和  $(ROOT)/artifacts/250mhz/"

hardware-clean:
	@echo "Cleaning Vivado generated state; preserving $(ARTIFACT_DIR)"
	rm -rf "$(VIVADO_DIR)/work" "$(VIVADO_DIR)/reports" \
	       "$(VIVADO_DIR)/output" \
	       "$(VIVADO_DIR)/hardware" "$(VIVADO_DIR)/.Xil"
	@for generated_dir in "$(VIVADO_DIR)"/work-* "$(VIVADO_DIR)"/reports-*; do \
		if [ -e "$$generated_dir" ]; then rm -rf "$$generated_dir"; fi; \
	done
	rm -f "$(VIVADO_DIR)"/*.jou "$(VIVADO_DIR)"/*.log \
	      "$(VIVADO_DIR)"/*.pb "$(VIVADO_DIR)"/*.str \
	      "$(VIVADO_DIR)"/*.zip "$(VIVADO_DIR)"/*.backup.*

chisel-clean:
	@echo "Cleaning Chisel/Mill generated state"
	rm -rf "$(CHISEL_DIR)/out" "$(CHISEL_DIR)/generated" "$(CHISEL_DIR)/Verilog"

firmware:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh clean && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh create && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh build
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

firmware-create:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh create
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

firmware-build:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh build
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

firmware-clean:
	@echo "Cleaning all Vitis workspaces; preserving $(ARTIFACT_DIR)"
	rm -rf "$(FIRMWARE_DIR)/workspace"

artifacts:
	@test -f "$(XSA)" || { echo "ERROR: missing XSA: $(XSA)"; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF: $(ELF)"; exit 1; }
	@du -h "$(XSA)" "$(ELF)"
	@test ! -e "$(ARTIFACT_DIR)/SHA256SUMS" || (cd "$(ARTIFACT_DIR)" && sha256sum -c SHA256SUMS)

artifacts-hash:
	@mkdir -p "$(ARTIFACT_DIR)"
	@lock="/tmp/xczu47dr-artifacts-$$(id -u).lock"; \
	while ! mkdir "$$lock" 2>/dev/null; do sleep 0.1; done; \
	trap 'rmdir "$$lock"' EXIT; \
	temporary_file="$(ARTIFACT_DIR)/SHA256SUMS.tmp.$$$$"; \
	{ for file in \
		custom_xczu47dr_waveform.xsa custom_xczu47dr_waveform.elf; do \
		test -f "$(ARTIFACT_DIR)/$$file" && (cd "$(ARTIFACT_DIR)" && sha256sum "$$file") || true; \
	done; } > "$$temporary_file"; \
	mv -f "$$temporary_file" "$(ARTIFACT_DIR)/SHA256SUMS"
artifacts-clean:
	@echo "Removing checked-in artifacts under $(ARTIFACT_DIR)"
	unlink "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).xsa" 2>/dev/null || true
	unlink "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).elf" 2>/dev/null || true
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

run program:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh program

host:
	cd $(SOFTWARE_DIR) && $(PYTHON) host.py --ip "$(IP)" --port "$(PORT)" --timeout "$(TIMEOUT)" --output-dir "$(HOST_OUTPUT_DIR)"

host-dry-run:
	cd $(SOFTWARE_DIR) && $(PYTHON) host.py --dry-run --output-dir "$(HOST_OUTPUT_DIR)"

clean: firmware-clean hardware-clean chisel-clean
