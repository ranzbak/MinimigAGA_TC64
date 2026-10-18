# L3 co-simulation bench

Work in progress (Phase 4 of the OSD host CPU migration). This file grows
with the bench; so far it has the section "Cards".

## Cards

`sim/l3/card` builds the SD card images the L3 scenarios boot, and
`sim/l3/gen` holds the generators of everything on them. Nothing on a card is
copyrighted: the kickstart is a synthetic 256 KB file, the drive sounds file
is the project's own (`sw/mkdrivesounds/drivesnd.bin`). Images are built,
never committed; `sim/l3/card/manifest.txt` lists name, size and sha256 of
every generated file and image, so a generator change shows in review.

Setup on a fresh Ubuntu 24.04, bash or zsh, from the repository root:

```sh
sudo apt install build-essential make python3 mtools dosfstools fdisk xorriso ghdl verilator ccache iverilog
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl_rv
```

The cards need `fw/ctrl_rv/build/RV32OSDA.BIN` (the last line) and,
for the 832 twin, `832OSDAD.BIN`. Until the 832 firmware is built (Task 6)
leave `FW832` out: a deterministic 84 KB stand-in takes its place.

Build the cards and run the proof (one minute; output in
`sim/l3/card/build/`, `B=<dir>` puts it elsewhere):

```sh
make -C sim/l3/card cards FWRV=fw/ctrl_rv/build/RV32OSDA.BIN
make -C sim/l3/card check FWRV=fw/ctrl_rv/build/RV32OSDA.BIN
```

`check` builds every card twice, two seconds apart, in two directories and
compares the bytes; runs `fsck.fat -n` on each image; lists each root
directory with `mdir` against the names the card should hold; reads the config
files back from the images and compares `cfgconv --check` with the field
table `gen/mkcfg.py` was given; prints the CHS of `SYNTH.HDF` and requires
more than 255 cylinders; and compares `manifest.txt` with a fresh stand-in
build. It ends with `check PASS`. The bytes of `TEST.ISO` depend on the xorriso version (the committed manifest was made with 1.5.6): on another version `check` can fail with "manifest.txt is stale", and `make -C sim/l3/card manifest` regenerates it. After a change to a generator,
`make -C sim/l3/card manifest` rewrites `manifest.txt`.

One card, with real firmware files (the 832 one from your own build):

```sh
make -C sim/l3/card hdd FWRV=fw/ctrl_rv/build/RV32OSDA.BIN FW832=path/to/832OSDAD.BIN
mdir -i sim/l3/card/build/hdd.img@@1048576 ::
```

| Card | Files (all cards also hold both firmwares and `KICK.ROM`) |
|---|---|
| `boot` | `MINMGAR.CFG` (RISC-V, little-endian), `MINMGAA.CFG` (832, big-endian) |
| `boot832cfg` | only `MINMGAA.CFG`: the RISC-V first-boot conversion path |
| `fdd` | boot + `TEST.ADF`, `DRIVESND.BIN` |
| `hdd` | boot + `SYNTH.HDF`, `RDB.HDF` |
| `cd` | boot + `TEST.CUE`, `TEST.BIN`, `TEST.ISO`; `CDCFG=iso` (image `cd_iso.img`) names `TEST.ISO` in the configs instead of `TEST.CUE` |
| `cdhdd` | boot + both HDFs + `TEST.CUE`, `TEST.BIN` |

All cards are 32 MB, FAT16 at LBA 2048 (`tools/sim/mkcard.sh`), file times
from `SOURCE_DATE_EPOCH` (default 2026-01-01 00:00 UTC).

Content (`sim/l3/gen`, python3 stdlib run with `-I`, plus `xorriso`):

| File | Generator | Content |
|---|---|---|
| `KICK.ROM` | `mkkick.py` | 262,144 bytes; word i = `0x4B490000` + i, big-endian; ASCII `L3 SYNTHETIC KICKSTART` at 0x18 |
| `TEST.ADF` | `mkadf.py` | 901,120 bytes; sector s (LBA) tagged `L` `B` s>>8 s&0xff, then the pattern of `fw/ctrl_rv/test/gold/mfm.py` |
| `SYNTH.HDF` | `mkhdf.py` | 4 MB, no RDB (the firmware synthesises one); CHS 257.1.32 (`mkhdf.py --chs SYNTH.HDF`); block n tagged `H` 2 n>>8 n&0xff |
| `RDB.HDF` | `mkhdf.py` | 2 MB, own RDSK at block 0 with `rdb_Flags` 0x17 (not 0x12) and a PART at block 1; other blocks tagged `H` 1 n>>8 n&0xff |
| `TEST.ISO` | `mkiso.sh` | one file `DATA.BIN`, 256 KB, block n of 2048 bytes tagged `L` `B` n>>8 n&0xff |
| `TEST.BIN`, `TEST.CUE` | `mkcue.py` | 364 raw sectors: 64 MODE1/2352 data, then two AUDIO tracks of 2 s; track 2 has the 2 s PREGAP; audio frame f (from track 2) is left `f & 0xFFFF`, right `~f & 0xFFFF` |
| `MINMGAA.CFG`, `MINMGAR.CFG` | `mkcfg.py`, `cfgconv --to-rv` | 212 bytes: kickstart `KICK`, IDE on, one floppy at normal speed, hardfile 0 = `RDB` (plain file, own RDB: unit 0, so the firmware patches its `rdb_Flags`), hardfile 1 = `SYNTH` (synthesised RDB), IDE port 2 master = CD with `TEST` (CUE or ISO), the rest the 832 defaults |

Disc map of `TEST.CUE`: LBA 0..63 data, 64..213 silent pregap of track 2,
214..363 track 2, 364..513 track 3, lead-out 514.
