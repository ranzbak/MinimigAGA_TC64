# SPI clock-domain benches (xsim)

Two xsim benches for the SPI path between the host CPU's SPI master
(`rtl/host/cfide.vhd`) and the Minimig SPI slaves (`paula_floppy`,
`userio_osd`). The slaves are clocked by `sck`, the logic around them by
`clk_28`; in hardware `sck` reaches the slaves a few ns after the `clk_114`
edge that made it, and where a `clk_28` edge lands relative to that is a
per-build accident. The benches move the two edges against each other and
check that nothing depends on one ordering.

| Bench | What | Host side |
|---|---|---|
| `tb_spi_cdc.v`, `run.sh` | cfide + `paula_floppy` + `userio_osd` + the SD card model; HDF sector writes and reads, the direct-mode transfer, the OSD version reply, the cross-frame case, and the OSD reply-ready handshake (`+RDY=1`) | a bus model: the number of `clk_114` cycles between one access's ack and the next request (`gap`) stands for the CPU |
| `host832/tb_832_dmode.v`, `host832/run.sh` | the direct-mode transfer with the real 832 (`EightThirtyTwo_Bridge`, `hostcache.v`) running the firmware's instruction sequence (`gen832.py`) | the EightThirtyTwo itself, with an SDRAM model of adjustable latency behind the cache |

## Prerequisites (fresh Ubuntu 24.04)

Vivado 2023.2 with its simulator (`xvlog`, `xvhdl`, `xelab`, `xsim`) in
`/opt/Xilinx/Vivado/2023.2/bin` (`VIVADO_PATH=` for another place; Vivado
is not installable from apt). On Ubuntu 24.04 the tools need
`libtinfo.so.5`; create the shim once (`run.sh` puts `$HOME/lib/tinfo5` on
`LD_LIBRARY_PATH`):

```sh
sudo apt install build-essential git python3
mkdir -p ~/lib/tinfo5
ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 ~/lib/tinfo5/libtinfo.so.5
```

`host832/run.sh` also needs the EightThirtyTwo sources: the submodule, or
`E832=<dir>/RTL` of another checkout (the submodule is not initialised in a
git worktree):

```sh
git submodule update --init EightThirtyTwo
```

Run one xsim at a time on the machine; the configurations of one `run.sh`
run one after the other in one directory (`sim/spi_cdc/run_<RUNTAG>/`, tag
default `wt`, or the `REV`), because concurrent xsim runs in one directory
corrupt each other.

## `run.sh`: the grid

From the repository root:

```sh
bash sim/spi_cdc/run.sh
```

Seven (`SCKDLY`, `C28DLY`) pairs in ns (`sck` at the slaves late against
the `clk_114` edge, `clk_28` late against the `clk_114` edge): `0.5 0.2`,
`0.2 0.5`, `1.5 0.3`, `4.0 0.3`, `0.3 4.0`, `8.0 0.3`, `9.5 0.3`: both orders
of the two edges, and `sck` almost a whole `clk_114` period (8.8 ns) late. Per
pair it runs every gap (2 to 64 `clk_114` cycles between accesses) `REPS`
(3) times for each test, and prints the failures per gap (`GAP <g> <test>
fail <n>/<m>`) and `=== PASS` or `=== FAIL`. The default grid takes about
2.5 minutes and passes. Its `osd` failures below `OSD_MIN_GAP` (default
40, the OSD reply latency: the 832 and the RV never read a reply byte that
fast) are printed but not counted; `NOTE: ... osd failures below
OSD_MIN_GAP` says how many.

Your own pairs, one `"<SCKDLY> <C28DLY>"` argument each:

```sh
RUNTAG=mine bash sim/spi_cdc/run.sh "1.5 0.3" "8.0 0.3"
```

`REV=<git rev>` runs the same grid on the RTL of that revision, for a
before and after comparison. `XARGS="+..."` passes plusargs to the
bench (`tb_spi_cdc.v` documents them): `+TESTS=<mask>` (1 `wr`, 2 `rd`, 4
`direct`, 8 `osd`, 16 `xframe`; the default is 15), `+REPS=<n>`,
`+SEED=<n>`, `+GAPMAX=<n>`, `+SPEED=<n>` (the SPI speed register, 1 as
`SPI_fast()`), `+OSD_MIN_GAP=<n>`, `+DEBUG=1`.

### The sweep

