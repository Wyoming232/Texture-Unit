set -e

module load siemens/questa/2023.4

rm -rf work vsim.wlf sim_build results.xml

mkdir -p sim_build

TOP=${1:-"triangle_setup_tb"}
SRC="testbenches/${TOP}.sv"

echo "-------------------------------------"
echo "WAVE SIM ON ${TOP}"
echo "-------------------------------------"

vlib work
vlog -sv -work work $SRC

vsim -c -64 -voptargs="+acc" -do "log -r /*; run -all; quit" work.${TOP} #idk i copied this from the cocotb logs and eda playground LOL

echo "--------- SIM COMPLETE ---------"
echo "Running Waves..."

if [ -f "waves/${TOP}.do" ]; then
	vsim -gui -view vsim.wlf -do waves/${TOP}.do &
else
	vsim -gui -view vsim.wlf &
fi
