# Freezer / monitor cartridge on the AP68040 core: assessment and plan

2026-09-19. Planning only; no RTL, firmware or config was changed for this
document. Every file:line below was read today on branch `e2-t4`. Anything
not read is marked **unverified**.

## 0. Verdict in five lines

1. What is in the tree is an **HRTmon** cartridge, not an Action Replay III.
   The RTL, the firmware upload, the config block it writes and the OSD line
   all target HRTmon at `$A10000`. Nothing of AR3 survives except the module
   header and a field name.
2. It is **wired but dead on the AP68040**: the cartridge only arms itself
   on a 68000-style interrupt-acknowledge bus cycle, and the AP68040 never
   performs one (`lib/AP68040/rtl/ap040_core.v:24`). Pressing the freeze key
   today would, by code reading, hold IPL at 7 forever and take every chipset
   interrupt with it.
3. The right target is **"finish and wire up what is there" (HRTmon)**, not
   AR3. AR3's ROM is 68000-only, needs `$400000`/`$440000` which this core
   hands to Zorro-II fast RAM, and needs a reset-vector takeover the design
   has no hook for. Adding it alongside would be new gateware for a worse
   result.
4. The 68040 problem is real but bounded: one acknowledge signal is missing
   (the core already exports it, `nmi_ack_toggle`, left `open` at
   `rtl/soc/TG68K.vhd:1149`), the frame format is the 040's business and is
   implemented, the D-cache is write-through so coherency is not the issue
   one would expect, and the MMU is the one genuinely open question.
5. Recommend a **monitor-only Stage 1 first** (the 832 already has a live
   window onto chip RAM and the wrapper already exports PC/SR/IR/A7) because
   it delivers "look at memory when it is wedged" in a day with no risk to
   the running machine, then the HRTmon freezer as Stages 2-4.

## 1. What exists today, and its state

### 1.1 Inventory

| Piece | Where | What it actually is | State |
|---|---|---|---|
| Cartridge RTL | `rtl/minimig/cart.v` | HRTmon block: 512 KB window at `$A00000` (`:109`), NMI vector override to `$00A1000C` (`:120-123`), custom-register mirror at `$A9F000` (`:192-200`), level-7 request/ack (`:135-171`) | Instantiated (`rtl/minimig/minimig.v:1010`), data ORed into `cpu_data_in` (`:1215`), `sel_cart` into the bank mapper (`:977`, `minimig_bankmapper.v:24` bank[4]). Dead on the 040, see 1.3 |
| ROM upload | `fw/ctrl_832/config.c:177 UploadActionReplay()` | Opens `HRTMON  ROM` from the SD root, uploads to Amiga `$A10000` via `SendFileV2`, then writes an HRTmon config block at `$A10014` and `maxchip` at `$A10044` | **Called unconditionally** on every Kickstart reload (`config.c:448`), regardless of the OSD setting. Missing file is non-fatal (`:221`) |
| Enable bit | `config.memory & 0x40` | OSD "HRTmon: enabled/disabled" line (`fw/ctrl_832/menu.c:1480`, toggled `:1524-1533`) -> `OSD_CMD_MEM` -> `userio_osd.v:109` `memory_config[6]` (latched immediately, not reset-gated) -> `minimig.v:853 .hrtmon_en` | Works. Its **only** consumer is the keyboard gate `amiga_keyboard.v:104` `freeze = hrtmon_en && freeze_out`. The cart itself is not gated by it |
| `config.disable_ar3` | `fw/ctrl_832/config.h:54` | A byte in the saved config struct | Only referenced in commented-out code at `menu.c:1528-1531`. Dead; removing it changes the config-file layout, so leave it or repurpose it |
| `ACTIONREPLAY_BROKEN` | `fw/ctrl_832/Makefile.68k:20` | Selects the help text without the HRTmon sentence | Only in the 68k Makefile. The 832 build (`fw/ctrl_832/Makefile:27,50`) does not define it, so the shipped help text says "hold Ctrl and press the Pause key" |
| Freeze key | `rtl/minimig/ciaa_ps2keyboard_map.v:789` maps PS/2 `E0 7E` (Ctrl+Break/Pause) to `keyrom = 16'h016F`; `:111` sets `freeze <= ~upstroke` on that code | Keyboard is real PS/2 into the FPGA on this board (`rtl/soc/openaars_defines.vh:9`, `minimig_virtual_top.v:1196`) | Works as far as `amiga_keyboard.v:104`. The MiST-path `8'h5f` branch (`amiga_keyboard.v:196`) is not compiled here |
| IPL injection | `minimig.v:1037` `_cpu_ipl = int7 ? 3'b000 : _iplx` | Level 7 overrides all other levels while `int7` is high | Correct for a pulse; catastrophic if `int7` sticks (1.3) |
| NMI vector fetch routing | `rtl/soc/TG68K.vhd:599-618` `sel_nmi_vector`, `:723-726` | A DATA read of `VBR+$7C` is forced onto the 16-bit adapter (chipset bus) even when chip RAM is turbo, so the cart can answer it. `gary` chip0 is masked by `~ovr` (`minimig.v:967`) | In place and deliberate (Stage E2 comment). `tg68_ovr` in `minimig_virtual_top.v:297,1148` is a dangling wire because `TG68K.vhd:172` has `ovr` commented out; harmless, the override happens inside minimig |
| Cart in the CPU decode | `TG68K.vhd:693` `sel_cart` commented out | `$A00000-$A7FFFF` is not in the wrapper's RAM router, so it falls to the adapter and goes over the 7 MHz chipset bus to gary -> bank mapper -> SDRAM bank 0 | Functional. Slow (every HRTmon fetch is an adapter cycle) but coherent and uncached, see 4.4 |
| Cacheability of `$A0xxxx` | `lib/AP68040/rtl/ap040_tg68k_compat.v:396-400` `cache_win` | Z2 window is `addr[23] ^ (addr[22]|addr[21])`; for `$A0` that is `1 ^ 1 = 0`. Not cacheable on I or D | Good for the monitor |
| Backing store | `doc/MemoryMap.txt`; `TG68K.vhd:968-971` | `$A00000-$A7FFFF` is SDRAM bank 0 at SD `$200000` (A ^ (B\|C) mangling). The 832 sees it at host `0x480000` (`0x210000 ^ 0x680000` for the ROM), which is exactly what `SendFileV2` computes (`fpga.c:95`) | Correct on the DDR3 build. **On a `haveddr3=false` build** the "leftover SDRAM" Zorro-III board 3 maps its first 2 MB onto SD `$200000-$3FFFFF` (`TG68K.vhd:969-971`: ramaddr(23)=0, (22)=x21, (21)=x21 xor 1), i.e. on top of the HRTmon image. `minimig_virtual_top.v:27` has `haveddr3 = 1`, so not today's problem, but it must be a build-time assertion |
| Debug taps | `TG68K.vhd:1340-1349` `dbg_pc/sr/ir/fault_addr/exc_vec/flags`; `minimig_virtual_top.v:229-234` | Go only to an ILA when `CPU040_DEBUG_ILA` (`:968-987`) | Available for a monitor-only path, see section 5 |
| 832 live memory window | `rtl/sdram/sdram_ctrl.v:285-287` `zmAddr`; `MINIMIG_HOST_DIRECT` (`openaars_defines.vh:13`); `hardware.h:22 HOSTMAP_ADDR 0x680000` | The 832 reads/writes SDRAM bank 0 (8 MB: chip, slow, Kick, cart, `$A0-$FF`) directly through its own SDRAM slot, **without** the minimig bridge and without halting the CPU | Works today; this is how ROMs are uploaded. Not snooped by either cache (4.4) |

