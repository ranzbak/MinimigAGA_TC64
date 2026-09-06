# DDR3 as Zorro-III fast RAM — design

Status: design for review, 2026-09-04. Nothing implemented.
Companion: [implementation-plan.md](implementation-plan.md). Background analysis:
[../ap68040/ddr3-dll-off.md](../ap68040/ddr3-dll-off.md),
[../ap68040/ddr3-fast-ram.md](../ap68040/ddr3-fast-ram.md),
[../ap68040/memory-masters.md](../ap68040/memory-masters.md).

## Goal

Move the 32-bit (Zorro III) fast RAM off the SDRAM onto the board's 256 MB DDR3,
so that the CPU stops competing with the chipset and the RTG scan-out for SDRAM
slots, and so that fast RAM can later grow far beyond 64 MB. The SDRAM keeps
everything that is DMA-visible or streamed: chip RAM, slow RAM, Kickstart, the
24-bit (Zorro II) fast RAM, the RTG framebuffer, audio buffers, the host CPU.

## Decisions (made by Claude at the user's request; each can be reversed)

| # | Decision | Why |
|---|---|---|
| D1 | **Zorro III RAM moves; Zorro II RAM stays on SDRAM.** | `doc/MemoryMap.txt`: the RTG framebuffer is allocated in the 24-bit fast RAM at 0x800000–0x9FFFFF and the RTG scan-out port reads it from the SDRAM. Moving Z2 would blind the display. Z3 is CPU-only. |
| D2 | **Reuse `core_ddr3_controller` (ultraembedded), not a new controller.** Your checkout: `~/work/fpga/Xilinx/artix7/qmtech_minimig_tests/core_ddr3_controller/core_ddr3_controller`. | Open source, DLL-off, made for exactly this (low clock, small, 7-series), proven on Arty A7 at 100 MHz with 367 MB/s. Its xc7 PHY captures reads with the DQS strobe through ISERDES, so tDQSCK drift is tracked rather than trained. Your own `ddr3-dll-off/signal-test` is a 130-line clock/CKE skeleton; not a controller. |
| D3 | **Run it at its proven 100 MHz on its own PLL; bridge to `clk_114` with a one-request handshake.** | The PHY needs clk, 4x clk, 4x clk at 90°, and a 200 MHz IDELAY reference in the ratios of a 1200 MHz VCO. The Minimig MMCM cannot make those at 113 MHz, and it must not be touched (fix-12 lesson). A PLLE2 from `clk_50` (×24 = 1200 MHz) gives 100/400/400@90°/200 exactly as on Arty. |
| D4 | **Native 128-bit port, not AXI.** | One BL8 = 128 bits = one 8-word cache line. The cache already speaks 8-word bursts. AXI wrapper is dead weight. |
| D5 | **Reuse `cpu_cache_new` unchanged as the front end.** | The SDRAM path's cache and write buffer are proven with the TG68K handshake. Only the backend (`sdr_*` signals) is reimplemented on the DDR3. |
| D6 | **~~Identity address mapping: DDR3 byte address = CPU address bits 27:0.~~ Superseded: the DDR3 address is the offset inside the board.** | Was: Z3 space 0x40000000–0x4FFFFFFF maps one-to-one onto 256 MB. The DDR3 is now the third Z3 board, whose base the OS assigns and the hardware latches, so the base bits are dropped and the offset is zero-extended (`z3ram3_size_log2` in `TG68K.vhd`). Identity again only when the board covers the whole 64 MB the backend addresses. See [z3ram3-on-ddr3-plan.md](z3ram3-on-ddr3-plan.md). |
| D7 | **Stage B keeps today's board sizes; stage C grows the board.** | Autoconfig, OSD menu and the cache tag width are separate work; ship the swap first. |
| D8 | **~~The "leftover" Z3 board (`sel_z3ram3`, 0x41000000) is disabled when DDR3 is present.~~ Superseded: that board *is* the DDR3 board.** | Was: scraps of SDRAM address space, pointless next to 256 MB. In fact it was disabled because its decode guessed 0x41000000 while the OS placed it at 0x08000000. Boards 1 and 2 now stay on the SDRAM and board 3 carries the DDR3, decoded against the latched base, so the DDR3 adds memory instead of taking 4 MB away. See [z3ram3-on-ddr3-plan.md](z3ram3-on-ddr3-plan.md). |

