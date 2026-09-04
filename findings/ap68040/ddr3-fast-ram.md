# DDR3 as fast RAM — would it help, and why it looked incompatible

Board facts (QMTech XC7A100T core board, vendor MIG example
`Software_XC7A100T/Test04_DDR3_mig_7series_0_1_ex.zip`, pins in
`Software_XC7A100T/DDR3.ucf`):

| | |
|---|---|
| Device | **MT41K128M16-15E** — DDR3L, 2 Gbit, x16, **256 MB** |
| MIG configuration that works on this board | 400 MHz (2.5 ns), 200 MHz input clock, 4:1 PHY, BL8 |
| User interface | `ui_clk` **100 MHz**, `app_rd_data`/`app_wdf_data` **128 bits** = one BL8 burst = **16 bytes per command** |
| Pins | 47, SSTL135, dedicated to the core board — no conflict with the OpenAARS I/O board |
| Peak bandwidth | 1.6 GB/s (vs 227 MB/s for the 16-bit SDRAM at 113 MHz) |

There was an earlier attempt in `~/work/fpga/Xilinx/artix7/open_aars_minimig.Mister`
(May–July 2020: "Working clock setup with memory at 333MHz DDR" → "Debug
snapshot: Check the CPU address/data bus" → "Commit before removing DDR3").
So MIG calibration on this board is known to work. What that attempt got wrong
is instructive — see "Why it looked incompatible".

## Does it help? Yes — for three reasons, none of them latency

**1. It takes the CPU out of the SDRAM slot machine.** Today every CPU
fast-RAM access competes in `sdram_ctrl`'s 16-phase round with the chipset,
refresh, RTG, audio and the host CPU. The CPU gets at most one slot per
141 ns round and loses it whenever chip DMA or RTG needs the bank. With fast
RAM in DDR3 the CPU never waits for a chipset slot and the chipset never waits
for the CPU. That alone removes the largest source of CPU stalls, independent
of clock rate.

**2. One command = one 68040 cache line.** MIG's 128-bit BL8 beat is exactly
16 bytes. The AP68040's line-fill port stub (`cache_req` / `cache_burst` /
`cache_ramaddr[28:1]` — 29 bits = 512 MB, sized for DDR3, not for a 32 MB
SDRAM) exists because the MiSTer fork feeds the 040 from DDR3 this way. Line
fill and write-back are single transactions, no sub-cycle handshake.

**3. Capacity and the RTG framebuffer.** 256 MB of fast RAM instead of what is
left of 32 MB after chip, kick, audio and RTG. And the RTG framebuffer belongs
there too: a 1280×720 16-bpp 60 Hz scan-out is ≈ 110 MB/s, half the SDRAM's
peak, streamed continuously — moving it to DDR3 is what makes the SDRAM
round quiet enough for the chipset.

### What it does not help: single-access latency

| Path | Latency of a cache-line miss |
|---|---|
| SDRAM today | wait for a CPU slot (0–141 ns) + 8-word burst (70 ns) + cache pipeline ≈ **100–250 ns** |
| DDR3 via MIG | `app_en` → `app_rd_data_valid` ≈ 20–25 `ui_clk` ≈ 220 ns, + CDC both ways ≈ 60 ns ≈ **≈ 300 ns** |

At 28–38 MHz that is 8–11 `clkena` per miss. DDR3 only pays off **behind a
cache with line fills** — which the 040 has and TG68K does not. For TG68K the
gain would be capacity and de-contention only, with a latency penalty. This is
the same conclusion as [memory path step 2](performance.md): the line-fill port
is the piece that makes everything else worth doing.

## Why it looked incompatible with the Minimig constraints

Three things, all fixable, none of them about the Minimig core:

