# AP68040 with MMU and FPU — implementation plan, second edition

> **NEXT SESSION STARTS AT [B4](#stage-b--mmu-walker-port-m--done), then Stage C
> and Stage D.**
>
> Stages 0, A and B are done and on hardware, 2026-09-07. The 68040 boots
> **Workbench with the MMU on**: `SetPatch` programs it through
> `68040.library`, the walker answers, and the machine runs. The library was
> never renamed in the end -- the walker landed first and the free experiment
> was not needed.
>
> Tagged `unoptimized_040_working` at that point. Since then, in simulation
> only: the OSD reports the CPU (`CORE_CAPS`), and **D1** raised the enable
> from every 4 cycles to every 3 (−19 % on the bench). Neither has been run on
> hardware yet -- `build/stage_ap040_osd` is the OSD change alone and
> `build/stage_ap040_d1` is both, and the firmware in `fw/ctrl_832` must go on
> the SD card for the OSD half. Still not done: D2, the DDR3 line port, which
> is where the rest of the speed is.

Date 2026-09-06, updated 2026-09-07. Status: **stages 0, A and B done and on
hardware.** The AP68040 is the sole core in `build/stage_ap040_mmu`
(WNS -0.501 ns, the usual SDRAM read path, hold clean, plus a new -0.243 ns
noted in B) and boots Kickstart 46.143 all the way to **Workbench with the MMU
on**: ExecBase published, memory list and allocator working, interrupts
arriving, `SetPatch` programming the MMU through `68040.library`, and the
table walker answering its descriptor reads and write-backs. Tagged
`unoptimized_040_working`. B4 (MuFastROM/MuScan) is what is left of stage B;
stage D is the whole of the performance work and has not started. See "Log" near the end for
what was found on the way -- two bugs, both the same bug on different ports.
Supersedes the order of work in [README.md](README.md), which was written
before the DDR3 fast RAM landed and assumed it would arrive as an in-domain
DLL-off controller. It arrived differently (see "What changed since the first
plan"), so the memory side of that plan is out of date; its compatibility
assessment ([compatibility.md](compatibility.md)) and clock-rate measurements
([performance.md](performance.md)) still stand and are relied on below.

## The question asked

Put the 68040 into the Minimig configuration next to the TG68K if it fits,
otherwise make it the only core. MMU and FPU on.

## The answer, with the numbers

Both fit. Measured on the bitstream tagged `ddr3-fast-ram` (build/stage_z3ram3,
`report_utilization -hierarchical`) and the AP68040 out-of-context place and
route at commit 0e76761 with the RAM-primitive fix
([synth-reports/util_routed.rpt](synth-reports/util_routed.rpt)):

| | LUTs | of 63,400 | BRAM tiles | DSP |
|---|---|---|---|---|
| Design today (TG68K, DDR3 board 3, RTG, Toccata) | 15,909 | 25 % | 49.5 | 18 |
| of which the TG68K wrapper `tg68k` (kernel + decode + Akiko/C2P) | 5,043 | | | |
| AP68040, MMU + FPU + 4 KB/4 KB caches, placed and routed | 28,694 | 45 % | 10 | 20 |
| **Sole core**: today − TG68K kernel (≈ 4,000–4,500) + AP68040 | **≈ 40,400** | **≈ 64 %** | ≈ 60 | 38 |
| **Both cores**, OSD-selected: today + AP68040 + kernel mux (≈ 300) | **≈ 44,900** | **≈ 71 %** | ≈ 60 | 38 |

So the honest answer to "does it fit" is: on LUT count, yes, either way. What
the count does not say is whether two 40-logic-level cores plus the DDR3
island route and close timing at 71 %. The AP68040 alone at 45 % of the device
routes with its worst path at 21.0 ns ([performance.md](performance.md)), and
every path fits the 3-cycle `clkena` budget with 5 ns to spare; congestion at
71 % will eat some of that. That is a place-and-route question, and the only
way to answer it is to run it. The earlier "not an option on this device" in
compatibility.md was written when the core was 70.8k LUTs, before the
`dpram.v` fix; it no longer holds.

**Recommendation.** Build the sole-core version first, as a build-time choice
(`CPU_CORE = "TG68K" | "AP040"` on the top level, two bitstreams). Everything
it needs — wrapper, walker port, constraints, benches — is also needed for the
dual-core version, so nothing is wasted. Then try the dual-core bitstream as a
bounded experiment (stage E): if it closes timing with margin, ship it; if it
does not, the two bitstreams are the product. Do not start with the dual
build: a timing failure there cannot be told apart from an integration bug.

## What changed since the first plan

* **DDR3 fast RAM exists**, as Zorro-III board 3 on the 100 MHz island
  (`rtl/ddr3/*`, vendored `core_ddr3_controller`, `cpu_cache_new` in front,
  a 16-byte line CDC behind). Boards 1 and 2 stay on the SDRAM. The README's
  C-track (in-domain DLL-off controller at 56.7 MHz, RTG on DDR3, the
  watermark arbiter) is superseded and is **not** part of this plan; RTG
  stays on the SDRAM.
* **The DDR3 backend is already a line port.** `ddr3_fastram.v` talks to the
  island in 16-byte lines with 16 byte enables through `ddr3_cdc.v`. The 040's
  line fills and copy-back writes map onto that 1:1 once they bypass the
  16-bit bus — stage D here, formerly B1/B2.
* **The Zorro-III bases are latched now** (`z3ram3_base`), which is exactly
  what the 040's cacheable-window inputs want.
* **Constraint prerequisites landed**: fix-04 (multicycles off
  `[all_registers]`), fix-05 (clock groups), fix-06/07/09/10. The multicycle
  sets in `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` are by instance path
  and the file says so: "if the CPU core is replaced, only the three set
  definitions change". fix-12 (SDRAM read capture clock) was **reverted**
  (does not run on hardware); the SDRAM read path keeps its known −0.5 ns.
* The AP68040 tree at `~/work/fpga/Xilinx/artix7/minimig/AP68040`, commit
  0e76761, is unchanged since the assessment; `primitives/dpram.v` is still
  the single-process version that dissolves into 43k LUTs. Its self-test
  suite runs on this machine (iverilog + vasm); results in "Numbers" below.

## What the core offers and what the SoC has to give it

From `rtl/ap040_tg68k_compat.v` (the only top level to use) and its headers.

**Drop-in part.** `clk`, `nreset`, `clkena_in`, `data_in[15:0]`,
`data_write[15:0]`, `addr_out[31:0]`, `nwr`, `nuds`, `nlds`, `busstate[1:0]`
(00 fetch, 01 idle, 10 read, 11 write — same encoding), `longword`, `fc`,
`ipl`, `nresetout`, `vbr_out`. The bus contract in `ap040_bus16_adapter.v`
is the Minimig one this wrapper already speaks: outputs registered on
`clkena_in`, one request at a time, level acknowledge, an IDLE cycle between
split sub-cycles, long = two word cycles when even. `cpu[1:0]` does not
exist — the core is always a 68040 — so the wrapper's `cpu(1)` (32-bit
decode, AGA longword chip access) is fixed high in the AP040 branch.

**Sideband the SoC must feed.**

| Port | Feed from | Notes |
|---|---|---|
| `cache_snoop_stb`, `cache_snoop_addr[31:0]` | `sdram_ctrl.v` `snoop_act` and `{chipAddr,1'b0}` (`:292-295`, already built for `cpu_cache_new`) | Needs a new output pair on `sdram_ctrl` and a new input pair on the wrapper; same clock domain. Without it chip RAM is uncacheable in the D-cache. The I-cache never caches the chip window by design (`ap040_tg68k_compat.v:227-242`). |
| `cache_z2_ena` | `z2ram_ena` | window is $200000–$9FFFFF, hard-wired in the core |
| `cache_z3_base0[4:0]`, `cache_z3_ena0` | `5'b01000`, `z3ram_ena` | window = `addr[31:27]`, 32 MB: $40000000–$41FFFFFF covers board 1 **and** board 3 where the OS puts it today |
| `cache_z3_base1[3:0]`, `cache_z3_ena1` | `z3ram3_base[7:4]`, `z3ram3_ena` | window = `addr[31:28]`, 256 MB: follows the DDR3 board wherever the OS places it |
| `cache_allow_all` | `0` | |
| `berr` | `0` for stage A | the SoC never raises bus errors today (undecoded space auto-completes with $FFFF); the core has its own watchdogs. Stage B may drive it from the walker router. |
| `ipl_autovector` | `1` | ignored by the core; always autovectored |
| `walker_req/we/addr/wdat` → `walker_ack/data/berr` | **stage B** | tied off in stage A: `ack = 0`, `berr = 0`. A walk that never acks becomes a bus error via the watchdog, so the MMU is unusable but the core does not hang. |
| `cacr_out[31:0]` | → `cpu_cache_ctrl[3:0]` for `cpu_cache_new` | **layout differs**: 040 CACR is DE = bit 31, IE = bit 15; `cpu_cache_new` wants the 020 nibble {clear, –, freeze, enable}. Proposal: `{cache_maint_req, 1'b0, 1'b0, 1'b1}` — external caches always on (they are coherent: snoop for chip RAM, single master for DDR3), cleared on CINV/CPUSH. Verify in the bench (stage A5). |
| `cache_maint_req/ic/dc`, `mmu_*`, `debug_*`, `nmi_ack_toggle` | open | observation |
| `cache_req/addr/data/ack/burst/burst_len/ramaddr` | leave open | **stubbed to zero inside the compat top** (`:434-438`): there is no line-fill port in this checkout; every fill is eight 16-bit sub-cycles through the adapter. Stage D adds one. |

**Two facts about the walker port** (from `ap040_mmu.v`):
`walk_ack = w_active && w_issued && walker_ack && !walker_berr` and the walk
FSM advances under `if (ce)`. So `walker_req` is a level held until the FSM
sees `walker_ack` on a `clkena` edge, and the ack must be a level, not a
one-cycle pulse on the free-running clock. `ap040_walker_cdc.v` is for hosts
whose MMU and memory run on different clocks; here everything is `clk_114`
with `clkena`, so it is not needed.

**One fact about the constraints.** The compat top has a core-side stall
watchdog that counts on the **free-running** clock ("a clkena wedge cannot
stop the count", `ap040_tg68k_compat.v:14-28`). It is a single-cycle path
inside what `cpu.xdc` will call the kernel island. The kernel multicycle set
must exclude it (`NAME !~ *watchdog*` or whatever the instance is called), or
Vivado will relax a genuine single-cycle path — harmless for a 21-bit counter,
wrong as a constraint, and exactly the class of thing fix-04 was about.

**Restart model.** On a write fault the faulting instruction re-executes; the
core never advertises a valid WB3. NetBSD's `trap.c` would double-apply RMW
stores if it completed writebacks itself. AmigaOS's `68040.library` does not,
so this matters only for stage F.

## Timing

### What the CPU island is today, and why the 040 fits in it unchanged

`clk_114` is 113.4375 MHz, 8.815 ns. The CPU does not run at that rate: the
kernel advances only on `clkena`, which the wrapper builds
(`TG68K.vhd:499`) from `enaWRreg` — pulsed by `sdram_ctrl.v:343-360` on
phases 2, 6, 10 and 14 of its 16-phase round, i.e. every 4th `clk_114`,
28.36 MHz — further gated on bus readiness (`mem_ready`, chipset
`ena7RD/WR`, `sel_undecoded_d`, `akiko_ack`). Every kernel register therefore
holds for at least 4 cycles, which `cpu.xdc` turns into:

| Path | Exception | Budget |
|---|---|---|
| kernel → kernel, kernel → wrapper | `-setup -start 4 / -hold -start 3` | 35.26 ns |
| kernel → memory side (`sdram`, `minimig`) | `-setup -start 3 / -hold -start 2` | 26.45 ns, because `sdram_ctrl` wants the address one cycle before chip-select |
| wrapper `addr*` registers → memory side | same 3-cycle rule | 26.45 ns |

The AP68040, placed and routed on its own at 45 % of the device with the
RAM fix: worst path **21.0 ns**, 39–40 logic levels, 66 % of it routing;
of the 5,000 worst endpoints, **0** exceed 26.45 ns and 1,148 exceed
17.63 ns ([performance.md](performance.md), [synth-reports/histogram.txt](synth-reports/histogram.txt)).
So under today's 4-cycle regime the core has 14 ns of margin; under a
3-cycle regime 5.4 ns standalone. The TG68K's in-system worst is 19.4 ns for
comparison — the 040 is the same class of path, not a harder one. Its
outputs to the bus are registered and change only on `clkena` edges
(`ap040_bus16_adapter.v` header), so the 3-cycle rule on kernel → memory is
satisfied for the same reason it is for the TG68K. The FPU is already inside
the 21.0 ns figure (full configuration was measured), and its 16 DSP48s sit
in the same multicycle island.

Conclusion: **stage A changes no clock and no exception values**; only the
three cell-set definitions in `cpu.xdc` move to the new instance.

### Where it can still go wrong, in order of likelihood

1. **The clock-enable net.** `clkena` is a *combinational* signal in the
   wrapper fanning out to the CE pin of every kernel flip-flop. The TG68K has
   roughly 2–3k of those; the AP68040 has **7,391**. That net is a genuine
   single-cycle path (enable source → CE, 8.815 ns) and no multicycle covers
   it. Vivado will replicate a high-fanout net, but a 7k-fanout CE driven by a
   LUT is the one path in this swap that is *new*, not just bigger. Watch it
   first in the A6 timing report. Mitigation ladder: let `phys_opt_design`
   replicate; then `MAX_FANOUT` on the wrapper's `clkena`; then register a
   duplicate enable tree in the wrapper — which shifts the kernel by one
   `clk_114` relative to the SDRAM round and must be re-benched in
   `sim/ddr3_cpu` before it is trusted, since the bus contract counts
   completions on that enable.
2. **Free-running logic inside the kernel set.** The compat top's stall
   watchdog counts on the raw clock by design (`ap040_tg68k_compat.v:14-28`),
   and `ap040_bus_timeout.v` may too. Their registers are single-cycle and
   must be *excluded* from the multicycle cell set, or Vivado relaxes them
   (TIMING-46 would flag some, not all). Step 0.3 finds them by reading for
   `always` blocks not qualified by `ce` and excludes them by instance name.
3. **Congestion at 64 %, then 71 %.** The 21.0 ns was measured at 45 %
   utilisation with nothing else on the die. Budget 10–20 % degradation
   in-system: 23–25 ns, still inside 35.26 with room, but *outside* the
   3-cycle 26.45 ns once the safety margin is counted. That is why the
   37.8 MHz option (D1) is a measured experiment after A6, never assumed.
4. **The SDRAM read path** (`clk_gen_sdram → clk_114`, 16 endpoints,
   −0.544 ns today, fix-12 reverted). It is I/O timing at the SDRAM bank, not
   CPU logic, but 28.7k extra LUTs change the placement around the
   `sdram_controller` pblock (`wizard.xdc:59-64`). Sign-off rule: no worse
   than today. If it degrades, add a pblock for the CPU island on the far
   side of the die from the SDRAM I/O before touching anything else.
5. **The DDR3 side is untouched.** No new clock crossing: the 040 sits behind
   the same `cpu_cache_new`/`ddr3_fastram`/`ddr3_cdc` chain, and the
   `set_max_delay -datapath_only` bounds in `ddr3.xdc` do not change. The
   040's caches change the *traffic* (8-sub-cycle line fills, copy-back
   writes) but not any timing path. The island's own slack (2.27 ns intra
   `clk_ddr100`) is unaffected.
