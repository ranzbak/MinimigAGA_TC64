# Memory masters — who needs the DRAM, and how the split has to respect that

Source: `rtl/sdram/sdram_ctrl.v` (Tobias Gubener, 2009/2011, TC64 lineage) and
`rtl/sdram/cpu_cache_new.v`. Everything below is what the code does today.

## The masters

`sdram_ctrl.v:110-118` names them:

```verilog
localparam [2:0]
REFRESH = 0, CHIP = 1, CPU_READCACHE = 2, CPU_WRITECACHE = 3,
HOST = 4, RTG = 5, AUDIO = 6, IDLE = 7;
```

| Master | Port on `sdram_ctrl` | What it is | Bank rule | Access shape |
|---|---|---|---|---|
| **CHIP** | `chipAddr/chipRW/chip_dma/chipWR/chipWR2/chipRD/chip48` | Chipset DMA and CPU chip-RAM/Kick cycles on the 7 MHz bus | bank 0 only (`:538`) | 1 word write + 2nd word, or 4-word read (`chipRD` + `chip48`, `:303-313`) |
| **REFRESH** | internal, `refreshcnt` | one AUTO REFRESH per 51 rounds (`:106`) | blocks slot 1, needs slot 2 idle (`:547`) | — |
| **CPU_READCACHE** | `cpuAddr/cpustate/cpuL/cpuU/cpuRD` via `cpu_cache_new` | 68k fast RAM / turbo chip / turbo kick reads, 8-word line fill | banks 1–3 in slot 2, any in slot 1 | 8-word burst |
| **CPU_WRITECACHE** | `cpuWR` via the cache write buffer | 68k writes, 2 words per slot | same | 2 × single write |
| **HOST** | `hostAddr/hostWR/hostRD/hostce/hostwe/hostbytesel` | the **EightThirtyTwo soft core** — OSD menu, firmware, disk/keyboard glue — mapped to `0x680000` (`:245-249`) | bank 0 only (`:596`) | 1–2 words |
| **RTG** | `rtgAddr/rtgce/rtgfill/rtgRd` | **RTG framebuffer scan-out** | banks 1–3, slot 2 only (`:669-676`) | 8-word burst, `rtgfill` pulses per word |
| **AUDIO** | `audAddr/audce/audfill/audRd` | Toccata sample buffers | bank 0, slot 1 (`:583`) | 8-word burst |

Plus the **snoop** side of `cpu_cache_new` (`:288-291`): every CHIP write is
presented to the CPU cache so cached chip RAM stays coherent — this is why chip
RAM can be cached at all.

## The arbiter

One 16-phase round per 7.09 MHz chipset cycle (141 ns), two access slots that
overlap on different banks (`:760-776`):

```
slot 1, allocated at ph1  (:530-608):   CHIP > REFRESH > CPU write > CPU read > AUDIO > HOST
slot 2, allocated at ph9  (:665-703):   RTG  > CPU write > CPU read
```

with the guards computed at `:423-436`: a slot-1 CPU access must not hit the
bank slot 2 is using and vice versa; bank 0 is reserved for slot 1 (`:426`);
HOST is "lowest priority, don't bother throttling" (`:434`, the `hostslot_cnt`
starvation guard is commented out — that is the "starve" at `:554`).

Each slot moves **8 words per round**: 16 bytes / 141 ns = **113 MB/s per
slot, 227 MB/s total**, and that is the whole memory system.

## What each master actually consumes

| Master | Demand | Share of a slot |
|---|---|---|
| CHIP (AGA, 4-word `chip48` reads every round when DMA is active) | up to 8 B / 141 ns ≈ **57 MB/s**, and it always wins slot 1 | ≈ ½ of slot 1, deterministic |
| RTG at 1280×720, 16 bpp, 60 Hz | ≈ **110 MB/s** continuous during active video | **≈ 100 % of slot 2** |
| AUDIO (Toccata, 2 × 16 bit × 48 kHz) | 0.2 MB/s | negligible |
| HOST (832, OSD) | bursts while the menu is open, otherwise idle | small, but lowest priority |
| CPU | whatever is left | slot 1 leftovers when CHIP is idle; slot 2 leftovers when RTG is idle |

