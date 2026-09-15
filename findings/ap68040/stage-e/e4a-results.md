# Stage E4a — results

Running record for [2026-09-15-e4a-plan.md](2026-09-15-e4a-plan.md), branch
`stage-e`. Each task appends one row from `tools/complexity_report.sh` and the
bench legs it ran.

## Complexity budget

"Code" counts exclude blank lines and full-line comments. "Posted-write paths"
is the live count (the 040's `POST_STORES`), plus the controller's tied-off
`cpu_wr_sync` option while it still exists.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| d3_stable | 2138 | 1029 | 727 | 591 | 1+wsync-option | 6 | 1 | 15 | dbg_phist dbg_snoop |
| stage-e e6b1b90 (baseline) | 2142 | 1031 | 727 | 591 | 1+wsync-option | 6 | 1 | 15 | dbg_phist dbg_rtg dbg_snoop |

The +4 wrapper lines between `d3_stable` and the baseline are the E0 `dbg_rtg`
probe (commit 4a0d2f6).

## `sim/sdram_coherency` reference (before any removal)

Taken at commit 85cac1b with `./run.sh fast sg7 +nobg +rounds=50` and
`./run.sh fast sg7 +rounds=50`. Both runs print `wrsync 0, cl_snoop 0`, the
shipping settings. E4a Tasks 2 (`cpu_wr_sync`) and 3 (`CL_SNOOP`) must
reproduce these counts exactly. Neither option is enabled here, so removing
them must not move a single number.

| check | `+nobg` | default (background load) |
|---|---|---|
| C2P (chipset write → CPU read) | 50 checked, 0 failed | 50 checked, 0 failed |
| P2C (CPU write → chipset read) | 50 checked, 0 failed | 50 checked, 4 failed (4 late, 0 lost) |
| C2P line buffer primed | 50 checked, 50 failed | 50 checked, 0 failed |
| C2P two-way cache primed | 50 checked, 0 failed | 50 checked, 0 failed |
| P2C longword write | 100 checked, 2 failed | 100 checked, 10 failed |
| cache-inhibited (Kickstart) read | 50 checked, 0 failed | 50 checked, 0 failed |
| read across a `cacheline_clr` pulse | 50 checked, 0 failed | 50 checked, 0 failed |
| background CPU reads | 0 | 3552 checked, 0 failed |
| **total** | **52 errors, 0 timeouts** | **14 errors, 0 timeouts** |

The failures are the two defects this bench found on unmodified RTL: the line
buffer that snoops never invalidate, and CPU writes that land late. They are
the reference, not a regression. Without `+rounds=50` the default 15-minute
`timeout` cut both legs off before their summary.

## Tasks

Baseline regression for these tasks: the fixed-bench rerun in
[e0-e1-results.md](e0-e1-results.md) ("Task 3 regression, rerun on the fixed
bench", commit f74ec3d). The morning table there was run on a bench with
undriven enables and is not a baseline.

### Task 1 — remove `dbg_snoop`

Removed: the `dbg_snoop` port and its TG68K-branch tie, the four counter
signals (`snp_in_cnt`, `snp_out_cnt`, `snp_out_s1/s2`), their two processes and
the assignment; the wire, port map and ILA probe in `minimig_virtual_top.v`;
`tools/vivado/ila_snoop_check.tcl`. Kept: `snp_stb_held`/`snp_addr_held`, the
snoop hold itself. `ila_cpu040` is now 11 probes: probe8 `dbg_phist` (384),
probe9 `dbg_rtg` (32), probe10 RTG state (29). The capture scripts find probes
by name and `rtg_decode.py` reads the column after `dbg_rtg`, so only comments
and the test fixture's column name changed.

- Analysis: `xvhdl --relax` over run.sh's six VHDL files (TG68K_Pack, ALU,
  Kernel, cornerturn, akiko, TG68K) — exit 0, no errors. The plan's two-file
  form cannot pass: the architecture needs the kernel and akiko units.
- `python3 -m unittest test_rtg_decode`: 3 tests OK.
- `./run.sh --snoop` (`t1`): exit 0, 2 passed, phase 8 at 1.763 ms.
- `./run.sh --snoopmutant` (`t1`): mutant failed as required — 14890 of 22340
  snoops never reached the core, 7295 out of order, phase 8 at 1704693182 ps:
  **identical** to the fixed-bench baseline, as it must be for a probe that
  only observed.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T1 dbg_snoop | 2090 | 1005 | 727 | 591 | 1+wsync-option | 6 | 1 | 15 | dbg_phist dbg_rtg |

−52 wrapper lines, −26 code lines against the baseline.

### Task 2 — remove `cpu_wr_sync`

Removed: the `cpu_wr_sync` input and the `CPU_SM_WSYNC` state of
`cpu_cache_new` (both write branches now take their posted `else` arm), the
port in `sdram_ctrl`, the ties in `ddr3_fastram` and `minimig_virtual_top`, the
wrapper's output and its `sel_chipram` assignment, the `WRSYNC` bench define
(`real_sdram.vh`, `run.sh`) and sdram_coherency's `+wrsync` plusarg. Both
controllers had it tied to 0, so shipped behaviour is unchanged. Two
`ddr3_cpu_tb.sv` comments that explain bench logic by this option now name it
as history. The coherency summary line no longer prints a `wrsync` field.

- Analysis: `xvlog --relax` on `cpu_cache_new.v`, `sdram_ctrl.v`,
  `ddr3_fastram.v` and `xvhdl` over the six VHDL files — exit 0, no errors.
- `sim/sdram_coherency fast sg7 +nobg +rounds=50`: **52 errors, 0 timeouts**,
  every check equal to the reference (line buffer 50, longword 2, rest 0).
- `sim/sdram_coherency fast sg7 +rounds=50`: **14 errors, 0 timeouts** = reference.
- `REALSDRAM=1 ./run.sh --ap040` (`t2`): 2 passed; placement **1953 / 78 off** =
  `e1cal3`.
- `REALSDRAM=1 DMA_OVERLAP=1 P7LOOPS=10 ./run.sh --ap040` (`t2ovl`): summary
  **identical** to `sim/ddr3_cpu/ref/overlap_gate3.txt` (29 lines), compared with
  the command in that file's header. (A first diff of the console capture
  "differed" only by the reference's `#` header and a repeated log tail; the
  runbook now gives the exact command.)

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T2 cpu_wr_sync | 2080 | 1003 | 711 | 589 | 1 | 6 | 1 | 15 | dbg_phist dbg_rtg |