`+SWEEP=1` replaces the 16 gaps by every even gap from 2 to 80, to find
where a test starts to fail. With `+OSD_MIN_GAP=0` every `osd` failure
counts, so each pair ends `=== FAIL` and the per-gap lines are the result:

```sh
RUNTAG=sweep XARGS="+SWEEP=1 +TESTS=8 +OSD_MIN_GAP=0 +REPS=10" bash sim/spi_cdc/run.sh
```

(48 s. Task 1 of the OSD migration took the fail counts of this run to
decide the OSD reply handshake: the version reply needs a slow host, a
reply byte started within about 34 cycles of the previous one is stale.)

### `+RDY`: the OSD reply-ready handshake

`+RDY=1` models the firmware's `OSD_RDY` wait (cfide `HOST_REQ`
`0x0fffffb4`, bit 0: cfide's count of OSD bytes started equals
`userio_osd`'s `osd_rx_seq`). Before every OSD reply byte (`osd` and
`xframe`) the bus model reads `HOST_REQ` until bit 0 is 1, each read an
ordinary bus access with the same gap; a poll that has not ended after
100,000 `clk_114` cycles ends the run with `=== FAIL (watchdog ...)`. It
prints per gap how many `HOST_REQ` reads it made and how many read 0, and
for `xframe` in how many runs the `OSD_WR` frame's last byte was still not
taken when the next frame's command byte started (the case the count exists
for; the bench fails if that never happens in a run with `xframe`). The
handshake run, every `osd` failure counted, 7 pairs, 42 s, expected `=== PASS`
in every pair with `osd` and `xframe` at 0 failures:

```sh
RUNTAG=rdy XARGS="+RDY=1 +TESTS=24 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
```

The tooth: `RDY_MUT=1` runs the same bench on a copy of `cfide.vhd` whose
`OSD_RDY` is always 1 (the line marked `-- OSD RDY`; `run.sh` checks that
exactly one line matches and that the edit applied). It must FAIL in every
pair: `osd` fails at gaps 2 to 12 and not above (there the extra `HOST_REQ`
read is itself an access with a gap, which gives the reply the time it needs):

```sh
RUNTAG=rdymut RDY_MUT=1 XARGS="+RDY=1 +TESTS=8 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
```

`run.sh` exits 1 when a pair does not PASS, so the tooth run exits 1 when
it works. That is the expected result of the mutant, not an error.

The cross-frame tooth (final review I4): `RESYNC_MUT=1` runs `xframe` on a
copy of `cfide.vhd` that resyncs `osd_tx_seq` to `osd_rx_seq` after 4 idle
cycles (`osd_idle(2)`) instead of 64 (`osd_idle(6)`; `run.sh` checks that
exactly one `elsif osd_idle(6)` line matches and that the edit applied).
The resync then lands while the `OSD_WR` frame's last byte is still in
`userio_osd`'s synchroniser, the late byte is counted against the VERSION
command byte, and `OSD_RDY` comes one byte early. It must FAIL in every
pair (run `p4fx_rsm`, 119 s: `xframe` fails 3 of 3 at gaps 2 to 10, and
the run ends on the watchdog at gap 20 in six pairs); the same command
without `RESYNC_MUT` passes in every pair (`p4fx_rsg`, 112 s):

```sh
RUNTAG=rsmut RESYNC_MUT=1 XARGS="+RDY=1 +TESTS=16 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
RUNTAG=rsgreen XARGS="+RDY=1 +TESTS=16 +OSD_MIN_GAP=0" bash sim/spi_cdc/run.sh
```

## `host832/run.sh`: the real 832

```sh
bash sim/spi_cdc/host832/run.sh
```

Seven (`SLAT`, `SJIT`) pairs by default (`0 0`, `2 0`, `4 0`, `8 0`, `16
0`, `0 16`, `4 32`): the SDRAM host-port latency in `clk_114` cycles and a
random 0..`SJIT` extra per access (other masters). The bench reports, per
sector, `L`: the cycles from the RDSPI ack to the 832's `DisableDMode()`
write, as a histogram per pair, and checks every sector paula_floppy hands
to the gayle model; `=== PASS` in all pairs is the result (about 3.5
minutes). `E832=<dir>` is the RTL directory of the EightThirtyTwo
checkout (default `EightThirtyTwo/RTL`), `REV=<git rev>` and `RUNTAG` as
above, `./run.sh "<slat> <sjit>" ...` your own pairs. `gen832.py` writes
the 832 program (ROM) the bench runs.
