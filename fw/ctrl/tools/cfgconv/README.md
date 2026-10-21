# cfgconv: Minimig config files, big-endian <-> RISC-V byte order

The OSD firmware keeps its settings in a 212-byte config file in the root of
the SD card. The RISC-V firmware (`fw/ctrl`) writes it little-endian as
`MINMGAR.CFG` (the default slot) and `MINMGAR1.CFG` .. `MINMGAR4.CFG`. The
previous firmware (the EightThirtyTwo host CPU, last in tag `osd-832-final`)
wrote it big-endian as `MINMGAA.CFG` and `MINMGAA1.CFG` .. `MINMGAA4.CFG`;
`cfgconv` calls that order "BE" and the RISC-V one "RV". Same layout
(`configTYPE` in `fw/ctrl/config.h`, `CONFIG_VERSION 4`, id `MNMGCFGA`); only
the seven 32-bit fields differ in byte order: `version` (offset 8),
`kickdir` (132), `extromdir` (136), `hdfdir[0..3]` (140, 144, 148, 152). The
byte order is told by `version`: 1..4 read little-endian is RV, 1..4 read
big-endian is BE. The swap is `fw/ctrl/cfgswap.c`, the same code the
firmware runs.

The RISC-V firmware converts on its own: when a slot has no `MINMGAR*` file
but has the big-endian one, its first load of that slot reads the
`MINMGAA*` file, converts it in memory and saves it as the `MINMGAR*` file
(boot line `Converted 832 configuration MINMGAA.CFG`). The `MINMGAA*` file is
never written. `cfgconv` is for the rest: converting ahead of time, carrying
settings back to a `MINMGAA*` file for a card that also boots an older
bitstream, and looking at a file. A big-endian file put under the RISC-V
name is rejected by the firmware ("Wrong configuration file format!",
"(832 byte order)"), which then uses its defaults.

## Usage

```
cfgconv --to-rv  <in> <out>   big-endian (BE) file -> RISC-V file
cfgconv --to-be  <in> <out>   RISC-V file -> big-endian (BE) file
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
sudo apt install build-essential python3 mtools dosfstools fdisk
make -C fw/ctrl/tools/cfgconv
fw/ctrl/tools/cfgconv/cfgconv --check fw/ctrl/tools/cfgconv/README.md || echo "refused, exit $?"
```

The binary is `fw/ctrl/tools/cfgconv/cfgconv`; the last line shows a
refusal (this file is not a config file: exit 1, "refused, exit 1").

No RISC-V toolchain is needed. `make -C fw/ctrl/tools/cfgconv B=<dir>`
puts the binary into `<dir>`.

## Examples

The commands work in bash and zsh, in one shell session (the variables
`C`, `off` carry from block to block), from the repository root for the
first block. `C` is the binary built above.

### A card image file

`card.img` is a raw image of the whole SD card (e.g. `sudo dd
if=/dev/sdX of=card.img bs=1M status=progress`, or one made by
`tools/sim/mkcard.sh`). To try the recipe without a card, make an image with
a big-endian config file on it (`mkcfgbe.py` writes made-up ones) in a
scratch directory and work there:

```sh
C="$PWD/fw/ctrl/tools/cfgconv/cfgconv"
mkdir -p build/cfgdemo
python3 -I fw/ctrl/test/gold/mkcfgbe.py build/cfgdemo
cp build/cfgdemo/defaults.cfg build/cfgdemo/MINMGAA.CFG
bash tools/sim/mkcard.sh build/cfgdemo/card.img 16 build/cfgdemo/MINMGAA.CFG
cd build/cfgdemo
```

mtools reaches the FAT partition at its byte offset:

```sh
export MTOOLS_SKIP_CHECK=1
start=$(sfdisk -d card.img | sed -n 's/^.*start= *\([0-9]*\),.*$/\1/p' | head -n 1)
off=$((start * 512))
# the MINMGAA*.CFG / MINMGAR*.CFG files
mdir -i "card.img@@$off" ::
# copy the big-endian file off the card
mcopy -n -i "card.img@@$off" ::MINMGAA.CFG ./MINMGAA.CFG
# order = BE, then every field
"$C" --check MINMGAA.CFG
# convert
"$C" --to-rv MINMGAA.CFG MINMGAR.CFG
# copy the RISC-V file back; -o: overwrite
mcopy -o -i "card.img@@$off" MINMGAR.CFG ::MINMGAR.CFG
```

Write the image back to the card afterwards (`sudo dd if=card.img
of=/dev/sdX bs=1M conv=fsync status=progress`), or work on the card itself:

### The SD card itself

With the card's FAT partition at `/dev/sdX1` (check with `lsblk`; not
mounted, or unmount it first with `udisksctl unmount -b /dev/sdX1`):

```sh
sudo env MTOOLS_SKIP_CHECK=1 mcopy -n -i /dev/sdX1 ::MINMGAA.CFG ./MINMGAA.CFG
sudo chown "$USER" MINMGAA.CFG
"$C" --to-rv MINMGAA.CFG MINMGAR.CFG
sudo env MTOOLS_SKIP_CHECK=1 mcopy -o -i /dev/sdX1 MINMGAR.CFG ::MINMGAR.CFG
```

A desktop that mounts the card (e.g. at `/media/$USER/MINIMIG`) works with
plain `cp` as well: `"$C" --to-rv "/media/$USER/MINIMIG/MINMGAA.CFG"
"/media/$USER/MINIMIG/MINMGAR.CFG"`, then `sync` before removing the card.

### RISC-V settings back to a big-endian file

For the default slot (slot `n` is `MINMGAR<n>.CFG` and `MINMGAA<n>.CFG`
the same way). The output replaces an existing `MINMGAA*` file of that name,
so keep a copy of it if its settings matter:

```sh
mcopy -n -i "card.img@@$off" ::MINMGAR.CFG ./MINMGAR.CFG
"$C" --to-be MINMGAR.CFG MINMGAA.CFG
mcopy -o -i "card.img@@$off" MINMGAA.CFG ::MINMGAA.CFG
```

## Tests

The host tests need the packages of `fw/ctrl/test/README.md` ("Setup":
`gcc-multilib` for the `-m32` builds, `python3`, `mtools dosfstools fdisk`).
`make -C fw/ctrl/test run-config_test` builds `cfgconv` with
AddressSanitizer and UBSan (native and `-m32`) and checks it against
`fw/ctrl/test/gold/mkcfgbe.py`, an independent generator of big-endian files:
`--check` of every case, the `--to-rv` / `--to-be` round trip byte for byte,
every refusal (`fw/ctrl/test/README.md`, `config_test`). There is no
config file in the repository; to run the same round trip on real big-endian files,
e.g. copies from an SD card, put them in a directory and name it. The
examples above leave the shell in `build/cfgdemo` (`card.img` and `off` are
from there); the first line goes back to the repository root, the `mcopy`
line takes the default slot's file (add `MINMGAA1.CFG` .. as present):

```sh
cd ../..
mkdir -p build/cfgbe
mcopy -n -i "build/cfgdemo/card.img@@$off" ::MINMGAA.CFG build/cfgbe/
make -C fw/ctrl/test run-config_test CFGBE_DIR="$PWD/build/cfgbe"
```


Each file there must convert, convert back to the same bytes, and show the
same fields in both `--check` outputs.
