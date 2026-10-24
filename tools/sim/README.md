# tools/sim: SD card images and the SD SPI model

Used by the host-CPU simulations (minfat host test, L2 boot bench, L3
co-simulation). Two parts: `mkcard.sh` makes a raw FAT16 card image,
`sim/common/sd_spi_model.v` is the card.

## Prerequisites

From a fresh Ubuntu 24.04 machine (the commands work in bash and zsh, from
the repository root). `mtools` is `mformat`/`mcopy`, `dosfstools` is
`mkfs.fat`, `fdisk` is `sfdisk`; `iverilog` (12.0) is for the bench:

```sh
sudo apt install mtools dosfstools fdisk python3 iverilog
```

The bench script looks for Icarus Verilog at `/usr/local/bin/iverilog`
(`IVERILOG=`, `VVP=` override it): with the Ubuntu package write
`IVERILOG=/usr/bin/iverilog VVP=/usr/bin/vvp` in front of the command (see
"Bench"). Vivado 2023.2 `xvlog` only if you want the xsim check. No root and no loop devices are needed:
`sfdisk` partitions the image file, `mkfs.fat --offset` formats inside it,
`mcopy -i img@@offset` copies the files.

## mkcard.sh

```
bash tools/sim/mkcard.sh <img> <size_MB> [file...]
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

Examples (the files must exist; `FW.BIN` and `KICK.ROM` stand for any two
files with 8.3 names; the image has the partition at LBA 2048, byte offset
1048576):

```sh
mkdir -p build/card_demo
head -c 4096 /dev/urandom > build/card_demo/FW.BIN
head -c 4096 /dev/urandom > build/card_demo/KICK.ROM
bash tools/sim/mkcard.sh build/card_demo/card.img 8 build/card_demo/FW.BIN build/card_demo/KICK.ROM
bash tools/sim/mkcard.sh build/card_demo/empty.img 64
MTOOLS_SKIP_CHECK=1 mdir -i build/card_demo/card.img@@1048576 ::
MTOOLS_SKIP_CHECK=1 mcopy -i build/card_demo/card.img@@1048576 ::KICK.ROM build/card_demo/out.rom
cmp build/card_demo/KICK.ROM build/card_demo/out.rom
```

(`build/` is the repository root's ignored build directory.) The guards, as
exit status 2 with nothing written:

```sh
bash tools/sim/mkcard.sh build/card_demo/big.img 4096 || echo "refused, exit $?"
bash tools/sim/mkcard.sh build/card_demo/low.img 8 build/card_demo/out.rom || echo "refused, exit $?"
ls build/card_demo
```

The first is a size above 2048 MB, the second a file whose name is not an
upper-case 8.3 name (`out.rom`); `big.img` and `low.img` do not appear.

## sd_spi_model

`sim/common/sd_spi_model.v`: Verilog-2005, no SystemVerilog, works in
iverilog and xsim.

```verilog
sd_spi_model #(.IMG_SECTORS(65536)) u_sd (.cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso));
```

SPI mode 0, MSB first, SDHC (block addressing, CCS=1). CRC checking is off
until CMD59 turns it on (below); data blocks always carry their real CRC16. The
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
| `+SD_ERR_RDCRC=<n>` | 0 (off) | the n-th CMD17/CMD18 data block the host receives has bit 0 of its last data byte flipped (CRC16 of the true data: a mismatch; the card unchanged); a block counts when its last data byte leaves the card, so one cut before that (CMD12, CS high, e.g. the CMD18 block in flight at CMD12) is neither counted nor corrupted |
| `+SD_ERR_WRREJ=<n>` | 0 (off) | the n-th data block the card takes in (CMD24/CMD25, every block whatever else happens to it) gets data response 0B, not written |
| `+SD_ERR_WRFAIL=<n>` | 0 (off) | the same with 0D (write error, then busy); on a block WRREJ also hits, WRREJ wins |
| `+SD_ERR_NORESP=<n>` | 0 (off) | the n-th command frame (CMD0 included) gets no response and has no effect |
| `+SD_ERR_CMDCRC=<n>` | 0 (off) | the n-th command frame (same count) gets R1 08 (09 while idle) and is not executed, as for a bad CRC7, with or without CMD59; on a command NORESP also hits, NORESP wins |
| `+SD_ERR_<kind>_CNT=<k>` | 1 | kind = RDCRC, WRREJ, WRFAIL, NORESP, CMDCRC: k consecutive failures |

n counts events from 1 at time 0 over the whole run. The n-th event and the
k-1 after it fail; each failure uses up one of the k, so the injection ends
after exactly k failures (retry exhaustion: e.g. `+SD_ERR_RDCRC=5
+SD_ERR_RDCRC_CNT=4`).
Task `remove_card` (called hierarchically, `u_sd.remove_card;`): the card is
gone for the rest of the run, MISO stays 1, nothing it receives is acted on
or written.

### Commands

CMD0 (R1=01; resets the card state, the application-command flag of a
CMD55 before it too), CMD8 (R1, then 00 00 01 AA), CMD55, ACMD41 (R1=01 for
`+SD_INIT_POLLS` polls, then 00), CMD58 (R1, OCR C0FF8000 when ready, CCS=1),
CMD16 (R1=00), CMD9 (R1, token, 16 byte CSD v2.0, 2 CRC), CMD17 (R1, token
FE, 512 bytes, 2 CRC), CMD18 (same, repeated until CMD12), CMD12 (one stuff
byte, R1=00, busy), CMD24 (R1, host: token FE + 512 + 2 CRC, card: data
response 05, busy), CMD25 (token FC per block, stop token FD, busy), CMD13
(R2: R1, 00), CMD59 (R1; arg bit 0 = CRC checking on/off), ACMD22 (R1,
token FE, 4 bytes big-endian: the blocks written with 05 by the last CMD25,
CRC16). CMD41
not right after CMD55 (also CMD55, CMD0, CMD41): plain CMD41, R1=05. Any
other command: R1=04. Address beyond the card: R1=40. Raising CS aborts a
running multi-block read or write. Not modelled: byte addressing (SDSC),
CMD1/MMC, write protect.

CRC (CRC7 x^7+x^3+1; CRC16 CCITT x^16+x^12+x^5+1, init 0): every data
block the card sends (CMD17, CMD18, CMD9, ACMD22) ends in its CRC16. With
CMD59(1) (CMD0 and CMD59(0) switch it off again) a command whose CRC byte
bits 7:1 are not its CRC7 gets R1 08 (09 while idle) and is not executed, and
a written block whose CRC16 does not match gets data response 0B and is not
written. Data responses: 05 then busy, 0B without busy, 0D then busy. In a
CMD25, after a 0B or 0D every further block up to the stop token gets the
same response and is not written.

### What the firmware sends (derived from the sources)

`fw/ctrl_boot/spi.c` (boot ROM, `spi_init` / `sd_read_sector`) and
`fw/ctrl/mmc.c` (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`, `MMC_Write`,
`MMC_GetCSD`); written from the previous firmware's copies,
from which these were ported with the SD protocol unchanged (the RISC-V
`mmc.c` bounds its token and busy waits by TIMER, `SD_TIMEOUT`, instead of a
loop count). Command byte = 0x40 | n; 4 argument bytes, MSB first; CRC byte.

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