6. **Stage B walker requester.** Its address register drives the `cpuaddr`
   mux → `sel_*` decode → memory side. Name it to match the existing
   `addr*` filter in `cpu.xdc` (or extend the filter) so it gets the 3-cycle
   rule the kernel address gets; it holds its value until `walker_ack`, so the
   rule is honest. The mux itself is one LUT level on a 26.45 ns path.
7. **Stage E dual-core.** The kernel-output mux is one LUT level on 3-cycle
   paths — fine. The unselected core is held in reset with `clkena_in` low:
   its registers are static, so it costs routing resources but no timing
   paths that matter. Both kernel instances get their own cell set. The
   select is latched at reset (`cpu_config` bit 4 below) and is quasi-static;
   `set_false_path -from` that register keeps it out of the CE-path report.
   What decides E is not any of this but item 3 at 71 %.

### Sign-off per stage

| Stage | Must hold |
|---|---|
| A6 | kernel island WNS ≥ 0 under `-start 4`; CE net WNS ≥ 0 with no replication warnings left unresolved; SDRAM read path ≥ −0.544 ns (no worse than today); DDR3 CDC exceptions unchanged in `report_exceptions` |
| D1 | same under `-start 3 / -hold -start 2` on the kernel island; measured, two build iterations maximum |
| D3 | `report_exceptions` shows no multicycles on the core at all (sibling 37.8 MHz clock, slow→fast 1:3 rule as `dll_28 → clk_114` uses) |
| E | A6's rules at ≈ 71 %; two build iterations, then stop |

### Calendar

Critical path to a usable MMU + FPU 68040 at 28 MHz: stage 0 (S) → A (M,
one hardware session at A6) → B (S–M, one hardware session at B3) → C (S).
Roughly one to two weeks including bench time, with three hardware sessions
(A6, B3, C). D and E are afterwards and independent of each other.

## OSD and firmware

### How the CPU setting reaches the RTL today

