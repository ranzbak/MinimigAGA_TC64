# tools/sim: SD card images and the SD SPI model

Used by the host-CPU simulations (minfat host test, L2 boot bench, L3
co-simulation). Two parts: `mkcard.sh` makes a raw FAT16 card image,
`sim/common/sd_spi_model.v` is the card.

## Prerequisites

```
sudo apt install mtools dosfstools fdisk python3      # mformat/mcopy, mkfs.fat, sfdisk
```

iverilog 12 (`/usr/local/bin/iverilog`) for the bench; Vivado 2023.2 `xvlog`
only if you want the xsim check. No root and no loop devices are needed:
`sfdisk` partitions the image file, `mkfs.fat --offset` formats inside it,
`mcopy -i img@@offset` copies the files.

## mkcard.sh

```
tools/sim/mkcard.sh <img> <size_MB> [file...]
```

Creates `<img>` (size_MB * 1 MiB, at least 5): MBR (signature 55AA), one
FAT16 partition (type 06) from LBA 2048 to the end, label `MINIMIG`, hidden
sectors = 2048, the files copied to the root directory (8.3 names, upper
case). Cluster size is chosen automatically so the volume stays FAT16.

It refuses (exit 2, nothing written) a size above 2048 MB (FAT16 holds at
most 65524 clusters of 32 KB) and a file whose name (the part after the
last `/`) is not an upper-case 8.3 name: 1-8 characters, optionally `.`
and 1-3 more, from `A-Z 0-9 _ ~ ! # % & @ ^ $ -`. The boot ROM and the
firmware compare the short directory name, and `mcopy` stores a
lower-case or long name as a long-name entry with a short name of its own
choosing.

The image is reproducible: the same arguments and file contents give the
same bytes (fixed disk identifier `0x4d494e49`, `mkfs.fat --invariant` for
the volume ID and label time, file times from `SOURCE_DATE_EPOCH`, default
2026-01-01 00:00 UTC, written in UTC). Two runs of a bench that build their
own card (e.g. `sim/host_bridge/run.sh fwboot` under xsim and Verilator)
then see the same card, and `run.sh compare` can diff their SPI logs.

```
tools/sim/mkcard.sh /tmp/card.img 8 FW.BIN KICK.ROM       # 8 MB card, two files
tools/sim/mkcard.sh /tmp/empty.img 64                     # empty 64 MB card
MTOOLS_SKIP_CHECK=1 mdir -i /tmp/card.img@@1048576 ::     # look inside (2048*512)
MTOOLS_SKIP_CHECK=1 mcopy -i /tmp/card.img@@1048576 ::KICK.ROM out.rom
```

## sd_spi_model

`sim/common/sd_spi_model.v`: Verilog-2005, no SystemVerilog, works in
iverilog and xsim.

```verilog
sd_spi_model #(.IMG_SECTORS(65536)) u_sd (.cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso));
```

SPI mode 0, MSB first, SDHC (block addressing, CCS=1), CRC ignored. The
image is held in a byte array (`IMG_SECTORS` * 512 bytes, default 32 MB; use
a smaller parameter and image for fast runs). `miso` is 1 while `cs_n` = 1.
At the end of a test the bench calls `u_sd.save_image;`, which writes the
card to `+SD_SAVE`.

### Plusargs

| Plusarg | Default | Meaning |
|---|---|---|
| `+SD_IMG=<file>` | none (card all 0) | raw image loaded at time 0 |
| `+SD_SAVE=<file>` | none | image written by task `save_image` |
| `+SD_TOKEN_DLY=<n>` | 4 | 0xFF bytes before every data token (reads, CSD) |
| `+SD_BUSY=<n>` | 8 | 0x00 busy bytes after a write, stop token, CMD12 |
| `+SD_NCR=<n>` | 1 | 0xFF bytes between the command CRC byte and R1 (0..8) |
| `+SD_INIT_POLLS=<n>` | 2 | ACMD41 polls answered "idle" (R1=01) before ready |
| `+SD_LOG=1` | 0 | one `SD:` line per command |

### Commands

CMD0 (R1=01), CMD8 (R1, then 00 00 01 AA), CMD55, ACMD41 (R1=01 for
`+SD_INIT_POLLS` polls, then 00), CMD58 (R1, OCR C0FF8000 when ready, CCS=1),
CMD16 (R1=00), CMD9 (R1, token, 16 byte CSD v2.0, 2 CRC), CMD17 (R1, token
FE, 512 bytes, 2 CRC), CMD18 (same, repeated until CMD12), CMD12 (one stuff
byte, R1=00, busy), CMD24 (R1, host: token FE + 512 + 2 CRC, card: data
response 05, busy), CMD25 (token FC per block, stop token FD, busy). Any
other command: R1=04. Address beyond the card: R1=40. Raising CS aborts a
running multi-block read or write. Not modelled: byte addressing (SDSC),
CMD1/MMC, CRC errors, write protect.