So with RTG active, slot 2 is gone and the CPU competes with the chipset for
what slot 1 has left. That is the number that limits the 68k today, before any
question of clock rate or bus width — and it is why the earlier notes proposed
moving both RTG and CPU fast RAM off this controller.

## The split, respecting all of them

| Master | Stays on SDRAM (`sdram_ctrl`, unchanged) | Moves to DDR3 |
|---|---|---|
| CHIP — chip RAM, Kickstart, chipset DMA | **yes** — deterministic slot, 7 MHz bus, snoop path | never: MIG/DDR3 refresh and training stalls are not deterministic |
| REFRESH | yes | (DDR3 has its own) |
| HOST — 832 soft core / OSD | **yes** — it lives in bank 0 next to chip RAM, tiny demand, and the menu must work when nothing else does | no |
| AUDIO | yes | no |
| CPU fast RAM (Z2/Z3) | no longer | **yes** — private line port |
| RTG framebuffer | no longer | **yes** — streaming port with guaranteed bandwidth |
| CPU turbo-chip / turbo-kick | yes (it *is* chip RAM / Kick) | no |

After the split the SDRAM round serves CHIP + HOST + AUDIO + REFRESH: slot 2
is empty, slot 1 is half used, and the chipset never waits. The 832 keeps its
bank-0 home; the OSD keeps working exactly as now.

## What the DDR3 controller therefore has to be

Not a single-master line port. Minimum two requesters with different service
classes, on the DLL-off controller from [ddr3-dll-off.md](ddr3-dll-off.md):

| Requester | Shape | Service |
|---|---|---|
| CPU line port (68040 fill / write-back, or `cpu_cache_new`'s `sdr_*` bus) | 16 B read, 16 B masked write | latency-sensitive, bursty |
| RTG scan-out | 16 B reads, sequential, continuous during active video | **bandwidth-guaranteed** — a line FIFO ahead of the pixel pipe, refilled whenever below a watermark; must never underrun |

Arbitration: RTG wins whenever its FIFO is below the watermark, CPU otherwise;
RTG's need is fixed and predictable, so a watermark-driven grant is enough —
no round-robin needed. Budget at the ÷2 clock: 227 MB/s − 110 MB/s RTG leaves
≈ 117 MB/s for the CPU, which is more than a 28–38 MHz 68040 through a 16-byte
line port can consume. At 113 MHz DLL-off (454 MB/s) it stops being a concern
at all, and 32-bpp or higher RTG modes become possible.

A third requester is required, not optional: the **MMU table walker** —
32-bit single reads and read-modify-writes of page descriptors, routed by
address to whichever memory holds the tables (fast RAM here, chip RAM on the
SDRAM side). `68040.library` uses the MMU on AmigaOS; MuFastROM remaps
Kickstart into fast RAM through it, after which ROM fetches are line fills from
DDR3 and the SDRAM `turbokick` path is idle for 040 users.

A fourth is optional and cheap: a **host/debug port** so the 832 can
peek/poke DDR3 for tests and for loading the RTG framebuffer from the menu.
It does not need bandwidth, only access.

## Snoop after the split

`cpu_cache_new` snoops CHIP writes because chip RAM is cacheable. Nothing on
DDR3 is written by anyone but the CPU (RTG scan-out only reads; the RTG
*blitter* writes come from the CPU side), so the DDR3 line port needs no
snoop. The chip-RAM snoop path stays where it is. If the 68040's internal
D-cache is enabled for chip RAM, it takes the same `snoop_act`/`snoop_adr`
the SDRAM side already produces ([compatibility.md](compatibility.md)).

## One thing not to lose

`cpu_cache_new` is what makes SDRAM tolerable for the CPU today: line fills,
a write buffer, and the snoop. On the DDR3 side the 68040's own caches take
that role. On the SDRAM side — turbo chip and turbo Kick — it must stay, or
those modes regress.