`fw/ctrl_832/osd.c:880` `ConfigCPU()` sends `OSD_CMD_CPU` (0x14) followed by
one byte, `cpu & 0x0f`. `rtl/minimig/userio_osd.v:416` takes `wrdat[3:0]`
into `t_cpu_config`; bits 1:0 (CPU type, the TG68K's `cpu(1:0)`) are copied
to `cpu_config` **only while reset is active** (`:83-89`), bits 3:2 (turbo
chip / kick) immediately. `cpu_config[3:0]` runs `userio.v` → `minimig.v` →
`minimig_virtual_top.v:214` → `.cpu(cpu_config[1:0])` on the wrapper. The
menu (`menu.c:85`) shows `config_cpu_msg[] = {"68000", "68010", "-",
"020 alpha"}` indexed by `config.cpu & 3` and cycles 0 → 1 → 3, skipping 2
(`:1323-1326`). `config.cpu` is saved to the SD-card config file as is.

The firmware already reads something back from the core:
`fpga.c:205-209` sends `OSD_CMD_VERSION` (0x88) and clocks four bytes,
`rtl_ver` in `userio_osd.v:588-596`, selected by `dat_cnt[2:0]` — a 3-bit
index of which only 0–3 are used; 4–7 fall to `default` and return
`MINION_VER`. That is the hook.

### Changes, by build

**Sole-core AP040 build.** The wrapper ignores `cpu(1:0)` (its 68040 branch
fixes 32-bit decode on). The OSD must say so rather than offer a choice that
does nothing:

| Where | Change |
|---|---|
| `userio_osd.v` | `rtl_ver` case gains `3'd4: 8'hA4` (a magic byte) and `3'd5: CORE_CAPS`. Old cores return `MINION_VER` for both, so a firmware that sees anything but 0xA4 in byte 4 knows there is nothing to read. `CORE_CAPS` is a parameter plumbed down from the top: bit 0 AP040 fitted, bit 1 AP040 *selectable* (dual build), bit 2 FPU, bit 3 MMU. Bytes 0–3 unchanged, so old firmware keeps working. |
| `minimig.v`, `userio.v` | pass `CORE_CAPS` through |
| `minimig_openaars_top.v` | `CORE_CAPS` derived from `CPU_CORE` and the AP040 parameters |
| `fpga.c:205` | clock two more bytes after the four; keep `core_caps` in a global (0 unless byte 4 == 0xA4); append " 68040" (and "/FPU", "/MMU") to the boot banner |
| `menu.c` | if `core_caps & 1` and not `& 2`: CPU line reads "68040", not selectable (skip `menusub == 0` in the select handler) |

Turbo chip / Kick stay as they are. (With the MMU on and MuFastROM in use,
turbo Kick is redundant for 040 users, but it is harmless and the menu does
not need to know.)

**Status: the sole-core changes above are done** (2026-09-08). `CORE_CAPS` is
a parameter on `minimig_virtual_top` derived from `cpu_core` and the AP040
parameters, passed down through `minimig.v` and `userio.v` to `userio_osd.v`,
where version bytes 4 and 5 are `8'hA4` and `CORE_CAPS`. The firmware reads
both in `fpga.c`, keeps `core_caps` (0 unless the magic byte matches), prints
`CPU: MC68040 + FPU + MMU` in the boot banner, and `menu.c` shows a greyed,
unselectable `CPU : 68040/FPU/MMU` line with `menumask` bit 0 cleared. Old
firmware on a new core and new firmware on an old core both behave exactly as
before -- that is what the magic byte is for.

### Building and installing the firmware

The firmware is **not** in the bitstream. The boot ROM that is in the
bitstream reads `832OSDAD.BIN` from the root of the SD card's first FAT
partition (`fw/ctrl_boot_832/Makefile`, `-DOSDNAME=\"832OSDADBIN\"`), so the
firmware is a file on the card and the bitstream is programmed over JTAG.
They are updated independently -- but a firmware that reports the CPU needs a
core that answers the query, so after this change update **both**.

    # 1. firmware -- needs the EightThirtyTwo toolchain at the repo root
    #    (git clone https://github.com/robinsonb5/EightThirtyTwo, make)
    cd fw/ctrl_832
    make                       # -> 832OSDAD.bin, about 90 KB

    # 2. onto the SD card: the FAT root, 8.3 name, uppercase
    cp 832OSDAD.bin /media/<you>/<card>/832OSDAD.BIN
    sync

    # 3. bitstream over JTAG
    LD_LIBRARY_PATH=<libtinfo5 shim> /opt/Xilinx/Vivado/2023.2/bin/vivado \
        -mode batch -nolog -nojournal -source tools/vivado/program.tcl \
        -tclargs build/stage_ap040_osd/minimig_openaars_top.bit

The name matters: `LoadFile` matches the packed 8.3 form, so it must be
`832OSDAD.BIN` in the **root**, not in a directory and not renamed. Keep a
copy of the previous `832OSDAD.BIN` on the card under another name before
overwriting -- a firmware that does not boot leaves no OSD to fix it from.

**Dual-core build (stage E).** The select must survive the same rules as
the CPU type: applied at reset only, and the RTL — not the firmware — is the
authority on whether it exists.

| Where | Change |
|---|---|
| `osd.c` `ConfigCPU` | send `cpu & 0x1f` |
| `userio_osd.v` | `t_cpu_config` and `cpu_config` become `[4:0]`; bit 4 is copied under reset next to bits 1:0, so a core switch takes effect at the next reset exactly as a CPU-type change does today |
| `userio.v`, `minimig.v`, `minimig_virtual_top.v` | widen to 5 bits; the wrapper gets `.cpu(cpu_config[1:0])` and `.core_sel(cpu_config[4])` |
| `TG68K.vhd` | in the dual build, `core_sel` picks the kernel; the unselected one is held in reset with `clkena_in` low. In a sole build the port is unused. |
| `menu.c` | when `core_caps & 2`: cycle 68000 → 68010 → 020 → **68040**; 68040 encodes as `config.cpu` bit 4 set with bits 1:0 = 11 (so an old core that only looks at bits 1:0 gets the TG68K in 020 mode — the closest thing). Leaving 68040 clears bit 4. |
| `config.c` | nothing: bit 4 lives inside the `unsigned char` that is already saved, and the load path does not mask it (checked: `config.c:337` only sets the default 0, `:428` passes the byte to `ConfigCPU` as is). |

Compatibility both ways: old firmware + new core sends bit 4 = 0 → TG68K
selected in a dual build, ignored in a sole build. New firmware + old core
reads byte 4 ≠ 0xA4 → `core_caps` = 0 → menu exactly as today.

One behaviour to keep: the firmware does not reset the machine when the CPU
type changes; the user does. Same for the core select. If that is felt to
be a trap, `menu.c` can call `OsdDoReset` when bit 4 changes — a one-line
addition, but a change in behaviour, so it is a decision, not a default.

## Order of work

Effort: S = hours, M = days, L = a week or more including bench time. Each
stage ends in a commit and a bench or hardware result; nothing is synthesised
before its bench passes, which is the rule that saved a bring-up cycle on the
DDR3 (`findings/ddr3/z3ram3-on-ddr3-plan.md`).

### Stage 0 — bring the core in, keep it verifiable (S)

| # | Step | Exit criterion |
|---|---|---|
| 0.1 | Vendor AP68040 as a git submodule at `lib/AP68040`, pinned at 0e76761 (same arrangement as `rtl/tg68k`). Add its eleven `rtl/*.v` to the Vivado project as SystemVerilog, `ap040_defs.svh` on the include path. | project opens, `read_verilog -sv` clean |
| 0.2 | RAM primitive: a project-local `rtl/cpu040/dpram.v` from [synth-reports/dpram_xilinx.v](synth-reports/dpram_xilinx.v) compiled **instead of** the submodule's, so the submodule stays pristine. Run `lib/AP68040/tb/run_tests.sh` with the override on the path. The replacement returns *old* data on a cross-port collision where the original returns *new*; `tb_ap040_cache_snoop.v` is the test for exactly that. | all tests pass with the override; `bench_loop` cycles recorded below |
| 0.3 | Constraints: make `cpu.xdc`'s three set definitions take the kernel instance path from one variable; add the watchdog exclusion. No behaviour change for the TG68K build. | `report_exceptions` identical before/after on the TG68K build |
| 0.4 | The 4 September OOC numbers were taken at 0e76761 with this same replacement; re-run only if 0.2 changes anything. | — |

### Stage A — sole core: AP040 in the wrapper, 16-bit bus, no MMU walk (M)

| # | Step | Exit criterion |
|---|---|---|
| A1 | `rtl/soc/TG68K.vhd`: generic `cpu_core : string` ("TG68K" default, "AP040"). The kernel instantiation (`pf68K_Kernel_inst`, ~line 430) becomes a `generate` with two branches; **all decode, Zorro-III, DDR3, Akiko, chipset state machine and NMI logic stay as they are**. AP040 branch: component declaration for `ap040_tg68k_compat`; `cpu(1)` forced '1'; `skipFetch` '0'; ports per the table above. New wrapper inputs `snoop_stb`, `snoop_addr[31:0]`. Top levels pass `CPU_CORE` down; `AP040_HAS_FPU`/`HAS_MMU`/`ENABLE_CACHE` exposed as top-level parameters, **all 1 by default**. | TG68K build bit-identical in behaviour (sim/ddr3_cpu, sim/autoconfig unchanged) |
| A2 | `sdram_ctrl.v`: bring out `snoop_act` and the chip address as outputs; `minimig_virtual_top.v` wires them to the wrapper. | lint clean |
| A3 | `cpu.xdc`: kernel set = the AP040 instance minus the watchdog; wrapper and memory sets unchanged. `-setup -start 4 / -hold -start 3` as today (28.36 MHz, 35.3 ns budget; core worst path 21 ns). | `report_exceptions` shows the sets populated for both builds |
| A4 | OSD: the capability bytes on `OSD_CMD_VERSION` and the firmware side of "OSD and firmware" above, sole-core rows. The wrapper ignores `cpu(1:0)` in the AP040 branch; the menu says "68040" because the core told it so, not because it was built that way. | firmware built; boot banner shows 68040/FPU/MMU on the AP040 bitstream and is unchanged on the TG68K one |
| A5 | **Bench**: `sim/ddr3_cpu` gets `CPU_CORE` as a plusarg/define and compiles the AP040 sources under xsim; the same 68k program runs (assembled `-m68020`, valid 040 code). Add: chip-RAM access through the AGA longword path (the `longword` contract, `TG68K.vhd:589/630`), a 32-bit fast-RAM write (`longword_en` in `ddr3_fastram.v`), `movec` to a 040-layout CACR and the `cpu_cache_ctrl` mapping, and an interrupt (IPL) with autovector. Mutant run stays. Run the variants **one at a time** (`sim/ddr3_cpu/run.sh` header). | PASS + backdoor PASS with CPU_CORE=AP040; TG68K variant unchanged |
| A6 | **Hardware**: build `CPU_CORE=AP040`, program by reprogramming (never soft reset). Boot **without startup-sequence** so SetPatch never runs and the MMU stays off — no `NOMMU` mechanism to get right on the first try. Then `ShowConfig` (CPU line must say 68040), `avail` (42 MB as today), ATK on the SDRAM board and the DDR3 board. Then a normal boot: SetPatch loads `68040.library`, which **will** enable the MMU and hit the tied-off walker → watchdog → access error. Expected; it is the exit condition for stage B. | Workbench up with MMU off; ATK clean on both boards; the MMU-on boot fails in the documented way |
| A7 | Baseline numbers: `bench_loop` cycles per instruction TG68K vs AP040 (from 0.2 and the TG68K equivalent), and a fast-RAM memory benchmark on hardware for both bitstreams. | table below filled |

### Stage B — MMU walker port (M) — **DONE**

**Done and on hardware, 2026-09-07** -- Workbench boots with the MMU on. What
was built, and what is worth carrying forward:

* **The walker rides the CPU's own bus**, as designed below, and the design
  survived contact. `rtl/soc/TG68K.vhd` muxes the five signals the bus side
  derives from -- address, bus state, byte selects, write data, write strobe --
  so a descriptor cycle is indistinguishable from a CPU cycle to every
  consumer, the 7 MHz chipset FSM included. Two 16-bit sub-cycles at A and
  A+2, an idle gap between them, completion on `clkena`.
* **The clkena deadlock was avoided structurally, not by gating.** The bus is
  released BEFORE the acknowledge goes out, so `bstate` is the core's own idle
  state and `clkena` is running when the core consumes the ack. The extra
  `wk_ack` term in `clkena` is belt and braces on top of that -- and it is the
  first thing to try removing in D1, because `wk_active` reaching `clkena`
  through the mux costs 0.243 ns on the FPU multiplier's clock enable.
* **Bench**: `./run.sh --mmu` builds a two-level table with the root and
  pointer tables in chip RAM and the leaf page table in the DDR3, so both
  ports carry descriptors, then walks a warm page, a cold one (U and M clear,
  so the read and the write each force a write-back -- walker WRITES into the
  DDR3), an invalid descriptor and a table branch into space that decodes as
  nothing. `--mmumutant` ties `walker_ack` low and must fail; it does, on the
  stall watchdog.
* **A lesson about watchdogs.** The stall watchdog's first threshold, 120k
  cycles, failed a *healthy* pattern run: that program's phase 2 -> 3 gap is
  legitimately 1.18 ms. A watchdog tuned by guess is a bug generator. The
  thresholds are per program now and both numbers are measured.
* **And one about mutant guards.** `run.sh` tested for `DDR3 CPU TB: PASS`,
  which is only the 68k program's own phases. `--lwmutant` completes every
  phase while 1895 assertions fail around it, so the guard called it a mutant
  that did not fail. It tests the summary line now: a mutant check that can
  only see the program's own verdict cannot see an assertion at all.

The original statement of the problem follows.

**Confirmed on hardware 2026-09-07.** The 040 boots AmigaDOS to a Shell with
the startup-sequence skipped. `SetPatch` crashes it, run by hand from that
Shell. The capture: `dbg_pc` = $400B53FE, `dbg_ir` = 4E7B (MOVEC),
`dbg_flags` = {fault, in_exc, halted}, last bus address $0000000A -- the second
word of the longword at $8, i.e. vector 2. So MOVEC enabled translation, the
first table walk found `walker_ack` tied to 0, `ap040_bus_timeout` turned the
missing acknowledge into an access fault, and the core halted on the vector
fetch. This is the only known blocker between here and Workbench.

**Before writing RTL, run the free experiment.** On the boot volume:

    rename LIBS:68040.library LIBS:68040.library.off

`SetPatch` only programs the MMU because that library is present; without it it
still installs its patches and enables the caches. If Workbench then boots, the
walker is confirmed as the last blocker and there is a usable machine to work
from. If it still crashes, something else is wrong and this stage is not the
whole story -- find that out before spending a day on the router.

**Design: the walker rides the CPU's own memory path.** A walk happens during
address translation, before the core's bus request exists, so the wrapper's bus
is idle whenever `walker_req` is high. No new SDRAM or DDR3 port, no arbiter --
`sdram_ctrl`'s slot arbiter already uses all eight types (REFRESH, CHIP,
CPU_READCACHE, CPU_WRITECACHE, HOST, RTG, AUDIO, IDLE = 7), so a dedicated port
means widening it, and that is the module every other master depends on.

