# Copyback data cache: plan

Status: **draft for Paul's review** (2026-09-29). Paul: "Lets go and do 4 [copyback], as it is the biggest gain."
Core branch to be: `copyback`, off `catchup` (be119bc and later).

## Why

On the board, xSysInfo shows **28,938 Dhrystones = 0.88** of an A4000/040 at 25 MHz. That is `stage_cu4`: store buffer, forwarding, return-address stack, precise fast reads, with the MMU on. The SoC bench matches the board within 1.5 %.

Dhrystone is store-heavy: about 120 stores per run. The data cache is **write-through**, so every store goes to memory:
- with the MMU on, stores are synchronous and WB waits for each one: 34 % of all clocks;
- with posting, the port still spends about 4.5 clocks per store and is busy half the time.

A 68040 under 68040.library runs fast RAM in **copyback** mode. A store that hits the data cache stays there, and the bus sees it only when the line is evicted or pushed. That is the main reason the real chip does more per clock.

Expected: store-hold from 34 % toward about 5 %, roughly **-15 to -25 %** clocks on Dhrystone. That is at or above parity with a 25 MHz 040.

## What the 68040 does (M68040UM 4.x, 3.x)

- **The page's cache mode (CM) decides**, from the ATC entry or a matching TTR. CM=00 is write-through, **01 copyback**, 10 and 11 cache-inhibited.
- **A copyback store hit** writes the cache line and marks it dirty; there is no bus cycle.
- **A copyback store miss** allocates the line: the 68040 reads the line, then writes it.
- **A dirty line chosen as the victim of a fill** is written back first.
- **CPUSH** (line, page, all) writes dirty lines back, then invalidates them. **CINV** invalidates *without* writing back: dirty data is lost, by definition.
- **The instruction cache is not coherent with data stores.** Code written through a copyback page needs CPUSH, which AmigaOS's CacheClearU does.
- **Bus snooping of a dirty line** is out of scope here. Alternate masters writing copyback memory need software support.

## Finding (2026-09-29, before any RTL): the cache's invalidation is row-wide

Every invalidate in ap040_cache.v zeroes a whole set (4 ways) through the tag RAM's port B in one clock:
- a chipset DMA snoop (free-running);
- a store that cannot merge (misaligned, line-crossing, inhibited);
- a cache-inhibited hit;
- a fill error.

CINV/CPUSH have no scope or address from the core either: every one sweeps the whole cache. The header calls this over-invalidation safe, and for write-through it is. **With dirty lines it loses data.** Chip-RAM DMA snoops alone would clear dirty fast-RAM lines that share a set, and a CINVL would drop every dirty line.

What copyback needs first:
1. The data bank's valid bits in flip-flops (a copy, dv[], already exists for the data read path), so that a row clear keeps the dirty ways.
2. The real CINV/CPUSH scope and address from the core: precise invalidation, and write-back for CPUSH.
3. A store that cannot merge writes back a dirty line under it first.

