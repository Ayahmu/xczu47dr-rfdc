SHELL := /bin/bash

TARGET ?= custom_xczu47dr_master
ALLOWED_TARGETS := custom_xczu47dr_master custom_xczu47dr_slave custom_xczu47dr_bw
ifneq ($(filter $(TARGET),$(ALLOWED_TARGETS)),$(TARGET))
$(error unsupported TARGET=$(TARGET). Allowed targets: $(ALLOWED_TARGETS))
endif

ROOT := $(CURDIR)

VIVADO_DIR := $(ROOT)/hardware/vivado
VIVADO_WORK_DIR ?= $(VIVADO_DIR)/work
VIVADO_OUTPUT_DIR ?= $(VIVADO_DIR)/output
VIVADO_REPORT_DIR ?= $(VIVADO_DIR)/reports
CHISEL_DIR := $(ROOT)/hardware/chisel
FIRMWARE_DIR := $(ROOT)/firmware
SOFTWARE_DIR := $(ROOT)/software

TARGET_PROJECT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^project_basename:/ {print $$2}')
TARGET_OUTPUT_BASENAME := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^output_basename:/ {print $$2}')
TARGET_FIRMWARE_WORKSPACE := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^firmware_workspace:/ {print $$2}')
TARGET_FIRMWARE_ELF := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^firmware_elf:/ {print $$2}')
TARGET_PSU_INIT := $(shell cd $(VIVADO_DIR)/scripts && tclsh target_config.tcl $(TARGET) | awk -F': ' '/^psu_init:/ {print $$2}')

BIT ?= $(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).bit
LTX ?= $(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).ltx
XSA ?= $(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).xsa
ELF ?= $(ROOT)/$(TARGET_FIRMWARE_ELF)
PSU_INIT ?= $(ROOT)/$(TARGET_PSU_INIT)

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
RELEASE_NAME ?= 10mhz-$(shell date +%Y%m%d)
RELEASE_DIR ?= $(ROOT)/releases/$(RELEASE_NAME)

.PHONY: help all test driver-test driver-wheel driver-smoke hardware hardware-fast hardware-clean bitstream-dual bitstream-master bitstream-slave bitstream-dual-clean xsa-master xsa-slave chisel vivado-project preflight synth impl bitstream xsa firmware firmware-create firmware-build firmware-rebuild firmware-clean artifacts release-dual host host-dry-run run program check-tools clean $(RUN_ARGS)

help:
	@echo "XCZU47DR RFDC top-level build"
	@echo ""
	@echo "Build targets:"
	@echo "  make all              Build hardware and firmware"
	@echo "  make test             Run software/unit and script syntax checks"
	@echo "  make hardware         Build Chisel, Vivado project, synth, impl, bitstream, XSA"
	@echo "  make hardware-fast    Reuse the current Vivado project for RTL/constraint iterations"
	@echo "  make firmware         Create/rebuild firmware app and ELF from current XSA"
	@echo "  make artifacts        Verify expected .bit/.ltx/.xsa/.elf artifacts exist"
	@echo "  make release-dual     Package checked-in master/slave release artifacts"
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
	@echo "  make hardware-clean   Clean Vivado work/output before hardware build"
	@echo "  make bitstream-dual-clean  Remove only the isolated dual-build trees"
	@echo "  make firmware-clean   Remove Vitis workspace"
	@echo "  make clean            Clean firmware workspace and Vivado generated outputs"
	@echo ""
	@echo "Defaults:"
	@echo "  PROJECT=$(TARGET_PROJECT_BASENAME)"
	@echo "  BIT=$(BIT)"
	@echo "  XSA=$(XSA)"
	@echo "  ELF=$(ELF)"
	@echo "  PSU_INIT=$(PSU_INIT)"
	@echo "  FW_WORKSPACE=$(ROOT)/$(TARGET_FIRMWARE_WORKSPACE)"
	@echo "  TARGET=$(TARGET) (allowed: $(ALLOWED_TARGETS))"
	@echo "  TARGET=custom_xczu47dr_master builds the master synchronization bitstream"
	@echo "  TARGET=custom_xczu47dr_slave builds the slave synchronization bitstream"
	@echo "  Default TARGET=custom_xczu47dr_master builds the master synchronization bitstream"
	@echo "  Use TARGET=custom_xczu47dr_bw only for the standalone DDR bandwidth pressure path"
	@echo "  RUN=cd firmware && TARGET=$(TARGET) ./build.sh program"
	@echo "  IP=$(IP) PORT=$(PORT) TIMEOUT=$(TIMEOUT)"
	@echo "  RELEASE_DIR=$(RELEASE_DIR)"

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

impl: synth
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/run_impl_manual.tcl -tclargs $(TARGET)

