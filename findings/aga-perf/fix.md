# Code from chip RAM in the instruction cache (ICHIP)

Branch `aga-perf` (superproject), core branch `aga-perf` in `lib/AP68040-faster`.
Date 2026-10-25.

## 1. The problem

Andromeda's *Nexus 7* needs a stock A1200 (68EC020 at 14 MHz, 256-byte
instruction cache). On the board it hangs, or runs slowly, unless Turbo chip
RAM is on. Its CODE hunk is `MEMF_CHIP` (base `$2000` on the board).

The ILA bus recorder (2026-10-25) shows what happens in the galaxy scene: 78-83 %
of all CPU bus transfers are instruction fetches from one 256-byte chip page
(`$37000`). Each one is a chip-slot access of about 480 ns (2 CCK). That loop is
the level-3 VBL hook (`nexus7-static.md` section 1). The interrupt overruns the
frame, the music slows down, and the foreground part is starved until it misses
an exact-match wait on the music position (the sync word), so it hangs. A real
020 runs that loop from its cache.

The cause is in `rtl/soc/ap68040_minimig.sv`. The bridge asserted TCI for every
transfer outside the configured Zorro II/III fast RAM, instruction fetches
included (`fastram()` → `cach` → `tci_n`). The core obeys TCI
(`ap68040_fetch.sv`: no allocation, one long word per fetch), so every
instruction from chip RAM or the ROM was a bus transfer. Turbo chip hid this
because chip accesses then go through the SDRAM CPU port and its line cache.

## 2. What a real Amiga does

* **68020 (A1200).** The 68020 has a 256-byte direct-mapped on-chip
  instruction cache (64 long-word entries). With CACR E set it caches every
  instruction fetch. The only hardware control is CDIS, and the A1200 does not
  use it per address. Kickstart enables the cache, so chip-RAM and ROM code run
  from it. The cache does not see data writes. Software clears it after it
  changes code: CACR C, or `exec.library/CacheClearU()`, which LoadSeg and
  well-behaved loaders call (MC68020 User's Manual, "On-Chip Cache Memory";
  exec autodocs, CacheClearU/CacheControl).
* **68040 (A4000/A3640, our core).** Everything the page descriptors, the TTRs
  and TCI allow is cached. With the MMU off the default mode is cachable
  (write-through) (MC68040UM 4.3). TCI only "inhibits read data from being
  loaded into the instruction or data caches" and is ignored for writes and
  after the first transfer of a line (5.4.5). The instruction cache "does not
  monitor data accesses"; to run self-modified code, CPUSHA is "imperative"
  (4.5). A snooped write that hits drops an instruction-cache line (4.7.1,
  table 4-3, V6). Reset does not invalidate the caches: "Both caches should be
  explicitly cleared after a hardware reset" (4.1, 4.2).

So every cached Amiga CPU runs chip-RAM and ROM code from its instruction
cache. The old "only fast RAM" rule was stricter than any real machine, and it
cost exactly the speed the demo needs. Data is different. Chip RAM changes
under chipset DMA, and the 68040's data cache only sees that through bus
snooping, which this single-master bridge cannot do. So chip *data* stays
uncached, as it does under the OS's usual 040 setup.

## 3. Options

