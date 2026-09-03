SHELL := /bin/bash

TARGET ?= custom_xczu47dr_master
ALLOWED_TARGETS := custom_xczu47dr_master custom_xczu47dr_slave custom_xczu47dr_slave_trigout custom_xczu47dr_bw
ifneq ($(filter $(TARGET),$(ALLOWED_TARGETS)),$(TARGET))
$(error unsupported TARGET=$(TARGET). Allowed targets: $(ALLOWED_TARGETS))
endif

ROOT := $(CURDIR)

VIVADO_DIR := $(ROOT)/hardware/vivado
ARTIFACT_DIR ?= $(ROOT)/artifacts
VIVADO_WORK_DIR ?= $(VIVADO_DIR)/work
VIVADO_OUTPUT_DIR ?= $(ARTIFACT_DIR)
VIVADO_REPORT_DIR ?= $(VIVADO_DIR)/reports
CHISEL_DIR := $(ROOT)/hardware/chisel
FIRMWARE_DIR := $(ROOT)/firmware
SOFTWARE_DIR := $(ROOT)/software

TARGET_PROJECT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^project_basename:/ {print $$2}')
TARGET_OUTPUT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^output_basename:/ {print $$2}')
TARGET_FIRMWARE_WORKSPACE := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^firmware_workspace:/ {print $$2}')
TARGET_FIRMWARE_ELF := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^firmware_elf:/ {print $$2}')
TARGET_PSU_INIT := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^psu_init:/ {print $$2}')

BIT ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).bit
LTX ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).ltx
XSA ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).xsa
ELF ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).elf
PSU_INIT ?= $(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME)_psu_init.tcl

BIT_ORIGIN := $(origin BIT)
ELF_ORIGIN := $(origin ELF)
PSU_INIT_ORIGIN := $(origin PSU_INIT)
EXPLICIT_PROGRAM_ARTIFACTS := 0
ifeq ($(BIT_ORIGIN),command line)
  EXPLICIT_PROGRAM_ARTIFACTS := 1
endif
ifeq ($(ELF_ORIGIN),command line)
  EXPLICIT_PROGRAM_ARTIFACTS := 1
endif
ifeq ($(PSU_INIT_ORIGIN),command line)
  EXPLICIT_PROGRAM_ARTIFACTS := 1
endif

RUN_ARGS :=
ifneq ($(filter run program,$(MAKECMDGOALS)),)
  RUN_ARGS := $(filter-out run program,$(MAKECMDGOALS))
  RUN_ARG1 := $(word 1,$(RUN_ARGS))
  RUN_ARG2 := $(word 2,$(RUN_ARGS))
  ifneq ($(RUN_ARG1),)
    ifneq ($(filter %.elf,$(RUN_ARG1)),)
      ELF := $(RUN_ARG1)
      EXPLICIT_PROGRAM_ARTIFACTS := 1
    else
      $(error legacy BOARD argument '$(RUN_ARG1)' is no longer supported. Use TARGET=$(ALLOWED_TARGETS) and optional BIT=... ELF=... PSU_INIT=...)
    endif
  endif
  ifneq ($(RUN_ARG2),)
    ELF := $(RUN_ARG2)
    EXPLICIT_PROGRAM_ARTIFACTS := 1
  endif
endif

IP ?= 10.87.5.241
PORT ?= 7
TIMEOUT ?= 5
HOST_OUTPUT_DIR ?= $(ROOT)/software/output

.PHONY: help all test driver-test driver-wheel driver-smoke hardware hardware-fast hardware-clean bitstream-dual bitstream-master bitstream-slave bitstream-slave-trigout bitstream-slave-both bitstream-dual-clean xsa-master xsa-slave chisel chisel-clean vivado-project preflight synth xdc-check impl bitstream xsa firmware firmware-create firmware-build firmware-rebuild firmware-clean artifacts artifacts-hash artifacts-clean host host-dry-run run program check-tools clean $(RUN_ARGS)

