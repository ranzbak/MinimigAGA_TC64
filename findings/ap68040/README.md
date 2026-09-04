# AP68040 + DDR3 — implementation plan

Everything in this directory was established by reading the sources, by Vivado
out-of-context synthesis/place-and-route on the xc7a100t-2, and by the board
schematic and the Micron datasheet. No RTL or constraint has been modified.

| Document | What it settles |
|---|---|
| [compatibility.md](compatibility.md) | The core is a drop-in for the TG68K port set; fits after one RAM-primitive fix |
| [performance.md](performance.md) | Measured Fmax and the realistic clock options |
| [memory-masters.md](memory-masters.md) | The seven DRAM masters in `sdram_ctrl.v` and the SDRAM/DDR3 split that serves all of them |
| [ddr3-fast-ram.md](ddr3-fast-ram.md) | Why DDR3 helps (de-contention, capacity, RTG) and the MIG route |
| [ddr3-dll-off.md](ddr3-dll-off.md) | The in-domain DLL-off route, schematic and datasheet facts, resource cost |
| [synth-reports/](synth-reports/) | Raw Vivado reports and the Tcl that produced them |

## Decisions taken

| Decision | Chosen | Because |
|---|---|---|
| CPU core | **AP68040**, `ap040_tg68k_compat` top | TG68K-shaped ports, 040 ISA + 4 KB/4 KB caches + FPU, passes 3776/3801 cputest; 28.7k LUTs after the `dpram.v` fix |
| CPU clock | **28.36 MHz first, then `clkena` every 3 = 37.8 MHz** | every core path fits 26.45 ns post-route; every-2 does not (1148 paths) |
| Fast RAM + RTG framebuffer | **DDR3, DLL-off, CK = `clk_114` ÷ 2 = 56.7 MHz**, own controller with IDDR/ODDR PHY | in-domain (no CDC), ≈ 1k LUTs vs MIG's ≈ 5–6k, 227 MB/s is above what this CPU can use; 113 MHz as a later stretch |
| Chip RAM, Kickstart, OSD soft core (832), audio | **stay on the SDRAM and `sdram_ctrl`, unchanged** | deterministic 7 MHz slots; OSD must work when nothing else does |
| Read capture in DLL-off | **fixed phase, trained at init, re-checked periodically** | `tDQSCK(DLL_DIS)` = 1–10 ns; DQS-clocked capture on 7-series means the hard PHY = MIG |
| I/O standard, bank 16 | `SSTL15` / `DIFF_SSTL15`, `INTERNAL_VREF 0.75` | VCCO_16 = 1V5 on the board; VREF pins are used as I/O |
| Line port | **one 16-byte fill / masked write-back port, two back-ends** (SDRAM now, DDR3 later) | designed once; DDR3 becomes a back-end swap |

## Order of work

Prerequisites from the other findings that must land first:

* [../constraints/fix-04](../constraints/fix-04-tg68k-blanket-multicycle.md) —
  rewrite the CPU multicycles by **enable domain**, not by instance name, or
  they silently stop matching when the kernel is replaced.
* [../constraints/fix-05](../constraints/fix-05-cdc-false-path.md) — async
  clock groups instead of false paths; needed before any new port/domain.
* [../constraints/fix-12](../constraints/fix-12-sdram-read-capture-clock.md) —
  the SDRAM read path is the interface the split leans on for chip RAM;
  fix it before loading it differently.

Then, in this order. Effort: S = hours, M = days, L = a week or more including
bench time.