### 1.2 It is HRTmon, and it matches WinUAE's HRTmon model

Evidence it is HRTmon and not AR3:

* `cart.v:22-29` says so, and says the module is "based on" the AR module and
  "requires the ctrl firmware to load the special hrtmon.rom file".
* Entry vector `$00A1000C` (`cart.v:123`): HRTmon base + `$C`.
* `config.c:187-218` writes, at ROM + `$14`: `mon_size, col0h, col0l, col1h,
  col1l, right, keyboard, key, ide, a1200, aga, insert, delay, lview, cd32,
  screenmode, novbr, entered, hexmode`, and at ROM + `$44` `maxchip`. That is
  WinUAE's `hrtmon_configure()` field order (**from memory of WinUAE
  `ar.cpp`, unverified against source**).
* The custom-register mirror at `$A9F000` = `$A10000 + $8F000` is where
  WinUAE places `hrtmon_custom` (**same caveat**). WinUAE also mirrors CIA-A
  and CIA-B at `+$8E000` / `+$8D000`; `cart.v:27` lists that as a TODO and
  it is not implemented.
* No AR3 decode (`$400000` ROM / `$440000` RAM), no AR mode/status register,
  no reset-vector takeover. The `aron` logic is commented out (`cart.v:93-106`).

So "finish HRTmon" is the honest description of the job. HRTmon itself is a
1990s A1200-era monitor which advertises 68000-68060 support and AGA
awareness (**unverified**: the ROM is not in the tree and I have not read its
documentation for this plan; Stage 0b checks it in WinUAE, which is the
reference this RTL was modelled on).

### 1.3 Why it is dead on the AP68040 (by code reading, not yet on hardware)

`cart.v` arms itself in three steps:

1. `freeze` rising edge -> `int7 <= 1` (`:143-152`). `minimig.v:1037` then
   drives IPL = 7.
2. It waits for an **interrupt-acknowledge bus cycle**, defined as A[23:1]
   all high with `_cpu_as` low (`:139`), to clear `int7` and, one clk7 later,
   set `active`/`stealth` (`:181-185`).