help:
	@echo "XCZU47DR RFDC top-level build"
	@echo ""
	@echo "Build targets:"
	@echo "  make all              Build hardware and firmware"
	@echo "  make test             Run software/unit and script syntax checks"
	@echo "  make hardware         Build Chisel, Vivado project, synth, impl, bitstream, XSA"
	@echo "  make hardware-fast    Reuse the current Vivado project for RTL/constraint iterations"
	@echo "  make firmware         Create/rebuild firmware app and ELF from current XSA"
	@echo "  make artifacts        Verify the selected role's checked-in artifacts"
	@echo "  make artifacts-hash   Refresh artifacts/SHA256SUMS atomically"
	@echo "  make artifacts-clean  Remove local checked-in artifacts explicitly"
	@echo ""
	@echo "Step targets:"
	@echo "  make chisel           Generate Chisel Verilog"
	@echo "  make vivado-project   Create Vivado project"
	@echo "  make preflight        Elaborate RTL and run structural checks without synthesis"
	@echo "  make synth            Run Vivado synthesis"
	@echo "  make impl             Run Vivado implementation"
	@echo "  make bitstream        Generate/copy bitstream and debug probes"
	@echo "  make bitstream-master Build the master bitstream in an isolated Vivado tree"
	@echo "  make bitstream-slave  Build the slave bitstream in an isolated Vivado tree"
	@echo "  make bitstream-slave-trigout  XS20 as a second Trigger output (bench measurement, bypass only)"
	@echo "  make bitstream-slave-both     Both slave variants in parallel"
	@echo "  make xdc-check        Verify XDC get_pins constraints against the synthesized netlist"
	@echo "  make bitstream-dual   Build master and slave bitstreams in parallel"
	@echo "  make xsa              Export XSA"
	@echo "  make xsa-master       Export XSA from the isolated master project"
	@echo "  make xsa-slave        Export XSA from the isolated slave project"
	@echo "  make firmware-create  Create Vitis platform/application"
	@echo "  make firmware-build   Build firmware ELF"
	@echo ""
	@echo "Board/host targets:"
	@echo "  make run              Program FPGA with BIT and download ELF over JTAG"
	@echo "  make run"
	@echo "  make run ELF=/path/app.elf BIT=/path/top.bit PSU_INIT=/path/psu_init.tcl"
	@echo "  make host             Run host.py against board IP/PORT"
	@echo "  make host IP=10.87.5.241 PORT=7"
	@echo "  make host-dry-run     Generate host artifacts without board access"
	@echo ""
	@echo "Maintenance:"
	@echo "  make hardware-clean   Clean Vivado work, reports, dual trees, and old ignored output"
	@echo "  make bitstream-dual-clean  Remove only the isolated dual-build trees"
	@echo "  make chisel-clean     Remove Chisel/Mill generated state"
	@echo "  make firmware-clean   Remove Vitis workspace"
	@echo "  make clean            Clean all generated build state except artifacts"
	@echo ""
	@echo "Defaults:"
	@echo "  PROJECT=$(TARGET_PROJECT_BASENAME)"
	@echo "  BIT=$(BIT)"
	@echo "  XSA=$(XSA)"
	@echo "  ELF=$(ELF)"
	@echo "  PSU_INIT=$(PSU_INIT)"
	@echo "  FW_WORKSPACE=$(ROOT)/$(TARGET_FIRMWARE_WORKSPACE)"
	@echo "  TARGET=$(TARGET) (allowed: $(ALLOWED_TARGETS))"
	@echo "  ARTIFACT_DIR=$(ARTIFACT_DIR)"
	@echo "  TARGET=custom_xczu47dr_master builds the master synchronization bitstream"
	@echo "  TARGET=custom_xczu47dr_slave builds the slave synchronization bitstream"
	@echo "  Default TARGET=custom_xczu47dr_master builds the master synchronization bitstream"
	@echo "  Use TARGET=custom_xczu47dr_bw only for the standalone DDR bandwidth pressure path"
	@echo "  RUN=cd firmware && TARGET=$(TARGET) ./build.sh program"
	@echo "  IP=$(IP) PORT=$(PORT) TIMEOUT=$(TIMEOUT)"

all: hardware firmware artifacts

test:
	python3 -m unittest discover -s tests
	bash -n software/capture_uart.sh
	bash -n firmware/build.sh

driver-test:
	python3 -m unittest tests.test_dr47_driver

driver-wheel:
	python3 -m pip wheel --no-deps -w "$(ROOT)/dist" "$(SOFTWARE_DIR)/dr47"

driver-smoke: driver-wheel
	python3 -c "import sys; sys.path.insert(0, '$(SOFTWARE_DIR)'); import dr47 as d; print(d.__version__)"

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

# Verify every "get_pins -quiet" XDC constraint still matches the synthesized
# netlist.  Six of them had silently rotted after signal renames - including the
# hmc_pl_clk -> dac_axis_clk Trigger CDC - because -quiet makes an empty match
# indistinguishable from success.  Fails the build by default; set
# XDC_CHECK_STRICT=0 to downgrade it to a warning.
xdc-check: synth
	@log=$$(mktemp); cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" vivado -mode batch -notrace \
	  -source scripts/check_xdc_pins.tcl -tclargs $(TARGET) > $$log 2>&1; rc=$$?; \
	grep -E "XDC pin check:|dead XDC pin pattern|unparsable XDC" $$log || true; \
	if [ $$rc -ne 0 ]; then \
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
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/export_ltx.tcl -tclargs $(TARGET)
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

