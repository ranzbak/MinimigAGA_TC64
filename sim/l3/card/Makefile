# L3 card images (sim/l3/README.md "Cards"): reproducible FAT16 SD cards for
# the co-simulation scenarios, from generators (sim/l3/gen) and the
# firmware, which is an input.
#
#   make -C sim/l3/card <card> FWRV=<firmware image>
#   make -C sim/l3/card cards  ...             all cards
#   make -C sim/l3/card check  ...             reproducibility + content proof
#   make -C sim/l3/card manifest               rewrite manifest.txt
#   make -C sim/l3/card list                   card name and the files on it
#   make -C sim/l3/card fwname                 the firmware's card name
#
# The firmware goes on the card as RV32OSDB.BIN, FW_FILE of
# fw/ctrl/fwname.mk (the name the boot ROM looks for).
# Cards (32 MB each; boot = RV32OSDB.BIN, MINMGAR.CFG + MINMGAA.CFG, KICK.ROM;
# MINMGAA.CFG is the previous firmware's big-endian config, which the RV
# firmware converts when its own MINMGAR.CFG is missing):
#   boot        boot
#   bootbecfg   RV32OSDB.BIN, only MINMGAA.CFG (the first-boot conversion), KICK.ROM
#   fdd         boot + TEST.ADF + DRIVESND.BIN
#   hdd         boot + SYNTH.HDF + RDB.HDF
#   cd          boot + TEST.CUE, TEST.BIN, TEST.ISO; CDCFG=cue (default) or iso
#               (iso: the configs name TEST.ISO, the image is cd_iso.img)
#   cdhdd       boot + SYNTH.HDF + RDB.HDF + TEST.CUE, TEST.BIN (CDCFG=cue)
# Variables:
#   B       output directory, default build (relative to this directory)
#   FWRV    the firmware image, default fw/ctrl/build/RV32OSDB.BIN (make -C fw/ctrl)
#   A relative FWRV is taken from this directory if it exists there, else
#   from the repository root.
#   SOURCE_DATE_EPOCH  file times on the card (default 2026-01-01 00:00 UTC)
#   NOKICK  1: the boot card without KICK.ROM (sim/l3 run.sh's negative
#           boot run; use its own B, the image name is boot.img all the same)
# Output in $(B): content/ (generated files), cfg_cue/ cfg_iso/ (MINMGAA.CFG,
# MINMGAA.check, MINMGAR.CFG), fw/ (the firmware copies under their card
# names), <card>.img, cfgconv.
TOP    := $(abspath $(CURDIR)/../../..)
B      ?= build
BA     := $(abspath $(B))
GEN    := $(TOP)/sim/l3/gen
MKCARD := $(TOP)/tools/sim/mkcard.sh
CFGDIR := $(TOP)/fw/ctrl/tools/cfgconv
DRIVESND := $(TOP)/sw/mkdrivesounds/drivesnd.bin
CARDMB := 32
CDCFG  ?= cue
PY     := python3 -I
export SOURCE_DATE_EPOCH ?= 1767225600
# FW_FILE: the firmware's name, on the card and of fw/ctrl's build output
include $(TOP)/fw/ctrl/fwname.mk

resolve = $(if $(filter /%,$(1)),$(1),$(if $(wildcard $(1)),$(abspath $(1)),$(TOP)/$(1)))
FWRV    ?= fw/ctrl/build/$(FW_FILE)
FWRV_A  := $(call resolve,$(FWRV))

CARDS  := boot bootbecfg fdd hdd cd cdhdd
CFGCD_cd := $(CDCFG)
img_cd = $(BA)/cd$(if $(filter iso,$(CDCFG)),_iso).img

FWS      := $(FW_FILE)
names_base       := $(FWS) MINMGAR.CFG MINMGAA.CFG KICK.ROM
names_boot       := $(if $(filter 1,$(NOKICK)),$(filter-out KICK.ROM,$(names_base)),$(names_base))
names_bootbecfg  := $(FWS) MINMGAA.CFG KICK.ROM
names_fdd        := $(names_base) TEST.ADF DRIVESND.BIN
names_hdd        := $(names_base) SYNTH.HDF RDB.HDF
names_cd         := $(names_base) TEST.CUE TEST.BIN TEST.ISO
names_cdhdd      := $(names_base) SYNTH.HDF RDB.HDF TEST.CUE TEST.BIN