No CDC either: `ap040_walker_cdc.v` exists for hosts whose wrapper is in
another clock domain (the MiSTer tree runs `cpu_wrapper` on clk_sys and memory
on clk_114). Ours is already clk_114 throughout. **Do not instantiate it.**

Everything on the RAM port derives from `cpuaddr`, so the mux is small. In
`rtl/soc/TG68K.vhd`:

  * `cpuaddr` (:548) -- currently `addrtg68 WHEN cpu_i(1) = '1' ELSE ...`;
    take `wk_addr` when the walker owns the bus. `sel_ram`, `sel_ddr`,
    `ramaddr` (:539-545), `ramcs` (:469) and `cpustate` (:497) then follow with
    no further change.
  * `state` -- "10" for a walker read, "11" for a write, so `cpustate[1:0]`
    is right.
  * `uds_in` / `lds_in` -- both asserted; descriptors are aligned longwords.
  * `w_datatg68` -- the write half on a U/M-bit update.
  * capture `fromram` / `fromddr` into `wk_data`; hold `walker_ack` as a LEVEL
    until `walker_req` drops (`ap040_mmu.v`: `walk_ack = w_active && w_issued
    && walker_ack && !walker_berr`, and the walk FSM advances under `ce`, so a
    one-cycle pulse can be missed).

A longword descriptor is **two 16-bit sub-cycles** at A and A+2. Do not try to
use the paired-transfer path: `longword_pair` is 0 for the AP040 precisely
because the core issues independent word cycles (see the Log -- that mismatch
caused both the $F800D6 hang and the AllocMem failure, on the two ports).

**The hazard that will bite: clock-enable deadlock.** The core consumes
`walker_ack` only under its `ce`, and `ce` is `clkena_in`, which this wrapper
gates on bus state (:820, the `state = "01"` term). Mux `state` away from idle
during a walk and `clkena` can stop, so the core never consumes the ack and the
machine hangs -- with no fault, which looks like the old AllocMem spin and will
waste hours. apolkosnik hit this: the `ap040x3` branch note says gating the
core on the bus wait "froze the whole stack for the length of every external
transaction", and that branch moves to a free-running `ce_core = 1'b1` with
only the bus16 adapter still gated. **Keep `clkena` alive while the walker owns
the bus** (add a `wk_active` term), and assert in the bench that the core sees
at least one enable per walk.

**Reference implementation**, for the address translation and the error cases:
`apol/ap040` (and x3) in the MiSTer tree, `rtl/cpu_wrapper.v` around lines
449-490 -- `walker_sel_z3ram0/1`, `walker_sel_z2ram`, `walker_sel_dd`,
`walker_sel_rtg`, `walker_ramaddr`, and especially `walker_mem_bad`: a
misaligned descriptor address, or a high address that decodes as nothing, must
raise `walker_berr` rather than hang. That is what turns a corrupt table into a
Guru instead of the fatal halt we get today. Our equivalent of `walker_mem_bad`
is `(|wk_addr(1 downto 0)) OR sel_undecoded`.

| # | Step | Exit criterion |
|---|---|---|
| B0 | Close the bench gap FIRST. `sim/ddr3_cpu`'s RAM model reads `cpustate[2:0]` and ignores bit 6, which is why the `cpustate(6)` bug reached hardware. Make the model honour the 32-bit-write bit, and assert it is never set while the AP040 is the core. | the bench fails on a reverted `cpustate(6)` fix |
| B1 | Requester in the wrapper, multiplexed into the kernel-side bus signals as above; `walker_berr` from misalignment or `sel_undecoded`; `clkena` kept alive under `wk_active`. | lint clean, `./run.sh --ap040` and `--ap040 --chipbus` still PASS |
| B2 | **Bench the router.** `sim/ddr3_cpu` program builds a two-level table with the root in chip RAM and leaves in DDR3 fast RAM, so both ports are exercised; loads URP/SRP/TC with `movec`; enables translation; touches a mapped page, a page with M clear (forces a descriptor write-back), an unmapped page (expects an access-error frame), and a misaligned root (expects `walker_berr`, not a hang). `lib/AP68040/tb` `t_mmu` already proves the MMU itself -- this proves OUR router. Add a watchdog that fails on no progress, so a `clkena` deadlock reports as a failure rather than a timeout. | PASS, and a mutant with `walker_ack` tied low FAILS |
| B3 | Hardware: boot with SetPatch. **DONE** -- the library was never renamed; the walker landed before the free experiment was needed. | **Workbench with the MMU on** -- met |
| B4 | Then MuFastROM (`MuFastROM ON`, MMULib) and `MuScan` to confirm Kickstart runs from fast RAM. **NEXT** | MuScan shows ROM in fast RAM |

**Debug kit that already exists**, if B3 misbehaves: `tools/vivado/build_ap040.tcl`
builds with `CPU040_DEBUG_ILA=1`; the CPU ILA carries `dbg_pc`, `tg68_adr`,
`tg68_dat_in`, `tg68_dat_out`, `bus_ctl` = {as,rw,uds,lds}, `dbg_flags` =
{fault,in_exc,halted,busy}, `dbg_ir`, 4096 deep, storage-qualified on `!as`.
`tools/vivado/ila_bus_decode.py <csv> --longs --pc` turns a capture into
longword bus transfers; `tools/kick_dis.py <rom> <start> <end>` disassembles
Kickstart at Amiga addresses. The board runs **46.143**
(`~/work/amiga/helloworld/kickstart/kick.a1200.46.143.rom`, md5
79bfe8876cd5abe397c50f60ea4306b9) -- verify any ROM by opcode fingerprint
against a capture before trusting a disassembly, offsets move between versions.

**Two lessons from stage A, worth the time they cost.** Both bugs were the same
bug on different ports -- the wrapper answering one request with two words while
the adapter issues two independent cycles -- and neither was findable by
reasoning: the winning move both times was a bus capture, and the second time
it was what the trace did NOT contain (ExecBase reads absent from the chipset
bus) that located it. And both slipped through because the bench did not model
the path. If stage B stalls, capture before theorising, and check what the
bench is not modelling.

### Stage C — FPU on hardware (S)

FPU is compiled in from stage A (fits: ≈ 40 k). This stage is verification
only: a program that uses FMOVE/FADD/FMUL/FDIV directly and one that hits an
unimplemented instruction (FSIN) so the FPSP trap path through
`68040.library` is exercised. `lib/AP68040/tb` `t_fpu` covers the core; this
covers the library. Record whether `AP040_HAS_FPU=0` is ever wanted as a
smaller build; if not, drop the parameter from the top level.

### Stage D — REVISED 2026-09-08 evening, after measuring and after reading apol/ap040x3

Two things changed the plan, and a cold session should read this section before
the table below it.

**1. What the machine actually spends its time on.** Measured with the CPU ILA
while a demo ran (`tools/vivado/ila_cpu040_capture.tcl ... now`, then count
`cpustate` bit 5, which IS `clkena`), 144 us of clk_114:

| | |
|---|---|
| core advanced | 14.4 % of clocks (the 4-phase enable ceiling is 25 %) |
| bus request pending | 44.8 % |
| stalled on memory | 44.2 % |
| instruction rate | 2.78 per us, i.e. ~5.2 clk_114 or ~1.3 enables per instruction |

So **perfect memory would be worth about x1.8, not x5**. SysInfo says 0.19x an
A4000 68040/25; roughly half that gap is memory and half is the enable rate and
the sequencer. Tight loops that miss stall 62 %; straight-line code 23 %. And
note the core is not wildly inefficient per enable -- 1.3 enables per
instruction -- so the enable RATE is the bigger structural limit, which is D1
and D3 territory, not D2.

