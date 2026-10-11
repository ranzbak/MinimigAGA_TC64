# Chip slots "Fast" -- results

Paul, 2026-10-10: "Can we have next to turbo mode also the every free slot mode".  Base: 9f969de (branch combo =
superproject 5.0-040-pipelined).  Board measurement that started it (xSysInfo): chip RAM 3.1 MB/s with Turbo chip off,
16.9 MB/s with it on; The Cure's music stutters and serial 115200 overruns only with Turbo chip off.

## What the real AGA chip bus allows

**At most one CPU chip cycle in two CCKs (560 ns), 32 bits wide; never consecutive CCKs.**  "Every free CCK" is not
what an A1200 or A4000 does.

- WinUAE `custom.cpp` `wait_cpu_cycle_read_ce020()` / `wait_cpu_cycle_write_ce020()` (master, fetched 2026-10-10, lines
  12616 / 12680): `sync_cycles(); x_do_cycles_pre(CYCLE_UNIT); dma_cycle(&ipl); <access>; x_do_cycles_post(CYCLE_UNIT, v);`
  `CYCLE_UNIT` (512, `include/sysdeps.h`) is one CCK (`HSYNCTIME = maxhpos * CYCLE_UNIT`).  `dma_cycle()` (12453) steps
  one CCK at a time while `read_rga_out()->alloc > 0`.  So an access lands in the first DMA-free CCK at least two CCKs
  after the previous one, and DMA may take the CCK in between.  Reads and writes are identical.  The 68040 uses the same
  functions (`mem_access_delay_*_c040`, newcpu.cpp); AGA chip RAM is `CE_MEMBANK_CHIP32` (memory.cpp), one access per
  aligned longword.
- Jens Schoenfeld (Individual Computers), forum.icomp.de thread 4510 "AGA - is the CPU access to chipram 32-bit?": "Yes,
  it's 32-bit. The limiting factor is time slots of the chip set - the CPU only gets every other time slot ... just under
  7.1MB/s."
- Kalms, EAB "Write waitstates on the 68020+": an 030/50 starts a chip write every 28 clocks = 560 ns = 2 CCK.

So the authentic ceiling is 4 bytes per 2 CCK = 7.09 MB/s (PAL), less whatever display DMA takes.

## Where today's core loses

The minimig side already follows that rule: the bridge grants the CPU a CCK only if Agnus left its DMA half free (dbr),
and sim/chip32's ideal master gets exactly one slot per 2 CCK.  The loss is in the wrapper's 68000-style chipset machine
(rtl/soc/TG68K.vhd S_state): it releases the CPU at the ena7RDreg ONE AND A HALF rounds after the slot, and the next
launch must then happen on the very next ena7WRreg (8 clk later) to make the 2-CCK cadence.  The real CPU needs 10-15
clk from release to its next request (sim/ddr3_cpu "CHIPBUS release->next request" histogram, both cores), so back to back
accesses run at 3 CCK, not 2.

## The design