bitstream: impl
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/run_bitstream.tcl -tclargs $(TARGET)

xsa: bitstream
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_WORK_DIR)" VIVADO_OUTPUT_DIR="$(VIVADO_OUTPUT_DIR)" VIVADO_REPORT_DIR="$(VIVADO_REPORT_DIR)" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs $(TARGET)

bitstream-master:
	+$(MAKE) $(if $(DUAL_PREPARED),SKIP_CHISEL=1,) TARGET=custom_xczu47dr_master VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/master" VIVADO_OUTPUT_DIR="$(VIVADO_DIR)/output" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/master" bitstream
	@bit="$(VIVADO_DIR)/output/custom_xczu47dr_master.bit"; ltx="$(VIVADO_DIR)/output/custom_xczu47dr_master.ltx"; test -s "$$bit" || { echo "ERROR: master bitstream missing: $$bit"; exit 1; }; echo "MASTER BIT: $$bit"; echo "MASTER SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "MASTER SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; test ! -e "$$ltx" || echo "MASTER LTX: $$ltx"

bitstream-slave:
	+$(MAKE) $(if $(DUAL_PREPARED),SKIP_CHISEL=1,) TARGET=custom_xczu47dr_slave VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/slave" VIVADO_OUTPUT_DIR="$(VIVADO_DIR)/output" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/slave" bitstream
	@bit="$(VIVADO_DIR)/output/custom_xczu47dr_slave.bit"; ltx="$(VIVADO_DIR)/output/custom_xczu47dr_slave.ltx"; test -s "$$bit" || { echo "ERROR: slave bitstream missing: $$bit"; exit 1; }; echo "SLAVE BIT: $$bit"; echo "SLAVE SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "SLAVE SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; test ! -e "$$ltx" || echo "SLAVE LTX: $$ltx"

xsa-master:
	@test -f "$(VIVADO_DIR)/work-dual/master/custom_xczu47dr_master_rfdc.xpr" || { echo "ERROR: isolated master project is missing; run make bitstream-master first"; exit 1; }
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/master" VIVADO_OUTPUT_DIR="$(VIVADO_DIR)/output" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/master" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs custom_xczu47dr_master

xsa-slave:
	@test -f "$(VIVADO_DIR)/work-dual/slave/custom_xczu47dr_slave_rfdc.xpr" || { echo "ERROR: isolated slave project is missing; run make bitstream-slave first"; exit 1; }
	cd $(VIVADO_DIR) && VIVADO_WORK_DIR="$(VIVADO_DIR)/work-dual/slave" VIVADO_OUTPUT_DIR="$(VIVADO_DIR)/output" VIVADO_REPORT_DIR="$(VIVADO_DIR)/reports-dual/slave" vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs custom_xczu47dr_slave

bitstream-dual: chisel
	+$(MAKE) -j2 DUAL_PREPARED=1 bitstream-master bitstream-slave
	@echo "Dual bitstream build complete"
	@for bit in "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.bit" "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.bit"; do test -s "$$bit" || exit 1; done
	@for role in master slave; do bit="$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_$${role}.bit"; echo "$$(printf '%s' "$${role}" | tr '[:lower:]' '[:upper:]') SIZE: $$(wc -c < "$$bit" | tr -d ' ') bytes"; echo -n "$$(printf '%s' "$${role}" | tr '[:lower:]' '[:upper:]') SHA256: "; sha256sum "$$bit" | awk '{print $$1}'; done

bitstream-dual-clean:
	rm -rf "$(VIVADO_DIR)/work-dual" "$(VIVADO_DIR)/reports-dual"
	rm -f "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.bit" "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.ltx" "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.bit" "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.ltx"

hardware:
	@echo "INFO: TARGET=$(TARGET) PROJECT=$(TARGET_PROJECT_BASENAME) BIT=$(BIT) LTX=$(LTX) XSA=$(XSA)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) ./build.sh --clean

hardware-fast:
	@echo "INFO: Fast hardware build reusing PROJECT=$(TARGET_PROJECT_BASENAME)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) ./build.sh

hardware-clean:
	rm -rf "$(VIVADO_DIR)/work"
	rm -f "$(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).bit" "$(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).ltx" "$(VIVADO_DIR)/output/$(TARGET_OUTPUT_BASENAME).xsa"
	mkdir -p "$(VIVADO_DIR)/output"

firmware:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh clean && TARGET=$(TARGET) ./build.sh create && TARGET=$(TARGET) ./build.sh build

firmware-create:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh create

firmware-build:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh build

firmware-rebuild:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh clean && TARGET=$(TARGET) ./build.sh create && TARGET=$(TARGET) ./build.sh build

firmware-clean:
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh clean