xsa: bitstream
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs $(TARGET)
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

bitstream-master:
	+$(MAKE) $(if $(DUAL_PREPARED),SKIP_CHISEL=1,) TARGET=custom_xczu47dr_master VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/master" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/master" bitstream
	@bit="$(ARTIFACT_DIR)/custom_xczu47dr_master.bit"; ltx="$(ARTIFACT_DIR)/custom_xczu47dr_master.ltx"; test -s "$$bit" || { echo "ERROR: master bitstream missing: $$bit"; exit 1; }; test -s "$$ltx" || { echo "ERROR: master debug probes missing: $$ltx"; exit 1; }; echo "MASTER BIT: $$bit"; echo "MASTER SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "MASTER SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; echo "MASTER LTX: $$ltx"

bitstream-slave:
	+$(MAKE) $(if $(DUAL_PREPARED),SKIP_CHISEL=1,) TARGET=custom_xczu47dr_slave VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/slave" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/slave" bitstream
	@bit="$(ARTIFACT_DIR)/custom_xczu47dr_slave.bit"; ltx="$(ARTIFACT_DIR)/custom_xczu47dr_slave.ltx"; test -s "$$bit" || { echo "ERROR: slave bitstream missing: $$bit"; exit 1; }; test -s "$$ltx" || { echo "ERROR: slave debug probes missing: $$ltx"; exit 1; }; echo "SLAVE BIT: $$bit"; echo "SLAVE SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "SLAVE SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; echo "SLAVE LTX: $$ltx"

bitstream-slave-trigout:
	+$(MAKE) $(if $(DUAL_PREPARED),SKIP_CHISEL=1,) TARGET=custom_xczu47dr_slave_trigout VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/slave-trigout" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/slave-trigout" bitstream
	@bit="$(ARTIFACT_DIR)/custom_xczu47dr_slave_trigout.bit"; ltx="$(ARTIFACT_DIR)/custom_xczu47dr_slave_trigout.ltx"; test -s "$$bit" || { echo "ERROR: slave-trigout bitstream missing: $$bit"; exit 1; }; test -s "$$ltx" || { echo "ERROR: slave-trigout debug probes missing: $$ltx"; exit 1; }; echo "SLAVE-TRIGOUT BIT: $$bit"; echo "SLAVE-TRIGOUT SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "SLAVE-TRIGOUT SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; echo "SLAVE-TRIGOUT LTX: $$ltx"

# Both slave variants at once: XS20 as SYNC input, and XS20 as a second Trigger
# output for the single-board scope measurement.
bitstream-slave-both: chisel
	+$(MAKE) -j2 DUAL_PREPARED=1 bitstream-slave bitstream-slave-trigout

xsa-master:
	@test -f "$(VIVADO_DIR)/work-dual/master/custom_xczu47dr_master_rfdc.xpr" || { echo "ERROR: isolated master project is missing; run make bitstream-master first"; exit 1; }
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/master" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/master" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs custom_xczu47dr_master
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

xsa-slave:
	@test -f "$(VIVADO_DIR)/work-dual/slave/custom_xczu47dr_slave_rfdc.xpr" || { echo "ERROR: isolated slave project is missing; run make bitstream-slave first"; exit 1; }
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/slave" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/slave" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs custom_xczu47dr_slave
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

bitstream-dual: chisel
	+$(MAKE) -j2 DUAL_PREPARED=1 bitstream-master bitstream-slave
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash
	@echo "Dual bitstream build complete"
	@for bit in "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.bit" "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.bit"; do test -s "$$bit" || exit 1; done
	@for role in master slave; do bit="$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_$${role}.bit"; echo "$$(printf '%s' "$${role}" | tr '[:lower:]' '[:upper:]') SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "$$(printf '%s' "$${role}" | tr '[:lower:]' '[:upper:]') SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; done

bitstream-dual-clean:
	rm -rf "$(VIVADO_DIR)/work-dual" "$(VIVADO_DIR)/reports-dual"

hardware:
	@echo "INFO: TARGET=$(TARGET) PROJECT=$(TARGET_PROJECT_BASENAME) BIT=$(BIT) LTX=$(LTX) XSA=$(XSA)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" ./build.sh --clean
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