| # | Step | Effort | Depends on | Exit criterion |
|---|---|---|---|---|
| A1 | Replace `AP68040/rtl/primitives/dpram.v` with the one-process-per-port version ([synth-reports/dpram_xilinx.v](synth-reports/dpram_xilinx.v)); run `tb/run_tests.sh` | S | — | all tests pass; OOC synth ≈ 28.7k LUTs, 10 BRAM |
| A2 | Wrapper `rtl/soc/AP040.vhd` with the `TG68K.vhd` port set; `cpu(1)` fixed high; `cache_snoop_*` from `sdram_ctrl` snoop; `cache_z*` from autoconfig; `walker_*` tied off **for this step only** (boot with `68040.library NOMMU`) | M | A1, fix-04 | boots AmigaOS 3.x at 28.36 MHz through the existing 16-bit bus |
| A3 | Baseline measurement: `bench_loop` on TG68K vs AP040, plus a fast-RAM memory benchmark on hardware | S | A2 | numbers in a table here |
| B1 | 16-byte line port on the CPU side: expose the 32-bit `b_*` master, route fast RAM to it, everything else through `bus16`; widen `cpu_cache_new`'s read side to 32 bits, extend `longword_en` to reads | M | A2 | longword fast-RAM access = 1 `clkena` |
| B2 | Line-fill back-end on `sdram_ctrl` (`CPU_READCACHE` slot streams the 8 words straight into the 040 cache port) | M | B1 | line fill = one round instead of 12 `clkena` |
| **B3** | **Walker port**: 32-bit read/write single-access requester on the same address router as the CPU master (chip RAM → SDRAM CPU port, fast RAM → DDR3 line port); no CDC needed in-domain | S–M | B1 | `68040.library` boots **with** MMU; MuFastROM remaps Kickstart into fast RAM and runs |
| C1 | DDR3 bench work with the existing signal test: full init with MR1 DLL-off, ZQCL, refresh, one BL8 write/read at 50 MHz, scope on DQS → **measure `tDQSCK` on this board** | S–M | — | number recorded here; decides C2's capture margin |
| C2 | DLL-off controller at CK = `clk_114` ÷ 2: ODDR CK/DQS/DQ/DM, trained capture clock + per-lane `IDELAYE2`, refresh, bank FSM; standalone testbench with the Micron model in DLL-off (`lib/models`, same method as `sim/sdram_timing`) | L | C1 | write/read pattern test passes at both simulated corners; training converges on hardware cold and hot |
| C3 | Two-requester arbiter: RTG scan-out FIFO with watermark priority, CPU line port; optional 832 peek/poke port | M | C2 | RTG never underruns at 720p16 with the CPU hammering fast RAM |
| C4 | Memory map: Z2/Z3 autoconfig space → DDR3; RTG framebuffer → DDR3; remove fast RAM from `sdram_ctrl`; simplify its slot rules | M | C3, B1 | SDRAM round shows only CHIP/HOST/AUDIO/REFRESH |
| D1 | `clkena` every 3 (`enaWRreg` on 5 of 16 phases) + `-setup -start 3 / -hold -start 2` on the CPU island; measure | S | A2 | timing closes; A3 benchmark improves ≈ 25–30 % |
| D2 | Clean form: sibling 37.8 MHz clock for the CPU island, `clkena_in` = handshake only, multicycles removed | M | D1 | `report_exceptions` shows none on the core |
| E1 | 113 MHz DLL-off (IDDR capture, 4.4 ns eye) — only if C2's drift data leaves margin | L | C2 data | — |
| E2 | NetBSD/amiga bring-up on the MMU (walker port from B3, restart-model caveat in the AP68040 README) | M | B3, C4 | — |
| E3 | FPU enable (+10k LUTs, +16 DSP) | S | A2 | fits: ≈ 40k / 63.4k LUTs |

A and B are independent of C; C1 can start today. The two tracks meet at C4.

**MMU is needed on AmigaOS, not only NetBSD**: `68040.library` builds page
tables and enables translation at boot (that is how a real 040 gets its
cache modes), and MuFastROM/MMULib remap Kickstart into fast RAM through it.
Hence B3 sits in the main line, not in the extras. Once B3 and C4 are in, ROM
fetches come from DDR3 through the line port and the SDRAM-side `turbokick`
hack is redundant for 040 users.

## Budget check (LUTs of 63,400)

| State | LUTs |
|---|---|
| Today | 14,375 |
| After A2 (AP040 without FPU, TG68K removed) | ≈ 29,000 |
| + C2/C3 DLL-off controller | ≈ 30,000 |
| + E3 FPU | ≈ 40,000 |
| (same with MIG instead of C2) | ≈ 45,000 |

## Numbers to fill in as they are measured

| | Value | Where measured |
|---|---|---|
| `tDQSCK(DLL_DIS)` on this board, cold / hot | — | C1 |
| AP040 vs TG68K `bench_loop` cycles per instruction | — | A3 |
| Fast-RAM longword read, `clkena` count, before/after B1 | 3 → — | A3 / B1 |
| Line fill, ns, SDRAM back-end vs DDR3 | — | B2 / C3 |
| Post-route WNS with the AP040 in the full design | — | A2 |