Against Task 1: wrapper −10 lines (−2 code), `cpu_cache_new` −16 code,
`sdram_ctrl` −2 code; posted-write paths `1+wsync-option` → `1`.

Found while waiting (recorded in the plan): the second-word latch Task 5 would
drop has readers, so it stays; and six other board ports compile this RTL —
out of scope (Paul: "I'm only building for the qmtech board"), marked
unsupported in Task 6.

### Task 3 — remove `CL_SNOOP`

Removed: the `CL_SNOOP` parameter of `cpu_cache_new` and `sdram_ctrl`, the
`cpu_cacheline_snooped` register with its clears, `cl_fill_active`, and the
snoop-invalidate block; both `(CL_SNOOP ? cpu_cacheline_snooped : 1'b0)` uses
are now the `1'b0` they evaluated to. sdram_coherency loses `CLS=1`, its
`ifdef CL_SNOOP` instance and the `cl_snoop` summary field. The comment that
describes the line-buffer hole stays, marked NOT FIXED HERE: the hole is real
("C2P line buffer primed"), and E4 decides whether the buffer stays.

- Analysis: `xvlog --relax` on `cpu_cache_new.v` and `sdram_ctrl.v`, and an
  iverilog compile of the coherency bench — both exit 0. No `CL_SNOOP`,
  `cacheline_snooped`, `cl_fill_active` or `CLS` left anywhere.
- `sim/sdram_coherency fast sg7 +nobg +rounds=50`: **52 errors, 0 timeouts**,
  every check equal to the reference.
- `sim/sdram_coherency fast sg7 +rounds=50`: **14 errors, 0 timeouts** (P2C 4
  late 0 lost, longword 10, 3552 background reads 0 failed) = reference.
- `REALSDRAM=1 ./run.sh --ap040` (`t3`): 2 passed; DMA 3958 writes 0 wrong;
  placement **1953 / 78 off**.
