TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES ?= wrappers/triangle_setup_wrapper.sv

COCOTB_TOPLEVEL ?= triangle_setup_wrapper

COCOTB_TEST_MODULES ?= python.triangle_stage_tb

ifeq (,$(filter setup setup_all,$(MAKECMDGOALS)))
  include $(shell PATH=$(HOME)/.local/bin:$$PATH cocotb-config --makefiles)/Makefile.sim
endif

.PHONY: setup, setup_all

clean:: #the :: will append whatever under the cocotb clean from include. Just do both together why not.
	@rm -rf work vsim.wlf transcript
	@echo "--------Cleaned Directory--------"

setup:
	@mkdir python
	@echo "--------Added python Directory--------"
	@mkdir wrappers
	@echo "--------Added wrappers Directory--------"
	@mkdir testbenches
	@echo "--------Added testbenches Directory--------"

	@pip3 install --user cocotb
	@chmod +x run.bash
	@chmod +x run_waves.bash

	@echo "--------Setup Complete--------"

setup_all:
	@mkdir interfaces
	@mkdir packages
	@mkdir python
	@mkdir testbenches
	@mkdir waves
	@mkdir wrappers

	@pip3 install --user cocotb
	@chmod +x run.bash
	@chmod +x run_waves.bash

	@echo "--------Full Setup Complete--------"