**2. Most of stage D already exists upstream, in apol/ap040x3.** Their
`rtl/ap040/` is ahead of our `lib/AP68040` submodule (0e76761): 407 changed
lines in `ap040_cache.v` alone, plus a file we do not have at all,
`ap040_fill_cdc.v`. Each feature is behind a parameter with an A/B reference:

* `FILL_CHANNEL` (their plan X3.4) -- a miss takes the whole line as one
  payload over `fill_req`/`fill_addr`/`fill_data`/`fill_ack`/`fill_err`,
  instead of four longword transactions through the adapter. **This is D2**,
  already built, with a better interface than the `cache_*` stub we have.
* `POST_STORES` (X3.3) -- a store is acknowledged one cycle after acceptance
  and drains from a latched copy, so the core stops waiting on every write.
* Store-hit update in place (X3.2) -- a store that hits a resident line
  updates it rather than clearing the row, as a 68040 does in write-through.
* A `C_IDLE` bypass fix, measured upstream at **x1.41 with a zero-latency bus
  and x2.27 with a latent one** on loop-heavy code. Ours is very much latent.

Their wrapper also enables the core as `~cpu_req | bus_complete | bus_berr` --
every clock unless a bus request is outstanding -- on `clk_sys` 28.6875 MHz
single-cycle. That removes the cadence rounding which is most of our gap
between a 25 % ceiling and 14.4 % measured. It is NOT a straight copy: our core
is on clk_114 inside a multicycle island, and their timing closure says nothing
about ours.

**Revised order.** Do not hand-roll D2 against the old submodule.

1. **Bump `lib/AP68040` to the x3 core.** Contained: new files, new ports on
   the compat top, their own suite (`tb/run_tests.sh`) as the gate. Leave the
   wrapper NOT routing `fill_req`, so everything falls back to the adapter path
   and the only behavioural difference is the cache fix -- which alone may beat
   D2. Build, then re-measure with SysInfo and the ILA stall capture.
2. **Route the fill channel** to `ddr3_fastram`. Their `fill_ena_zorro` /
   `fill_ena_chip` pick which memories may serve a line. Coherency is a
   non-issue on the DDR3 board: `ddr3_fastram` already ties `snoop_act` to 0
   ("no chipset snooping here") because chipset DMA cannot reach Zorro-III
   space, and `cpu_cache_new` is write-through with a single master, so
   reading a line around it cannot return stale data.
3. **Then the enable scheme**, which subsumes D1.

**D1 is written but does not boot, and the bisect is done.** Five enable phases
(2,5,8,11,14) plus the latched chipset release: the machine hangs in
expansion.library's ConfigDev walk, reading `$00000019` from a board whose
`cd_BoardAddr` is nil. `chipset_done` is NOT the culprit -- with it kept and
the cadence reverted to four phases the same board boots (ILA: CopyMem, then
ROM, then 4096 samples at `$F815D2`, the dispatcher idle). Confirmed on both a
false-constraint build (WNS -1.141, 1236 endpoints) and a corrected one
(WNS -0.391, 17), so it is logic, not timing. The untested hypothesis is
`slower`: `ramcs` opens three cycles after an enable and `slower` reloads on
every enable, so at a three-cycle spacing the select opens on the very cycle
the next enable can release the CPU, breaking the "address stable one cycle
before `cpustate[2]` goes low" contract both controllers state in their
headers. Try reloading `"0011"` instead of `"0111"`. **Teach `sim/ddr3_cpu` to
enforce that contract first** -- it models the SDRAM side itself and passed all
three broken variants happily.

### Stage D — the original table (M each, independent, in this order)

| # | Step | Depends on | Exit criterion |
|---|---|---|---|
| D1 | `clkena` every 3 (`enaWRreg` on 5 of 16 phases) + `-setup -start 3 / -hold -start 2` on the kernel island — [performance.md](performance.md) option 1a. **DONE in RTL and simulation 2026-09-08, bitstream `build/stage_ap040_d1`, not yet run on hardware.** Timing closes: WNS −0.544 ns with the known SDRAM read capture as the only violated path. Measured −19.2 % on the pattern program, −18.5 % on the MMU one, short of +25–30 % because the benchmark is half DDR3 latency — which is D2. See the note below for the prerequisite option 1a omits. | A6 | timing closes in the full design; A7 benchmark ≈ +25–30 % |
| D2 | Line port to the DDR3 — see the survey below, written 2026-09-08 before starting it. | A6 | a line fill = one CDC round trip instead of eight sub-cycles |
| D3 | Sibling 37.8 MHz clock for the CPU island, `clkena_in` = handshake only, multicycles removed — option 1b. | D1 | `report_exceptions` shows none on the core |

**D1 has a prerequisite option 1a does not mention.** The five enable phases
must be spaced 3-3-3-3-4, and `ena7RDreg`/`ena7WRreg` sit on phases 6 and 14.
Five gaps of at least 3 summing to 16 are four 3s and one 4, and no partial
sum of those spans the eight phases from 6 to 14 -- so the enable **cannot**
land on both. It has to keep 14 (which it does: 2, 5, 8, 11, 14) and lose 6.

That matters because the wrapper's release term was
`(ena7RDreg = '1' AND clkena_e = '1')`, which only ever released the CPU
because `clkena_in` happened to pulse on phase 6 as well. Lose the
coincidence and every chipset access hangs -- silently, with no fault, which
is the same failure signature as the walker deadlock. So D1 also latches the
chipset answer (`chipset_ready` -> `chipset_done` in `TG68K.vhd`) and holds it
until the CPU's next enable, and the end-of-cycle test moves out of the
`ena7RDreg` branch for the same reason. A side effect worth having: the
release now lands 2-3 cycles after the answer instead of waiting a full 7 MHz
round.

**D2, second survey (2026-09-08 evening), after SysInfo said 0.19x an A4000
68040/25.** The first survey below assumed the win was in the DDR3 transfer.
It is not. Reading the three interfaces properly:

* `cpu_cache_new` **already fetches the whole 16-byte line on the first miss**
  (`cpu_cacheline_lo/hi[0:7]`, `cpu_cacheline_valid`) and serves the other
  seven words as hits. So a 040 line fill costs **one** DDR3 round trip, not
  eight.
* What it costs eight of is **CPU-side handshakes**. Each word pays `slower`'s
  three-cycle chip-select setup, the rounding up to the next clock enable, and
  the bus16 adapter's two sub-cycles per longword. That -- not memory latency
  -- is the term to remove.
* The stub port on the compat top is shaped for exactly that and is **not** a
  128-bit line port: `cache_data` is `[15:0]`, with `cache_burst`,
  `cache_burst_len[2:0]` and `cache_ramaddr[28:1]`. One address phase, then
  words streamed on `cache_ack`.

So D2 is: on a fill, raise the burst request once, and stream the eight words
back at one per clock from `cpu_cache_new`'s line buffer (or straight from
`ddr3_cdc`'s 128-bit response register), instead of eight independent selects.
The DDR3 side needs no widening; it is already 16 bytes wide and idle between
those handshakes.

Coherency note before bypassing anything: `cpu_cache_new` is write-through and
snoops chipset DMA writes into board 3, so reading a line around it is safe
only while writes keep going through it. Read `findings/ddr3/design.md` before
cutting it out of the read path.

**First survey, kept because the file locations are still right.** What the checkout actually does today, so
the next session does not have to find it again:

