SHELL := /bin/bash

TARGET ?= zcu216
ALLOWED_TARGETS := zcu216 custom_xczu47dr
ifneq ($(filter $(TARGET),$(ALLOWED_TARGETS)),$(TARGET))
$(error unsupported TARGET=$(TARGET). Allowed targets: $(ALLOWED_TARGETS))
endif

ROOT := $(CURDIR)

VIVADO_DIR := $(ROOT)/hardware/vivado
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

.PHONY: help all hardware hardware-clean chisel vivado-project synth impl bitstream xsa firmware firmware-create firmware-build firmware-rebuild firmware-clean artifacts host host-dry-run run program check-tools clean $(RUN_ARGS)

help:
	@echo "ZCU216 RFDC top-level build"
	@echo ""
	@echo "Build targets:"
	@echo "  make all              Build hardware and firmware"
	@echo "  make hardware         Build Chisel, Vivado project, synth, impl, bitstream, XSA"
	@echo "  make firmware         Create/rebuild firmware app and ELF from current XSA"
	@echo "  make artifacts        Verify expected .bit/.ltx/.xsa/.elf artifacts exist"
	@echo ""
	@echo "Step targets:"
	@echo "  make chisel           Generate Chisel Verilog"
	@echo "  make vivado-project   Create Vivado project"
	@echo "  make synth            Run Vivado synthesis"
	@echo "  make impl             Run Vivado implementation"
	@echo "  make bitstream        Generate/copy bitstream and debug probes"
	@echo "  make xsa              Export XSA"
	@echo "  make firmware-create  Create Vitis platform/application"
	@echo "  make firmware-build   Build firmware ELF"
	@echo ""
	@echo "Board/host targets:"
	@echo "  make run              Program FPGA with BIT and download ELF over JTAG"
	@echo "  make run TARGET=custom_xczu47dr"
	@echo "  make run ELF=/path/app.elf BIT=/path/top.bit PSU_INIT=/path/psu_init.tcl"
	@echo "  make host             Run host.py against board IP/PORT"
	@echo "  make host IP=10.87.5.241 PORT=7"
	@echo "  make host-dry-run     Generate host artifacts without board access"
	@echo ""
	@echo "Maintenance:"
	@echo "  make hardware-clean   Clean Vivado work/output before hardware build"
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
	@echo "  RUN=cd firmware && TARGET=$(TARGET) ./build.sh program"
	@echo "  IP=$(IP) PORT=$(PORT) TIMEOUT=$(TIMEOUT)"

all: hardware firmware artifacts

check-tools:
	@command -v vivado >/dev/null || { echo "ERROR: vivado not found. Source Vivado settings first."; exit 1; }
	@command -v xsct >/dev/null || { echo "ERROR: xsct not found. Source Vitis settings first."; exit 1; }
	@command -v python3 >/dev/null || { echo "ERROR: python3 not found."; exit 1; }

chisel:
	cd $(CHISEL_DIR) && ./build.sh all

vivado-project: chisel
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/create_project.tcl -tclargs $(TARGET)

synth: vivado-project
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_synth.tcl -tclargs $(TARGET)

impl: synth
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_impl.tcl -tclargs $(TARGET)

bitstream: impl
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_bitstream.tcl -tclargs $(TARGET)

xsa: bitstream
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/export_xsa.tcl -tclargs $(TARGET)

hardware:
	@echo "INFO: TARGET=$(TARGET) PROJECT=$(TARGET_PROJECT_BASENAME) BIT=$(BIT) LTX=$(LTX) XSA=$(XSA)"
	cd $(VIVADO_DIR) && TARGET=$(TARGET) ./build.sh --clean

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