hardware-fast:
	@echo "INFO: Fast hardware build reusing PROJECT=$(TARGET_PROJECT_BASENAME)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(ARTIFACT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" ./build.sh
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

hardware-clean:
	@echo "Cleaning Vivado generated state; preserving $(ARTIFACT_DIR)"
	rm -rf "$(VIVADO_WORK_DIR)" "$(VIVADO_REPORT_DIR)" \
	       "$(VIVADO_DIR)/work-dual" "$(VIVADO_DIR)/reports-dual" \
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

firmware-rebuild:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh clean && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh create && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh build
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

firmware-clean:
	@echo "Cleaning all Vitis workspaces; preserving $(ARTIFACT_DIR)"
	rm -rf "$(FIRMWARE_DIR)/workspace"

artifacts:
	@test -f "$(BIT)" || { echo "ERROR: missing bitstream: $(BIT)"; exit 1; }
	@test -f "$(XSA)" || { echo "ERROR: missing XSA: $(XSA)"; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF: $(ELF)"; exit 1; }
	@test -f "$(PSU_INIT)" || { echo "ERROR: missing PS init script: $(PSU_INIT)"; exit 1; }
	@du -h "$(BIT)" "$(XSA)" "$(ELF)" "$(PSU_INIT)"
	@test ! -e "$(LTX)" || du -h "$(LTX)"
	@test ! -e "$(ARTIFACT_DIR)/SHA256SUMS" || (cd "$(ARTIFACT_DIR)" && sha256sum -c SHA256SUMS)

artifacts-hash:
	@mkdir -p "$(ARTIFACT_DIR)"
	@lock="/tmp/xczu47dr-artifacts-$$(id -u).lock"; \
	while ! mkdir "$$lock" 2>/dev/null; do sleep 0.1; done; \
	trap 'rmdir "$$lock"' EXIT; \
	temporary_file="$(ARTIFACT_DIR)/SHA256SUMS.tmp.$$$$"; \
	{ for file in \
		custom_xczu47dr_master.bit custom_xczu47dr_master.ltx custom_xczu47dr_master.xsa custom_xczu47dr_master.elf custom_xczu47dr_master_psu_init.tcl \
		custom_xczu47dr_slave.bit custom_xczu47dr_slave.ltx custom_xczu47dr_slave.xsa custom_xczu47dr_slave.elf custom_xczu47dr_slave_psu_init.tcl \
		custom_xczu47dr_bandwidth.bit custom_xczu47dr_bandwidth.ltx custom_xczu47dr_bandwidth.xsa custom_xczu47dr_bandwidth.elf custom_xczu47dr_bandwidth_psu_init.tcl; do \
		test -f "$(ARTIFACT_DIR)/$$file" && (cd "$(ARTIFACT_DIR)" && sha256sum "$$file") || true; \
	done; } > "$$temporary_file"; \
	mv -f "$$temporary_file" "$(ARTIFACT_DIR)/SHA256SUMS"
artifacts-clean:
	@echo "Removing checked-in artifacts under $(ARTIFACT_DIR)"
	rm -f "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).bit" \
	      "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).ltx" \
	      "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).xsa" \
	      "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME).elf" \
	      "$(ARTIFACT_DIR)/$(TARGET_OUTPUT_BASENAME)_psu_init.tcl"
	+$(MAKE) --no-print-directory ARTIFACT_DIR="$(ARTIFACT_DIR)" artifacts-hash

run program:
ifeq ($(EXPLICIT_PROGRAM_ARTIFACTS),1)
	@test -f "$(BIT)" || { echo "ERROR: missing BIT=$(BIT). Run make bitstream first or pass BIT=..."; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF=$(ELF). Run make firmware first or pass ELF=..."; exit 1; }
	@test -f "$(PSU_INIT)" || { echo "ERROR: missing PSU_INIT=$(PSU_INIT). Run make firmware-create first or pass PSU_INIT=..."; exit 1; }
	cd $(FIRMWARE_DIR) && xsct scripts/program.tcl "$(BIT)" "$(ELF)" "$(PSU_INIT)"
else
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ARTIFACT_DIR="$(ARTIFACT_DIR)" ./build.sh program
endif

$(RUN_ARGS):
	@:

host:
	cd $(SOFTWARE_DIR) && python3 host.py --ip "$(IP)" --port "$(PORT)" --timeout "$(TIMEOUT)" --output-dir "$(HOST_OUTPUT_DIR)"

host-dry-run:
	cd $(SOFTWARE_DIR) && python3 host.py --dry-run --output-dir "$(HOST_OUTPUT_DIR)"

clean: firmware-clean hardware-clean chisel-clean
