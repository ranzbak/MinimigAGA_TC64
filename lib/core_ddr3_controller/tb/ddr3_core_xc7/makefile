# Vendored from ultraembedded/core_ddr3_controller, commit a03492a.
# Local changes (see ../../README.md, "Flow fixes"):
#   * the controller sources are the SystemVerilog variants (.sv), so project.prj
#     is generated with a per-file language keyword (sv / verilog) instead of
#     "verilog" for everything;
#   * xvlog/xelab/xsim are invoked through $(VIVADO_PATH)/bin so the flow does not
#     depend on Vivado's settings64.sh having been sourced;
#   * the $(abspath ...) quoting bug in the project.prj rule is fixed;
#   * run.tcl is a checked-in file, so "clean" no longer deletes it.
ifeq ($(VIVADO_PATH),)
  ${error VIVADO_PATH needs to be specified (should contain /bin /data folders)}
endif

###############################################################################
# Variables:
###############################################################################
# Verilog-2001 sources
SRC_V       += ../../examples/arty_a7/artix7_pll.v
SRC_V       += ./ddr3.v
SRC_V       += ./testbench.v
SRC_V       += ../../src_v/phy/xc7/ddr3_dfi_phy.v
SRC_V       += $(VIVADO_PATH)/data/verilog/src/glbl.v

# SystemVerilog sources
SRC_SV      += ../../src_v/ddr3_dfi_seq.sv
SRC_SV      += ../../src_v/ddr3_core.sv

XELAB        = $(VIVADO_PATH)/bin/xelab
XSIM         = $(VIVADO_PATH)/bin/xsim

###############################################################################
# Rules
###############################################################################
all: run

project.prj:
	@echo "" > $@
	@$(foreach _file,$(SRC_SV),echo "sv work \"$(abspath $(_file))\"" >> $@;)
	@$(foreach _file,$(SRC_V),echo "verilog work \"$(abspath $(_file))\"" >> $@;)

elaborate: project.prj
	$(XELAB) -prj project.prj -debug typical -relax -L secureip -L unisims_ver -L unimacro_ver testbench glbl -s top_sim

run: elaborate
	$(XSIM) top_sim -t run.tcl

view:
	gtkwave waveform.vcd gtksettings.sav

clean:
	rm -rf xsim.dir xsim*.jou xsim*.backup.* xsim.log webtalk* xelab*.* top_sim.wdb project.prj *.vcd