Only then the design below. Several days, with heavy verification (DMA snoop stress, every CINV/CPUSH scope, the fuzzer's copyback variant). Paul chooses: A full copyback, B store buffer stage 4 first (about 11 %, no cache redesign), C the store-path speedups.

RTG: the framebuffer is AllocMem'd from Zorro II RAM (MEMF_24BITDMA). `doc/workbench-setup.md` now tells users to mark `$200000`-`$9FFFFF` write-through in `ENVARC:MMU-Configuration`.

## Design

1. **MMU → cache: a copyback flag per access.** It is set when the cache mode is 01, from the TTR or the ATC, like today's `cache_inhibit`. With translation off and no TTR match the access stays write-through, exactly as now.
2. **Dirty state.** One dirty bit per line, in flip-flops next to the valid bits (64 sets × 4 ways). The data banks already hold whole lines.
3. **Store hit on a copyback page.** The line is updated, as the existing update path does, and marked dirty; the store is acknowledged without a memory write. A misaligned or line-crossing store stays write-through, as today.
4. **Store miss on a copyback page.**
   - Stage 1: **no allocate**. The store writes through, as today. That is simplest, and Dhrystone's stack and globals are read, and so resident, before they are written.
   - Stage 3 (if measured worth it): allocate.
5. **Eviction.** A fill whose victim way is valid and dirty first writes that line back: four longwords on `m_*`, where TG68K's RAM sequencer turns them into its own transfers. Then it fills. A bus error on a write-back is fatal, as for posted stores (halt).
6. **CPUSH and CINV.**
   - CPUSH, all three scopes, writes back dirty lines before invalidating them. The sweep FSM gets a write-back step, and CPUSHL/CPUSHP need the core's line/page address, which it already sends for CINV.
   - CINV drops dirty lines, as the 68040 does. Invalidating the data cache while it holds dirty lines is software's choice.
7. **The core's paths.**
   - The data read path (dfp), forwarding and the store buffer are unchanged: the cache holds the newest data, and reads that hit it are right.
   - Stores still go through the BCU. A copyback hit simply acknowledges in about 2 clocks instead of reaching memory.
   - With copyback, the MMU-on store buffer (stage 4) may no longer be needed; measure after this.
8. **Snoop.** A chipset DMA write to a line that is dirty in the cache still invalidates the line, and the dirty data is lost. A sim-only counter flags it. On the Amiga, chip RAM is never copyback, since 68040.library maps it write-through or inhibited, and fast RAM has no DMA writers. See decision 2 for RTG.
9. **The MMU's table walker reads memory directly.** Page tables in copyback pages would go stale; MMULib keeps its tables write-through, as the 68040 requires.

## Stages (each: full suite, the new programs, mutants, SoC Dhrystone with copyback, routed clk_38 timing near cu4's +0.258 ns)

0. **Tests first.** New compat programs, with DTT0 set to CM=01 over the work area, since the TTR CM works with translation off:
   - store hits leave memory untouched until a push;
   - eviction writes the line back;
   - CPUSHL/P/A write back, CINV drops;
   - MOVE16 through a copyback page;
   - a store miss writes through;
   - an I-fetch of code written through copyback needs a CPUSH;
   - a bus error on a write-back halts;
   - translation on with an ATC CM=01 page.

   A memory-image checker at the end of each program compares memory after CPUSHA with a reference model. The SoC Dhrystone loader gets a DTT0 copyback mode.
1. **MMU flag, dirty bits, store hit to copyback.** No eviction yet: copyback is restricted to lines that are never evicted in the tests, and the stage is not for the board.
2. **Eviction write-back, CPUSH write-back.** The first board image, behind `AP040_COPYBACK`, default 0.
3. **Write-allocate on a store miss**, if the SoC Dhrystone shows it worth it.

## Risks

- **Silent memory corruption**, the MISPLIT lesson. Mitigations:
  - the flat-memory fuzzer (`tb/perf/fuzz`) gets a copyback variant, with CPUSHA before its dump;
  - the board test includes file copies to and from the HDF and the SD card;
  - I/O correctness is checked before any benchmark.
- **Timing.** The dirty-bit update and the eviction path are in the cache (clk_38). Keep it registered.
- **RTG** (decision 2).
- **OS configuration.** The gain depends on 68040.library marking fast RAM copyback. If it uses write-through, nothing changes.

## Decisions for Paul

1. **Scope.** Copyback only where the page or TTR says CM=01, as a 68040 does. With translation off everything stays write-through. OK?
2. **RTG framebuffer.** It lives in the shared SDRAM (`rtg_addr`, minimig_virtual_top.v) and the RTG display reads it directly. If 68040.library maps it copyback, the screen shows stale pixels until lines are evicted or pushed. How is the RTG memory mapped under MMULib: its own board, marked cache-inhibited? If you don't know, I'll check what the RTG driver allocates. It may need a line in ENVARC:MMU-Configuration.
3. **Write-allocate** only as stage 3, if measured worth it. OK?
