# MINIMIG-MIST
# top makefile
# 2015, rok.krajnc@gmail.com
# 2020, AMR

### boards ###
BOARDS?=mist chameleonv1 chameleonv2 de10_lite de0_nano

### release ###
RELEASE?=minimig-mist-test

### paths ###
REL_DIR      = rel
FW_DIR       = fw
FPGA_DIR     = fpga
FW_SRC_DIR   = $(FW_DIR)
FPGA_SRC_DIR = $(FPGA_DIR)

# all
all: dirs
	@echo Building all ...
	@make fw
	@make fpga
	@echo DONE building all!

# directories
dirs: Makefile
	@echo Creating release dirs $(REL_DIR)/$(RELEASE) ...
	@mkdir -p $(REL_DIR)

# fw
fw: Makefile dirs
	@echo Building firmware in $(FW_SRC_DIR) ...
	@$(MAKE) -C $(FW_SRC_DIR) $(BUILD_OPT)


# fpga
fpga: Makefile dirs
	cd rtl/minimig; \
	quartus_sh -t ../../tcl/build_id.tcl
	@for BOARD in ${BOARDS}; do \
		echo "Building $(FPGA_SRC_DIR)/$$BOARD ..."; \
		make -C fpga/$$BOARD; \
	done
	@for BOARD in ${BOARDS}; do \
		grep Design-wide\ TNS fpga/$$BOARD/*.sta.rpt;\
	done
#	@$(MAKE) -C $(FPGA_SRC_DIR) $(BUILD_OPT)
#	@cp $(FPGA_BIN_FILES) $(FPGA_REL_DIR)/


# clean
clean:
	@echo Clearing release dir ...
	@$(MAKE) -C $(FW_SRC_DIR) clean
	@$(MAKE) -C $(FPGA_SRC_DIR) clean