3. While `active`, a read of `VBR+$7C` is overridden to `$00A1000C` (`:120`),
   and `active` clears on the first read from `$A0xxxx` (`:186-187`).

Step 2 never happens. `ap040_core.v:24`: "interrupts are always autovectored
(ipl_autovector is ignored)"; `TG68K.vhd:1134` ties `ipl_autovector => '1'`;
the core never puts `$FFFFFx` on the bus. Consequences, in order:

* `int7` never clears. IPL stays at 7. `ap040_core.v:174-178` re-arms the
  edge-triggered NMI only when "the pins leave" level 7, so exactly one NMI
  is taken, ever, and levels 1-6 are invisible for the rest of the session
  (`minimig.v:1037`). VBL, CIA, disk, keyboard: gone. The machine appears
  to wedge on the first Ctrl+Pause.
* `cpu_speed & ~int7` (`minimig.v:930`) also drops turbo permanently.
* `active` is never set, so the one NMI that is taken reads the real
  `VBR+$7C`, i.e. whatever Exec left there (**unverified** what Kickstart
  does with an unexpected level 7; a Guru is the likely outcome).

The core does export the acknowledge: `nmi_ack_toggle` flips when a level-7
exception is entered (`ap040_core.v:2802`, `:156-158`), comes out of
`ap040_tg68k_compat.v:64`, and is left `open` at `TG68K.vhd:1149`. That is
the one wire the design is missing.

### 1.4 Side finding (outside this task, reported because it was in the path)

`rtl/minimig/userio.v:76` declares `memory_config` as `[7-1:0]` while
`userio_osd.v:36` drives 8 bits and `minimig.v:665` expects 8. Bit 7 is the
"Boards: DDR3 only" toggle (`menu.c:1493`, `minimig.v:1155 ddr3_only`). By
the port widths, bit 7 is dropped at the `userio` boundary. **Unverified**
in a synthesis log; worth a look since it is a one-character fix if real.

## 2. What Action Replay III needs (and why it is the wrong target here)

From WinUAE's `ar.cpp` model of the AR2/AR3 and Datel's hardware, **from
memory, unverified against source**:

* **Address space.** 512 KB ROM at `$400000-$47FFFF`, 64 KB RAM at
  `$440000-$44FFFF` (the RAM sits inside the ROM window; the mode register
  decides which answers). Both must be invisible or ROM-only to the running
  program until the freeze, and the cartridge has a small mode/status
  register (`armode`) written by the ROM code to hide/show itself.
* **Freeze path.** Button -> level 7 -> the cartridge watches the vector
  fetch at `VBR+$7C` (68000: `$7C`) and overrides it with its own ROM entry,
  exactly as `cart.v:120-123` does for HRTmon. That part is shared.
* **Takeover at reset.** AR3 also takes control at power-on/reset by
  overriding the reset vector fetch at `$0`/`$4` so its boot code runs first
  and installs its hooks (the "AR at boot" behaviour and the `ovl` game).
  This core has no hook for that: Kickstart overlay is `ovl` from CIA-A, the
  vector table is cleared by the 832 (`config.c:45`), and nothing arbitrates
  a third ROM over `$0`.
* **Chipset state.** AR3 hardware snoops every custom-register write and
  every CIA write into its own RAM so the ROM can restore the chipset on
  exit and show the "real" register values. `cart.v:192-200` has the custom
  half (256 words) and not the CIA half.
* **Save/restore.** The ROM code saves D0-D7/A0-A7/SR/PC from a **68000
  3-word exception frame** and returns with RTE. On a 68010+ the frame is 4
  words with a format/vector word; a 68000-only RTE leaves the SP wrong and
  returns to garbage. The A500 AR3 was never usable on 020+ machines for
  this reason (**unverified** beyond general knowledge; Datel sold separate
  A1200 units).
* **CPU-specific tricks.** MOVE from SR, self-modifying code, no cache
  awareness; none of it 040-safe.

On this design specifically:

* `$400000-$47FFFF` is inside the Zorro-II fast RAM the core autoconfigs
  (`TG68K.vhd:685 sel_z2ram`, `$200000-$9FFFFF`). AR3's window would have to
  punch a hole in Z2 RAM, or Z2 RAM would have to be reduced, or the AR3 ROM
  relocated (it is position-dependent code). Every option is a compatibility
  loss for the normal use of the machine.
* Its ROM would need a 68040 port of the save/restore code, which is the
  reverse-engineering half of a Datel ROM, not gateware.