- Busy leg (`t3ovl`, not required by the plan; the only leg with saturating
  chipset writes into the lines the CPU reads): **identical** to
  `ref/overlap_gate3.txt`.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T3 CL_SNOOP | 2080 | 1003 | 695 | 587 | 1 | 6 | 1 | 15 | dbg_phist dbg_rtg |

Against Task 2: `cpu_cache_new` −16 code, `sdram_ctrl` −2 code.

### Task 4 — fold the settled phase-gate and data-capture switches

Folded to the shipping settings (gate on, data captured with the grant, gate
delay 3, no request gate) and removed: TG68K.vhd's `cpu_phase_gate_en`,
`cpu_data_reg_en`, `cpu_phase_gate_dly` and `cpu_phase_gate_req` generics,
`gate_open`, `gate_req`, `datatg68_k` and the `g_gate_dly*` generates; the
matching parameters and maps in `minimig_virtual_top.v` and
`minimig_openaars_top.v`; `build_ap040.tcl` arguments 7–10 (it now stops with an
error if given more than 6); the bench's `CPU_PHASE_GATE_DLY` define, instance
parameter and `run.sh` pass-through. The gate is now one process: `ena_sr`
shrinks to 3 bits and the gate opens on `ena_sr(2)` — `clkena_in` delayed 3 clk
cycles, the same tap as `ena_sr(cpu_phase_gate_dly - 1)` at delay 3. A comment
at the process records why 2/6/10/14 and that the mechanism is unexplained.

New leg `REALSDRAM=1 ./run.sh --gatemutant`: run.sh generates the wrapper with
`ena_sr(2)` replaced by `clkena_in` (the gate as first built) and asserts the
substitution.

The busy-leg reference's placement line dropped its `(CPU_PHASE_GATE_DLY=3)`
label, which no longer exists; its numbers are unchanged and its header says
so. (The first relabel also lost the space after the colon; the Task 4 busy-leg
diff caught it, and it was restored before the comparison below.)

- Analysis: xvhdl over the six VHDL files; `xvlog --sv --relax -d REALSDRAM -d
  CPU_AP040 -d SOC_SIM` on `ddr3_cpu_tb.sv`; `xvlog --relax` on both tops — all
  exit 0, no errors. No switch name left outside an unrelated `datareg` signal
  in `rtl/tg68k/TG68K_ALU.vhd`.
- `REALSDRAM=1 ./run.sh --ap040` (`t4`): 2 passed; DMA 3958 writes 0 wrong;
  placement **1953 / 78 off**, all 16 bins **identical to `e1cal3`** (the
  shipping gate through the old generic).
- `REALSDRAM=1 ./run.sh --gatemutant` (`t4`): **mutant failed as required** —
  1862 of 1972 off the grid; all 16 bins **identical to `e1cal0`** (the old
  `CPU_PHASE_GATE_DLY=0` leg).
- Busy leg (`t4ovl`): **identical** to `ref/overlap_gate3.txt` (29 lines).
- `./run.sh --ap040 --chipbus` (`t4`): 2 passed, phase 8 at 937021277 ps, as
  before.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T4 gate switches | 2051 | 987 | 695 | 587 | 1 | 6 | 1 | 0 | dbg_phist dbg_rtg |

Against Task 3: wrapper −29 lines (−16 code); switch uses 15 → 0.

### Task 5 — remove the 32-bit AGA chipset cycle path (`longword_pair`)

For the AP68040 every branch guarded by `longword_pair` was already constant
off. Removed: `longword_pair` (declaration, comment, assignment), `clkena_f`,
the 32-bit write branch in chipset state "00", the 32-bit read branch in the
ena7RDreg state "11", the `clkena_f`/`data_read2` capture in the ena7WRreg state
"11", and the `clkena_f` term of `chipset_ready` (now `ena7RDreg AND
clkena_e`). `cpustate(6)` is the constant `'0'`; the comment above it keeps the
AllocMem history and names `--lwmutant` as its guard.