# where each name comes from, for a card whose configs are in $(1)
src_$(FW_FILE) = $(BA)/fw/$(FW_FILE)
src_KICK.ROM     = $(BA)/content/KICK.ROM
src_TEST.ADF     = $(BA)/content/TEST.ADF
src_SYNTH.HDF    = $(BA)/content/SYNTH.HDF
src_RDB.HDF      = $(BA)/content/RDB.HDF
src_TEST.CUE     = $(BA)/content/TEST.CUE
src_TEST.BIN     = $(BA)/content/TEST.BIN
src_TEST.ISO     = $(BA)/content/TEST.ISO
src_DRIVESND.BIN = $(BA)/content/DRIVESND.BIN
src_MINMGAA.CFG  = $(BA)/cfg_$(1)/MINMGAA.CFG
src_MINMGAR.CFG  = $(BA)/cfg_$(1)/MINMGAR.CFG
files = $(foreach n,$(names_$(1)),$(call src_$(n),$(2)))

.PHONY: all cards $(CARDS) check manifest list fwname clean
all cards: $(CARDS)

# $(1) card, $(2) config variant, $(3) image
define CARD
$(1): $(call files,$(1),$(2)) | $(BA)
	$(MKCARD) $(3) $(CARDMB) $(call files,$(1),$(2))
endef
$(eval $(call CARD,boot,cue,$(BA)/boot.img))
$(eval $(call CARD,bootbecfg,cue,$(BA)/bootbecfg.img))
$(eval $(call CARD,fdd,cue,$(BA)/fdd.img))
$(eval $(call CARD,hdd,cue,$(BA)/hdd.img))
$(eval $(call CARD,cd,$(CDCFG),$(img_cd)))
$(eval $(call CARD,cdhdd,cue,$(BA)/cdhdd.img))

$(BA) $(BA)/content $(BA)/fw $(BA)/standin:
	mkdir -p $@

# ---- content ----
$(BA)/content/KICK.ROM: $(GEN)/mkkick.py | $(BA)/content
	$(PY) $< $@
$(BA)/content/TEST.ADF: $(GEN)/mkadf.py | $(BA)/content
	$(PY) $< $@
$(BA)/content/SYNTH.HDF $(BA)/content/RDB.HDF: $(BA)/content/.hdf
$(BA)/content/.hdf: $(GEN)/mkhdf.py | $(BA)/content
	$(PY) $< $(BA)/content
	touch $@
$(BA)/content/TEST.CUE $(BA)/content/TEST.BIN: $(BA)/content/.cue
$(BA)/content/.cue: $(GEN)/mkcue.py | $(BA)/content
	$(PY) $< $(BA)/content
	touch $@
$(BA)/content/TEST.ISO: $(GEN)/mkiso.sh | $(BA)/content
	$< $(BA)/content
$(BA)/content/DRIVESND.BIN: $(DRIVESND) | $(BA)/content
	cp $< $@

# ---- configs: the previous firmware's (BE) file from the field table, the RV file by cfgconv ----
$(BA)/cfgconv: $(CFGDIR)/cfgconv.c $(CFGDIR)/Makefile
	$(MAKE) -C $(CFGDIR) B=$(BA)
$(BA)/cfg_%/MINMGAA.CFG: $(GEN)/mkcfg.py $(TOP)/fw/ctrl/test/gold/mkcfgbe.py
	$(PY) $< $(@D) $*
$(BA)/cfg_%/MINMGAA.check: $(BA)/cfg_%/MINMGAA.CFG ;
$(BA)/cfg_%/MINMGAR.CFG: $(BA)/cfg_%/MINMGAA.CFG $(BA)/cfgconv
	$(BA)/cfgconv --to-rv $< $@

# ---- firmware input under its card name ----
$(BA)/fw/$(FW_FILE): $(FWRV_A) | $(BA)/fw
	cp $< $@
# the stand-in's content seed keeps its old text (its bytes, and so its
# manifest line's size and sha256, do not depend on the name)
$(BA)/standin/$(FW_FILE): $(GEN)/mkblob.py | $(BA)/standin
	$(PY) $< $@ 94208 STANDIN-RV32OSDA

# ---- proof and manifest ----
list:
	@$(foreach c,$(CARDS),echo "$(c) $(names_$(c))";)
fwname:
	@echo $(FW_FILE)

# manifest.txt: the generated files and the images built with stand-in
# firmware (so it does not change with a firmware build)
manifest:
	$(MAKE) B=$(BA)/manifest FWRV=$(BA)/manifest/standin/$(FW_FILE) cards CDCFG=cue
	$(MAKE) B=$(BA)/manifest FWRV=$(BA)/manifest/standin/$(FW_FILE) cd CDCFG=iso
	$(CURDIR)/manifest.sh $(BA)/manifest $(FW_FILE) > manifest.txt

check:
	$(CURDIR)/check.sh "$(MAKE)" "$(BA)" "$(FWRV_A)"

clean:
	@echo "remove $(BA) by hand"
