# Questa simulation targets for the implemented SystemVerilog testbenches.
# Load your site's Questa module (if needed) before running make.

ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR ?= $(ROOT)/.questa
BUILD_DIR := $(abspath $(BUILD_DIR))

VLIB ?= vlib
VLOG ?= vlog
VSIM ?= vsim
VCOVER ?= vcover
VLOG_FLAGS ?= -sv
VSIM_FLAGS ?=
SEED ?= 1
COVER_TYPES ?= bcefst

TESTS := address_calculation coalescer tag_array fragment_fifo miss_request_fifo data_array \
         reorder_buffer payload_buffer hit_path_temp

TB_address_calculation := testbenches/address_calculation_tb.sv
TB_coalescer := testbenches/coalescer_tb.sv
TB_tag_array := testbenches/tag_array_tb.sv
TB_fragment_fifo := testbenches/fragment_fifo_tb.sv
TB_miss_request_fifo := testbenches/miss_request_fifo_tb.sv
TB_data_array := testbenches/data_array_tb.sv
TB_reorder_buffer := testbenches/reorder_buffer_tb.sv
TB_payload_buffer := testbenches/payload_buffer_tb.sv
TB_hit_path_temp := testbenches/hit_path_temp.sv

TOP_address_calculation := address_calculation_tb
TOP_coalescer := coalescer_contract_tb
TOP_tag_array := tag_array_tb
TOP_fragment_fifo := fragment_fifo_tb
TOP_miss_request_fifo := miss_request_fifo_tb
TOP_data_array := data_array_tb
TOP_reorder_buffer := reorder_buffer_tb
TOP_payload_buffer := payload_buffer_tb
TOP_hit_path_temp := hit_path_temp_tb

# The other benches include their DUT source. data_array_tb does not.
EXTRA_data_array := $(ROOT)/src/data_array.sv

SOURCES := $(wildcard $(ROOT)/packages/*.sv $(ROOT)/interfaces/*.sv \
             $(ROOT)/interfaces/*.vh $(ROOT)/src/*.sv $(ROOT)/testbenches/*.sv)

.DEFAULT_GOAL := help
.PHONY: help list check all clean
.SECONDARY:

help:
	@echo 'Questa targets (run from the Texture-Unit directory):'
	@echo '  make <test>.sim      compile and run one bench in batch mode'
	@echo '  make <test>.wav      run with full WLF logging, then open Wave GUI'
	@echo '  make <test>.cov      run code coverage, save UCDB and HTML report'
	@echo '  make <test>.compile  compile only'
	@echo '  make check           run all implemented benches'
	@echo '  make list            show supported test names and top modules'
	@echo '  make clean           remove generated .questa files'
	@echo 'Options: SEED=<integer>, BUILD_DIR=<path>, VLOG_FLAGS=..., VSIM_FLAGS=...'
	@echo 'hit_path_temp is the end-to-end bench (TMU model + out-of-order memory model).'

list:
	@$(foreach test,$(TESTS),echo '$(test) -> $(TOP_$(test)) ($(TB_$(test)))';)

all check: $(addsuffix .sim,$(TESTS))

# One library per bench prevents a test's included RTL/interfaces from
# redefining modules in another test. The package is compiled first; the
# include guard then prevents its in-source includes from redeclaring it.
$(BUILD_DIR)/%/.compiled: $(SOURCES) $(ROOT)/Makefile
	$(if $(filter $*,$(TESTS)),,$(error Unknown test '$*'; run make list))
	@mkdir -p "$(@D)"
	@cd "$(@D)" && $(VLIB) work && \
	  $(VLOG) $(VLOG_FLAGS) -work work -l package.log +incdir+"$(ROOT)" \
	    "$(ROOT)/packages/cache_pkg.sv" && \
	  $(VLOG) $(VLOG_FLAGS) -work work -l compile.log +incdir+"$(ROOT)" \
	    +define+CACHE_PKG_SV $(EXTRA_$*) "$(ROOT)/$(TB_$*)"
	@touch "$@"

%.compile: $(BUILD_DIR)/%/.compiled
	@echo 'Compiled $* in $(BUILD_DIR)/$*'

%.sim: $(BUILD_DIR)/%/.compiled
	@cd "$(BUILD_DIR)/$*" && $(VSIM) -c $(VSIM_FLAGS) -sv_seed $(SEED) \
	  -l sim.log -do 'onerror {quit -code 1}; onbreak {quit -code 2}; run -all; quit -code 0' \
	  work.$(TOP_$*)

%.wav: $(BUILD_DIR)/%/.compiled
	@cd "$(BUILD_DIR)/$*" && $(VSIM) -c $(VSIM_FLAGS) -sv_seed $(SEED) \
	  -voptargs=+acc -wlf waves.wlf -l waves.log \
	  -do 'onerror {quit -code 1}; onbreak {quit -code 2}; log -r /*; run -all; quit -code 0' \
	  work.$(TOP_$*)
	@cd "$(BUILD_DIR)/$*" && $(VSIM) -gui -view waves.wlf \
	  -do 'do "$(ROOT)/waves/$*_wave.do"'

# Coverage uses its own instrumented library so ordinary runs stay fast.
$(BUILD_DIR)/%/.covered: $(SOURCES) $(ROOT)/Makefile
	$(if $(filter $*,$(TESTS)),,$(error Unknown test '$*'; run make list))
	@mkdir -p "$(BUILD_DIR)/$*/coverage"
	@cd "$(BUILD_DIR)/$*/coverage" && $(VLIB) work && \
	  $(VLOG) $(VLOG_FLAGS) +cover=$(COVER_TYPES) -work work -l package.log \
	    +incdir+"$(ROOT)" "$(ROOT)/packages/cache_pkg.sv" && \
	  $(VLOG) $(VLOG_FLAGS) +cover=$(COVER_TYPES) -work work -l compile.log \
	    +incdir+"$(ROOT)" +define+CACHE_PKG_SV \
	    $(EXTRA_$*) "$(ROOT)/$(TB_$*)"
	@touch "$@"

%.cov: $(BUILD_DIR)/%/.covered
	@cd "$(BUILD_DIR)/$*/coverage" && $(VSIM) -c -coverage $(VSIM_FLAGS) \
	  -sv_seed $(SEED) -l coverage.log \
	  -do 'onerror {quit -code 1}; onbreak {quit -code 2}; coverage save -onexit coverage.ucdb; run -all; quit -code 0' \
	  work.$(TOP_$*)
	@cd "$(BUILD_DIR)/$*/coverage" && $(VCOVER) report -html coverage.ucdb
	@echo 'Coverage report: $(BUILD_DIR)/$*/coverage/covhtmlreport/index.html'

clean:
	rm -rf "$(BUILD_DIR)"