Kept on purpose:
- the second-word latch (`S_state = "01" AND clkena_e`): its outputs still reach
  `minimig_m68k_bridge` (`_uds2/_lds2`) and `sdram_ctrl` (`chipWR2`), though it
  never fired for the AP68040; E2 rewrites that port;
- the `IF clkena_e = '0' THEN r_data <= data_read` guard, which also keeps a
  second `ena7RDreg` in state "11" from overwriting the captured word;
- the `data_read2` input port (both tops connect it; E2).

`--lwmutant` retargeted: its sed now puts `longword` back on `cpustate(6)`
(`cpustate <= '0' & clkena` → `cpustate <= longword & clkena`, with `\&` in the
sed replacement) and asserts the substitution. Bench and wrapper comments that
named `longword_pair` now describe the constant.

- Analysis: xvhdl over the six VHDL files and `xvlog --sv` on the testbench —
  exit 0, no errors. No `longword_pair` or `clkena_f` left in `rtl/`, `tools/`
  (bar the complexity script's own counter) or `fpga/openaars`.
- `./run.sh --ap040` (`t5`): 2 passed; phase 8 at **1677190382 ps**, identical to
  the fixed-bench baseline.
- `./run.sh --ap040 --chipbus` (`t5`): 2 passed; phase 8 at **937021277 ps**,
  identical.
- `./run.sh --lwmutant` (`t5`): **mutant failed as required** — **2021**
  32-bit-write protocol violations, identical to the baseline: the mutant still
  catches the same bug with only the RAM-port bit reverted.
- `REALSDRAM=1 ./run.sh --ap040` (`t5`): 2 passed; DMA 3958 writes 0 wrong;
  placement **1953 / 78 off**, bins identical to `e1cal3`.
- Busy leg (`t5ovl`): **identical** to `ref/overlap_gate3.txt`.

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T5 longword_pair | 2025 | 972 | 695 | 587 | 1 | 0 | 1 | 0 | dbg_phist dbg_rtg |

Against Task 4: wrapper −26 lines (−15 code); `longword_pair` uses 6 → 0.

### Task 6 — remove the TG68K CPU branch

Scope first (Paul, 2026-09-15: "I'm only building for the qmtech board"): six
other ports compile this RTL (MiST directly; Chameleon v1/v2, DE0-Nano,
DE10-Lite and virtual through `minimig_virtual_top`). They are now unsupported
on this branch; `README.md` says so and names `d3_stable` as the last tag that
builds them.

Removed:
- `TG68K.vhd`: `g_tg68k` (the only user of `rtl/tg68k`, instantiated as
  `entity work.TG68KdotC_Kernel`), the `cpu_core` generic, `use_ap040`,
  `cpu_i`, the `cpu` port; every `X WHEN use_ap040 ELSE Y` folded to `X`
  (`cpu_phase_gate`, `cpu_ce_phase`, `cpu_bus_settled`, `bus_fresh`, `clkena`,
  `bus_step`), `sel_32` and `cpuaddr` lose their `cpu_i(1)` terms, TG68K-only
  comments reworded. **`g_ap040` is kept as an always-true generate**: Vivado
  names the kernel `tg68k/g_ap040.ap040`, and `cpu.xdc`, the ILA scripts and
  the sim hierarchy name that path; unwrapping it would rename it and the
  `-quiet` timing rules would drop silently.
- Tops: `minimig_virtual_top.v` `cpu_core` parameter and map, `.cpu` connection
  (`cpu_config` stays, `minimig` uses it), `CORE_CAPS` with `use_ap040_caps`
  folded to 1 (same value an AP040 build had); `minimig_openaars_top.v`
  `CPU_IS_AP040`.
- Constraints: `cpu.xdc` TG68K kernel sets (`cpu_kernel_tg68k`,
  `cpu_not_kernel`, `tg68_kernel`, `tg68_wrap`), the TG68K island block and the
  C2P→kernel rules (`tg68_seq`, `tg68_mem` stay); `wizard.xdc` two rules into
  `g_tg68k.pf68K_Kernel_inst`; `clocks.xdc` comment.
- Build: `build.tcl` stops with a pointer to `build_ap040.tcl` / `d3_stable`;
  `build_ap040.tcl` drops `CPU_IS_AP040=1`. The local `project_1.xpr` also lost
  the three `rtl/tg68k` sources and the `tg68vswf68k30sim` fileset (TG68K vs
  WF68K30, which took the kernel from `sources_1`), **but `project_1/**` is
  git-ignored (`.gitignore:35`), so that change lives only in this working
  copy** and is not in any commit. `rebuild.tcl`, the tracked project
  recreation script, is not edited: it has no AP68040 at all (last touched
  2024-03), so it cannot recreate this design anyway.
- Bench: `run.sh` requires `--ap040` (or a flag that implies it) and exits 2
  with the leg list otherwise; `--mutant`, the TG68K sources in the `.prj` and
  `-d CPU_AP040` gone; the 12 `CPU_AP040` conditionals in `ddr3_cpu_tb.sv`
  collapsed by a nesting-aware script (block 1131–1155 held a nested
  `REALSDRAM` conditional); `git rm` of `mutant/TG68K_mutant.vhd`,
  `xsim_run_pass.log`, `xsim_run_mutant.log`.

A first suite run failed every `ddr3_cpu` leg at elaboration: the testbench
still connected `.cpu (2'b11)` to the removed port (`binding VHDL entity
'tg68k_default' does not have port 'cpu'`). xvlog analysis cannot see a port
mismatch; only elaboration does. Line removed; suite rerun.

- Analysis: xvhdl on `cornerturn.vhd`, `akiko.vhd`, `TG68K.vhd` **without**
  `TG68K_Pack`, ALU or kernel — exit 0; xvlog on both tops and the testbench —
  exit 0. `./run.sh` and `./run.sh --mutant` exit 2 with the message.

| leg | result |
|---|---|
| `--ap040` | 2 passed, phase 8 at 1677190382 ps (= fixed-bench baseline) |
| `--mmu` | 2 passed, 707928242 ps (=) |
| `--ap040 --chipbus` | 2 passed, 937021277 ps (=) |
| `--nofill` | 2 passed, 1694291482 ps (no earlier fixed-bench baseline) |
| `--snoop` | 2 passed, 1762554842 ps (= Task 1) |
| `REALSDRAM=1 --ap040` | 2 passed, placement 1953 / 78, bins = `e1cal3` |
| busy leg | identical to `ref/overlap_gate3.txt` |
| `--lwmutant` | failed as required, 2021 violations (=) |
| `--mmumutant` | failed as required, stall watchdog |
| `--fillmutant` | failed as required, 3 checks |
| `--snoopmutant` | failed as required, 14890 of 22340 (=) |
| `REALSDRAM=1 --gatemutant` | failed as required, 1862 / 1972, bins = `e1cal0` |
| sdram_coherency `+nobg` / default | 52 / 14 errors (= reference) |

| label | wrapper lines | wrapper code | cpu_cache_new code | sdram_ctrl code | posted-write paths | longword_pair uses | g_tg68k uses | switch uses | debug probes |
|---|---|---|---|---|---|---|---|---|---|
| E4a T6 TG68K branch | 1934 | 917 | 695 | 587 | 1 | 0 | 0 | 0 | dbg_phist dbg_rtg |

Against Task 5: wrapper −91 lines (−55 code). Against the E4a baseline
(stage-e e6b1b90): wrapper 2142 → 1934 lines (1031 → 917 code),
`cpu_cache_new` 727 → 695, `sdram_ctrl` 591 → 587; posted-write paths
`1+wsync-option` → 1; `longword_pair`, `g_tg68k` and switch uses → 0.

### Task 7 — builds (hardware test pending)

Both built from HEAD d3e0924 plus the uncommitted Task 6 tree (diff saved as
`build/<name>/source.diff`); their hardware sources are identical.

| | `stage_ap040_d3stable_gd3` | `stage_ap040_e4a` | `stage_ap040_e4a_ila` |
|---|---|---|---|
| clk_114 → clk_38 | +0.98 ns, 0 fail | +0.93 ns, 0 fail | +0.79 ns, 0 fail |
| clk_38 → clk_114 | +1.70 ns, 0 fail | +1.57 ns, 0 fail | +1.26 ns, 0 fail |
| clk_38 → clk_38 | +1.17 ns, 0 fail | +1.59 ns, 0 fail | +0.79 ns, 0 fail |
| clk_gen_sdram → clk_114 (known) | −0.55 ns, 16 fail | −0.60 ns, 16 fail | −0.54 ns, 16 fail |
| LUTs / BRAM | 40,300 / 59.5 | 40,287 / 59.5 | 47,286 / 127.5 |
| ignored exceptions | 0 | 0 | — |

Generics confirmed from synthesis: no-ILA build `CPU040_DEBUG_ILA=0
DDR3_FASTRAM_ILA=0 cpu_clk_ratio=3 HAVEDDR3=1`; ILA build both ILAs on. The LUT
count barely moves because the TG68K branch was never elaborated in an AP040
build: E4a removes source, not hardware. Hardware protocol (Paul) and the tag
`e4a` follow.

## Found while writing the E2 plan: `datatg68_r` never reached the AP68040

`datatg68_r` (`TG68K.vhd:306`, captured at `:1400`) is assigned and never read.
It is not something E4a disconnected:

- ba323b9 ("capture datatg68 with the enable") changed the `data_in` of the
  **TG68K kernel** instance. At `d3_stable` that mapping is inside `g_tg68k`
  (`data_in => datatg68_k`), while the AP68040 instance in `g_ap040` maps
  `data_in => datatg68`, unregistered.
- E4a Task 4 folded `datatg68_k` to `datatg68_r` in the TG68K instance; Task 6
  deleted that instance, leaving `datatg68_r` with no reader.
- So every AP68040 build, `d3_stable` included, has had the same read-data
  path. **E4a changed nothing here; the loaded `stage_ap040_e4a` is unaffected.**

What it means: the hardware result recorded with ba323b9 ("Way Too Rude still
corrupts") was measured on an AP68040 build that did not contain the fix, and
the `cb_nodatareg` chipbus experiment switched off a register the AP68040 never
used. The read-data crossing into clk_38 is still in neither D4 category, and
it is a candidate for the unexplained 3/7/11/15 corruption. A zero-delay
simulation cannot show it (the data is stable at the kernel edge there). The E2
plan (finding 4, and the separate one-line hardware A/B) takes it up.

### The A/B bitstreams are built and waiting (2026-09-16, JTAG only)

Built overnight from HEAD in two scratchpad worktrees, each `e4a` plus
`data_in => datatg68_r` on the AP68040 instance (the capture the core never
had), with Paul's three uncommitted firmware files copied in so the hardware
sources otherwise equal `stage_ap040_e4a`. Each build directory holds its own
`source.diff`.

| | `stage_ap040_e4a` | `_dreg3` (gate 3) | `_dreg0` (gate 3 → 0) |
|---|---|---|---|
| clk_38 → clk_114 | +1.574 ns, 0 fail | +1.640 ns, 0 fail | +1.352 ns, 0 fail |
| clk_114 → clk_38 | +0.927 ns, 0 fail | +1.283 ns, 0 fail | +1.031 ns, 0 fail |
| clk_gen_sdram → clk_114 (known, pre-existing) | −0.600 ns, 16 fail | −0.488 ns, 16 fail | −0.518 ns, 16 fail |
| LUTs / BRAM | 40287 / 59.5 | 40291 / 59.5 | 40315 / 59.5 |
| ignored exceptions | 20 | 20 | 20 |

**What the A/B decides.** `_dreg0` also reverts the phase gate to opening on
`clkena_in`, i.e. the placement that corrupted Way Too Rude at ratio 3 and
crashed the boot at ratio 4 with Chip turbo (tag `d3_stable` notes). With the
read data now captured on the edge that grants the enable:

- if `_dreg0` runs Way Too Rude cleanly with Chip+Kick turbo, the 3/7/11/15
  mechanism IS the read-data crossing, and Stage E2 can drop the placement rule
  instead of carrying it forward;
- if `_dreg0` still corrupts, the crossing is not the mechanism and the rule
  stands. `_dreg3` then says only whether the capture costs anything (it should
  not: SysInfo and Way Too Rude as `e4a`).

Order on the board: `_dreg3` first (it is the safe one), then `_dreg0`.
**JTAG only, neither goes to flash**; `_dreg0` is deliberately the
configuration that is expected to fail.