### What the firmware sends (derived from the sources)

`fw/ctrl_boot_832/spi.c` (boot ROM, `spi_init` / `sd_read_sector`) and
`fw/ctrl_832/mmc.c` (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`, `MMC_Write`,
`MMC_GetCSD`). Command byte = 0x40 | n; 4 argument bytes, MSB first; CRC byte.

Boot ROM init (`SPI_slow`; no byte addressing is ever used because the
card answers CMD8 and CCS=1):

1. CS high, 200 x 0xFF (`spi_spin`), CS low, 0xFF.
2. CMD0 (`40 00000000 95`), repeated up to 7 times until R1 = 01.
3. 200 x 0xFF, CMD8 (`48 000001AA 87`), R1 must be 01, then 4 bytes read
   (low 16 bits must be 01AA), 0xFF.
4. Loop (up to 50 x): 200 x 0xFF, CMD55 (`77 0 FF`, R1 must be 01), 0xFF,
   ACMD41 (`69 40000000 87`), 0xFF; retried until R1 = 00.
5. CMD58 (`7A 0 FF`), R1 = 00, 0xFF, OCR byte 0 bit 6 = CCS, 4 x 0xFF,
   CS high, 0xFF. (Non-SDHC fallback sends CMD16 `50 00000001 FF`.)
6. Each sector read (`SPI_fast`): 0xFF, CS low, 0xFF, CMD17 (`51 lba FF`),
   R1 = 00 (polled until != 0xFF), then 0xFF until the token 0xFE, 512 bytes
   (4 x 0xFF per word), one 0xFF, CS high. The CRC bytes are not read.

Main firmware (`mmc.c`):

1. `MMC_Init`: 10 x 0xFF, CMD0 (R1 = 01), CMD8 `48 000001AA`, 4 x 0xFF
   (R7 tail: bytes 2,3 = 01 AA), CMD55 / ACMD41 (`69 40000000`) until R1 =
   00, CMD58 then 4 x 0xFF (OCR[0] & 0x40 = SDHC), CS high. Every command is
   preceded by a flush 0xFF and R1 is polled with up to 100 x 0xFF.
2. `MMC_Read`: CMD17 (`51 lba`), 0xFF until 0xFE, 512 x 0xFF, 2 x 0xFF (CRC).
3. `MMC_ReadMultiple`: CMD18 (`52 lba`), per block: 0xFF until 0xFE, 512
   bytes, 2 CRC bytes; then CMD12 sent without a flush byte
   (`4C 00 00 00 00 00`), one stuff 0xFF, R1 polled (00), then 0xFF while the
   byte is 00 (busy).
4. `MMC_Write`: CMD24 (`58 lba`), R1 = 00, 0xFF, token FE, 512 bytes, 2 x
   0xFF, one 0xFF read as data response (low 5 bits must be 05), then 0xFF
   while the byte is 00.
5. `MMC_GetCSD`: CMD9 (`49 0`), 0xFF until FE, 16 bytes, 2 CRC. C_SIZE
   (`CSDData[7..9]`) gives `(C_SIZE+1) * 1024` sectors.

(`+SD_NCR=n` puts n bytes of 0xFF between the command's CRC byte and R1; the
firmware's polling loops accept any n from 0 to 8.)

### Bench

```
bash sim/common/run_sd_model.sh [+SD_TOKEN_DLY=200 +SD_NCR=8 ...]
RUNTAG=a bash sim/common/run_sd_model.sh +SD_TOKEN_DLY=0     # run dir run_a
```

It builds an 8 MB card image with `mkcard.sh` holding a 4 KB pseudo-random
`TEST4K.BIN`, runs `tb_sd_spi_model.v` (init as in the boot ROM, MBR check,
BPB, root directory, 8 sectors by CMD18 + CMD12 compared with the file's
hex dump, CMD9, CMD24 write + CMD17 read-back, CMD25 two blocks + CMD18
read-back), then checks that the `+SD_SAVE` image holds the CMD24 pattern
at LBA 100 and still reads `TEST4K.BIN` back with `mcopy`. Pass line:
`=== PASS`. Outputs in `sim/common/run_${RUNTAG:-wt}/`. Takes about 20 s
(the 8 MB array is initialised and saved byte by byte).

xsim check (compile and run, Vivado 2023.2):

```
export LD_LIBRARY_PATH=$HOME/lib/tinfo5:$LD_LIBRARY_PATH LC_ALL=C
cd sim/common/run_wt          # after one run_sd_model.sh
V=/opt/Xilinx/Vivado/2023.2/bin
$V/xvlog ../sd_spi_model.v ../tb_sd_spi_model.v && $V/xelab -debug off tb_sd_spi_model -s tbs
$V/xsim tbs -R -testplusarg SD_IMG=$PWD/card.img -testplusarg HEX=$PWD/test4k.hex
```