## Architecture

```
TG68K.vhd                     rtl/ddr3/ddr3_fastram.v            core_ddr3_controller
 sel_z3ram3 ────── ddr_cs ─► cpu_cache_new ─ sdr_* ─► line bridge ─ CDC ─► ddr3_core ─ DFI ─► ddr3_dfi_phy ─► pins
 (board 3, base latched from autoconfig; boards 1 and 2 stay on the SDRAM)
 datatg68 ◄─ fromddr ────────  cpu_dat_r                          (clk_114 │ 100 MHz)
 ramready ◄─ ddr_ready ──────  cpu_ack
```

Three new pieces, one edit:

1. **`rtl/ddr3/ddr3_fastram.v`** (clk_114 domain). Instantiates `cpu_cache_new` exactly as
   `sdram_ctrl` does (same `cpu_*` port, `snoop` tied off, `cache_inhibit` 0). Implements the
   cache backend:
   * read: on `sdr_read_req`, issue one 128-bit read at `{sdr_adr[25:4], 4'b0}`; when the
     response returns, present the 8 words on `sdr_dat_r` one per clock with `sdr_read_ack`,
     starting at the requested word and wrapping within the line (the cache expects the
     SDRAM's wrapped-burst order; see `zreadword` in the host cache and `cpu_adr[3:1]` use in
     `cpu_cache_new`).
   * write: on `sdr_write_req`, one 128-bit write with 16 byte enables built from
     `sdr_dqm_w` (active-low) and `sdr_adr[3:1]`; `sdr_write_ack` when accepted.
   * one outstanding request at a time. The cache never issues both.
2. **`rtl/ddr3/ddr3_cdc.v`**: request/response handshake between clk_114 and the 100 MHz
   island. Request side: address, 128-bit data, byte enables, read/write held stable;
   `req` toggle synchronised into the island (2 flops); the island issues the core
   transaction and returns `ack` toggle plus 128-bit read data held stable. Constrain with
   `set_max_delay -datapath_only` on the data buses and an asynchronous clock group. This
   is the standard toggle-handshake CDC; the buses change only while the far side is idle.
3. **`rtl/ddr3/ddr3_top.v`** (island): PLLE2 (`clk_50` in; 100 / 400 / 400@90° / 200 out),
   reset synchroniser, `ddr3_core` (`DDR_MHZ=100`), `ddr3_dfi_phy` (xc7), the core's `cfg`
   port driven by constants (DLL-off mode register values are inside the core), and a
   small **BIST** engine usable over VIO in bring-up (write/read patterns over a range,
   count errors). Also exposes `init_done` (core calibration complete).
4. **`rtl/soc/TG68K.vhd`**: split `sel_ram` into the SDRAM set and the DDR set
   (`sel_z3ram OR sel_z3ram2`); a second chip-select (`ddrcs`, same shape as `ramcs`,
   including the `slower` throttle); `datatg68` chooses `fromddr` when the registered DDR
   select is active; `clkena` also honours `ddr_ready`. `ramaddr` is untouched.
   `minimig_virtual_top.v` instantiates `ddr3_fastram` and routes the pins up through
   `minimig_openaars_top.v`.

The SDRAM controller is not modified. If the DDR3 is disabled (generic `HAVE_DDR3=false`),
the Z3 selects fall back to the SDRAM path exactly as today.

## Latency and bandwidth, honestly

A line fill today: wait for a slot (up to two 141 ns rounds under load) plus the burst,
140–300 ns. On DDR3: CDC (≈40 ns) + core (ACT, RD, CL6, 4 data clocks at 100 MHz ≈ 130 ns)
+ CDC back + word delivery, ≈ 250 ns unloaded, and **independent of chipset and RTG load**.
So single-access latency is similar, throughput per CPU is similar (400 MB/s peak on the
DDR3 vs a share of 227 MB/s), and the win is isolation: the CPU no longer steals slot 2 from
the RTG or waits behind it. This is the case made in ddr3-fast-ram.md. Faster comes later
with the core at 113–125 MHz on a fractional MMCM, or with a 68040-class CPU that issues
32-bit accesses (one line = one native access).

## Clocking and constraints