Any plusarg of the table may follow (`+SD_TOKEN_DLY=200 +SD_NCR=8`); the run
directory is `run_${RUNTAG}`:

```sh
IVERILOG=/usr/bin/iverilog VVP=/usr/bin/vvp bash sim/common/run_sd_model.sh +SD_TOKEN_DLY=200 +SD_NCR=8
IVERILOG=/usr/bin/iverilog VVP=/usr/bin/vvp RUNTAG=a bash sim/common/run_sd_model.sh +SD_TOKEN_DLY=0
```

It builds an 8 MB card image with `mkcard.sh` holding a 4 KB pseudo-random
`TEST4K.BIN`, runs `tb_sd_spi_model.v` (CMD55, CMD0, CMD41 answered as a
plain CMD41, init as in the boot ROM, MBR check,
BPB, root directory, 8 sectors by CMD18 + CMD12 compared with the file's
hex dump, CMD9, CMD24 write + CMD17 read-back, CMD25 two blocks + CMD18
read-back), then checks that the `+SD_SAVE` image holds the CMD24 pattern
at LBA 100 and still reads `TEST4K.BIN` back with `mcopy`. The file compare
reads 8 consecutive sectors from the file's start cluster: it assumes that
the file is stored contiguously, true for the freshly made `mkcard.sh` image
(one file, nothing deleted), and does not follow the FAT chain. Pass line:
`=== PASS`. Outputs in `sim/common/run_${RUNTAG:-wt}/`. Takes about 20 s
(the 8 MB array is initialised and saved byte by byte).

CRC and error injection (`tb_sd_model_crc.v`, its own CRC7/CRC16 checked
against the SD spec's examples: CMD0 95, CMD17 55, CMD8 87, 512 x FF ->
7FA1):

```sh
bash sim/common/run_sd_model.sh crc
```

One run per case on a 512 KB pseudo-random card, each with its plusargs:
`basic` (CRC off by default, CMD59, R1 08, CRC16 of reads, CMD24 bad/good
CRC -> 0B/05, CMD25 x3 + ACMD22 = 3, CMD18, CMD13, CMD9, CMD59(0)),
`wrrej` (`+SD_ERR_WRREJ=2`: CMD25 x3 -> 05 0B 0B, ACMD22 = 1), `wrfail`
(`+SD_ERR_WRFAIL=1`), `rdcrc` (`+SD_ERR_RDCRC=3`, a CMD18 block cut by
CMD12 not counted), `noresp` (`+SD_ERR_NORESP=11`), `remove` (`remove_card`
mid-read and before a write), `cmdcrc` (`+SD_ERR_CMDCRC=11`: R1 08, not
executed), `rdcnt` (`+SD_ERR_RDCRC=2 +SD_ERR_RDCRC_CNT=4`: four bad reads,
the fifth good), `nrcnt` (`+SD_ERR_NORESP=11 +SD_ERR_NORESP_CNT=3`),
`rdcut` (a block cut after 100 bytes neither counted nor corrupted, one
corrupted block, no re-fire), `wrcnt` (`WRREJ=1 CNT=2`, `WRFAIL=3 CNT=2`:
0B 0B 0D 0D 05); every case but `remove` ends with a
`remove_card` in the middle of a CMD24 block. Logs in
`run_${RUNTAG:-wt}/crc_<case>.log`, pass line `=== PASS run_sd_model crc`.

xsim check (compile and run, Vivado 2023.2):

After one `run_sd_model.sh` (the run directory `sim/common/run_wt`), and the
libtinfo shim of `sim/host_bridge/README.md` ("Prerequisites") in
`~/lib/tinfo5`:

```sh
export LD_LIBRARY_PATH="$HOME/lib/tinfo5:$LD_LIBRARY_PATH" LC_ALL=C
cd sim/common/run_wt
V=/opt/Xilinx/Vivado/2023.2/bin
"$V/xvlog" ../sd_spi_model.v ../tb_sd_spi_model.v && "$V/xelab" -debug off tb_sd_spi_model -s tbs
"$V/xsim" tbs -R -testplusarg SD_IMG="$PWD/card.img" -testplusarg HEX="$PWD/test4k.hex"
```
