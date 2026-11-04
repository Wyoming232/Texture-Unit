----------- HOW TO USE -----------

Step 0:
  MAKE SURE YOU SSH WITH THE -X FLAG FOR GUI WAVES!!! Eg: ssh -X asicfab
  Copy these files into the directory where you intend to work on your project.

Step 1:
Run make setup or make setup_all \
  make setup: 
    sets up only what you need (python, testbenches, wrappers directories)  

  make setup_all:
    setups up every directory to test spec (recommended if you dont already have existing directories)  
    
That's actually it...  

2 OPTIONS FOR RUNNING SIM:
  run_waves.bash:
    your standard simulate and open questa waves.  

    run as follows: ./run_waves.bash module_name_tb

    This sets the module name to whatever you put as an argument and sets the source file to testbenches/module_name_tb.sv so make sure the tb file is in testbenches directory!!

  run.bash:
    this is the more involved cocotb testbench. your cocotb testbench should be in the python directory. the wrapper for the testbench should be in the wrappers directory.  

    run as follows: ./run.bash example_wrapper example_stage_tb
    
    This sets the wrapper to the file name you mentioned in the first argument (you dont need to put .sv or anything.) It also sets the cocotb file to the second argument! Remember the cocotb file should be in the python directory or it wont work.