* New PLLE2_BASE in `ddr3_top.v`: CLKIN 50 MHz, MULT 24, DIVCLK 1 (VCO 1200), CLKOUT0 /12
  = 100, CLKOUT1 /3 = 400, CLKOUT2 /6 = 200, CLKOUT3 /3 = 400 at 90°. Copied from the
  controller's `examples/arty_a7/artix7_pll.v`, which the core's testbench also uses.
* `IDELAYCTRL` in bank 16 on the 200 MHz clock (`REFCLK_FREQUENCY 200`).
* New `fpga/openaars/aars_v5.0/xc7a100t/ddr3.xdc`: pins from
  `QMTECH .../Software_XC7A100T/DDR3.ucf` (all bank 16), **`SSTL15` / `DIFF_SSTL15`** (the
  bank's VCCO is 1.5 V; the vendor file's SSTL135 mis-states the rail),
  `set_property INTERNAL_VREF 0.75 [get_iobanks 16]`, the four PLL clocks renamed, an
  asynchronous clock group between the island and `{clk_114 dll_28 clk_sd_114}`,
  `set_max_delay -datapath_only` across the CDC buses, and the DDR IO false paths the Arty
  example uses (the PHY's ISERDES/OSERDES/IDELAY paths are not meaningfully timed by STA).
* `clocks.xdc` gains a comment pointing at `ddr3.xdc`; nothing else in the Minimig
  clock tree changes.

## Verification

1. **Controller alone**: run the core's own `tb/ddr3_core_xc7` under xsim with the Micron
   model (`ddr3.v`, `2048Mb_ddr3_parameters.vh` are in that directory) to prove the
   toolchain flow before touching anything.
2. **`ddr3_fastram` bench** (xsim, unisims): cache + bridge + CDC + core + PHY + Micron
   model. Reuse the CPU-port tasks from `sim/sdram_timing/sdram_timing_tb.v`
   (`cpu_read` with the TG68K handshake). Test: fills, hits, re-fills after eviction,
   16- and 32-bit writes with byte masks, read-after-write, wrapped burst order, back to
   back requests, and a reset in the middle of a transaction.
3. **Hardware, stage A**: island only, no CPU connection. BIST over VIO: pattern sweep
   over 256 MB, error count, repeated after 30 minutes warm. Also sweep the PHY's DQS
   delay through the core's `cfg` register to find the window on this board; centre it
   in `DQS_TAP_DELAY_INIT`.
4. **Hardware, stage B**: Z3 on DDR3. Boot by **reprogramming** (never the soft reset;
   see lessons), then `SysTest` / AmigaTestKit RAM test on the Z3 range, Workbench copy
   of a large file to RAM: and back, then the same after 30 minutes.
5. **Timing**: full build meets timing except the known SDRAM read (−0.349 ns); the
   island's clocks appear only in the DDR3 report groups.

## Risks and fallbacks

| Risk | Signal | Fallback |
|---|---|---|
| DLL-off at 100 MHz misbehaves on this Micron part (mode is "targeted, not guaranteed") | BIST errors at all delay settings | Core at 90 or 80 MHz (PLL divisors only) |
| PHY delay defaults wrong for this board | BIST errors at default, clean at other taps | Use the swept value; add auto-tune later |
| Resource growth | Post-route utilisation | Budget: ≈2k LUTs, 16 IDELAYE2, 18 OSERDES, 16 ISERDES, 1 PLL. Fits with >40k LUTs free |
| CDC bug | Sim (item 2) with random request spacing; hardware BIST through the CDC | Standard toggle handshake, formal reasoning in the module header |
| Boot-test confusion | Same as this session: a failed boot is sticky | Reprogram between attempts; treat white screen as an SD stage marker |

## Later stages (not in this design)

* **Stage C**: one Z3 board of 128 MB or 256 MB: autoconfig size code
  (`minimig_autoconfig.v` `ramsize` for the Z3 entry), OSD memory menu in
  `fw/ctrl_832`, `cpu_cache_new` tag width for >64 MB.
* Core at 113–125 MHz: MMCME2 with fractional multiply for the 4x clocks; the CDC then
  becomes a ratio change only.
* Chipset and RTG on DDR3, SDRAM removed: needs the refresh-hiding scheduler and a
  redesigned round; see [../ap68040/ddr3-dll-off.md](../ap68040/ddr3-dll-off.md).