artifacts:
	@test -f "$(BIT)" || { echo "ERROR: missing bitstream: $(BIT)"; exit 1; }
	@test -f "$(LTX)" || { echo "ERROR: missing debug probes: $(LTX)"; exit 1; }
	@test -f "$(XSA)" || { echo "ERROR: missing XSA: $(XSA)"; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF: $(ELF)"; exit 1; }
	@du -h "$(BIT)" "$(LTX)" "$(XSA)" "$(ELF)"

# Package already-built, role-matched artifacts for clone-and-program use.
# This target deliberately does not invoke Vivado or Vitis; run the build
# targets first, then commit the resulting release directory.
release-dual:
	@test -s "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.bit" || { echo "ERROR: missing master bitstream; run make bitstream-master"; exit 1; }
	@test -s "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.bit" || { echo "ERROR: missing slave bitstream; run make bitstream-slave"; exit 1; }
	@test -s "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.xsa" || { echo "ERROR: missing master XSA; run make xsa-master"; exit 1; }
	@test -s "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.xsa" || { echo "ERROR: missing slave XSA; run make xsa-slave"; exit 1; }
	@test -s "$(ROOT)/firmware/workspace/custom_xczu47dr_master/rfdc_app/Debug/rfdc_app.elf" || { echo "ERROR: missing master ELF; run make firmware TARGET=custom_xczu47dr_master"; exit 1; }
	@test -s "$(ROOT)/firmware/workspace/custom_xczu47dr_slave/rfdc_app/Debug/rfdc_app.elf" || { echo "ERROR: missing slave ELF; run make firmware TARGET=custom_xczu47dr_slave"; exit 1; }
	@mkdir -p "$(RELEASE_DIR)"
	@cp "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.bit" "$(RELEASE_DIR)/"
	@cp "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.bit" "$(RELEASE_DIR)/"
	@cp "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_master.xsa" "$(RELEASE_DIR)/"
	@cp "$(VIVADO_OUTPUT_DIR)/custom_xczu47dr_slave.xsa" "$(RELEASE_DIR)/"
	@cp "$(ROOT)/firmware/workspace/custom_xczu47dr_master/rfdc_app/Debug/rfdc_app.elf" "$(RELEASE_DIR)/custom_xczu47dr_master.elf"
	@cp "$(ROOT)/firmware/workspace/custom_xczu47dr_slave/rfdc_app/Debug/rfdc_app.elf" "$(RELEASE_DIR)/custom_xczu47dr_slave.elf"
	@cp "$(ROOT)/firmware/workspace/custom_xczu47dr_master/hw_platform/export/hw_platform/hw/psu_init.tcl" "$(RELEASE_DIR)/custom_xczu47dr_master_psu_init.tcl"
	@cp "$(ROOT)/firmware/workspace/custom_xczu47dr_slave/hw_platform/export/hw_platform/hw/psu_init.tcl" "$(RELEASE_DIR)/custom_xczu47dr_slave_psu_init.tcl"
	@{ \
		echo "# XCZU47DR 10 MHz Hardware Release"; \
		echo; \
		echo "- Source commit: $$(git rev-parse HEAD)"; \
		echo "- XS17 reference: 10 MHz"; \
		echo "- HMC7044 DAC reference: 128 MHz"; \
		echo "- Roles: master XS20 output; slave XS20 input"; \
		echo "- Program only files with the same role prefix."; \
	} > "$(RELEASE_DIR)/MANIFEST.md"
	@(cd "$(RELEASE_DIR)" && sha256sum *.bit *.xsa *.elf *.tcl > SHA256SUMS)
	@echo "Release packaged at $(RELEASE_DIR)"

run program:
ifeq ($(EXPLICIT_PROGRAM_ARTIFACTS),1)
	@test -f "$(BIT)" || { echo "ERROR: missing BIT=$(BIT). Run make hardware first or pass BIT=..."; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF=$(ELF). Run make firmware first or pass ELF=..."; exit 1; }
	@test -f "$(PSU_INIT)" || { echo "ERROR: missing PSU_INIT=$(PSU_INIT). Run make firmware-create first or pass PSU_INIT=..."; exit 1; }
	cd $(FIRMWARE_DIR) && xsct scripts/program.tcl "$(BIT)" "$(ELF)" "$(PSU_INIT)"
else
	cd $(FIRMWARE_DIR) && TARGET=$(TARGET) ./build.sh program
endif

$(RUN_ARGS):
	@:

host:
	cd $(SOFTWARE_DIR) && python3 host.py --ip "$(IP)" --port "$(PORT)" --timeout "$(TIMEOUT)" --output-dir "$(HOST_OUTPUT_DIR)"

host-dry-run:
	cd $(SOFTWARE_DIR) && python3 host.py --dry-run --output-dir "$(HOST_OUTPUT_DIR)"

clean: firmware-clean hardware-clean
