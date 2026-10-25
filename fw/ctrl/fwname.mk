# The OSD firmware's file name: the one place it is written.
#
# fw/ctrl/Makefile builds $(FW_FILE) (with the 'SDCV' lock-step trailer);
# the boot ROM (fw/ctrl_boot/Makefile, -DOSDNAME) looks for $(FW_83) in the
# card's root directory; the sims (sim/host_bridge, sim/l3) and their card
# builders read it from here (make include, or sim/common/hostsim.sh
# hs_fwname).  `make -C fw/ctrl check` (i) checks that the committed boot
# ROM image looks for this name.
#
# RV32OSDB: the boot ROM on the SD card peripheral and its firmware (SD card
# engine, Task 13b).  The earlier chain (the card on cfide's SPI, no
# trailer) loads RV32OSDA.BIN; with different names both firmwares can sit
# on the same card and each bitstream boots its own.
FW_NAME := RV32OSDB
FW_EXT  := BIN
# the file name on the card and of the build output: RV32OSDB.BIN
FW_FILE := $(FW_NAME).$(FW_EXT)
# the 8.3 directory entry the boot ROM compares (name padded to 8, extension
# to 3; both are full here): RV32OSDBBIN
FW_83   := $(FW_NAME)$(FW_EXT)
