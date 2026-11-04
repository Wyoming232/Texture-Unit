set -e

module load siemens/questa/2023.4

export PATH="$HOME/.local/bin:$PATH"

export PYTHONPATH="$PWD:$PWD/python:$HOME/.local/lib/python3.6/site-packages:$PYTHONPATH"

make clean

python3 --version
cocotb-config --version

TOP=${1:-"triangle_setup_wrapper"}
SRC="wrappers/${TOP}.sv"
TBIN=${2:-"triangle_stage_tb"}
TB="python.${TBIN}"

echo "------------------------------------------------"
echo "RUNNING COCOTB SIMULATION ON ${TBIN}"
echo "------------------------------------------------"

echo "Simulating with Questa"
make SIM=questa-compat COCOTB_TOPLEVEL="$TOP" VERILOG_SOURCES="$SRC" COCOTB_TEST_MODULES="${TB}"
