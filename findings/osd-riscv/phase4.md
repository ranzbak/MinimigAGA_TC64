# OSD host CPU migration, Phase 4 findings

## Measurements

### Task 1: failure edge of the real `userio_osd` reply (E_osd)

Bench `sim/spi_cdc/tb_spi_cdc.v` (xsim 2023.2, RTL of the tree at the time of the run, `git status rtl` clean), `osd` test only.
Reference first: `RUNTAG=p4t1ref bash sim/spi_cdc/run.sh` gave `=== PASS` in all seven (SCKDLY, C28DLY) pairs of the default grid (wall 2 min 24 s; the osd failures it prints are below OSD_MIN_GAP=40 and not counted).
Sweep: `RUNTAG=p4t1 XARGS="+SWEEP=1 +TESTS=8 +OSD_MIN_GAP=0 +REPS=10" bash sim/spi_cdc/run.sh` (wall 48 s, seed 1). Every even gap 2..80, 10 repetitions each, every failure counted. Each pair ends `=== FAIL` as expected with OSD_MIN_GAP=0.
`+GAP` adds a random 0..3 `clk_114` cycles per access (`jitter = $urandom % 4`), so the gap value in the table is the minimum; the real gap is gap..gap+3 and the edge is a band.

Failures out of 10 by gap (`clk_114` cycles; 2..22 fail 10/10 in all pairs, 34..80 fail 0/10 in all pairs):

| SCKDLY / C28DLY (ns) | 24 | 26 | 28 | 30 | 32 | 34 | largest failing gap | smallest gap, all larger pass |
|---|---|---|---|---|---|---|---|---|
| 0.5 / 0.2 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 0.2 / 0.5 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 1.5 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 4.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 0.3 / 4.0 | 9 | 9 | 7 | 0 | 0 | 0 | 28 | 30 |
| 8.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 9.5 / 0.3 | 9 | 9 | 8 | 7 | 3 | 0 | 32 | 34 |

**E_osd = 34** (smallest `+GAP` at which `osd` passes 10/10 in every pair, and at every larger gap up to 80). With the 0..3 jitter that is an effective gap of 34..37 cycles; in the pair 0.3 / 4.0 alone the edge is 30.
**Band:** the transition is gradual, not a cliff: failures are 10/10 up to gap 22, 7..10/10 at 24..28, and fall to 0..7/10 at 30 and 0..3/10 at 32. Treat gaps below 34 as unsafe, and 34..37 as the first fully passing band (no failure in 10 reps x 7 pairs at any gap >= 34, so the margin to the firmware's 40 is 3..6 cycles plus jitter).
Consistent with commit 1e135e7 (stale replies below ~32): the largest failing gap is 32, no failure at any gap >= 34 and none at >= 40, so the 40-cycle reply gap of the RV firmware measured in L2 (Phase 3) sits 6 cycles above E_osd. One seed only; a lower tail below 34 at other seeds is not excluded (default grid, REPS=3, saw 1/3 failures at gap 32 in three pairs, same as here).

## Shared defects

(none yet)

## Findings for Paul (RTL outside Phase 4 scope)

Found by the X-sensitivity twin of Task 2 (`XRAND=1`, sim/host_bridge, 2026-10-18); not fixed, rtl/ is untouched.

**Five flops have no reset and rely on the FPGA's power-up 0.**

| signal | file | where it is written |
|---|---|---|
| `cache_req` | `rtl/host/832_bridge.vhd` (decl. line 62) | lines 359, 373; the reset branch (335-337) sets only `state`, `hw_req`, `wr` |
| `cpu_ack` | `rtl/host/832_bridge.vhd` (55) | lines 341, 368, 376, 386 |
| `rom_wr` | `rtl/host/832_bridge.vhd` (73) | lines 342, 353, 367 |
| `sdram_req` | `rtl/host/hostcache.v` (output reg, line 18) | lines 144, 158, 173, 193; the `!reset_n` branch (line 244) sets only `zstate`, `zreadword_burst` |
| `ack` | `rtl/host/hostcache.v` (line 16) | `ack <= #1 1'b0` default and the states that set it |

**Failure under random init** (`--x-initial unique`, `+verilator+rand+reset+2`): if `cache_req` or `sdram_req` starts at 1, the SDRAM model sees a request with a garbage address from cycle 0 (`BUS VIOLATION sdram model: request outside 0..0x7FFFFF`), the request never drops (the states that clear it are not reached), and the host CPU never boots (boot: no `ErrorCode`, `=== FAIL timeout`; fwboot: 4300 bench errors). About half of the seeds fail; `ack`/`cpu_ack`/`rom_wr` at 1 give the same class of false accesses.

**Why the board is fine at power-up:** FPGA configuration initialises every flop to 0 (no INIT attribute is needed), so the flops start at 0 exactly as the 2-state simulations assume.

**Warm-`nReset` risk:** `nReset` is also an in-system reset. Asserting it while a cache fill or a write is in flight resets `zstate` / `state` but leaves `sdram_req` / `cache_req` at 1; the SDRAM controller's ack then arrives with no state machine waiting, and the request stays high. Not reproduced on the board; the bench cannot show it either (it asserts reset only at time 0).

**Minimal fix (a decision for Paul):** clear `cache_req`, `cpu_ack`, `rom_wr` in the `nReset='0'` branch of `832_bridge.vhd` (and give them `:= '0'` initial values), and clear `sdram_req`, `ack` in hostcache's `!reset_n` branch. Four to six lines, behaviour after the first reset unchanged.

**Which builds:** `832_bridge.vhd` and `hostcache.v` are in the 832 build too: `rtl/soc/minimig_virtual_top.v` instantiates `EightThirtyTwo_Bridge` (generic `cpu_riscv` selects the CPU) for both firmwares, and `hostcache` sits behind the bridge for either CPU. An RTL change is therefore a change to the 832 bitstream (reference `build/stage_spicdc_49b1868`).

**Bench handling:** `XRAND=1` pins exactly these five flops to 0 at time 0 (declaration initialisers in the run copy of `hostcache.v` and in the GHDL-converted bridge, `hs_pin_hostcache`, `hs_pin_bridge` in `sim/common/hostsim.sh`), prints `=== XRAND pinned 5 regs`, and randomises everything else. The pin models the FPGA configuration; remove it when the RTL resets them.