**a. MIG is its own clock island and must stay one.** `ui_clk` is generated
by MIG's internal MMCM (memory clock ÷ 4); the application side cannot be run
on `clk_114`. Every signal between the Minimig domains and `ui_clk` is a real
clock-domain crossing. The 2020 wrapper did that crossing "using registers"
(`sdram_ddr_wrapper.v:22`, `` `define VIA_REG ``) on a multi-bit address/data
bus at 28.57 MHz — the same bug class as the offset bus in
[../adv7511/fix-03](../adv7511/fix-03-offset-cdc.md), and consistent with its
last commit being "check the CPU address/data bus". The correct structure is
an asynchronous FIFO (`xpm_fifo_async`) per direction, or a request/response
register pair with toggle handshakes (`xpm_cdc_handshake`). Once that is the
only path between the domains, the constraint is one line:

```tcl
set_clock_groups -asynchronous \
  -group [get_clocks -of_objects [get_pins u_mig/u_ddr3_infrastructure/mmcm_i/CLKOUT*]] \
  -group [get_clocks {clk_114 clk_sd_114 dll_28 clk_148}]
```

MIG ships its own XDC for the DDR3 pins, its 200 MHz input, the IDELAYCTRL
reference and its internal resets. Nothing in the Minimig constraints changes.

**b. The existing XDC has no clock-group discipline**, so adding a fourth
domain to it looked like adding to a pile of false paths and name-keyed
multicycles. After [../constraints/fix-05](../constraints/fix-05-cdc-false-path.md)
it is a list of asynchronous groups, and a new group is routine.

**c. The 2020 attempt put the chipset on DDR3 too** (`wrap_big_r` / 48-bit
chipset reads in the wrapper). The chipset needs deterministic 7 MHz slot
timing; MIG has calibration, refresh and reordering stalls that are not
deterministic. That is the part that cannot be made to work reliably — and it
is not needed. Keep chip RAM and Kickstart in the SDRAM with the existing
controller; put fast RAM and RTG in DDR3.

## Clocking

MIG wants a 200 MHz system clock and a 200 MHz IDELAYCTRL reference. The
vendor example derives both from the 50 MHz oscillator with an MMCM; use a
third MMCM (the 100T has six CMTs; `amiga_clk` and `clk_hdmi` use two) fed
from `clk_50`, MIG input set to "No Buffer". The commented-out `clk_100_p/n`
ports in `minimig_openaars_top.v:14-15` are a leftover and not required.

## Proposed structure

```
                     clk_114 / clkena domain          |  ui_clk 100 MHz domain
                                                      |
  AP68040 ---- 16-bit bus16 adapter ---- TG68K.vhd wrapper ---- chipset / kick / SDRAM (unchanged)
      |                                               |
      +---- line-fill / write-back port (16 B) --- xpm_fifo_async x2 --- DDR3 port FSM --- MIG app i/f
                                                      |
  RTG scan-out ----- xpm_fifo_async (data) ---------- DDR3 port FSM (second requester)
```

The DDR3 port FSM is small: arbitrate two requesters, issue `app_cmd` with the
16-byte-aligned `app_addr`, push 128 bits + 16-bit byte mask for writes, return
128 bits on `app_rd_data_valid`. The 040's cache line, MIG's burst and the
FIFO word are all the same 16 bytes, which is what keeps it small.

## Effort and order

| Step | Effort | Depends on |
|---|---|---|
| MIG IP for MT41K128M16-15E @ 400 MHz, vendor pinout as XDC, example design run on the board | 1 day | — |
| Third MMCM, async clock group, MIG reset/calibration handling | ½ day | [../constraints/fix-05](../constraints/fix-05-cdc-false-path.md) |
| DDR3 port FSM + two async FIFOs, standalone testbench against the MIG behavioural model | 2–3 days | — |
| 040 line-fill port wired to it (the same port [performance.md](performance.md) step 2 needs against SDRAM) | 2–3 days | AP68040 integration |
| RTG framebuffer moved to DDR3 | 2 days | above |
| Remove fast RAM from the SDRAM map; simplify `sdram_ctrl` slots | 1 day | above |

Design the 16-byte line port once, with two back-ends (SDRAM now, DDR3 later),
and the DDR3 step becomes a back-end swap rather than a second integration.

## Alternative: DLL-off DDR3 inside `clk_114`

Running the DDR3 at 113 MHz with its DLL disabled removes MIG, `ui_clk` and
the CDC entirely, at 454 MB/s and better latency than MIG. Assessed in
[ddr3-dll-off.md](ddr3-dll-off.md).

## Who else needs the DRAM

Chipset, the 832 OSD soft core, audio and RTG all go through `sdram_ctrl`
today. Which of them move and what the DDR3 arbiter must guarantee is in
[memory-masters.md](memory-masters.md).

## Not verified

* Current MIG (Vivado 2023.2) generates for this part and pinout without
  complaint — the vendor example is Vivado 2018.3; expect only version churn.
* Real `ui_clk` read latency in this configuration — 20–25 cycles is the
  usual 7-series DDR3 4:1 figure; measure it in the example design.
* Power/thermal: DDR3L at 400 MHz adds ≈ 0.5 W on a board whose SDRAM read
  path already drifts with temperature ([../constraints/sdram-sim-results.md](../constraints/sdram-sim-results.md)).