| | A: core I-cache + side-band invalidation (chosen) | B: 020-like loop buffer in the bridge | C: Turbo chip by default |
|---|---|---|---|
| chip-loop speed | I-cache hit: about 2 words/clock | one bridge transfer per long word, about 4-5 clocks | SDRAM line cache, about 2-3x slower than A |
| real-Amiga behaviour | yes (section 2) | close (a 256 B buffer) | no: changes chip-bus timing (Paul's "Turbo off" is the authentic mode) |
| ROM code | cached | cached only if the buffer is extended to the ROM | no |
| coherency | needs CPU-write and DMA invalidation, plus ordering (section 4) | invalidate on any chip write: as simple as the old TCI | unchanged |
| core change | small (a queue input, a WB hold, a WB refetch, a reset sweep) | none | none |

B would have been the fallback if A had been too invasive. It is not. The core
already had the I-cache snoop invalidation path, a refetch for snooped code
(EXC_SNR) and a refetch after stores into nearby code (`smc_pend`). A reuses
all three. Each step adds one push source or one hold condition. A is also the
only option that makes the ROM and chip-RAM code as fast as fast-RAM code.

## 4. Design

### 4.1 What may be cached (bridge, `ICHIP = 1`)

For an **instruction fetch** (TM 2/6) the bridge negates TCI if the address is
in one of these windows:

* chip RAM `$000000-$1FFFFF`, only while `ichip_ok`, i.e. chip RAM is 2 MB and
  the ROM overlay is off (`minimig.v`: `!ovl && &memory_config[1:0]`, the same
  condition Turbo chip uses). With less chip RAM the space has mirrors. With the
  overlay `$000000` reads the ROM.
* slow RAM `$C00000-$D7FFFF`, as gary decodes it from `slow_config`;
* the ROMs `$E00000-$E7FFFF` and `$F00000-$FFFFFF` (read-only to the CPU);
* configured fast RAM, as before.

Data from these regions still gets TCI. Device registers (`$BFxxxx`,
`$DFxxxx`, `$D8-$DF`), autoconfig, Akiko, RTG and undecoded space get TCI for
both instructions and data. `sim/ap040_bridge` checks every data transfer
outside fast RAM and every bench-register transfer.

### 4.2 Keeping the code coherent

The core gets a side-band port, `xinv`/`xinv_pa` (core `ap68040.sv`). It drops
the I-cache line at `xinv_pa` through the same queue the bus snooper uses
(MC68040UM table 4-3, V6). The bridge pushes three kinds of address:

1. **The CPU's own bus writes** (self-snoop) to the cacheable windows. They are
   presented combinationally with TS, so they reach the queue before the write
   can complete.
2. **Chipset DMA writes to chip RAM.** This is sdram_ctrl's chip-slot snoop
   (`snoop_stb`/`snoop_addr`, held for exactly one `clk_cpu` edge by
   `TG68K.vhd`'s `snp_stb_held`, as the reference core used it). It covers the
   blitter, disk DMA and the CPU's own chip-bus writes. The snoop address is
   the chip bus's SDRAM address. For chip RAM with 2 MB and no overlay that is
   the CPU address. Slow RAM and the ROM are written only by the CPU (case 1).
3. **A 4 KB page filter** (`pres`, 512 bits of LUT RAM). A bit is set when an
   instruction fetch asks to cache a chip-RAM page, before any of its data is
   read. Bits stay set; a sweep clears them while the CPU is held in reset. A
   write (CPU or DMA) to a chip page whose bit is clear cannot hit cached code,
   so it is not pushed. This keeps bitplane, audio and blitter traffic away from
   the core. A stale 1 costs only an extra lookup. A 0 is never wrong, because
   the bit is set before the line can be filled.

In the core (`lib/AP68040-faster`, commit 18526b9 plus the reset commit):

* The snooper's two-entry instruction-cache queue takes a second push source.
  Same-line pushes merge. On overflow the whole cache is invalidated, which is
  more than needed and never less.
* **The DMU holds a bus store at WB** (`st_rdy`) until the queue is empty. The
  store's own invalidation is therefore done before the store retires, even
  when a line fill holds the queue (the fetch takes no invalidation during a
  fill).
* **The back end refetches after a store whose snoop dropped code.** If
  `sn_ihit` fires while a store waits at WB, the instruction after the store is
  fetched again, together with everything younger: `wb_redir`, or `smc_pend`
  when the store is not its instruction's last uop. The existing `snp_pend`
  reaches only AG. A store into code followed at once by a call of that code
  could otherwise run instructions fetched from the old line that are already
  in DC1..EX (core test 4 fails without this).
* **Reset empties the instruction cache** (`RST_ICINV`, which the bridge sets
  to `ICHIP`). The host loads Kickstart and memory while the CPU is held in
  reset, and nothing snoops that. The 68040 itself keeps its lines (4.1).

Result: a CPU store into cached code runs as new code without CINV/CPUSH. That
is more than a 68020 or 68040 promises (4.5), and it is what old programs that
decrunch and jump, or that patch themselves, assume. DMA-written code is
dropped as the snoop arrives. A program that waits for the DMA to end (polling
a chipset register takes hundreds of ns) then runs the new code. The core test
uses NOP as that synchronisation.

### 4.3 The A/B switch

`ICHIP = 0` restores the old behaviour exactly: only fast RAM is cached, no
pushes, and reset leaves the cache alone. The switch is plumbed as follows:

* bridge parameter `ICHIP`
* `TG68K.vhd` generic `ap040_fast_ichip`
* `minimig_virtual_top` / `minimig_openaars_top` parameters `ap040_fast_ichip` /
  `AP040_FAST_ICHIP`
* the build: `FAST_ICHIP=0 vivado ... build_ap040.tcl ...`

Both defaults are 1. The ILA bus recorder (`ila_cpu040`, mode "fast") gains
`dbg_ir` bit 5 = the transfer may be cached, and bit 4 = an invalidation was
pushed since the previous transfer.

## 5. Verification

### 5.1 Core unit tests (`lib/AP68040-faster`, `tb/run_tests.sh`, Verilator)

New program `t_xinv`. It uses bench registers `$F2F0-$F2FC`: pokes behind the
core's back, an `xinv` per poke with a programmable delay, and a self-snoop for
each CPU write.

| test | what | RED (before / mutant) |
|---|---|---|
| 1 | a poke without `xinv` leaves the cached line (the code *is* cached) | passes before too; it guards the others |
| 2 | poke + `xinv`, ten times: new code | fails without the port (step 1 RED run) |
| 3 | four pokes on consecutive clocks (queue overflow): all new | (with the port) passes |
| 4 | store into a cached routine, then call it at once, 10x, BTB-predicted | fails without the WB refetch, 5/5 bus configurations |
| 5 | the same through MOVEM.L (store not the last uop) | fails without the WB refetch (isolated) |
| 6 | word store into the next instruction, DBRA loop | fails without the WB refetch (isolated) |
| 7 | the store's invalidation queued behind a DMA one (delay swept 0..31) | fails without the DMU hold (zero wait; +waits +tbi=2 +retry=10) |
| 8 | reset with a stale line: old line (68040), new code with `RST_ICINV` | fails with the reset sweep reverted, 5/5 |

The full suite is now 37 programs x 5 bus configurations:

* bench default: 185/185
* board configuration (`AP_FPU_PIPE=0 AP_LOOP_PRED=0 AP_EARLY_RES=0 AP_DC1_ATC=1 AP_DUAL=1 AP_BTIC=1`): 185/185
* board configuration + `AP_RSTINV=1`: 185/185

The baseline before the change was 180/180 in both configurations. Cycle
counts of the old 36 programs are unchanged, apart from one +bclk2 run of
t_cbsplit (+4 clocks). `tb_cputest` still builds.

### 5.2 Bridge bench (`sim/ap040_bridge`, new, Verilator)

This bench puts the core behind the real bridge on a model of TG68K's master
port, with chip/slow/ROM latency of 26 clocks and fast RAM 4. Program
`t_ichip` runs all ten tests and reports a failure mask.

| | result |
|---|---|
| `ICHIP=1` (design) | **PASS** (all 10) |
| `ICHIP=0` (old bridge) | FAIL mask `0x4c2`: tests 1 (chip loop), 6 (ROM), 7 (slow RAM), 10 (no pushes) |
| `MUTANT=noxinv` (pushes tied off) | FAIL mask `0x40c`: tests 2 (store-then-call), 3 (DMA), 10 |

A 2-instruction loop in chip RAM, 1000 iterations: the old bridge makes 6006
fetch transfers and the program reaches the end of test 1 at clock 383,617.
With ICHIP there are no fetch transfers after the line fill (the prefetch
fetched the line before the counter was cleared) and test 1 ends at clock
4,644. The same loop in fast RAM, the ROM and slow RAM fetches nothing after
its fill. At `$A00100`, `$C80100`
(slow RAM not configured) and in chip RAM with `ichip_ena` low it fetches
12,000 times. The bench also checks every data transfer outside fast RAM and
every device-register transfer for a negated TCI (never seen).

### 5.3 SoC (`sim/ddr3_cpu`, FASTER=1 CPU_RATIO=2 FREECORE=1)

* **xsim on the RTL** fails, and this is xsim's X start-up again. The core's
  cache RAMs start X in xsim (0 on the board and in Verilator):
  * `--ap040` fails in phase 2: `fetch: the table predecode of xxxx`.
  * `FASTCHIP=1 --chipbus` fails in phase 2, writing X to the DDR3 (`got
    XXZd`).
  * With `XDEFS="-d FASTNOICHIP"` (chip code uncached, the old behaviour) the
    same chipbus leg fails in phase 5 with code 8. That is the failure the
    faster core already had in xsim (commit `5afbf25`).

  Now that chip code goes through the I-cache, the X tags are reached
  earlier. Per the standing rule, this leg is untrusted for this core.
* **GLNET** runs on Vivado's netlist of bridge and core
  (`tools/vivado/glnet_bridge.tcl`, `glnet_rename.py`; new: the generator was
  never in the repo):
  both legs pass on the final netlist (core 1f059a9, bridge 4db06f7):

  | leg | result |
  |---|---|
  | `--ap040` (Turbo chip) | PASS: all 8 phases, DDR3 backdoor matches, DMA window 1130 writes / 0 wrong. ICHIP: 269 instruction-fetch transfers, all from chip RAM, all cacheable |
  | `FASTCHIP=1 --ap040 --chipbus` | PASS: all phases, backdoor matches, DMA 704 / 0 wrong, chip-slot cadence 34 clk launch-to-release (Fast). ICHIP: 316 fetch transfers, all from chip RAM, all cacheable |

  The bench now counts the bridge's instruction fetches and their TCI. It
  fails if no chip-RAM fetch was cacheable, which checks the
  `ichip_ok` -> `TG68K.vhd` -> bridge plumbing. Its 2,192-byte program is
  fetched about once and then runs from the I-cache: 269-316 transfers in all,
  i.e. 67-79 line fills. An earlier netlist without the reset sweep also
  passed `--ap040`. In the chipbus leg the program takes 96 us from phase 1
  to phase 5, against 728 us with chip code uncached (FASTNOICHIP, the source
  in xsim, before its X failure); the uncached run makes 1,728 fetch
  transfers by then.

### 5.4 Synthesis

The OOC synthesis of bridge and core (xc7a100tfgg676-2, 17.63 ns), against the
same synthesis of the previous bridge `cd08445` / core `6985f7d`:

| | before | after |
|---|---|---|
| LUT as logic | 31,087 | 31,592 (+505) |
| LUT as memory | 1,606 | 1,638 (+32: the page filter) |
| registers | 12,602 | 12,800 (+198) |
| block RAM tiles | 32 | 32 |
| synth WNS estimate | +5.06 ns | +5.08 ns |

The log has no `decloning`, no `inactive write enable`, and no new 8-3333 or
8-7257 on the cache, ATC or queue registers (`snoop/ic_pa_reg[3:0]` = 0 is
the 16-byte alignment).

### 5.5 The image

`build/stage_fast56_icchip_4db06f7/` holds `minimig_openaars_top.bit` (md5
`cde18f55e9177bd3e330a130fd615da7`), `.ltx` and the reports. It is superproject
4db06f7 with core 1f059a9 (the later commits change only sims and tools). The
build ran as the shipping fast56 images did:

```
LC_ALL=C LANG=C LD_LIBRARY_PATH=$HOME/lib/tinfo5 FASTRAM_ILA=0 \
  vivado -mode batch -nojournal -log <out>/vivado.log \
    -source tools/vivado/build_ap040.tcl -tclargs <out> 1 <repo> 1 20 1024
```

That is CPU ILA on at depth 1024, divider 20 (56.72 MHz), FASTER=1, ICHIP=1.
With the fast-RAM ILA as well (`FASTRAM_ILA` defaulting to the ILA argument)
the design needs 150 RAMB36 against 135, as the script's comment warns. The
first attempt failed placement on exactly that.

| | stage_fast56_dn_an_6785490 (shipping) | stage_fast56_icchip_4db06f7 |
|---|---|---|
| slice LUTs | 50,726 | 50,619 |
| registers | 34,199 | 34,358 |
| slices | 96.49 % | 96.75 % |
| block RAM tiles | 119 | 119 |
| clk_38 (the CPU island, 56.72 MHz) WNS | +0.971 | **+1.483** |
| clk_114 WNS (intra) | -0.264 (8) | -0.359 (10): upsampler `my_pal_to_ddr` |
| clk_gen_sdram -> clk_114 (dr_d pins) | -0.524 (16) | -0.544 (16) |
| clk_ddr100 -> clk_114 | -3.749 (3) | -3.787 (3): `ddr3_island/init_done_q` -> ILA trigger probes |
| clk_148, clk_ddr100, dll_28 | met | met |

Every failing endpoint belongs to a class that also fails in the shipping
image: the SDRAM `dr_d` input pins, the HDMI upsampler's `r_addra` replicas,
and the ILA's own probe registers. Nothing in the CPU island or the bridge
fails. Synthesis reports no `decloning` and no `inactive write enable`. The
page filter is LUT RAM (`pres_reg`, 512x1, RAM128X1D x 8, two copies). There
is no new 8-3333 or 8-7257 on the core's cache, ATC or snoop registers.

## 6. Risks and what to test on the board

### Risks

* **Invalidation load.** A chipset write to a chip page that holds cached
  code costs the fetch about three clocks (the tag lookup). It also holds a
  CPU store at WB while the lookup runs, which is usually hidden behind the
  480 ns chip write. During an instruction line fill from chip RAM (about
  110 clocks) the fetch takes no invalidations. More than two distinct lines
  queued in that time overflow the queue into a whole-cache invalidation:
  correct, but the cache is then empty, fast-RAM code included. Only blits
  into pages that also hold executed code can do this. The page filter keeps
  ordinary display and blitter traffic out. Watch `dbg_ir` bit 4 in an ILA
  capture if a demo is slower with ICHIP than without.
* **The filter only fills up.** A page that once held code stays in the
  filter until the next reset, so later DMA into it costs lookups. This
  matters only on chip-only machines that recycle code pages as bitmaps.
* **Ordering against DMA.** A DMA write is dropped from the I-cache a few
  clocks after it lands (the sdram snoop path, then the bridge, then the
  queue). Code the front end already holds is refetched from AG on; anything
  past AG at that moment ran before the write in program terms, as on any
  CPU. A program that waits for the DMA to finish (polling DMACONR, a
  chip-bus read of hundreds of ns) is safe.
* **Self-modification beyond the 68040.** CPU stores into cached chip/slow/ROM
  code are coherent (section 4.2). Fast-RAM code keeps the 68040 rule:
  CPUSHA/CacheClearU after a change, as before (copyback stores do not reach
  the bus).
* **Less than 2 MB of chip RAM, or the overlay on.** Chip code is not cached
  then: the old behaviour.
* **The OS's MMU still decides.** ICHIP only stops the *bus* from forbidding
  the cache (TCI). If a 68040.library's page tables or TTRs mark chip RAM
  non-cacheable, the core honours that for instruction fetches too (the 68040
  page descriptors serve both caches), exactly as a real A4000/040 does.
  MuFastChip exists for that case. A demo started from such a Workbench then
  still fetches chip code uncached. `ChipCoh` prints the chip caching mode it
  finds ("chip data caching as found: ..."). `dbg_ir` bit 5 in the ILA shows
  only the bridge's decision. With the MMU off (no SetPatch, or a
  floppy-booted demo) the 68040 default applies: cacheable (MC68040UM 4.3).
* **Area and timing.** See section 5 (the OOC synthesis and the full build).

### What to test on the board

Image: `build/stage_fast56_icchip_4db06f7/minimig_openaars_top.bit` (section
5.5). Turbo chip **off** unless stated, and Workbench on a *copy*
of the HDF (never the real disk with a new image).

1. **Nexus 7**, Chip slots **Standard**: the galaxy and ball scenes. The music
   should keep tempo and the demo should not hang. An ILA "fast" capture in the
   galaxy scene should show chip instruction fetches from page `$37000` falling
   from about 80 % of all transfers to a few line fills (`dbg_ir` bit 5 set on
   them).
2. The same with Chip slots **Fast**, and once with Turbo chip **on** (that
   setting must still work).
3. **Workbench boot** from the HDF copy, then a benchmark (SysInfo or AIBB)
   against `stage_fast56_dn_an_6785490` (0.88x 060@50). Expect equal or better.
   ROM code (exec, graphics) now runs from the I-cache.
4. **Self-modifying code**: `amiga_sw/ChipCoh/ChipCoh ONLY=AS` (and
   `ONLY=ICOFF`). CODEN-CHIP must report `fresh 5120 stale 0 other 0`. The
   chip routines are now cached, and only the self-snoop makes them fresh.
   CODEF-CHIP/FAST must PASS. CODEN-FAST may show stale code, as on a real
   68040. The blitter tests are unchanged (chip data is still not cached).
5. A Kickstart change from the OSD (e.g. 3.2.2 to 3.1 and back) and a few
   keyboard resets. Reset now empties the I-cache.
6. **A/B**: the same build with `FAST_ICHIP=0` is the old behaviour. Build it
   only if a regression needs bisecting.
