# L3 card images (sim/l3/README.md "Cards"): reproducible FAT16 SD cards for
# the co-simulation scenarios, from generators (sim/l3/gen) and the two
# firmwares, which are inputs.
#
#   make -C sim/l3/card <card> FWRV=<RV32OSDA.BIN> FW832=<832OSDAD.BIN>
#   make -C sim/l3/card cards  ...             all cards
#   make -C sim/l3/card check  ...             reproducibility + content proof
#   make -C sim/l3/card manifest               rewrite manifest.txt
#   make -C sim/l3/card list                   card name and the files on it
#
# Cards (32 MB each; boot = both firmwares, MINMGAR.CFG + MINMGAA.CFG, KICK.ROM):
#   boot        boot
#   boot832cfg  both firmwares, only MINMGAA.CFG (the first-boot conversion), KICK.ROM
#   fdd         boot + TEST.ADF + DRIVESND.BIN
#   hdd         boot + SYNTH.HDF + RDB.HDF
#   cd          boot + TEST.CUE, TEST.BIN, TEST.ISO; CDCFG=cue (default) or iso
#               (iso: the configs name TEST.ISO, the image is cd_iso.img)
#   cdhdd       boot + SYNTH.HDF + RDB.HDF + TEST.CUE, TEST.BIN (CDCFG=cue)
# Variables:
#   B       output directory, default build (relative to this directory)
#   FWRV    RV32OSDA.BIN, default fw/ctrl_rv/build/RV32OSDA.BIN (make -C fw/ctrl_rv)
#   FW832   832OSDAD.BIN, default a stand-in (gen/mkblob.py, 86,016 bytes)
#   A relative FWRV / FW832 is taken from this directory if it exists there,
#   else from the repository root.
#   SOURCE_DATE_EPOCH  file times on the card (default 2026-01-01 00:00 UTC)
# Output in $(B): content/ (generated files), cfg_cue/ cfg_iso/ (MINMGAA.CFG,
# MINMGAA.check, MINMGAR.CFG), fw/ (the firmware copies under their card
# names), <card>.img, cfgconv.
TOP    := $(abspath $(CURDIR)/../../..)
B      ?= build
BA     := $(abspath $(B))
GEN    := $(TOP)/sim/l3/gen
MKCARD := $(TOP)/tools/sim/mkcard.sh
CFGDIR := $(TOP)/fw/ctrl_rv/tools/cfgconv
DRIVESND := $(TOP)/sw/mkdrivesounds/drivesnd.bin
CARDMB := 32
CDCFG  ?= cue
PY     := python3 -I
export SOURCE_DATE_EPOCH ?= 1767225600

resolve = $(if $(filter /%,$(1)),$(1),$(if $(wildcard $(1)),$(abspath $(1)),$(TOP)/$(1)))
FWRV    ?= fw/ctrl_rv/build/RV32OSDA.BIN
FWRV_A  := $(call resolve,$(FWRV))
ifdef FW832
FW832_A := $(call resolve,$(FW832))
else
FW832_A := $(BA)/standin/832OSDAD.BIN
endif

CARDS  := boot boot832cfg fdd hdd cd cdhdd
CFGCD_cd := $(CDCFG)
img_cd = $(BA)/cd$(if $(filter iso,$(CDCFG)),_iso).img

FWS      := RV32OSDA.BIN 832OSDAD.BIN
names_boot       := $(FWS) MINMGAR.CFG MINMGAA.CFG KICK.ROM
names_boot832cfg := $(FWS) MINMGAA.CFG KICK.ROM
names_fdd        := $(names_boot) TEST.ADF DRIVESND.BIN
names_hdd        := $(names_boot) SYNTH.HDF RDB.HDF
names_cd         := $(names_boot) TEST.CUE TEST.BIN TEST.ISO
names_cdhdd      := $(names_boot) SYNTH.HDF RDB.HDF TEST.CUE TEST.BIN

# where each name comes from, for a card whose configs are in $(1)
src_RV32OSDA.BIN = $(BA)/fw/RV32OSDA.BIN
src_832OSDAD.BIN = $(BA)/fw/832OSDAD.BIN
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

.PHONY: all cards $(CARDS) check manifest list clean
all cards: $(CARDS)

# $(1) card, $(2) config variant, $(3) image
define CARD
$(1): $(call files,$(1),$(2)) | $(BA)
	$(MKCARD) $(3) $(CARDMB) $(call files,$(1),$(2))
endef
$(eval $(call CARD,boot,cue,$(BA)/boot.img))
$(eval $(call CARD,boot832cfg,cue,$(BA)/boot832cfg.img))
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

# ---- configs: the 832 file from the field table, the RV file by cfgconv ----
$(BA)/cfgconv: $(CFGDIR)/cfgconv.c $(CFGDIR)/Makefile
	$(MAKE) -C $(CFGDIR) B=$(BA)
$(BA)/cfg_%/MINMGAA.CFG: $(GEN)/mkcfg.py $(TOP)/fw/ctrl_rv/test/gold/mkcfg832.py
	$(PY) $< $(@D) $*
$(BA)/cfg_%/MINMGAA.check: $(BA)/cfg_%/MINMGAA.CFG ;
$(BA)/cfg_%/MINMGAR.CFG: $(BA)/cfg_%/MINMGAA.CFG $(BA)/cfgconv
	$(BA)/cfgconv --to-rv $< $@

# ---- firmware inputs under their card names ----
$(BA)/fw/RV32OSDA.BIN: $(FWRV_A) | $(BA)/fw
	cp $< $@
$(BA)/fw/832OSDAD.BIN: $(FW832_A) | $(BA)/fw
	cp $< $@
$(BA)/standin/832OSDAD.BIN: $(GEN)/mkblob.py | $(BA)/standin
	$(PY) $< $@ 86016 STANDIN-832OSDAD
$(BA)/standin/RV32OSDA.BIN: $(GEN)/mkblob.py | $(BA)/standin
	$(PY) $< $@ 94208 STANDIN-RV32OSDA

# ---- proof and manifest ----
list:
	@$(foreach c,$(CARDS),echo "$(c) $(names_$(c))";)

# manifest.txt: the generated files and the images built with stand-in
# firmware (so it does not change with a firmware build)
manifest:
	$(MAKE) B=$(BA)/manifest FWRV=$(BA)/manifest/standin/RV32OSDA.BIN FW832= cards CDCFG=cue
	$(MAKE) B=$(BA)/manifest FWRV=$(BA)/manifest/standin/RV32OSDA.BIN FW832= cd CDCFG=iso
	$(CURDIR)/manifest.sh $(BA)/manifest > manifest.txt

check:
	$(CURDIR)/check.sh "$(MAKE)" "$(BA)" "$(FWRV_A)" "$(FW832_A)"

clean:
	@echo "remove $(BA) by hand"