HRTmon needs none of that: its window (`$A00000-$A7FFFF`, "PCMCIA space, not
mapped" in `doc/MemoryMap.txt`) is free, it is loaded as data by the 832,
and its ROM was written for 020+ Amigas. Recommendation: **treat "Action
Replay III" as the wrong name for the feature and finish HRTmon.** Section
7 lists what AR3 would additionally cost if Paul still wants the real thing.

## 3. How the (HRTmon) cartridge maps onto this design

* **ROM image.** `HRTMON.ROM` in the SD root, exactly as
  `UploadActionReplay()` does today via the `UploadKickstart`/`UploadExtROM`
  pattern (`config.c:59-174`): `RAOpen` + `SendFileV2(file, NULL, 0,
  0xa10000, sectors)`. It lands in SDRAM bank 0 at SD `$210000`, which the
  CPU sees at `$A10000` through gary -> bank[4] -> `minimig_sram_bridge`.
  Only change needed: make the upload conditional on `config.memory & 0x40`
  and stop printing "not found" at every boot when it is disabled.
* **Address decode.** Already split correctly: `cart.v:109` decodes the
  512 KB window on the chipset bus (`sel_cart` -> bank mapper), and the CPU
  wrapper leaves `$A0xxxx` undecoded (`TG68K.vhd:693`) so it goes to the
  adapter. Today's `sel_reg` narrowing to `$DFxxxx` (`gary.v:226`) does not
  touch `$A0xxxx`; `sel_cia` is `$Bxxxxx` (`gary.v:228`), Akiko `$B8xxxx`
  (`TG68K.vhd:650`). No overlap. The custom mirror at `$A9F000` is inside the
  512 KB cart window but only answers while `stealth` (`cart.v:192`), so it
  is invisible before the first freeze.
* **Visibility policy.** `sel_cart` requires `stealth | cpuhlt` (`cart.v:109`).
  Before the first freeze the OS cannot see or clobber the image (a read of
  `$A1xxxx` returns `$0000` from the OR mux); the 832 can still write it
  while the CPU is halted at boot (`cpuhlt`). This is fine and should stay.
* **CPU wrapper.** Needs one new output, the level-7 acknowledge, brought
  from `ap040_tg68k_compat.v:64 nmi_ack_toggle` through `TG68K.vhd`
  (currently `open` at `:1149`), `minimig_virtual_top.v` and `minimig.v`
  into `cart.v`. It crosses from `clk_cpu` (37.8 MHz, `virtual_top.v:597`)
  into the `clk`/`clk7_en` domain: two-flop synchroniser on the toggle, then
  XOR to a pulse, in `TG68K.vhd` next to the existing `cpu_tgl` machinery.
* **Vector override data path.** Unchanged: the longword read of `VBR+$7C`
  is split by the adapter into two word reads (address advancing,
  `TG68K.vhd:975`), `cart.v:123` answers `$00A1` then `$000C` on `A[1]`.
  Because `sel_nmi_vector` requires `x_instr = '0'` and `x_we = '0'`
  (`TG68K.vhd:617-618`), the override only ever answers the exception
  vector fetch, never an instruction fetch or a walker access.

## 4. The 68040 problem, worked through

### 4.1 Interrupt acknowledge (blocking, known fix)

Covered in 1.3. Fix in `cart.v`: replace `int7_ack` with the synchronised
`nmi_ack` pulse; on it, clear `int7` and set `active`/`stealth`. Two details
that matter on the 040 and not on a 68000:

* `int7` **must fall** after acceptance, or the core never re-arms
  (`ap040_core.v:174-178`) and levels 1-6 stay hidden. Also bound it: if no
  acknowledge arrives within, say, 64 clk7 cycles (interrupts masked at 7 by
  the running code, or the core stalled), drop `int7` and give up rather
  than jam IPL. The core samples IPL through a two-flop synchroniser and
  requires the level to be stable across both (`:170-173`), so the pulse
  must be several `clk_cpu` cycles wide; `clk7_en` granularity (5+ cycles
  of `clk_cpu`) is enough.
* `ovr` is currently unbounded in time once `active`: it clears only on the
  first `$A0xxxx` read (`cart.v:186`). If the OS's level-7 handler ran
  instead (Stage 0a will show whether that can still happen), `ovr` would
  sit armed until something reads `$A0xxxx`. Add a clear on a bounded
  timeout too.

### 4.2 Exception stack frame

The AP68040 stacks a 4-word format-0 frame for interrupts: SR, PC, then
`{fmt, vec}` (`ap040_core.v:2813-2819`, `exc_fmt` 0 for IRQ), enters
supervisor with the interrupt mask set to 7 (`:2795-2800`) and validates the
format word on RTE (header `:14`). That is a correct 68040. Whether HRTmon's
freeze handler reads the format word and RTEs a 4-word frame is a property
of the ROM, not of this design; the firmware writes `novbr = 0xff`
(`config.c:207`), which suggests the monitor is told not to touch VBR and
the hardware follows VBR for it (`cart.v:114`). **Unverified until Stage 0b
runs the same ROM under WinUAE with a 68040.**

Master/interrupt stack: the core implements the M bit and ISP/MSP
(`ap040_core.v:15`). Exec on a 68040 with `68040.library` does not set M
(**unverified**); if a guest OS did, HRTmon would be looking at the ISP and
the user program's A7 would be the MSP. Not a correctness problem for
freeze/resume, only for what the monitor displays as A7.

### 4.3 MMU

This is the open question, and it is not the cartridge's to fix.

* With the MMU **off** (TC.E = 0), everything is physical and HRTmon's model
  of the machine holds. This is the state under Kickstart without
  `68040.library`, and in every demo that boots from floppy.
* With `68040.library` loaded, the library **enables the MMU with an
  identity map** to mark chip RAM and I/O non-cacheable/serialised (this
  is the whole reason the library exists; **unverified** against the
  library itself, and whether the ITT/DTT transparent-translation registers
  or a page table are used). Under an identity map, addresses are still
  physical, so the monitor is right about memory; the only difference is
  that its own fetches from `$A1xxxx` and its accesses to `$A9F000` must be
  mapped in the current table. If the library's table does not cover
  `$A00000-$A7FFFF` (it "is not RAM" from the OS's point of view), the
  vector fetch faults, the fault handler's fetch faults, and the core
  reports a double fault (`tb_ap040_double_fault.v` exists, so that path is
  tested). That would be a hard freeze-time crash, deterministic and easy to
  see on the ILA (`dbg_exc_vec`).
* With a **non-identity** map (NetBSD, Linux, a demo doing its own MMU
  tricks), the monitor sees the interrupted context's logical space,
  supervisor translation for its own accesses, and memory it "pokes" is
  not where it thinks. Nothing in the RTL can fix that short of forcing
  TC.E off on freeze, which changes the state we are trying to preserve.

Practical position: **support freeze with the MMU off or identity-mapped;
detect TC.E at freeze time and report, do not attempt to fix.** Stage 0c
answers whether `68040.library` maps `$A0xxxx`; Stage 4 adds a TC.E tap next
to `dbg_flags` so the OSD can say "MMU on" when a freeze goes wrong.
Whether `ap040_mmu.v` exposes TC in a form the wrapper can tap is
**unverified** (it holds the register; I did not read the port list).

### 4.4 Caches and "modifying memory behind the CPU's back"

Less bad than it sounds, for three reasons that are verified in the RTL:

1. The 040 D-cache is **write-through, no write-allocate**
   (`ap040_cache.v:7-8`). Every CPU store reaches memory. The external
   `cpu_cache_new` is also write-through (`TG68K.vhd:1361-1365` comment).
   So while the monitor runs, memory always holds the interrupted program's
   latest data and the monitor's own stores are never trapped in a cache.
2. The cartridge hardware **does not write memory**. In both AR and HRTmon
   the CPU does the saving and restoring; the hardware only supplies the
   vector and the register mirror. So there is no non-CPU writer to worry
   about during a freeze. The only non-snooped writer in the system is the
   832 host port (`sdram_ctrl.v:285`; snoops come from `chipAddr` only,
   `:318-321`; the 040's snoop is the chipset DMA path,
   `ap040_tg68k_compat.v:381-390`). That matters for the monitor-only path
   (section 5), not for HRTmon.
3. `$A0xxxx` is uncacheable on both sides (1.1), so the monitor's own code
   and its register mirror are never stale.

What remains:

* **Instruction cache on resume.** If the monitor patches code in
  cacheable fast RAM (Z2/Z3 windows, `compat.v:396-400`) and resumes, the
  I-cache holds the old bytes: nothing snoops the I bank, by design
  (`compat.v:381-395`). Code in chip RAM is safe because chip-window
  instruction fetches bypass the I-cache (`:394`). Options: (a) rely on the
  ROM doing CINV (an 020+-aware monitor flushes CACR on exit; **unverified**
  for HRTmon), (b) have `cart.v` pulse a cache clear when `active` drops,
  i.e. on the resume path, using the same `cacheline_clr`/`ap040_maint`
  plumbing that CINV drives (`TG68K.vhd:1208,1369`). (b) is cheap and
  belt-and-braces; do it in Stage 4.
* **Stale D lines the monitor reads.** Only possible if memory changed
  under a valid line without a snoop, i.e. via the 832 host port or the
  DDR3 ("nothing but the CPU writes the DDR3", `TG68K.vhd:1362`). Not a
  freezer concern.
* **Posted stores** (`TG68K.vhd:47-50`, plan X3.3). An interrupt is taken
  at an instruction boundary; whether the core drains posted stores before
  stacking the frame is **unverified**, but the frame is written through
  the same D-cache path so ordering is preserved either way. Not a state
  hazard, only a "the last store may land a few cycles later" one, which
  the monitor cannot observe.

### 4.5 Can a freeze leave a restorable state?

Yes, with the caveats above, and for the same reason it works on a real 040
Amiga with an A1200 HRTmon: the interrupt is a normal, architected,
instruction-boundary exception with a normal RTE. What the design must
guarantee, and does not today:

* IPL 7 is a pulse, acknowledged by `nmi_ack`, and back to the encoder's
  value before RTE (4.1). Otherwise the next freeze is impossible and the
  OS is deaf.
* The monitor's accesses never take longer than the core stall watchdog:
  `ap040_tg68k_compat.v:173-195`, 2^21 `clk_cpu` cycles, ~55 ms at 37.8 MHz,
  after which the core is handed an access error. Adapter cycles are
  microseconds; the only way to trip it is holding the chipset bus, which
  is exactly what `SPI_CPU_HLT` does (`minimig_m68k_bridge.v:140`,
  `_as` ignored while `halt`). **So the 832 must never halt the bus while
  the monitor is active**, and, separately, halting the bus is *not* a
  usable "hardware freeze" for section 5: after ~55 ms it turns into a
  format-7 access error on the interrupted program.
* FPU state is untouched if the monitor does not execute FP instructions
  (**unverified** that HRTmon never does; a 1990s monitor has no reason to).
* Chipset: the running program's DMA continues during the freeze on a real
  AR/HRTmon too; the monitor takes over the display by rewriting the custom
  registers from its mirror and restores them on exit. `cart.v`'s mirror
  captures CPU and copper writes alike (`reg_data_in = custom_data_in`,
  `gary.v:118`, `dbr`-muxed), which is what the ROM needs. CIA state is not
  mirrored (`cart.v:27` TODO); HRTmon reads the CIAs directly and lives
  with what it finds (**unverified**).

Timing of the monitor itself: every instruction fetch from `$A1xxxx` is a
16-bit adapter cycle on the 7 MHz bus, so HRTmon runs like a 7 MHz 68000
with a 37 MHz core waiting on it. Acceptable for a monitor; if it is
painful, adding `sel_cart` back to the wrapper's RAM router
(`TG68K.vhd:693`) with `cache_inhibit` set is a Stage-4 option, not a
requirement.

## 5. Monitor-only: most of the debugging value for a fraction of the risk

Paul's stated need is "stop a wedged demo and look at memory". Two things
already exist that give most of that without a freeze at all:

1. The 832 reads SDRAM bank 0 **live**, while the 040 runs, through its own
   arbitrated SDRAM slot (`sdram_ctrl.v:282-287`, `hostena` on slot 1).
   That is all of chip RAM (2 MB), slow RAM, Kickstart, the cart window and
   the `$A0-$FF` scratch. Not Z2 fast (bank 1), not Z3/DDR3. A wedged demo
   is in chip RAM.
2. The wrapper already exports `dbg_pc`, `dbg_sr`, `dbg_ir`, `dbg_fault_addr`,
   `dbg_exc_vec`, `dbg_flags = {fault, in_exc, halted, busy}`
   (`TG68K.vhd:1340-1349`), and `ap040_dbg1` also carries A0, D0-D2, A7
   (`:1340` comment). Today they only feed an ILA in a debug build.

What a monitor-only Stage 1 gives, with reads only:

* An OSD "Debug" page (the Ctrl+LAlt+Menu `DebugMode` at `menu.c:357-364`
  is the natural home) showing PC/SR/IR/A7 and the fault flags, sampled
  through a new `OSD_CMD_*` readback in `userio_osd.v` (the SPI read path
  `spi_mem_read_sel`/`OSD_CMD_READ` is the pattern; `OSD_CMD_KEYQ` at
  `osd.h:49` is the most recent example of adding a command with a
  capability bit, `fpga.h:29`).
* A hex viewer over the host window (`hexdump.c:4` exists) with an address
  entry, plus a decoded custom-register view if the cart's mirror is also
  exposed over SPI (256 words, `cart.v:86`; needs a read port).
* Because nothing stops the CPU, "wedged" state is seen exactly as it is;
  PC sampled a few times tells you the spin loop.

What it cannot do: disassemble, set breakpoints, single-step, edit
registers, resume something you changed. Also: **writes** from the 832 are
not snooped by either cache (4.4), so a poke into chip RAM may be masked
by a valid D line in the 040 or in `cpu_cache_new` until it is evicted.
Stage 1 should be read-only, or pokes must be documented as "may not be
seen by the CPU immediately"; a snoop of the host port into both caches is
possible but is a Stage-4 nicety.

Judgement: monitor-only is one firmware day plus a small `userio_osd.v`
readback, touches nothing on the CPU path, and is useful during every
future corruption hunt. HRTmon adds the interactive monitor and the
nostalgia, at the cost of the 4.1-4.3 work and an unknown in the ROM.
**Do the monitor-only page first; it is also the instrument you want when
bringing up the freezer.**

## 6. Staged plan

Effort: S = an hour or two, M = a day, L = several days with hardware time.

### Stage 0: de-risk (S+S+S+S, half a day total)

* **0a. Prove 1.3 on hardware.** Put `HRTMON.ROM` on the card, enable HRTmon
  in the OSD, boot Workbench, press Ctrl+Pause. Expected by code reading:
  display keeps running (DMA is unaffected), no HRTmon screen, mouse/keyboard
  dead (level 2/6 lost), or a Guru from the level-7 vector. With the
  `CPU040_DEBUG_ILA` build (`build_ap040.tcl`, `virtual_top.v:968`), trigger
  on `dbg_exc_vec == 31` and read `dbg_pc`. If instead HRTmon appears, this
  whole document is wrong about the acknowledge and Stage 2 collapses.
* **0b. Prove the ROM on a 68040.** Run the same `hrtmon.rom` in WinUAE
  configured as 68040 + AGA + 2 MB chip, with and without `68040.library`.
  WinUAE is the reference `cart.v` was modelled on. Freeze, inspect, resume.
  If HRTmon cannot resume on a 68040 in WinUAE, no RTL work will make it
  resume here; the fallback is a different monitor image or monitor-only.
* **0c. MMU state after `68040.library`.** In the same WinUAE session, read
  TC and the transparent-translation registers from the debugger after the
  library loads. Answers 4.3: identity map or not, `$A0xxxx` mapped or not.
* **0d. Build hygiene.** Confirm `haveddr3 = 1` is the only shipped
  configuration (1.1 backing-store conflict) and add a `-- pragma`/assert
  note for the `haveddr3=false` overlap; confirm `ACTIONREPLAY_BROKEN` is
  absent from the 832 build (it is, `Makefile:27,50`).

Riskiest assumptions named: (i) HRTmon's ROM handles a 4-word frame and
does not touch the FPU; (ii) `68040.library` identity-maps and covers
`$A0xxxx`. Both are settled by 0b/0c before any RTL is written.

### Stage 1: monitor-only debug page (M)

* `userio_osd.v`: a new SPI read command returning `dbg_pc`, `dbg_sr`,
  `dbg_ir`, `dbg_flags`, `dbg_exc_vec`, `dbg_fault_addr` (these must be
  brought into `minimig.v`/`userio.v` from `minimig_virtual_top.v:229-234`;
  they are `clk_cpu`-domain values, so register them under a toggle or
  accept a torn sample and document it). Capability bit in `CORE_CAPS`.
* Firmware: Debug page showing them; hex viewer over `HOSTMAP_ADDR`
  (existing `hexdump.c`), address entry from the keypad; read-only.
* Test: extend the `sim/osd_keyq` bench pattern (`osd_keyq_tb.v`, `run.sh`,
  `run_mutant`) for the new command with a mutant that returns the wrong
  word order. Hardware: wedge a known demo, read PC, compare with an ILA
  capture of `dbg_pc`.
* Independently useful; no CPU-path change; no dependency on Stage 0b/0c.

### Stage 2: the acknowledge, in RTL (M-L)

* `TG68K.vhd`: connect `nmi_ack_toggle`, synchronise into `clk`, export
  `nmi_ack` pulse. `minimig_virtual_top.v`, `minimig.v`: route to `CART1`.
* `cart.v`: replace `int7_ack` (`:139`) with `nmi_ack`; `int7` falls on ack
  or on a bounded timeout; `active`/`stealth` set on ack; `ovr` bounded.
  Keep `sel_cart`'s `stealth | cpuhlt` policy.
* Bench: a new `sim/cart/` xsim bench around `cart.v` alone (cheap, minutes),
  driving `freeze`, an `nmi_ack` pulse, then adapter-style word reads of
  `VBR+$7C`/`+$7E` and of `$A1000C`; checks `int7` width, the `$00A1`/`$000C`
  answer, and that `int7` never sticks. Mutant per project habit: tie
  `nmi_ack` to 0 and the bench MUST fail on the stuck-IPL check.
  Second bench: `sim/ddr3_cpu` with a small vasm program (`asm/`,
  `build_68k_test.sh` pattern) that unmasks interrupts and spins, the tb
  pulsing `IPL` to 7 and answering the adapter's vector fetch with
  `$00A1000C` and the fetch at `$A1000C` with a `RTE` sequence; checks the
  format word on the stack, the toggle, and that a second IPL 7 is taken.
  Note `minimig.v` is not in that bench, so the cart's answer is modelled
  in the tb; the two benches meet at the adapter interface. (See the
  `sim/ddr3_cpu bench traps` memory note before trusting a green run.)
* Hardware: Stage 0a repeated; HRTmon screen expected.

### Stage 3: firmware and config (S-M)

* `UploadActionReplay()`: only when `config.memory & 0x40`; rename to
  `UploadHRTmon`; keep the WinUAE config block; check `maxchip`
  (`config.c:212` TODO) against the OSD chip setting for all four sizes.
* Help text: drop the `ACTIONREPLAY_BROKEN` branch (`menu.c:109-113`).
* `config.disable_ar3`: leave the byte (config file layout) and document it
  as reserved, or use it as the "HRTmon loaded" flag.
* OSD: the HRTmon line moves out of "Memory" to wherever the Stage 1 debug
  page lives; the enable should also gate the upload message at boot.

### Stage 4: 040-specific hardening (M-L, driven by 0b/0c results)

* Cache clear on resume: pulse `cacheline_clr`/maint when `active` drops
  (4.4). Bench: `sim/cart` checks the pulse; hardware: patch a loop in fast
  RAM from the monitor, resume, observe the patched behaviour.
* TC.E tap next to `dbg_flags` so the Stage 1 page and a freeze failure
  can say "MMU on". If 0c shows `$A0xxxx` unmapped under `68040.library`,
  either document "freeze with MMU off" or add the range to the library's
  map from the Amiga side (a startup-sequence tool, not gateware).
* CIA shadow at `+$8E000`/`+$8D000` if HRTmon's CIA display is wrong on
  hardware (**only if** 0b shows it matters).
* Optional speed: `sel_cart` in the wrapper's RAM router with
  `cache_inhibit`, if the 7 MHz monitor is annoying.

### Stage 5 (not recommended): a real AR3

Only if the nostalgia is the point. Needs: a second cart module with the
`$400000`/`$440000` decode and mode register, a Z2 fast-RAM hole or a
reduced Z2 board (`TG68K.vhd:685`, `minimig_autoconfig.v`), a reset-vector
override path over `$0`/`$4` that coexists with `ovl`, CIA shadowing, and a
68040 port of the AR3 ROM's save/restore code. L+, and the ROM work is the
part nobody on this project can test in simulation without the ROM.

## 7. Test strategy summary

| What | Simulate | Hardware |
|---|---|---|
| `cart.v` acknowledge, IPL width, vector answer | `sim/cart/` unit bench (new, xsim, minutes) + mutant | 0a/Stage 2: HRTmon screen, ILA on `dbg_exc_vec` |
| Core takes level 7, stacks format 0, RTEs, re-arms | `sim/ddr3_cpu` program + tb-modelled cart (15-20 min per leg) | Freeze twice in a row |
| OSD readback of dbg words | `sim/osd_keyq`-style bench + mutant | Wedge a demo, compare with ILA |
| ROM behaviour on 68040, MMU state | WinUAE (Stage 0b/0c), not xsim | Workbench + `68040.library`, freeze, resume |
| Cache clear on resume | `sim/cart` pulse check | Patch fast-RAM code from the monitor |
| `haveddr3=false` overlap | Not needed; assert at elaboration | None |

The minimig-level benches under `sim/minimig*/nc/` are Cadence NC scripts
from the upstream tree (`dir.lst`, `rtl.lst`), not runnable in this flow, so
`cart.v` in context is covered by the unit bench plus the adapter-level
model in `sim/ddr3_cpu`.

## 8. Risks and effort

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | HRTmon ROM cannot resume on a 68040 (frame/FPU/cache assumptions) | Low-medium | Freezer is inspect-only | Stage 0b in WinUAE before any RTL; monitor-only still delivers |
| R2 | `68040.library` does not map `$A0xxxx`; freeze under WB double-faults | Medium | Freezer only usable with MMU off (demos, floppy boots) | Stage 0c; TC.E tap; Amiga-side mapping tool |
| R3 | `nmi_ack` CDC or pulse-width mistake leaves IPL stuck (same failure as today) | Medium | Machine deaf after first freeze | Bounded `int7`; unit bench with mutant; ILA |
| R4 | `sel_nmi_vector` routing misses a case (e.g. vector read from a page-table walk) | Low | Wrong vector once | Already excludes `wk_go`, `x_instr`, `x_we` (`TG68K.vhd:617-618`) |
| R5 | Non-DDR3 build maps Z3 board 3 over the HRTmon image | Certain if such a build is made | Silent corruption of the monitor | Elaboration assert; document |
| R6 | 832 host pokes masked by caches (monitor-only) | Certain for pokes | Confusing "poke did nothing" | Read-only Stage 1; document; optional host snoop later |
| R7 | Someone halts the bus (`SPI_CPU_HLT`) while frozen; watchdog fires | Low | Access error in the frozen program | Firmware rule: no halt while HRTmon active |
| R8 | The OSD/firmware side finding (1.4, `memory_config[7]`) is real | Unknown | "DDR3 only" toggle never applied | One-line width fix; outside this plan |

| Stage | Effort | Independently testable |
|---|---|---|
| 0 | 0.5 day | yes, each item |
| 1 | 1-1.5 days | yes (bench + hardware) |
| 2 | 1-2 days incl. benches | yes |
| 3 | 0.5 day | yes |
| 4 | 1-3 days depending on 0b/0c | yes, per item |
| 5 | not estimated; not recommended | -- |

Total for a working HRTmon freezer plus the monitor page: roughly one
working week, with Stage 0 able to shorten it to "monitor page only" in
half a day if the ROM or the MMU says no.
