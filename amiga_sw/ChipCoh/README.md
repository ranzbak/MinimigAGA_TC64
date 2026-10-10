# ChipCoh -- chip RAM coherency: CPU caches and store buffer vs blitter and copper

Open issue (doc/backlog.md, "Demos: garbage in TBL Ocean Machine and the
Roots2 rotozoomer"): stripes with the right colours in the wrong place, 68040
core only; not CHIP32, not the CPU's arithmetic. Suspects:

- the data cache (or a buffer in front of chip RAM) misses a chipset write,
  so the CPU reads a stale copy of chip RAM;
- the instruction cache runs generated code without a flush;
- the CPU's longword chip writes reach chip RAM after the blitter has read it.

Two coherency defects are already proven in simulation for Turbo chip RAM
(sim/sdram_coherency): the SDRAM controller's 16-byte line buffer
(`cpu_cache_new`) answers CPU reads and is never invalidated by a chipset
write, and CPU writes are acknowledged when they reach the write buffer, not
when SDRAM takes them. ChipCoh looks for both kinds on the board.

## Usage

    ChipCoh [ROUNDS=n] [ONLY=AS|DCOFF|ICOFF|OFF|FORCED]

Takes a few seconds (default 20 rounds). Run it from a Shell, redirect it to a
file to keep it: `ChipCoh >SD0:coh_turbo_off.log`. Return code 0 = all passed,
5 = something failed. The display skips one frame during each COPBLIT round.

## What it prints

    ChipCoh: CPU 68040 CACR 80008000 TC 0000c000 ITT0 ... DTT0 ... DTT1 ... URP ...
    buffers: src 0001e000 dst 0001f000 chip code 00020000 fast code 4a2b10 expect ...
    chip data caching as found: MMU on, page CM 2 (non-cacheable serialized)
    state AS: CACR 80008000
      BLITCPY    PASS 20 rounds
      BLITSTALE  FAIL 3/20 rounds, 12 longs; first @0001f2a0 exp 1234abcd got 89ab0123 again 1234abcd
      ...
      CODEN-FAST INFO fresh 0 stale 5120 other 0
    state DCOFF: CACR 00008000
    ...
    ChipCoh: done, 1 failed

(example values are illustrative)

The first lines are the CPU's cache and MMU registers as found, and how chip
RAM's data accesses are cached: by a transparent translation register, by the
MMU page (the descriptor's CM field), or -- MMU off and no TTR match -- by the
68040's default, cacheable write-through.

For a failure: rounds with errors / rounds, wrong longwords in total, and the
first wrong one: address, expected, got, and **again** = the same address read
after `CacheClearU` plus a read of another chip RAM line (which displaces the
SDRAM controller's line buffer):

- `again` = `exp`: chip RAM was right, the CPU saw a **stale copy** (data
  cache, or the turbo-chip line buffer);
- `again` = `got`: chip RAM itself is wrong (a blit read old data, or a CPU
  store was lost or landed late).

The address says which buffer: `src`, `dst` or a code buffer (see `buffers`).

## The cache states (68040; any other CPU runs AS only)

| state | CACR | chip RAM |
|---|---|---|
| `AS` | as found | as found |
| `DCOFF` | data cache off (DE = 0) | as found |
| `ICOFF` | instruction cache off (IE = 0) | as found |
| `OFF` | both off | as found |
| `FORCED` | both on | the test's chip pages made **cacheable write-through** in the MMU tables |

`FORCED` is a stress test of the core's snooping, not a normal configuration.
It needs the MMU on (MMULib or 68040.library) and no TTR covering chip RAM
(a TTR over $00xxxxxx also covers the custom chips, so ChipCoh will not change
it). The chip area is page-aligned so only ChipCoh's own memory changes; the
descriptors are put back afterwards. It assumes the page tables are mapped
1:1, as MMULib and 68040.library set them up.

## The tests

All buffers are 4 KB; each round uses new patterns.

| test | what happens | a failure means |
|---|---|---|
| `BLITCPY` | CPU fills src, `CacheClearU`, blitter copies src to dst, CPU reads dst | the basic path is broken |
| `BLITSTALE` | as BLITCPY, but the CPU reads dst before the blit | the CPU keeps a stale dst: cache (if dst is cacheable) or the turbo-chip line buffer |
| `BLITRMW` | CPU writes dst, then **at once** the blitter computes dst = src EOR dst | the CPU's posted chip stores reached chip RAM after the blitter read them (store buffer vs DMA ordering; `again` = `got`) |
| `STORESIZE` | 2048 byte/word/long stores at any alignment to src (and a fast-RAM shadow), then at once a blit src to dst; CPU reads src, then dst | in src: byte lanes or misaligned splitting on the CPU's chip path; in dst only: ordering against the blit |
| `COPBLIT` | the **copper** writes the blitter registers and BLTSIZE (COPCON danger bit), then requests COPER; the CPU had read dst before | as BLITSTALE, with a copper-started blit (`TIMEOUT` = the copper never got there) |
| `CODEF-CHIP`, `CODEF-FAST` | 256 routines `MOVEQ #k,D0 / RTS` written, `CacheClearU`, each called | `CacheClearU` does not make new code visible |
| `CODEN-CHIP`, `CODEN-FAST` | the routines rewritten **without** `CacheClearU` and called | INFO only: how many ran the new code (`fresh`) and how many the old (`stale`); `other` (neither) is a failure |

## What a real 68040 does, and what this core should do

A real 68040 does not snoop Amiga chipset DMA; that is why the OS keeps chip
RAM non-cacheable (MMULib/68040.library page attributes or a TTR).

| state | real 68040 (A4000, MMULib) | this core |
|---|---|---|
| AS, DCOFF, ICOFF, OFF | all PASS | all PASS |
| CODEN-CHIP | fresh (chip is non-cacheable for instructions too) | the same |
| CODEN-FAST, I-cache on | stale (the I-cache does not see data writes) | stale is normal; fresh means the I-cache snoops writes |
| CODEN-FAST, I-cache off | fresh, unless fast RAM is copyback (then the new code is still in the data cache: stale) | the same |
| FORCED: BLITSTALE, COPBLIT | FAIL (no snoop; `again` = `exp`) | should PASS -- the core snoops chipset writes; a FAIL is a snoop gap |
| FORCED: BLITRMW, STORESIZE | PASS (write-through) | PASS |
| FORCED: CODEN-CHIP | stale | stale |

A failure in **AS** is the interesting one: that is how the demos run. If AS
fails only with Turbo chip on, it is the SDRAM controller's turbo-chip path
(the line buffer for stale reads, the early write acknowledge for BLITRMW). If
everything passes in both Turbo settings, the demo garbage is not one of these
coherency problems; the next suspects are chipset timing (copper/blitter
against the display, see the backlog's bitplane-commit A/B).

With the MMU **off** (no MMULib, no 68040.library) and no TTR over chip RAM,
the 68040 caches chip RAM by default: AS then behaves like FORCED, and the
summary line says so.

## Board sequence

1. Boot as usual (MMULib as installed). OSD: Turbo chip **off**.
   `ChipCoh >SD0:coh_t0.log`
2. OSD: Turbo chip **on**. `ChipCoh >SD0:coh_t1.log`
3. Any FAIL: repeat that state with more rounds to see how often,
   e.g. `ChipCoh ROUNDS=500 ONLY=AS >SD0:coh_t1_as.log`.
4. Optional: the same on the 68020 image (AS only) for comparison, and with
   CopyBack set on fast RAM (CODEN-FAST changes, the rest must not).

## Build and test

    make            # ChipCoh, vasm -m68040 (MOVEC TC/TT/URP, CPUSHA, PFLUSHA)
    make test       # test_chipcoh.sh: vamos plumbing test

`test_chipcoh.sh` runs a `-DVAMOS=1` build under vamos (amitools, python3.10).
vamos has no blitter, copper, caches or MMU: the VAMOS build writes every
blitter and copper register as on the board (vamos logs them) and then does
the blit in software, so the checking side runs for real -- patterns,
expected buffers, the compare, the report, the code generator. A second build
with `-DFAULT=1` flips one bit of every blit's destination; every blitter test
must then FAIL and name that longword (dst + $44, got = exp ^ 1, again = got).
The test checks all five states on a 68040 (FORCED skipped: no MMU), AS only
on a 68020, ROUNDS/ONLY, a refused bad option, the return codes, and the
register order (BLTCON0 before BLTSIZE; COPCON danger bit and the COPER clear
before COP2LC and the COPJMP2 strobe; the OS's COP2LC and COPCON 0 after).

**Only the board can show** whether the chipset and the caches are coherent,
the page-table walk and patch for FORCED, and that the copper really starts
the blit.