`fastchip` (OSD Chipset menu "Chip slots: Standard / Fast" -> config.cpu bit 4 -> SPI OSD_CMD_CPU data bit 4 ->
userio_osd cpu_config[4] (live, like Turbo) -> minimig `fastchip` -> TG68K `fastchip`, registered as `fastchip_d` at the
Turbo switches' safe point).  Reset state and old firmware (which sends `cpu & 0x0f`): 0 = Standard.

With `fastchip_d = 1`, state "10" on the ena7WRreg whose round sampled dtack low (waitm = 0) is the END of the CPU's chip
slot (bridge dtack at phase 8 of the cck-high round, slot taken at phase 1 of the cck-low round, read data latched by the
bridge at phase 12, this ena7WRreg at phase 15).  There the cycle drops its strobes, captures data_read/data_read2 into
r_data/r_data2 and answers the CPU two clk later (fast_p1 -> fast_ready -> chipset_ready; two because datatg68_c is one
more register behind r_data).  The next launch still waits for an ena7WRreg in state "00", the bridge's grant rule is
untouched, so:

- the CPU never uses a CCK whose DMA half was used (Agnus/dbr decides, as before),
- the CPU never uses two consecutive CCKs (authentic 2-CCK spacing),
- the CPU now hits the 2-CCK cadence whenever it re-requests within ~2 rounds of the release (bench: CPU latency up to
  24 clk + the task's 2), instead of within 8 clk.

Nothing in minimig, gary, the bridge or sdram_ctrl changed; DMA (bitplanes, sprites, copper, blitter, audio, disk,
refresh) keeps exactly its slots.  With Fast the bridge sees the address strobe rise at the end of the slot round rather
than mid-way through the next (cck-high) round, where it is unused: enable needs cck low, bls needs dtack high, so both
are 0 there either way.  The blitter's bls (CPU waiting) can change timing in Fast mode only through the CPU asking for
slots more often, which is what the real machine does too.

Every free CCK (14.2 MB/s) would need the next access's address on the bus before the previous one completes (a
pipelined/burst chipset cycle) -- not authentic, not built.

## Benches

All runs from the working tree of the commit; RED = before the wrapper logic.

### sim/chip32 (bridge + gary + bank mapper + SRAM bridge + real sdram_ctrl + SDRAM model; master = S_state transcription)

New: `+fast` transcription, CCK accounting over the whole run (steal = CPU chip slot in a DMA CCK, b2b = CPU chip slots in
consecutive CCKs; both judged), T8 rate stream at CPU latency 0/6/12/24, T9 2048 CCKs of CPU-independent DMA (8 patterns,
reads and writes) under checked random CPU traffic with the DMA slots written to a file, T10 P2C (DMA reads a word in the
CCK after each CPU write of it), a trace checksum over T1-T7, two new mutants.  `./run.sh`, 2026-10-11:

    std:  T1-T7 slots 0:0 1:1079 2:0 3+:0, 2083 checks, 0 errors; checksum c140f8a19ea7e96d  (= the bench before fastslot)
    std:  T8 lat 0/6/12/24: 2.00 / 2.00 / 3.00 / 3.00 CCK per access
    std:  T9 435 CPU accesses; T10 480 DMA reads, 0 wrong; CCK accounting steal 0, b2b 0; 4586 checks, 0 errors: PASS
    fast: T8 lat 0/6/12/24: 2.00 / 2.00 / 2.00 / 2.00 CCK per access (every period exactly 2)
    fast: T9 610 CPU accesses (1.40x); T10 321, 0 wrong; steal 0, b2b 0; 4940 checks, 0 errors: PASS
    T9: Standard and Fast DMA traces identical (1264 DMA slots)
    std_gated (Standard under the Fast rate gate): failed as required (T8 lat 12, 24)   <- the RED for the rate
    mut_word2 / mut_nowr2: failed as required (T2 / T3)
    mut_steal (bridge never sees dbr, Fast): failed as required (30 steal)
    mut_early (Fast cycle ends a round early): failed as required (30 slots)

The checksum reference is the HEAD bench plus the checksum monitor alone (c140f8a19ea7e96d).

### sim/ddr3_cpu --chipbus (real AP68040 + real TG68K.vhd + real sdram_ctrl; its chipset always acks, no CCK)

New: CHIPBUS cadence monitor (print-only) and, with `FASTCHIP=1`, a gate: launch->release <= 40 clk on average.

| leg | phase 1 | phase 8 | launch->launch | launch->release | release->next req | result |
|---|---|---|---|---|---|---|
| reference core, HEAD (base) | 273101922 ps | 1109610162 ps | 87.19 clk | 56.00 | 20.79 | 2 passed |
| reference core, port stub, FASTCHIP=1 (RED) | 273101922 | 1109610162 | 87.19 | 56.00 | 20.79 | FAIL FASTCHIP (56 clk) |
| reference core, Standard | 273101922 | 1109610162 | 87.19 | 56.00 | 20.79 | 2 passed, identical to base |
| reference core, FASTCHIP=1 | 266614082 | 863918482 | 62.43 | 34.00 | 20.29 | 2 passed |
| pipelined core, FASTCHIP=1 | 261536642 | 776050562 | 53.05 | 34.00 | 12.75 | 2 passed |
| pipelined core, Standard | 267601362 | 1046565282 | 80.58 | 56.00 | 13.28 | 2 passed |

Standard is bit-identical to HEAD: every phase timestamp, 1148 chipset cycles, 1062 wide / 86 narrow, the cadence
histograms.  Phase 1 -> 8, Standard -> Fast: reference core 836.5 -> 597.3 us (1.40x), pipelined core (the board's,
generics at the bench defaults; PIPELINED=1 PIPE_DIR=lib/AP68040-pipelined) 779.0 -> 514.5 us (1.51x).  The pipelined
core re-requests faster (release -> next request mostly 10-12 clk), so more of its accesses make the 2-CCK window.

### sim/sdram_coherency (the Turbo chip coherency bench; sdram_ctrl's CPU port, untouched here)

`fast sg7 +nobg +rounds=50`: 57 errors, 0 timeouts (line buffer primed 50/50, P2C 6 late / 0 lost, P2C longword 1).
`fast sg7 +rounds=50`: 5 errors, 0 timeouts (P2C 2 late, P2C longword 3).  Both outputs are byte-identical to the same
legs on the HEAD tree, so the two known Turbo chip bugs (unsnooped line buffer, posted writes late to the chipset) are
still found and untouched.  (The 52 / 14 references in findings/ap68040/stage-e/e4a-results.md predate later
sdram_ctrl/cpu_cache_new commits, e.g. 0a6091a and bc5dda6; HEAD itself gives 57 / 5.)

Fast mode does not use that port at all (chip RAM goes through the chip slot); its coherency is T6a/T10 above.

### sim/osd_keyq (userio_osd)

New section OSD_CMD_CPU: 0x1d -> cpu_config[4:2] = 111, an old firmware's 0x0d -> 011 (Standard), 0x10 -> 100.
HEAD userio_osd: 2 failures (bit 4 dropped); now PASS; the queue mutant still fails.

## Expected on the board

Back-to-back chip accesses go from 3 CCK to 2 CCK (1.5x); the bench workloads show 1.40x.  xSysInfo's 3.1 MB/s should
become roughly 4-4.5 MB/s; the hard ceiling is 7.1 MB/s with no display DMA.  Turbo chip (16.9 MB/s) stays far ahead --
it is not on the chip bus at all.

## Risks for the build

- Timing: `chipset_ready` gains one registered term (fast_ready) on its way into chipset_done, c32_done, bus_ready16 and
  so clkena_r's D input -- all register-to-register, one LUT input more.  r_data/r_data2 gain a second capture point
  (ena7WRreg in state "10"); data_read comes from the bridge's ldata_in on dll_28, latched 4 clk_114 edges before that
  ena7WRreg, which is exactly wizard.xdc's dll_28 -> clk_114 multicycle (-setup 4).
- Phase assumption: the Fast end relies on the bridge raising dtack after the cck-high round's ena7RDreg (phase 8 vs 6),
  which is fixed by amiga_clk and sdram_ctrl's round sync.  sim/chip32 uses a copy of amiga_clk's enables and the real
  bridge/sdram_ctrl; mut_early shows an end one round early is caught.
- sim/chip32's master is a transcription of S_state (deferred chip32 review item M2 still holds); sim/ddr3_cpu runs the
  real wrapper but its chipset always acks.

## Board (build/stage_fastslot, 2026-10-11, Paul)

xSysInfo chip RAM, Turbo chip off: Chip slots Standard 3.1 MB/s, Fast 4.4 MB/s (1.42x; the benches
predicted 1.40-1.51x).  Turbo chip on stays at 16.9 MB/s.