* There is **no line port**. `cache_req`, `cache_addr`, `cache_burst`,
  `cache_burst_len` and `cache_ramaddr` are tied to zero inside
  `ap040_tg68k_compat.v:433-438` ("external cache/burst interface idle until
  milestone G") and nothing drives them. The wrapper leaves them open.
* A cache fill is **four longword beats on the ordinary bus**:
  `ap040_cache.v:302-306` -- `m_req = fill_active`, `m_size = AP040_SZ_L`,
  `m_addr = {r_addr[31:4], r_beat, 2'b00}`. `ap040_bus16_adapter` then splits
  each longword into two word cycles, which is where the eight sub-cycles per
  line come from.
* So D2 is: recognise `fill_active` in the compat top, issue **one** 16-byte
  request, and answer the four beats out of a 128-bit buffer. That is new
  logic inside the core's top level (a small FSM plus the buffer), not
  plumbing -- and `lib/AP68040` is a **git submodule** (0e76761), so it needs
  its own commit and a pointer bump here.
* The SoC side is ready: `ddr3_fastram.v` already speaks 16-byte lines to the
  island through `ddr3_cdc.v` (`cdc_req`/`cdc_rd`/`cdc_be`/`cdc_addr`, with
  `dbg_cdc_ready`/`req`/`done` brought out for an ILA). The open question is
  whether the line request bypasses `cpu_cache_new` or arbitrates with it;
  bypassing is the point of the exercise, but `cpu_cache_new` is also what
  snoops chipset writes into board 3, so read the coherency argument in
  `findings/ddr3/design.md` before cutting it out.
* Two things that must not be forgotten: the **walker borrows the same bus**
  (stage B), so a line fill and a descriptor read have to be ordered rather
  than allowed to interleave; and the bench models the SDRAM side itself, so
  a line path needs a model in `sim/ddr3_cpu` before it can be trusted -- see
  what happened in D1 when the bench and the RTL disagreed about the enable
  cadence.

### Stage E — both cores in one bitstream, OSD-selected (M, bounded experiment)

Both kernels under the wrapper's `generate`, selected by `cpu_config[4]`
latched at reset (the dual-build rows of "OSD and firmware": bit 4 = AP040,
else TG68K in the 68000/010/020 mode bits 1:0 select); the unselected core
held in reset with `clkena` low; the kernel-side outputs muxed (one LUT
level on paths that have a 3-cycle budget); two kernel multicycle sets in
`cpu.xdc`; `CORE_CAPS` bit 1 set so the menu offers the choice. Then the
real question: place and route at ≈ 71 %.

Accept if WNS ≥ 0 on the CPU island with the SDRAM read path no worse than
today's −0.544 ns. Otherwise stop, keep the two bitstreams, and record the
numbers. Time-box: two build iterations, no re-architecting to make it fit.

### Stage F — NetBSD/amiga (optional, M)

Walker port from B, the restart-model caveat above. Not on the AmigaOS path.

## Verification, collected

* `lib/AP68040/tb/run_tests.sh` — core alone, with the RAM override (0.2).
* `sim/ddr3_cpu` with `CPU_CORE=AP040` — wrapper + DDR3 chain + chipset model;
  extended in A5 and B2. Sequential runs only.
* `sim/autoconfig` — unchanged, guards the Zorro side.
* Hardware, per stage, always by reprogramming; `ShowConfig`, `avail`, ATK on
  both boards, then the stage's own test. The WinUAE `cputest` corpus is a
  native Amiga program; running it on the board after B3 is the strongest
  integration check available and costs nothing to set up.

## Log

**2026-09-07, stages 0 and A (RTL).** Core vendored and pinned; RAM primitive
replaced and the core's own suite run against it; wrapper generate, snoop
path and constraints written; the AP68040 ran the full `sim/ddr3_cpu` program
through this project's wrapper and DDR3 chain on the first attempt.

Two bugs, both mine, both the same shape -- something moved and a downstream
reference still named the old place, and neither is visible to any bench:

* `z3ram3_base` was declared and consumed but never driven between `minimig`
  and `TG68K`; an undriven wire synthesises to zero, the board-3 decode then
  matched `$00`, and the machine black-screened as soon as the OS configured
  that board.  Synthesis warned about nothing.  (That one is the DDR3 work,
  fixed under `findings/ddr3/`, but it is the same lesson.)
* Making the kernel a generate renamed it: Vivado calls a VHDL if-generate
  instance `<label>.<instance>`, so every cell moved from
  `tg68k/pf68K_Kernel_inst/...` to `tg68k/g_tg68k.pf68K_Kernel_inst/...`.
  `cpu.xdc` and `wizard.xdc` both still named the old path, so twelve
  multicycle exceptions were dropped and a bitstream was written with no CPU
  timing exceptions at all.

Also: an XDC file is not general Tcl.  `foreach` is rejected outright
(Designutils 20-1281), which silently produced empty filter strings and cost
a build before the log said so.

**Rule for the rest of this work:** after moving or renaming anything in the
hierarchy, query the netlist for the new path and check the cell counts
before trusting a constraint or spending a build on it.  `read_xdc` against an
open run takes a minute and would have caught both.

**2026-09-07, first AP040 bitstream.** It fits and the CPU island closes:
43,750 LUTs (69 %, ILA included) and `clk_114` at +0.290 ns with no failing
endpoint.  Getting there took one more fix of the same family.

The first build failed `clk_114` at −0.436 ns on 18 endpoints -- all of them
from a *single* register, and all wrapper-to-kernel while kernel-to-kernel was
clean, so the multicycle island was working and the path was simply new.  It
was new because of the snoop: taking `cache_snoop_addr` as a raw tap on
`sdram_ctrl`'s `chipAddr` closed a loop from the CPU wrapper's address
register, out through `minimig`, through `sdram_ctrl` combinationally, and
back into the 040's cache tag RAM across the die -- 14 logic levels.
Registering the exported pair fixed it outright.

Worth recording why that fix and not a constraint: a wrapper-to-kernel
multicycle would have been the easy answer and would also have covered
`datatg68_c`, which is registered every cycle and feeds the core's `data_in`.
Relaxing that would have been wrong in the way `findings/constraints/fix-04`
is about.

**Correction, same day.**  I reported block RAM at 82 % and called it the
binding constraint.  That was the *debug* bitstream: the fast-RAM ILA is 24
probes about 461 bits wide by 4096 deep, roughly 1.9 Mbit, and it accounts for
almost all of it.  The shipping build, no ILA, measures:

| | LUTs | of 63,400 | BRAM tiles | `clk_114` |
|---|---|---|---|---|
| AP68040, MMU + FPU + caches, no ILA | **39,750** | **62.7 %** | **59.5 (44 %)** | **+0.694 ns, 0 failing** |
| the same with both ILAs | 43,750 | 69 % | 111 (82 %) | +0.290 ns, 0 failing |

So the estimate at the top of this document (≈ 64 %) was right, block RAM is
not close to binding, and stage E's dual-core question stays where the plan
first put it: LUTs, at roughly 70 %, with BRAM around 44 %.  Do not plan
against the 82 % figure.

**And the SDRAM path is not worse either.**  The debug bitstream measured
−0.643 ns against the TG68K's −0.544 and I named it as a risk; the shipping
build measures **−0.544**, the same number.  That degradation was the ILA's
congestion too.  Both of the caveats raised against the first AP040 bitstream
were artifacts of the debug cores in it, which is an argument for measuring
the configuration you intend to ship before drawing conclusions from one you
do not.

The sign-off rule ("SDRAM read path no worse than today") is therefore met,
and the CPU island has more margin with the 040 (+0.694 ns) than with the
TG68K (+0.067 ns) -- the multicycle budget is generous for both, and the 040
is simply placed better here.

**2026-09-07, first hardware run.**  Yellow Kickstart screen, which means an
exception before the trap handlers exist.  The fault ILA (stage A's
`CPU040_DEBUG_ILA`) named it without guesswork: the core reset cleanly, read
SSP and PC, entered Kickstart at $00F800D2, fetched D2 and D4, and hung on D6
with a request outstanding and `clkena` never pulsing.

The addresses were the diagnosis.  $F800D4 is the first longword-aligned
fetch, and the wrapper answers those with its AGA paired-word path: ONE request
served with TWO words, the second through `data_read2`, no second address from
the CPU.  The TG68K kernel expects that; `ap040_bus16_adapter` documents the
opposite contract -- one request, one completion per 16-bit sub-cycle, longs
split into two separate cycles.  So the wrapper delivered $F800D6 unasked and
the two fell permanently out of step.  Gated on `longword_pair` now: the
kernel's `longword` for the TG68K, constant 0 for the AP040.  The SDRAM and
DDR3 sides keep using `longword`, because serving two sub-cycles from one
cache line is exactly how the 040 drives them.

**Where it stands after that fix.**  The 040 executes Kickstart -- real
instructions (MOVE.L, RTS, BRA, BNE), condition codes changing, no exception
at all -- roughly 1,500 bytes further in.  It then spins forever at
$F8068E-$F806A2, repeatedly touching $3E8, with SR = 2700, so it is not
waiting on an interrupt.  Screen black, no disk activity.

That is a NEW failure, not the old one moved.

**What the loop actually is.**  The ILA snapshot was read wrongly at first --
as a stalled bus cycle, then as the exception-vector fill.  It is neither.  All
1024 samples hold a nine-PC cycle, and the ROM names it.  The ROM had to be
identified first: `tools/kick_dis.py` takes Amiga addresses, and an opcode
fingerprint straight off the ILA (`$F80690`=`2002`, `$F80692`=`4eae`,
`$F80698`=`2d40`, `$F8069A`=`6608`, `$F8069C`=`223c`, `$F806A2`=`60ec`) matches
exactly one image on this machine, `kick.a1200.46.143.rom`, at exactly
`$F8068E`.  Match the ROM by content, never by filename: five other 3.x images
here disassemble to plausible-looking nonsense at that address.  The fingerprint
also shows `dbg_pc` runs one instruction ahead of `dbg_ir`.

```asm
00F805D8  move.l  #$604, d0        ; 1540 bytes
00F805DE  move.l  #$10001, d1      ; MEMF_CLEAR | MEMF_PUBLIC
00F805E4  jsr     -$c6(a6)         ; AllocMem -- SUCCEEDS
00F805EA  beq.w   $f806bc          ; not taken, or we would never reach the loop
...
00F80686  rol.l   #$8, d2          ; d2 = $1800 = 6144
00F80688  move.l  #$10004, d1      ; MEMF_CLEAR | MEMF_FAST
00F8068E  move.l  d2, d0
00F80690  jsr     -$c6(a6)         ; AllocMem -- returns 0
00F80698  bne.b   $f806a2
00F8069A  move.l  #$50000, d1      ; MEMF_CLEAR | MEMF_REVERSE, any type
00F806A0  bra.b   $f8068e          ; forever
```

Exec is allocating its supervisor stack and cannot.  Three things follow, and
they rule out most of what looked likely before:

* The 040 is executing correctly.  It runs a `jsr`, returns from it, and sets
  and clears Z.  The `$3E8`/`$3EA` writes are the return-address push -- so
  `$3E8` is the supervisor stack (SSP near `$400`), not the vector table, and
  the 040 is splitting the longword into two word cycles exactly as intended.
* Longword chip RAM access is not broken outright.  A corrupted push would
  send the matching `rts` somewhere random; the loop is stable instead.
* **The first AllocMem succeeded.**  Memory exists and the allocator works
  once.  A 6 kB request then fails even asking for any memory type at all.
  That is the free list being wrong after the first allocation -- which was
  `MEMF_CLEAR`, so it wrote 1540 bytes of zeros -- not memory being absent.

**The untested path.**  `sim/ddr3_cpu` tied `turbochipram` to 1, so
`sel_chipram` makes `sel_ram`, `chipset_cycle` is 0, and every chip access
leaves on the SDRAM-side port.  The AP040 run therefore never issued a single
chipset-bus cycle.  The user has Turbo off, which is the opposite: all chip RAM
goes over the 7 MHz chipset bus -- the path `longword_pair` changes.  The green
AP040 simulation and the failing hardware were never exercising the same logic.
`./run.sh --ap040 --chipbus` closes that gap; `--chipbus` alone is the TG68K
control that must still pass.

**Fixed, and what it cost to find.**  `cpustate(6)` still carried the raw
`longword` on the SDRAM/DDR3 port.  `sdram_ctrl` makes `cpuLongword` of it and
`cpu_cache_new` answers a set bit by acking the high word at once and entering
`CPU_SM_WAIT_LOWORD`, expecting the low word as a continuation of the SAME
request -- the TG68K's paired-write protocol.  The AP040 issues two independent
word cycles, so the controller banked half a longword.  The $F800D6 hang again,
on the port `longword_pair` did not reach.

Two hypotheses were wrong before this one, and both were refuted by evidence
rather than argument: the list-relocation instructions (phase 7 passes) and the
three wrapper divergences from the reference integration (they are TC64-fork
lineage, predating the 040).  What actually found it was the bus trace, and
specifically what the trace did NOT contain -- the ExecBase reads were absent
from the chipset bus while the stack pushes were there, which placed ExecBase
in slow/fast RAM and pointed at the other port.  `sim/ddr3_cpu` is blind to
this: its RAM model reads `cpustate[2:0]` and ignores bit 6.  **Close that gap
before trusting the bench on the RAM port again.**

**Where it stands now.**  Exec runs.  ExecBase is published at $4, the memory
list is intact, allocation works and the dispatcher reaches its idle loop
($F815BA-$F815D2, `STOP #$2000`).  Interrupts arrive -- the machine wakes from
the STOP and runs on into fast RAM.  It then fatal-halts:

    dbg_pc = $400B53FE   dbg_ir = 4E7B (MOVEC)   dbg_flags = E   tg68_adr = $0000000A

`dbg_flags` is {fault, in_exc, halted, busy}, and $0000000A is the second word
of the longword at $8 -- vector 2, the access fault.  So MOVEC enabled the MMU,
the next access wanted a table walk, the tied-off walker never acked, the
watchdog made an access fault of it and the core halted on the vector fetch.

That is **stage B, exactly as predicted** ("a walk that never acks becomes a
bus error via the watchdog").  It is the next piece of work, not a new bug.

**2026-09-08, stage D task 1 -- the x3 overlay.**  `lib/AP68040` carries the
`apol/ap040x3` core: `ap040_cache.v`, `ap040_core.v`, `ap040_mmu.v`,
`ap040_tg68k_compat.v` and the new `ap040_fill_cdc.v`, copied verbatim from
`Minimig-AGA_MiSTer` branch `apol/ap040x3` commit 8665741, directory
`rtl/ap040`, on a local branch `x3-overlay`.  Three benches came with them --
`tb_ap040_program.v`, `tb_ap040_cache_snoop.v`, `asm/t_exceptions.s` -- because
without them the suite does not measure this core: test 136 aimed one fixed
interrupt delay at the inside of a `MOVE to SR`, which only landed there while
the core froze during bus waits, so it fails on a *working* x3 core.  The
wrapper declares the `fill_*` port group and ties both enables low, so
`fill_ok` is a constant 0 and every miss still takes the adapter path; the
channel is compiled in (`AP040_FILL_CHANNEL => 1`) only to keep the port set
stable for the task that routes it.  `AP040_POST_STORES` is a new TG68K
generic, default 1.

**And one line that is NOT verbatim.**  x3's A2b-0 also frees the core, MMU and
cache from the clock enable (`ce_core = 1'b1`).  That reasoning holds where
`clkena_in` is a pure bus wait, which is what MiSTer's `cpu_wrapper.v` supplies
("`~cpu_req | bus_complete | bus_berr`", high on every idle cycle).  It is not
what `TG68K.vhd` supplies: this wrapper ANDs the bus wait with `enaWRreg`, so
the enable is high on 5 of every 16 `clk_114` phases.  `ap040_bus16_adapter`
clears `mem_ack` *inside* `else if (clkena_in)`, so under a duty-cycled enable
the acknowledge is not the one-clock pulse its header promises -- it is held
for the whole phase gap.  A gated cache samples it once; a free-running one
reads the stale level as the acknowledge of the NEXT request.  `--ap040` died
at phase 0 on the first run.  Reproduced in two minutes rather than
twenty-five by gating `tb_ap040_program`'s own `clkena_in` to those five
phases: free-running fails `t_integer` test 67 and runs away to
`pc=ffff6708`; re-gated passes the whole suite.  So `ce_core` is `clkena_in`
here, as a second commit so the verbatim state stays in history.

**What that costs, and the lesson.**  On the same gated bench the free-running
core needs **2.4x fewer cycles** than the re-gated one (t_integer 12,342 /
13,488 / 12,220 against 30,722 / 32,210 / 30,572).  A2b-0 is the prize in stage
D, not a side effect of it -- and it needs two things this task did not do: a
one-pulse-per-completion acknowledge (a three-line rising-edge detector in the
compat top was tested and works, on the gated *and* the ungated bench, but the
honest place for it is `ap040_bus16_adapter` upstream), and a rewrite of
`cpu.xdc`, whose whole kernel island rests on "every kernel register holds its
value for at least 3 `clk_114` cycles".  With the re-gating that premise is
true again and `cpu.xdc` needs no edit today; `st_snooped` is the one new
free-running register and the existing `*_snooped_reg*` wildcard already
excludes it.

The lesson is the one this bench keeps teaching: a core's own suite cannot see
its host.  Eleven legs passed on the verbatim overlay because they drive
`clkena_in` as a pure bus wait.  The reverse also holds -- a naively gated
`tb_ap040_program` is not a valid harness for the interrupt and walker legs
either: the *stock* 0e76761 core fails it at `exceptions` 141 and at `mmu`.
It is sound only as a discriminator for the desync itself.

**Gates.**  Core suite 11/11 with `rtl/cpu040/dpram.v`.  `sim/ddr3_cpu`:
`--ap040`, `--ap040 --chipbus` and `--mmu` PASS, `--lwmutant` and
`--mmumutant` fail as required, plain `./run.sh` (TG68K) PASS.  Phase
timestamps moved everywhere, so the change reaches the bench: measured from
CPU release, `--mmu` phase 6 634.25 -> 615.44 us (-2.97 %) and phase 8
652.27 -> 631.12 us (-3.24 %); `--ap040` phase 8 1939.83 -> 1870.30 us
(-3.58 %), with the instruction-bound phase 1->2 gap -11.07 %; `--chipbus`
phase 8 855.71 -> 847.24 us (-0.99 %), which is what a 7 MHz-bus-bound run
should show.  No bitstream in this task.

**2026-09-08, stage D task 2 -- Vivado build and sign-off of the x3-core
state.**  Two bitstreams from superproject commit 4b033dc (no RTL touched):
`build/stage_ap040_x3` (ila = 0, the shipping config, signed off) and
`build/stage_ap040_x3_ila` (ila = 1, the CPU ILA for the stall capture --
numbers reported, not signed off).  Build times: ila = 0 took 20 min 28 s;
ila = 1 took 26 min 46 s.

Two things worth a cold reader's attention.  First, `build/stage_ap040_ddr3only`
-- "the current board bitstream" this task compares against -- turns out to
have been built with **ila = 1** itself (its own build log's `-tclargs
build/stage_ap040_ddr3only 1`, and it carries a `.ltx`), not ila = 0 as this
task's brief assumed.  `build_ap040.tcl`'s single `ila` argument gates both
`DDR3_FASTRAM_ILA` and `CPU040_DEBUG_ILA`, and forces `PHYS_OPT_DESIGN` /
`POST_ROUTE_PHYS_OPT_DESIGN` on unconditionally (for every build, ila or not)
specifically to claw back the ILA's own congestion cost.  So the ila = 0 x3
build being signed off here carries strictly less debug logic than the
baseline it beat -- a fair "no regression" test, but not the like-for-like
congestion match the brief pictured.

Second, `ap040_fill_cdc.v` -- new in the x3 overlay -- does **not** enter the
Vivado project via `build_ap040.tcl`: that script neither sources
`tools/vivado/build.tcl` (whose add_src loop is the only place that lists the
AP68040 core files) nor adds AP68040 sources itself, and `project_1.xpr`
currently carries the other 10 AP68040 files but not this one.  Harmless for
this task -- nothing in the tree instantiates `ap040_fill_cdc` yet (task 1
left the fill channel "declared but not routed") -- but D task 3 (routing the
fill channel) needs a `build.tcl` run, or a `build_ap040.tcl` fix, before that
file can be synthesized at all.

Sign-off, ila = 0 vs `build/stage_ap040_ddr3only`: `clk_114` WNS improved
(−0.347 ns vs −0.588 ns) with one extra failing endpoint --
`g_cache.cache/st_snooped_reg`, −0.262 ns -- which is `st_snooped`, a
free-running register by the x3 source's own comment
(`ap040_cache.v`: "set free-running -- the snoop is -- and consumed/cleared
in the ce domain", same sentence covering `look_snooped`) and already excluded
from the kernel multicycle set by `cpu.xdc`'s pre-existing `*_snooped_reg*`
wildcard (`exceptions.rpt` confirms the `-start 3`/`-hold 2` kernel set's
filter carries that exclusion and both `cycles=3(start)`/`cycles=2(start)`
lines resolve without "Invalid endpoint"). Not a constraint gap. SDRAM read
path also improved (−0.510 ns vs −0.602 ns, same 16 failing endpoints). DDR3
CDC `set_max_delay -datapath_only` exceptions unchanged, byte-identical.
Kernel multicycle set populated, unchanged filter text. **PASS.**  ila = 1
numbers reported for the stall capture but not signed off (ILA congestion is
known to cost ~0.1-0.4 ns): actual cost is bigger than that guess -- `clk_114`
WNS −0.753 ns (vs the ila=1 baseline's −0.588 ns, i.e. 0.165 ns worse) with
**210** failing endpoints on `clk_114` (baseline 1, x3 ila=0 build 2), worst
path the same `atc_ram -> st_snooped_reg` pair at 11 logic levels. SDRAM path
unaffected (−0.508 ns, 16 failing, same as ila=0's −0.510/16). Utilization
close to the ila=1 baseline (45,635 LUT / 29,266 FF / 125.5 BRAM / 28 DSP).
Not a sign-off requirement for this build, but a heads-up worth having before
using it for the stall capture: this bitstream's kernel timing is well
outside spec, well past a token ILA tax.

Full sign-off table, both build logs, and both `.xpr` source-list findings:
`.superpowers/sdd/plan-v2-with-ddr3/task-2-report.md`.

**2026-09-09, stage D task 3 -- the line-fill channel routed (D2).**
`rtl/soc/TG68K.vhd` gains a second bus master beside the stage-B walker: a
five-state router that takes the cache's `fill_req`, decodes the line address
with the wrapper's own `sel_*` logic, streams the eight words through the
existing memory port at the free `clk_114` rate and hands the cache the whole
line as one 128-bit payload.  No CDC (one clock domain here, as for the
walker), no new port on any controller, `fill_ena_zorro = 1` and
`fill_ena_chip = 0`.  The two masters are ordered, not interleaved: the walker
refuses to start while `fl_busy`, the fill refuses to start while `wk_req` is
high or the walker is out of `WK_IDLE`, and `ddr3_cpu_tb.sv` asserts they are
never both on the bus.

**The bench had never enabled the 040's internal caches, so it had never taken
a line fill at all.**  `ddr3_cpu_test.asm` wrote `CACR = 3` -- the 68020
encoding -- and `ap040_core.v:3352` masks MOVEC to CACR with `$80008000`, so
DE and IE stayed clear.  The first run of the new fill counters read "0 over
the channel, 0 down the adapter", which is what found it.  `run.sh` now passes
`-DCACRVAL`: `$80008003` for the AP68040, and the unchanged `3` for the
TG68K, whose control leg comes out with every phase timestamp bit-identical to
task 1's.  Both programs got it, so the MMU leg is the first cached traffic
this bench has ever run through a translated address.

The A/B is one line of the port map (`--nofill` ties `fill_ena_zorro` low and
must PASS; it is the reference, not a mutant).  82 of 87 line fills move to
the channel and the program ends **1.072 % earlier** -- phase 8 at 1867.70 us
against 1887.93 us from CPU release, with phases 3, 4, 5 and 7 all between
-1.0 and -1.15 % and the write-sweep phases 1 and 2, which take no fills, bit
for bit identical.  That is **28.0 `clk_114` cycles removed per line**, and
the MMU program agrees at 30.5 over its four fills.  The whole-program figure
is small only because this program sweeps memory once: 82 fills in 1.87 ms.
Turning the caches on at all costs +0.94 % here for the same reason, so the
routed channel is very slightly ahead of task 1's caches-off number overall.

Two things measured on the way that are worth carrying: the fill router's
`clkena` term keeps the CPU alive on `fl_ack`/`fl_err` but does **not**
suppress `clkena` during a fill, so a clock enable landing in the router's
gap cycle reloads `slower` and costs about three cycles of the next word's
select -- suppressing it is the next lever and is worth roughly another eight
cycles a line; and the fill's `busstate` is a data read, so an instruction
line now allocates in `cpu_cache_new`'s data half instead of its instruction
half (the fill port carries no I/D bit, upstream included).  Full contract,
design, seven-leg results and phase tables:
`.superpowers/sdd/plan-v2-with-ddr3/task-3-report.md`.

## Risks

| Risk | Shows as | Mitigation |
|---|---|---|
| Timing at 64 % (sole) / 71 % (dual) with 40-level paths and the DDR3 island | negative WNS on the kernel island | stage order: sole core first at 28 MHz; D1/D3 only after A6; E time-boxed |
| The `clkena` net: combinational, fanning out to 7,391 CE pins, single-cycle | negative WNS on enable → CE paths, or a replication storm | "Timing" item 1: watch it first at A6; `MAX_FANOUT`, then a registered enable tree re-benched in `sim/ddr3_cpu` |
| SDRAM read path degrades with the placement change | `clk_gen_sdram → clk_114` worse than −0.544 ns | CPU-island pblock away from the SDRAM bank; sign-off rule "no worse than today" |
| Firmware and core disagree about which CPUs exist | menu offers a choice the RTL ignores, or hides one it has | capability bytes behind a magic value on `OSD_CMD_VERSION`; old/new compatibility both ways in "OSD and firmware" |
| `dpram` read-during-write semantics changed by the Xilinx-inferable form | cache/ATC stale for one cycle on a same-row collision | `tb_ap040_cache_snoop.v` in 0.2 |
| Free-running watchdog inside the multicycle set | wrong constraint, TIMING-46 | exclusion in 0.3 |
| 040 CACR → `cpu_cache_ctrl` mapping | external cache never enabled, or never cleared | A5 checks the mapping explicitly |
| `longword` / split-cycle contract differs from TG68K's in a corner | AGA longword chip access or `longword_en` DDR3 write corrupts | A5 covers both paths |
| The SoC never raises `berr`; the 040 expects bus errors on empty space | software that probes memory by trapping sees $FFFF instead | same as today with the TG68K; B1 can add it for walker accesses |
| The open intermittent DDR3 Guru (`findings/ddr3`) | the 040's internal caches change the access pattern on board 3 — may hide it, may expose it | keep the `ddr_ready`-triggered capture on the list; ATK on board 3 in A6 |
| `68040.library` enables the MMU before stage B | boot dies at SetPatch | A6 boots without startup-sequence first, and the failure is the documented exit condition |

## Numbers to fill in as they are measured

| | Value | Where |
|---|---|---|
| AP68040 self-tests at 0e76761 with the RAM override | **all 11 pass**, cache_snoop included | 0.2, 2026-09-07 |
| `sim/ddr3_cpu` with CPU_CORE=AP040, smoke (PATBYTES=64) | **PASS + backdoor PASS**, first run | A5, 2026-09-07 |
| Program phase 6 reached, AP040 vs TG68K, same program | 287 us vs 141 us | A5 smoke; 16-bit split transfers, 040 internal caches off |
| `sim/ddr3_cpu --mmu` phase 6, x3 overlay vs 0e76761 | **615.44 us vs 634.25 us, −2.97 %** (from CPU release) | D task 1, 2026-09-08; core re-gated, fill channel not routed |
| `bench_loop` cycles per instruction, AP040 / TG68K | — | 0.2 / A7 |
| **`sim/ddr3_cpu` with the AP68040's internal caches ON at all** | the bench had never done it: the program wrote CACR = 3, the 68020 encoding, and `ap040_core.v:3352` masks MOVEC to CACR with `$80008000`, so DE and IE were both clear and the core took **zero** cache line fills.  Fixed with `-DCACRVAL`; the TG68K leg is bit-identical (every phase timestamp unchanged) | D task 3, 2026-09-09 |
| Cost of turning those caches on, pattern program | **+0.94 %** (phase 8, 1870.30 -> 1887.93 us from CPU release): this program sweeps memory once and has almost no reuse, so the cache mostly adds a lookup cycle and fetches eight words where one was wanted | D task 3 |
| **Line-fill channel routed (D2), A/B on one binary** (`--ap040` vs `--nofill`, same program, same caches, one line of the port map differing) | 82 of 87 line fills move from the bus16 adapter to the channel; **phase 8 1887.93 -> 1867.70 us, -1.072 %**, phases 3/4/5/7 all -1.0 to -1.15 %, phases 1-2 (the write sweep, no fills) bit-identical | D task 3 |
| Cost removed per Zorro line fill | **-20.23 us / 82 fills = 0.247 us = 28.0 `clk_114` cycles**; cross-checked on the MMU program, -1.075 us / 4 fills = 30.5 cycles | D task 3 |
| `sim/ddr3_cpu --mmu` **phase 6**, channel on vs off, both with caches on | **655.686 us vs 656.762 us, -0.164 %** (from CPU release).  Only four fills in that program, and they are taken through TRANSLATED addresses -- the first cached traffic this bench has ever run under the MMU | D task 3 |
| **Post-route, sole-core AP040 build with ILA** (2026-09-07) | | |
|   LUTs / FF / BRAM / DSP | **43,750 (69 %)** / 26,335 (21 %) / **111 (82 %)** / 28 | A6 |
|   `clk_114` (the CPU island) | **+0.290 ns, 0 failing endpoints** | A6 |
|   `clk_ddr100` | +1.774 ns, 0 failing | A6 |
|   `clk_gen_sdram` → `clk_114` (the known SDRAM read path) | **−0.643 ns, 16 failing** (TG68K build: −0.544) | A6 |
| **Post-route, x3-core build, ila = 0** (`build/stage_ap040_x3`, 2026-09-08, signed off against `build/stage_ap040_ddr3only`) | | |
|   LUTs / FF / BRAM / DSP | **40,127 (63 %)** / 19,316 (15 %) / **59.5 (44 %)** / 28 | D task 2 |
|   `clk_114` (the CPU island) | **−0.347 ns, 2 failing endpoints**: `mmu/atc_ram -> g_cache.cache/look_snooped_reg` (same pair as baseline's sole failure) and, new, `mmu/atc_ram -> g_cache.cache/st_snooped_reg` (−0.262 ns) — both free-running snoop registers already excluded from the kernel multicycle set by `cpu.xdc`'s `*_snooped_reg*` wildcard, not a constraint gap. Baseline: −0.588 ns, 1 endpoint. | D task 2 |
|   `clk_gen_sdram` → `clk_114` (the known SDRAM read path) | **−0.510 ns, 16 failing** (baseline: −0.602 ns, 16 failing) | D task 2 |
|   DDR3 CDC `set_max_delay -datapath_only` exceptions | unchanged from baseline, same two lines (`cdc/req_*_r_reg*`, `cdc/rdata_r_reg*`) | D task 2 |
|   Build wall clock | 20 min 28 s (23:18:23 → 23:38:51) | D task 2 |
| **Post-route, x3-core build, ila = 1** (`build/stage_ap040_x3_ila`, 2026-09-08, CPU ILA for the stall capture — not signed off, reported only) | | |
|   `clk_114` (the CPU island) | **−0.753 ns, 210 failing endpoints** (baseline: −0.588 ns, 1) | D task 2 |
|   `clk_gen_sdram` → `clk_114` | **−0.508 ns, 16 failing** (baseline: −0.602 ns, 16) | D task 2 |
|   Build wall clock | 26 min 46 s (23:43:06 → 00:09:52) | D task 2 |
| Post-route WNS on the `clkena` → CE paths | not the limit; no CE path in the top 40 violators | A6 |
| Fast-RAM benchmark, TG68K vs AP040, 28 MHz | — | A7 |
| Same after D1 (37.8 MHz) and D2 (line port) | D2 measured in simulation, above; hardware number still owed | D1 / D2 |
| Post-route LUTs and WNS, dual-core build | — | E |
