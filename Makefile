### Makefile for the nand_phy project
### Generated by Bluespec Workstation on Tue Jul 15 01:50:13 EDT 2014

#FPGA_FLAGS = -D FPGA_TARGET
#NAND_FLAGS = -D SLC_NAND
NAND_FLAGS =
FPGA_FLAGS = 
SIM_FLAGS = -D NAND_SIM
BSC_FLAGS = -keep-fires -aggressive-conditions
TOP_MODULE = mkTopTB
TOP_PATH = src/TopTB.bsv

default: full_clean compile

sim: full_clean compile_sim

.PHONY: compile
compile:
	@echo Compiling...
	bsc -u -verilog -elab -vdir verilog -bdir bscOut -info-dir bscOut $(BSC_FLAGS) $(FPGA_FLAGS) $(NAND_FLAGS) -p .:%/Prelude:%/Libraries:%/Libraries/BlueNoC:%/BSVSource/Xilinx:./src:./src/ECC/src_bsv -g $(TOP_MODULE)  $(TOP_PATH)
	@echo Compilation finished

.PHONY: compile_sim
compile_sim:
	@echo Compiling SIMULATION ONLY...
	bsc -u -verilog -elab -vdir verilog -bdir bscOut -info-dir bscOut $(BSC_FLAGS) $(SIM_FLAGS) $(NAND_FLAGS) -p .:%/Prelude:%/Libraries:%/Libraries/BlueNoC:%/BSVSource/Xilinx:./src:./src/ECC/src_bsv -g $(TOP_MODULE)  $(TOP_PATH)
	@echo Compilation SIMULATION ONLY finished

.PHONY: clean
clean:
	exec rm -f bscOut/*

.PHONY: full_clean
full_clean:
	rm -f bscOut/*
	rm -f verilog/*
