SHELL := /bin/bash

PROJECT := zcu216_rfdc
ROOT := $(CURDIR)

VIVADO_DIR := $(ROOT)/hardware/vivado
CHISEL_DIR := $(ROOT)/hardware/chisel
FIRMWARE_DIR := $(ROOT)/firmware
SOFTWARE_DIR := $(ROOT)/software

BIT ?= $(VIVADO_DIR)/output/$(PROJECT).bit
LTX ?= $(VIVADO_DIR)/output/$(PROJECT).ltx
XSA ?= $(VIVADO_DIR)/output/$(PROJECT).xsa
ELF ?= $(FIRMWARE_DIR)/workspace/rfdc_app/Debug/rfdc_app.elf
PSU_INIT ?= $(FIRMWARE_DIR)/workspace/hw_platform/hw/psu_init.tcl
BOARD ?= zcu216

RUN_ARGS :=
ifneq ($(filter run program,$(MAKECMDGOALS)),)
  RUN_ARGS := $(filter-out run program,$(MAKECMDGOALS))
  RUN_ARG1 := $(word 1,$(RUN_ARGS))
  RUN_ARG2 := $(word 2,$(RUN_ARGS))
  ifneq ($(RUN_ARG1),)
    ifneq ($(filter %.elf,$(RUN_ARG1)),)
      ELF := $(RUN_ARG1)
    else
      BOARD := $(RUN_ARG1)
    endif
  endif
  ifneq ($(RUN_ARG2),)
    ELF := $(RUN_ARG2)
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
	@echo "  make run ELF=/path/app.elf BIT=/path/top.bit"
	@echo "  make run zcu216 /path/app.elf"
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
	@echo "  BIT=$(BIT)"
	@echo "  XSA=$(XSA)"
	@echo "  ELF=$(ELF)"
	@echo "  PSU_INIT=$(PSU_INIT)"
	@echo "  BOARD=$(BOARD)"
	@echo "  IP=$(IP) PORT=$(PORT) TIMEOUT=$(TIMEOUT)"

all: hardware firmware artifacts

check-tools:
	@command -v vivado >/dev/null || { echo "ERROR: vivado not found. Source Vivado settings first."; exit 1; }
	@command -v xsct >/dev/null || { echo "ERROR: xsct not found. Source Vitis settings first."; exit 1; }
	@command -v python3 >/dev/null || { echo "ERROR: python3 not found."; exit 1; }

chisel:
	$(MAKE) -C $(CHISEL_DIR) all

vivado-project:
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/create_project.tcl

synth: vivado-project
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_synth.tcl

impl: synth
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_impl.tcl

bitstream: impl
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/run_bitstream.tcl

xsa: bitstream
	cd $(VIVADO_DIR) && vivado -mode batch -notrace -source scripts/export_xsa.tcl

hardware:
	cd $(VIVADO_DIR) && ./build.sh --clean

hardware-clean:
	rm -rf "$(VIVADO_DIR)/work"
	rm -f "$(VIVADO_DIR)/output/$(PROJECT).bit" "$(VIVADO_DIR)/output/$(PROJECT).ltx" "$(VIVADO_DIR)/output/$(PROJECT).xsa"
	mkdir -p "$(VIVADO_DIR)/output"

firmware:
	cd $(FIRMWARE_DIR) && ./build.sh clean && ./build.sh create && ./build.sh build

firmware-create:
	cd $(FIRMWARE_DIR) && ./build.sh create

firmware-build:
	cd $(FIRMWARE_DIR) && ./build.sh build

firmware-rebuild:
	cd $(FIRMWARE_DIR) && ./build.sh clean && ./build.sh create && ./build.sh build

firmware-clean:
	cd $(FIRMWARE_DIR) && ./build.sh clean

artifacts:
	@test -f "$(BIT)" || { echo "ERROR: missing bitstream: $(BIT)"; exit 1; }
	@test -f "$(LTX)" || { echo "ERROR: missing debug probes: $(LTX)"; exit 1; }
	@test -f "$(XSA)" || { echo "ERROR: missing XSA: $(XSA)"; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF: $(ELF)"; exit 1; }
	@du -h "$(BIT)" "$(LTX)" "$(XSA)" "$(ELF)"

run program:
	@test "$(BOARD)" = "zcu216" || { echo "ERROR: unsupported BOARD=$(BOARD). Only zcu216 is configured."; exit 1; }
	@test -f "$(BIT)" || { echo "ERROR: missing BIT=$(BIT). Run make hardware first."; exit 1; }
	@test -f "$(ELF)" || { echo "ERROR: missing ELF=$(ELF). Run make firmware first."; exit 1; }
	@test -f "$(PSU_INIT)" || { echo "ERROR: missing PSU_INIT=$(PSU_INIT). Run make firmware-create first."; exit 1; }
	cd $(FIRMWARE_DIR) && xsct scripts/program.tcl "$(BIT)" "$(ELF)" "$(PSU_INIT)"

$(RUN_ARGS):
	@:

host:
	cd $(SOFTWARE_DIR) && python3 host.py --ip "$(IP)" --port "$(PORT)" --timeout "$(TIMEOUT)" --output-dir "$(HOST_OUTPUT_DIR)"

host-dry-run:
	cd $(SOFTWARE_DIR) && python3 host.py --dry-run --output-dir "$(HOST_OUTPUT_DIR)"

clean: firmware-clean hardware-clean
