set -e

module load siemens/questa/2023.4

rm -rf work vsim.wlf sim_build results.xml

mkdir -p sim_build

TOP=${1:-"wrappers/triangle_dispatch_wrapper.sv"}
SRC="testbenches/${TOP}.sv"

TESTNAME=${2:-"dispatch_test"}

echo "-------------------------------------"
echo "UVM SIM ON ${TESTNAME}"
echo "-------------------------------------"

vlib work
vlog -sv -work work $SRC

vsim -c -64 -uvm -uvmcontrol=all +UVM_TESTNAME=${TESTNAME} -voptargs="+acc" -do "log -r /*; run -all; quit -f" work.${TOP}

echo "--------- SIM COMPLETE ---------"
echo "Running Waves..."

if [ -f "waves/${TOP}.do" ]; then
	vsim -gui -view vsim.wlf -do waves/${TOP}.do &
else
	vsim -gui -view vsim.wlf &
fi
