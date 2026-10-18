# cfgconv: Minimig config files, 832 <-> RISC-V byte order

The OSD firmware keeps its settings in a 212-byte config file in the root of
the SD card. The 832 firmware (`fw/ctrl_832`) writes it big-endian as
`MINMGAA.CFG` (the default slot) and `MINMGAA1.CFG` .. `MINMGAA4.CFG`; the
RISC-V firmware (`fw/ctrl_rv`) writes it little-endian as `MINMGAR.CFG` and
`MINMGAR1.CFG` .. `MINMGAR4.CFG`. Same layout (`configTYPE` in
`fw/ctrl_rv/config.h`, `CONFIG_VERSION 4`, id `MNMGCFGA`); only the seven
32-bit fields differ in byte order: `version` (offset 8), `kickdir` (132),
`extromdir` (136), `hdfdir[0..3]` (140, 144, 148, 152). The byte order is
told by `version`: 1..4 read little-endian is RISC-V, 1..4 read big-endian is
832. The swap is `fw/ctrl_rv/cfgswap.c`, the same code the firmware runs.

One card serves both bitstreams. The RISC-V firmware converts on its own:
when a slot has no `MINMGAR*` file but has the 832 one, its first load of
that slot reads the 832 file, converts it in memory and saves it as the
`MINMGAR*` file (boot line `Converted 832 configuration MINMGAA.CFG`). The
832 file is never written. From then on each firmware has its own file, and
a change made under one does not reach the other. `cfgconv` is for the rest:
carrying RISC-V settings back to the 832 file, converting ahead of time, and
looking at a file. An 832 file put under the RISC-V name is rejected by the
firmware ("Wrong configuration file format!", "(832 byte order)"), which then
uses its defaults.

## Usage

```
cfgconv --to-rv  <in> <out>   832 file -> RISC-V file
cfgconv --to-832 <in> <out>   RISC-V file -> 832 file
cfgconv --check  <in>         print the byte order and every field, "name = value"
```

Exit 0 on success. Refused with exit 1 and nothing written: a file that is
not a config file (length outside 156..212 bytes, another id, or a `version`
that is 1..4 in neither order), a file that is already in the target order,
and an output path that is the input (also through another spelling or a
hard link). Usage errors exit 2. An existing output file other than the input
is overwritten. A file shorter than 212 bytes (older firmware wrote 208 before
the audio and video position fields) keeps its length; it needs at least 156
bytes, the end of `hdfdir[3]`.

## Build (fresh Ubuntu 24.04, bash or zsh, from the repository root)

```sh
sudo apt install build-essential mtools fdisk
make -C fw/ctrl_rv/tools/cfgconv              # -> fw/ctrl_rv/tools/cfgconv/cfgconv
fw/ctrl_rv/tools/cfgconv/cfgconv --check fw/ctrl_rv/tools/cfgconv/README.md   # refused: not a config file
```

No RISC-V toolchain is needed. `make -C fw/ctrl_rv/tools/cfgconv B=<dir>`
puts the binary into `<dir>`.

## Examples

The commands work in bash and zsh. `C` is the binary built above.

### A card image file

`card.img` is a raw image of the whole SD card (e.g. `sudo dd
if=/dev/sdX of=card.img bs=1M status=progress`, or one made by
`tools/sim/mkcard.sh`). mtools reaches the FAT partition at its byte offset:

```sh
C=$PWD/fw/ctrl_rv/tools/cfgconv/cfgconv
export MTOOLS_SKIP_CHECK=1
start=$(sfdisk -d card.img | sed -n 's/^.*start= *\([0-9]*\),.*$/\1/p' | head -n 1)
off=$((start * 512))
mdir -i "card.img@@$off" ::                              # the MINMGAA*.CFG / MINMGAR*.CFG files
mcopy -n -i "card.img@@$off" ::MINMGAA.CFG ./MINMGAA.CFG  # copy the 832 file off the card
"$C" --check MINMGAA.CFG                                  # order = 832, then every field
"$C" --to-rv MINMGAA.CFG MINMGAR.CFG                      # convert
mcopy -o -i "card.img@@$off" MINMGAR.CFG ::MINMGAR.CFG    # copy the RISC-V file back (-o: overwrite)
```

Write the image back to the card afterwards (`sudo dd if=card.img
of=/dev/sdX bs=1M conv=fsync status=progress`), or work on the card itself:

### The SD card itself

With the card's FAT partition at `/dev/sdX1` (check with `lsblk`; not
mounted, or unmount it first with `udisksctl unmount -b /dev/sdX1`):

```sh
C=$PWD/fw/ctrl_rv/tools/cfgconv/cfgconv
sudo env MTOOLS_SKIP_CHECK=1 mcopy -n -i /dev/sdX1 ::MINMGAA.CFG ./MINMGAA.CFG
sudo chown "$USER" MINMGAA.CFG
"$C" --to-rv MINMGAA.CFG MINMGAR.CFG
sudo env MTOOLS_SKIP_CHECK=1 mcopy -o -i /dev/sdX1 MINMGAR.CFG ::MINMGAR.CFG
```

A desktop that mounts the card (e.g. at `/media/$USER/MINIMIG`) works with
plain `cp` as well: `"$C" --to-rv "/media/$USER/MINIMIG/MINMGAA.CFG"
"/media/$USER/MINIMIG/MINMGAR.CFG"`, then `sync` before removing the card.

### RISC-V settings back to the 832 firmware

```sh
mcopy -n -i "card.img@@$off" ::MINMGAR1.CFG ./MINMGAR1.CFG     # slot 1
"$C" --to-832 MINMGAR1.CFG MINMGAA1.CFG
mcopy -o -i "card.img@@$off" MINMGAA1.CFG ::MINMGAA1.CFG
```

## Tests

The host tests need the packages of `fw/ctrl_rv/test/README.md` ("Setup":
`gcc-multilib` for the `-m32` builds, `python3`, `mtools dosfstools fdisk`).
`make -C fw/ctrl_rv/test run-config_test` builds `cfgconv` with
AddressSanitizer and UBSan (native and `-m32`) and checks it against
`fw/ctrl_rv/test/gold/mkcfg832.py`, an independent generator of 832 files:
`--check` of every case, the `--to-rv` / `--to-832` round trip byte for byte,
every refusal (`fw/ctrl_rv/test/README.md`, `config_test`). There is no
config file in the repository; to run the same round trip on real 832 files,
e.g. copies from an SD card, put them in a directory and name it:

```sh
mkdir -p ~/cfg832
mcopy -n -i "card.img@@$off" ::MINMGAA.CFG ~/cfg832/     # and MINMGAA1.CFG .. as present
make -C fw/ctrl_rv/test run-config_test CFG832_DIR="$HOME/cfg832"
```

Each file there must convert, convert back to the same bytes, and show the
same fields in both `--check` outputs.
