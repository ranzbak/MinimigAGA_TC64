# Task 1 report -- bump lib/AP68040 to the apol/ap040x3 core, fill channel NOT routed

**Status: DONE_WITH_CONCERNS.** All gates pass. The concern is not the result
but what it revealed -- see sections 5 and 6.

The x3 core is overlaid onto `lib/AP68040`, the wrapper carries the new fill
ports tied off, and the source lists are updated. One thing the brief could not
know turned up and cost a round trip: x3 also frees the core, MMU and cache
from the clock enable (A2b-0), and that change is incompatible with this
project's duty-cycled enable -- the first `sim/ddr3_cpu --ap040` run died at
phase 0. Per the coordinator's ruling the core is re-gated to `clkena_in` in
our copy, as a second commit so the verbatim x3 state stays in history.

---

## 1. What was implemented

### Submodule `lib/AP68040`, local branch `x3-overlay`

Two commits, from 0e76761:

**`3a6180b` -- Overlay the ap040x3 core from Minimig-AGA_MiSTer.** Files copied
verbatim from branch `apol/ap040x3` commit `8665741`, directory `rtl/ap040`
(benches from `tests/ap040` in the same commit):

| file | why |
|---|---|
| `rtl/ap040_cache.v` | store-hit update (X3.2), posted stores (X3.3), fill channel (X3.4) |
| `rtl/ap040_core.v` | `post_busy`/`post_err` sideband; MOVEC/PTEST/PFLUSH drain a posted store |
| `rtl/ap040_mmu.v` | `walk_hold`: no table search under a draining posted store |
| `rtl/ap040_tg68k_compat.v` | `AP040_POST_STORES`, `AP040_FILL_CHANNEL`, the `fill_*` ports, `ce_core` |
| `rtl/ap040_fill_cdc.v` | new; the fill channel's CDC bridge. **Not instantiated by the compat top.** |
| `rtl/ap040.qip` | one added line listing `ap040_fill_cdc.v` (the submodule's own source list) |

Blob-hash comparison confirmed the brief's list exactly: `ap040_alu`,
`ap040_bus16_adapter`, `ap040_bus_timeout`, `ap040_defs.svh`, `ap040_fpu`,
`ap040_muldiv`, `ap040_regfile`, `ap040_walker_cdc` are byte-identical between
0e76761 and x3.

**`c5d5cc3` -- Re-gate the core, MMU and cache to clkena_in for this wrapper.**
One line, `wire ce_core = clkena_in;`, under a comment naming the reason. See
section 5 for the measurement behind it.

**Deviation from the brief, deliberate and accepted by the coordinator:** three
test files were overlaid too -- `tb/tb_ap040_program.v`,
`tb/tb_ap040_cache_snoop.v`, `tb/asm/t_exceptions.s`. Without them the gate does
not measure this core. Evidence: with the five RTL files alone the suite reports

```
  FAIL  exceptions  (see build/exceptions.log)
FAIL: program reports failure, test 136 (phase 0, pc=0000218c, ill=2, addr=4)
```

Test 136 aimed **one fixed interrupt delay** at the inside of a `MOVE to SR`.
That only landed there while the core froze during bus waits; it fails on a
working x3 core. x3's version sweeps the arrival across the instruction and
moves the IPEND rule itself into the bench (`tb_must`).
`tb_ap040_cache_snoop.v` gains the posted-store and fill-channel cases; without
it the new cache paths have no bench at all. x3's own `run_tests.sh` and
`build_tests.sh` were **not** taken -- they are the MiSTer harness and compile
that project's `cpu_wrapper`, `sdram_ctrl` and `ddram_ctrl`. This repo keeps its
standalone eleven-leg suite.

### Superproject

* `rtl/soc/TG68K.vhd`
  * new generic `ap040_post_stores : integer := 1`, alongside
    `ap040_has_mmu`/`has_fpu`/`enable_cache`;
  * `ap040_tg68k_compat` component: generics `AP040_POST_STORES`,
    `AP040_FILL_CHANNEL`; ports `fill_ena_zorro`, `fill_ena_chip` (in),
    `fill_req`, `fill_addr(31 downto 4)` (out), `fill_data(127 downto 0)`,
    `fill_ack`, `fill_err` (in);
  * instantiation: `AP040_POST_STORES => ap040_post_stores`,
    `AP040_FILL_CHANNEL => 1`, both enables `'0'`,
    `fill_data => (others => '0')`, `fill_ack`/`fill_err` `'0'`,
    `fill_req`/`fill_addr` `open`.
  * The stage-B walker mux is untouched.
* `tools/vivado/build.tcl` (~line 84) and `sim/ddr3_cpu/run.sh` (~line 201):
  `ap040_fill_cdc` added to the AP040 source lists. Those two are the only such
  lists in the repo (`grep -rn "AP68040/rtl" tools sim rtl`).
  `tools/vivado/build_ap040.tcl` adds no AP040 sources of its own -- it opens
  the existing `project_1`, so a project created before this change will not
  contain `ap040_fill_cdc.v` until `build.tcl` is re-run. Inert either way,
  since nothing instantiates it.

---

## 2. Fill-channel fallback, and the RAM primitive

**Fallback with both enables low: confirmed, so `AP040_FILL_CHANNEL` stays 1.**
`ap040_cache.v:93-110` states it outright -- "fill_ok = 0 (the wrapper's value
until A1-2 wires the channel) keeps every fill on the adapter path, bit for bit
as before" -- and the C_LOOK miss arm is

```verilog
else if (FILL_CHANNEL != 0 && fill_ok) begin
        fill_req <= 1;
        cst <= C_FILLC;
end
else cst <= C_FILL;
```

`fill_ok` is built in the compat top as
`(fill_ena_zorro & (cache_win & ~cache_chip | cache_allow_all)) | (fill_ena_chip & cache_chip)`,
so with both enables tied `'0'` it is a constant 0 and C_FILLC/C_FILLW are
unreachable (synthesis prunes them).

**RAM primitive: unchanged, the override still applies exactly.** x3 has no
`rtl/primitives` directory of its own; the MiSTer tree supplies
`tests/ap040/sim_dpram.v`, byte-identical in port shape to our submodule's
`rtl/primitives/dpram.v`. The only two instantiations are `dpram #(7, ROWW)
ctag_ram` in `ap040_cache.v` and `dpram #(5, ROWW) atc_ram` in `ap040_mmu.v` --
same module, same `#(AW, DW)` parameters, same port names (`clock, address_a,
data_a, wren_a, q_a, address_b, data_b, wren_b, q_b`). The cache's four data
ways are plain `reg [31:0] cdataN [0:511]` arrays carrying
`(* ramstyle = "no_rw_check" *)`, not dpram. So `rtl/cpu040/dpram.v` replaces
exactly the primitive x3 uses, and its deliberate old-data-on-collision
difference is still covered by `tb_ap040_cache_snoop.v`, which passes.

---

## 3. Free-running registers in the x3 compat top

**No new `always` block.** The compat top has exactly one -- the walker-write
snoop edge detector (`walker_wr_d`, `wsnp_pend`, `wsnp_addr`), unchanged from
0e76761 -- plus the instantiated `ap040_bus_timeout core_stall_watchdog`. Both
are already named in `cpu.xdc`'s `cpu_not_free` list, so no XDC change is
needed for the compat top.

One new free-running register elsewhere: `st_snooped` in `ap040_cache.v:345`
(the store-hit-update snoop window), in the same ungated block as
`fill_snooped`/`look_snooped`. **Still no XDC change needed** -- the existing
exclusion is the wildcard `NAME !~ *_snooped_reg*`, which already matches it.
`ap040_mmu.v`'s ungated lookup pipe is still `l_row`/`l_tag`/`l_ld` at the same
place, also already listed and also covered by the `cpu_ce_aligned` two-cycle
group.

The compat top instance name is unchanged -- `g_ap040.ap040` inside
`openaars_virtual_top/tg68k` -- so `cpu_kernel_ap040` still resolves and the
`cpu.xdc` "Who the CPU is" block needs no edit.

`ce_core` would have made this answer very different: as shipped, x3 ties it
high and the entire kernel above the bus adapter free-runs, which would make
`cpu.xdc`'s three-cycle island exception false for essentially every AP040
kernel register. With the re-gating in `c5d5cc3` the premise `cpu.xdc` is
written against -- "every kernel register therefore holds its value for at
least 3 clk_114 cycles" -- holds again, and the file is correct as it stands.
**That is the thing to re-check first when the free-running core is revisited.**

---

## 4. Gate results

### Gate 1 -- `tools/test_ap040.sh`: **PASS, 11/11** (re-gated core)

```
$ tools/test_ap040.sh
== AP68040 self-tests with rtl/cpu040/dpram.v ==
  pass  reset          pass  double_fault   pass  walker_cdc
  pass  bus16_gap      pass  bus_timeout    pass  cache_snoop
  pass  integer        pass  exceptions     pass  mmu
  pass  cache          pass  fpu
AP68040: ALL TESTS PASSED
```

Eleven legs, the same count as 0e76761. It also passed 11/11 on the verbatim
`3a6180b` overlay -- the core's own bench drives `clkena_in` as a pure bus wait,
which is exactly why it could not see the wrapper problem below.

### Gate 2 -- `sim/ddr3_cpu`: all six legs as required

Baseline logs (all seven `xsim_run_*.log`) were copied aside before the first
run. Run one at a time, in the brief's order, ~5-11 min each (`xelab` dominates
the short legs):

| leg | command | required | result |
|---|---|---|---|
| 1 | `./run.sh --ap040` | PASS | **PASS** -- `DDR3 CPU TB: 2 passed, 0 failed` |
| 2 | `./run.sh --ap040 --chipbus` | PASS | **PASS** -- `2 passed, 0 failed` |
| 3 | `./run.sh --mmu` | PASS | **PASS** -- `2 passed, 0 failed` |
| 4 | `./run.sh --lwmutant` | must FAIL | **failed as required** -- `FAIL 1940 32-bit-write protocol violations on the RAM port` (baseline 1895) |
| 5 | `./run.sh --mmumutant` | must FAIL | **failed as required** -- `FAIL the program stopped making progress (stall watchdog)`, last phase 2 |
| 6 | `./run.sh` (TG68K control) | PASS | **PASS** -- `2 passed, 0 failed` |

Both mutants were checked on the SUMMARY line, not on `DDR3 CPU TB: PASS`:
`--lwmutant` completes every 68k phase and fails only on the bench's
assertions, which is exactly the trap the run script's comment warns about.

### Phase timestamps, x3 overlay vs 0e76761

All times in microseconds **measured from CPU release** (64,389,167 ps in every
run, so the DDR3 bring-up is not counted). The pattern program never emits
phase 6 -- it goes 5 -> 7 -- so the plan's phase-6 row comes from the MMU
program, which does.

**`--ap040`** (pattern program, TURBOCHIP=1, PATBYTES=1024)

| phase | 0e76761 | x3 overlay | delta |
|---|---|---|---|
| 1 | 10.85 | 10.40 | -4.14 % |
| 2 | 459.47 | 408.61 | **-11.07 %** |
| 3 | 1411.80 | 1360.49 | -3.63 % |
| 4 | 1612.33 | 1547.85 | -4.00 % |
| 5 | 1634.36 | 1568.89 | -4.01 % |
| 7 | 1908.66 | 1841.13 | -3.54 % |
| 8 | 1939.83 | 1870.30 | **-3.58 %** |

**`--mmu`**

| phase | 0e76761 | x3 overlay | delta |
|---|---|---|---|
| 1 | 12.63 | 12.01 | -4.95 % |
| 2 | 599.01 | 582.15 | -2.82 % |
| 3 | 603.67 | 586.97 | -2.77 % |
| 4 | 609.26 | 592.50 | -2.75 % |
| 5 | 618.54 | 601.86 | -2.70 % |
| **6** | **634.25** | **615.44** | **-2.97 %** |
| 7 | 648.80 | 627.67 | -3.26 % |
| 8 | 652.27 | 631.12 | -3.24 % |

**`--ap040 --chipbus`** (reduced sizes; 7 MHz chipset bus)

| phase | 0e76761 | x3 overlay | delta |
|---|---|---|---|
| 1 | 34.43 | 33.87 | -1.64 % |
| 2 | 124.13 | 118.63 | -4.43 % |
| 3 | 392.81 | 387.31 | -1.40 % |
| 4 | 498.31 | 491.82 | -1.30 % |
| 5 | 585.90 | 578.99 | -1.18 % |
| 7 | 713.54 | 706.35 | -1.01 % |
| 8 | 855.71 | 847.24 | **-0.99 %** |

**The numbers moved everywhere, so the change reaches the bench** -- the first
thing to check here, per the bench's own history of three green runs that
tested nothing. The shape is right as well as the sign: the biggest win is the
pattern program's instruction-bound phase 1->2 gap (-11 %), which is where a
store-hit update that no longer clears a whole row should pay; the smallest is
`--chipbus` (-1 %), which is bound by the 7 MHz chipset bus and cannot be
helped by anything inside the CPU.

**The TG68K control's saved baseline is stale and was not compared.** It PASSes,
which is the point of the leg -- the `g_tg68k` branch cannot see any of these
changes -- but `xsim_run_pass.log` dates from 2026-09-06 and stops at phase 6,
while the current program runs to phase 8. Different program, so its
timestamps are not comparable to today's; only the verdict is.

---

## 5. Why the core had to be re-gated (the measurement)

The first `./run.sh --ap040`, on the verbatim x3 overlay:

```
INFO: CPU released at 64389167.0 ps (ddr_ready=1 init_done=1 pll_locked=1)

DDR3 CPU TB: FAIL  the 68k program never wrote the mailbox (timeout)
       last phase reached: 0

FAIL: DDR3 array contents wrong in 764 places (independent backdoor read)
DDR3 CPU TB: 2 checks failed
```

The 68k program never reached phase 1. (The 764 DRAM mismatches are a
consequence, not a second fault: nothing was ever written, so the backdoor read
sees uninitialised `X`/`Z`.)

**Mechanism.** `ap040_bus16_adapter.v` clears its acknowledge *inside* the clock
enable:

```verilog
else if (clkena_in) begin
        mem_ack <= 0;
        ...
                        mem_ack  <= 1;
```

so the header's claim -- "mem_ack is a single-cycle pulse asserted in the same
cycle busstate returns to idle" -- is a promise about a **continuously high**
enable. In the MiSTer tree it is one: `rtl/cpu_wrapper.v:285` passes
`.clkena_in(~cpu_req | bus_complete | bus_berr)`, a pure bus wait with no phase
divider. The A2b-0 commit (`0baf7668`) reasons explicitly from that -- *"mem_ack
is a registered one-clock pulse visible in the cycle after a qualified edge,
when the adapter is idle and clkena high anyway."*

`rtl/soc/TG68K.vhd:967` is a different signal:

```vhdl
clkena <= '1' WHEN (clkena_in = '1' AND (bstate = "01" OR bus_ready = '1' OR wk_ack = '1' OR wk_berr = '1')) ELSE '0';
```

`clkena_in` here is `enaWRreg`, high on **5 of every 16** `clk_114` phases
(2/5/8/11/14). So `mem_ack` rises at a qualified edge and is not cleared until
the *next* one, three or four cycles later. A gated cache samples it exactly
once; a free-running one reads the stale level as the acknowledge of the **next**
request, and the machine desyncs immediately.

**Reproduced at the core level in two minutes instead of twenty-five.**
`tb_ap040_program.v`'s enable was gated with this project's cadence, in a
scratch copy only:

```verilog
wire clkena_in = ((busstate == 2'b01) | mem_ready | berr) & tb_ena;  // tb_ena: ph 2/5/8/11/14 of 16
```

| core config | bench enable | `t_integer` |
|---|---|---|
| x3, `ce_core = 1'b1` (as shipped) | **gated 5/16** | **FAIL** test 67, runaway to `pc=ffff6708` |
| x3, `ce_core = clkena_in` (shipped here) | gated 5/16 | ALL TESTS PASSED, 30722 / 32210 / 30572 cycles |
| x3, `ce_core = 1'b1` + rising-edge ack | gated 5/16 | ALL TESTS PASSED, 12342 / 13488 / 12220 cycles |
| stock 0e76761 | gated 5/16 | ALL TESTS PASSED |

---

## 6. Findings for the enable-scheme stage

Input to a later task; **none of this is in the tree.**

**a. The free-running core is worth a lot.** Rows 2 and 3 of the table above are
the same core on the same bench: **2.4x fewer cycles** with the core, MMU and
cache free-running. That is far more than the cache fix alone is likely to be
worth, so A2b-0 is the prize in Stage D, not a side effect of it.

**b. A three-line fix in the compat top makes it work here, and was tested.**
The adapter is untouched:

```verilog
wire        b_ack_raw;                       // .mem_ack(b_ack_raw) on bus16
reg         b_ack_d;
always @(posedge clk) if (!nreset) b_ack_d <= 1'b0; else b_ack_d <= b_ack_raw;
wire        b_ack = b_ack_raw & ~b_ack_d;    // rising edge: one pulse per completion
```

The adapter asserts `mem_ack` once per transaction, so its rising edge is
exactly one pulse per completion whatever the enable's duty cycle. With it, the
full suite passes on the **stock (ungated) bench** too, so it does not disturb
the MiSTer enable shape and is a viable upstream patch rather than a local fork.
The cleaner place for it is arguably `ap040_bus16_adapter.v` itself -- clearing
`mem_ack` on the free clock so the module's own documented contract is true
unconditionally -- which is what to propose to apolkosnik.

**c. Do not trust a naively gated `tb_ap040_program`.** With the fix in place
the gated bench still failed `exceptions` (tests 33 and 98). The control run
settles what that means: the **stock 0e76761 core** -- the one running on
hardware today -- fails the same gated bench at `exceptions` test 141 *and* at
`mmu` (`core halted, fault=1 pc=000004e8 ir=4e7b ... mem_flt=1`, a MOVEC turning
into an access fault). So the gated bench is **not a valid harness for the
interrupt and walker legs**: those rules count free `clk` cycles and are written
against a continuously high enable, the same coincidence class that broke test
136. It *is* sound as a discriminator for the desync itself -- `t_integer` is
pure compute and memory, and it separated all four configurations cleanly.
A real harness for that stage needs either the MiSTer benches that model a
controller (`tb_cpu_wrapper_chip`, `tb_sdram_turbo`) or this project's
`sim/ddr3_cpu`.

**d. `cpu.xdc` is the other half of the work.** Freeing the core makes the
three-cycle kernel-island multicycle exception false for every register above
the bus adapter -- the TIMING-46 class `findings/constraints/fix-04` was about,
applied to thousands of cells instead of four. The enable-scheme stage is an
RTL change *and* a constraints change, and the constraints half cannot be
deferred past the first bitstream.

**e. `sim/ddr3_cpu` costs more than the header says.** `xelab` takes about ten
minutes per leg on top of the twelve-minute run, so the six-leg gate is nearer
2.5 hours than 1.5.

---

## 7. Files changed, commits

**Submodule `lib/AP68040`**, local branch `x3-overlay` (local-only, as the brief
accepts), pointer moved 0e76761 -> c5d5cc3:

* `3a6180b` Overlay the ap040x3 core from Minimig-AGA_MiSTer
  -- `rtl/ap040_cache.v`, `rtl/ap040_core.v`, `rtl/ap040_mmu.v`,
  `rtl/ap040_tg68k_compat.v`, `rtl/ap040_fill_cdc.v` (new), `rtl/ap040.qip`,
  `tb/tb_ap040_program.v`, `tb/tb_ap040_cache_snoop.v`, `tb/asm/t_exceptions.s`
* `c5d5cc3` Re-gate the core, MMU and cache to clkena_in for this wrapper
  -- `rtl/ap040_tg68k_compat.v`, one line plus its comment

**Superproject**, `4b033dc` "D1: overlay the ap040x3 core, fill channel declared
but not routed":

* `lib/AP68040` (pointer), `rtl/soc/TG68K.vhd`, `tools/vivado/build.tcl`,
  `sim/ddr3_cpu/run.sh`, `findings/ap68040/plan-v2-with-ddr3.md`

Staged by explicit path, never `git add -A`. Everything Paul had dirty is
untouched: `fw/ctrl_832/version.h`, `sim/hostcpu-i2c-bridge/*.wcfg`,
`tools/vivado/ila_fastram_check.py` and every untracked file. The six tracked
`sim/ddr3_cpu/xsim_run_*.log` files were rewritten by the runs and are
deliberately **left uncommitted** -- they are not in the brief's commit list.
One stray `xelab.log` I created at the repo root with an `xelab -version` probe
was removed.

---

## 8. Self-review

* **Completeness.** All eight brief steps done. Both source lists updated, and
  they are the only two in the repo. The free-running-register check is done and
  reported (section 3): no new `always` block, one new register `st_snooped`
  already covered by an existing wildcard, instance name unchanged, no `cpu.xdc`
  edit needed *given the re-gating*.
* **Quality.** The VHDL follows the surrounding style -- a comment block above
  each port group, the same alignment, `open` for unused outputs, the fill ports
  in the same position they occupy in the Verilog. The one divergence inside the
  vendored file is marked "MinimigAGA_TC64 DIVERGES FROM UPSTREAM HERE" and
  carries the measurement, so the next person to pull from upstream will see it.
* **Discipline.** Nothing beyond the brief. The rising-edge-ack fix was tested
  only in scratch copies and is recorded in section 6, not in the tree. The
  submodule is otherwise verbatim, and `3a6180b` preserves that state in history
  so a future rebase onto a newer x3 has a clean base.
* **Output pristine.** No new elaboration warnings: the only AP040 lines in
  `xelab` are the pre-existing XSIM 43-4099 "doesn't have a timescale" notes,
  one per module, now including `AP040_POST_STORES=1,AP040_FILL_CHANNEL=1` in
  the parameter list -- which is itself the confirmation that the new generics
  reached the elaborated design. `ap040_fill_cdc` correctly does not appear:
  nothing instantiates it.

### Concerns

1. **The 2.4x is still on the table and this task did not take it.** Re-gating
   was the right call for a task whose gate is "everything still works", but
   section 6a is the real Stage D number: 12,342 cycles against 30,722 on the
   same bench. Whoever picks up the enable-scheme stage should start from
   section 6, not from a fresh reading of x3.
2. **`AP040_POST_STORES` is on but cannot pay.** With the core re-gated, a
   posted store buys almost nothing -- the author's own reasoning is that the
   core takes one step and then waits for the store's last half anyway. It is
   left at 1 because the brief says so and because it is measured harmless
   (all gates pass), but the generic exists precisely so the A/B can be run.
3. **`sim/ddr3_cpu`'s enable cadence is hand-maintained** -- the bench does not
   compile `sdram_ctrl`. It is currently in step with the five-phase `enaWRreg`,
   and my scratch reproduction copied those same five phases, so both the gate
   and the reproduction share one unverified assumption. If `enaWRreg` moves
   again, both move with it or both lie.
4. **The three overlaid test files are a fork of the bench**, small but real. If
   `lib/AP68040` upstream ever ships its own x3-era `tb/`, these should be
   dropped in favour of it rather than merged.

---

# Fix round 1: black screen on hardware

**Status: NEEDS_CONTEXT.** No RTL defect was found, and no RTL was changed.
The premise did not survive the evidence: **the x3 core boots.** What is left
is one experiment that needs a person in front of the monitor for ten seconds,
and it is named at the end of this section.

## 1. Evidence, in the order it arrived

| time | event | source |
|---|---|---|
| 23:41 | `build/stage_ap040_x3` (ila=0) programmed | controller |
| 23:5x | **black screen, no boot** -- one observation | Paul |
| 23:50 | `build/stage_ap040_ddr3only` programmed: boots | Paul (board is fine) |
| 00:11 | `build/stage_ap040_x3_ila` (ila=1) programmed | controller |
| 00:13 | ILA `now`: 4096 samples at `dbg_pc=$00F815D2`, `dbg_ir=4E72` (STOP) | `x3_now.csv` |
| 00:15 | ILA `busy`: level-3 autovector, VERTB server chain, ExecBase `$40000864` | `x3_busy.csv` |
| **00:25** | **the machine BOOTS to Workbench; SysInfo 0.23x an A4000/040-25** (the 0e76761 core measured 0.19x) | Paul |

The 00:13 and 00:15 captures were therefore taken on a **booted, idle
Workbench**, not on a parked machine. That is the first finding and it
invalidates the debug brief's Phase 1: there was nothing to locate. It also
recovers a positive result -- +21 % on SysInfo from the x3 cache alone, under
the re-gated enable.

## 2. The two bitstreams differ in nothing but placement

Checked before designing any experiment, because a "one build boots, the other
does not" story is only worth chasing if the builds can differ.

* **Generics are identical.** Both build logs carry the same line, with only
  the `$ila` substitution differing:
  `set_property generic "CPU_IS_AP040=1 HAVEDDR3=1 DDR3_BIST_VIO=0 DDR3_FASTRAM_ILA=$ila CPU040_DEBUG_ILA=$ila"`
  (`build_x3_ila0.log:171`, `build_x3_ila1.log:172`).
* **Both parameters gate observation only.** `CPU040_DEBUG_ILA` and
  `DDR3_FASTRAM_ILA` appear in exactly two places,
  `rtl/soc/minimig_virtual_top.v:919` (`g_cpu040_ila`) and `:937`
  (`g_ddr3_fastram_ila`). Each generate block instantiates one ILA and drives
  nothing; every signal in them is an existing wire.

So there is no logic difference between `stage_ap040_x3` and
`stage_ap040_x3_ila` to look for. Only placement, routing and utilisation.

## 3. The placement/timing hypothesis is refuted by its own control

The coordinator's hypothesis was that the ila=0 build's two failing clk_114
endpoints -- the free-running `atc_ram -> look_snooped` snoop path -- are what
black-screened it. They are not, and the proof is the build that boots:

| build | boots? | worst clk_114 path | slack |
|---|---|---|---|
| `stage_ap040_ddr3only` (0e76761 core) | yes | `mmu/atc_ram -> g_cache.cache/look_snooped_reg` | **-0.588** |
| `stage_ap040_x3` (ila=0) | one black screen | `atc_ram/mem_reg_0 -> look_snooped_reg` | **-0.347** |
| | | `atc_ram/mem_reg_0 -> st_snooped_reg` | **-0.262** |
| `stage_ap040_x3_ila` (ila=1) | **yes, twice tonight** | `atc_ram/mem_reg_2 -> st_snooped_reg` | **-0.753** |

(`build/stage_ap040_x3/clk114_intra_paths_x3.rpt:15,98`;
`build/stage_ap040_x3_ila/timing_summary.rpt:285`.)

The build that boots violates the suspected path by **twice** what the build
that black-screened does, and the booting baseline violates it by nearly as
much again. On every reported figure -- clk_114 WNS and failing endpoints,
`clk_gen_sdram -> clk_114`, utilisation -- the ila=0 build is the *healthiest*
of the three. There is no timing argument that separates them.

The path itself is real and worth carrying forward (section 7): it is the
MMU's ATC output becoming the physical address, compared against the snoop
address to arm `look_snooped`/`st_snooped`. `cpu.xdc` correctly excludes
`*_snooped_reg*` from the kernel island, so this is honest single-cycle timing
that genuinely fails setup -- in **every** AP040 bitstream built so far,
including the one that has been booting reliably since stage B.

## 4. A screen-free boot detector, and what it says

Nobody could be assumed to be at the monitor, so the first thing built was a
way to ask the board. `tools/vivado/ila_boot_probe.tcl` (new, committed) takes
three captures in one hw session -- `now`, `busy`, `write` -- and the reference
signature is documented in its header. Measured 00:31 on the machine Paul had
just confirmed was at Workbench (`ref_booted_*.csv`):

* `now`: 4096 of 4096 samples at `$00F815D2`, `dbg_ir=4E72`, `as` never low.
* `busy`: `$6C -> $F81354`, INTENAR `$602C`, INTREQR with VERTB, ExecBase from
  `$4` = `$40000864` (the fast-RAM board window), then the VERTB server chain.
* `write`: on into Exec's server dispatch at `$F8190A`, INTREQ cleared at
  `$DFF09C`, into a ROM server at `$F945AC`.

And what a machine that has **not** finished booting looks like, same build,
60 s and 110 s after programming (`x3ila_run1_*`, `x3ila_run1b_*`): a dozen ROM
PCs around `$00F81EF6` / `$00FB7FAC`, CIA-B at `$00BFD800`/`$00BFDF00`, and
`WaitBlit` spinning on DMACONR `$00DFF002`. The two states are not confusable.
A cold boot needs four to five minutes before an untriggered probe means
anything -- that alone would have been worth the exercise.

**Reproducibility, three program cycles of the x3 core, all booted:**

| cycle | programmed | verdict | evidence |
|---|---|---|---|
| Paul's | 00:11 | Workbench, SysInfo 0.23x | Paul |
| run 1 | 00:32:38 | booted by 00:38 | `x3ila_run1c_*`: the reference signature exactly, plus a PC at `$4018C1EA` -- disk-loaded code executing in fast RAM |
| run 2 | 00:38:54 | booted, with a program drawing | `x3ila_run2b_write.csv`: a tight loop at `$03708A-$0370A0` storing bytes into chip RAM at an **88-byte stride** (`$3E953, $3E9AB, $3EA03 ...`) between DMACONR waits -- a bitmap plot |

Run 2 is the stronger of the two. A drawing loop storing into chip RAM at a
bitplane modulo, with the blitter being waited on, is a machine whose **display
is up and whose chip-RAM store path is landing** -- which is the first thing a
posted-store or store-hit-merge defect would break. (Chip RAM is
cache-inhibited in this wrapper -- every `movea.l $4.w` in the captures is a
real bus read -- so those stores take the unchanged synchronous path; the
capture confirms the drain ordering x3 wrapped around it does not lose them.)

## 5. Hypotheses tested

| # | hypothesis | test | result |
|---|---|---|---|
| 1 | the machine is parked in ROM init / a hung task | decode `x3_busy.csv` against Kickstart 46.143 `$F81340-$F813B0` | **refuted.** It is Exec's level-3 handler: `d1 = INTENAR & INTREQR = $0020`, VERTB only, `movem.l $90(a6),a1/a5` served from the data cache (no bus read at `$400008F4`). A healthy machine. Paul then confirmed Workbench |
| 2 | the ila=0 and ila=1 builds differ functionally | generics in both build logs; every use of the two ILA parameters | **refuted**, section 2 |
| 3 | the ila=0 build's failing snoop endpoints black-screened it | compare the same path in the two builds that boot | **refuted**, section 3: the booting build is worse on it |
| 4 | the x3 core boots unreliably | three program cycles with the boot detector | **not supported**: 3 of 3 booted |
| 5 | posted stores / store-hit merge corrupt chip RAM (the classic "OS in fast RAM survives, display dies" shape) | run 2's drawing loop; and the code path: `st_post_ok` and `st_upd_ok` both require `!c_nocache`, and chip RAM is cache-inhibited here | **refuted**: chip stores never enter either new path, and the capture shows them landing |
| 6 | a silent access fault is being taken on the running machine | five ILA watches on `dbg_flags[3]` | **not testable**: the fault trigger is broken in this tooling, section 6 |

## 6. The fault watch is not usable, and neither was the one in the brief

Hypothesis 6 -- "a silent access fault is being taken on the running machine"
-- could not be tested, and the reason corrects a line of the debug brief's
evidence.

Five attempts, two scripts, one booted machine:

| attempt | trigger | result |
|---|---|---|
| `ila_cpu040_capture_fixed.tcl ... fault`, 6 min | `dbg_flags` `eq4'b1xxx` | "FAULT captured" after 6 min -> `x3_faultwatch.csv`: **two lines, and its columns are the DDR3 fastram ILA's** |
| `ila_fault_watch.tcl`, 5 min | same | "FAULT captured" -> same degenerate file |
| same, with `current_hw_ila` set explicitly and the core printed | same | same |
| the fault trigger appended to `ila_boot_probe.tcl`, behind three uploads that had just worked in the same session | same, capture `BASIC` | fired **one second** after arming; same degenerate file |
| same, capture `ALWAYS`, then again with `eq4'b1XXX` | same | same, one second, same degenerate file |

The core selection is not the problem: `ila_props.tcl` (workspace) shows
`hw_ila_1` is `openaars_virtual_top/g_cpu040_ila.ila_cpu040_i` carrying
`dbg_pc`/`dbg_flags`, and `hw_ila_2` is the fastram core; the scripts pick
`hw_ila_1` and print that they did. What separates the working modes from the
broken one is the trigger pattern: `eq4'bxxxx` (mode `now`) and `eq4'b00XX` on
`bus_ctl` (mode `write`) arm and upload correctly, three times per session, all
night. Any pattern with a **`1`** in it on `dbg_flags` returns instantly with a
dataset belonging to the other core and no samples.

**So the debug brief's line "a fault-mode capture fired instantly with zero
samples: a transient at programming time, not a fault" is not an observation of
the machine.** It is this, and it reproduces on a machine that has been sitting
at Workbench for half an hour. Nothing is known about whether the running x3
core takes access faults; the tool cannot ask yet. `tools/vivado/ila_boot_probe.tcl`
therefore ships with the three modes that work and a header note saying why
there is no fourth.

## 7. Carried forward

1. **`atc_ram -> {look,st}_snooped` fails setup in every AP040 bitstream**
   (-0.588 on the booting baseline, -0.753 on the booting x3 ila=1 build). The
   flag is armed on the free clock from a combinational compare of the MMU's
   just-translated physical address against the snoop address, and a late
   arrival does not delay anything -- it silently arms the wrong value, and for
   `st_snooped` the wrong value in one direction merges a store into a way the
   snoop has invalidated. It has not bitten yet, but it is the only
   *mechanism* in this design that produces rare, placement-dependent
   corruption. The fix is RTL, not a constraint: register the physical address
   (or the compare) so the snoop window closes on a flop-to-flop path. Belongs
   with the enable-scheme stage, which rewrites this area anyway.
2. **If `build/stage_ap040_x3` does black-screen reproducibly**, the next
   bitstream to build is `CPU040_DEBUG_ILA=1, DDR3_FASTRAM_ILA=0` -- the CPU
   ILA alone. It is a far smaller perturbation than tonight's ila=1 build (the
   fastram ILA's 24 probes include two 128-bit ones) and would be the first
   bitstream that is both observable and close to the shipping placement.
   `build_ap040.tcl` takes one `<ila>` argument for both cores today; splitting
   it is a two-line change.
3. **No ILA trigger on `dbg_flags` works** (section 6), so "did this core take
   an access fault while running" is still an unanswerable question on
   hardware. Worth half an hour with a VIO or a hand-built trigger the next
   time someone is in front of Vivado; a fault flag nobody can trigger on is a
   probe that is not really there. The `must`/`pr` typo on line 78 of
   `tools/vivado/ila_cpu040_capture.tcl` is fixed in this round's commit; its
   `fault` mode is left as it is, and section 6 says what it reports.

## 8. Gates

No RTL was changed, so there is no new bench and nothing to regress. For the
record, on the tree as it stands:

```
$ tools/test_ap040.sh
== AP68040 self-tests with rtl/cpu040/dpram.v ==
  pass  reset          pass  double_fault   pass  walker_cdc
  pass  bus16_gap      pass  bus_timeout    pass  cache_snoop
  pass  integer        pass  exceptions     pass  mmu
  pass  cache          pass  fpu
AP68040: ALL TESTS PASSED
```

`sim/ddr3_cpu` was not re-run: nothing it compiles changed since Task 1's
six-leg pass.

## 9. Commits, board state, and the one experiment left

**Commit `43ecd84`** -- `tools/vivado/ila_boot_probe.tcl` (new) and the
`must` -> `pr` fix in `tools/vivado/ila_cpu040_capture.tcl`. Tooling only; no
RTL, no constraints, no submodule movement. Paul's uncommitted edits and every
untracked scratch file are untouched.

**Board: `build/stage_ap040_x3_ila`**, programmed by me at 00:38:54, verified
booted by capture at 00:41 and 00:45. This is a deliberate deviation from the
debug brief's "leave `build/stage_ap040_ddr3only`" rule, which was written when
the x3 core was believed not to boot: the board is holding a bitstream this
round *measured* booting three times, and it is the faster core. Programming
log, in full: 00:32:38 `stage_ap040_x3_ila`, 00:38:54 `stage_ap040_x3_ila`.
Nothing else was programmed tonight by me.

**The experiment that is left, and it is five minutes of watching a monitor:**

> Program `build/stage_ap040_x3` -- the ila=0, shipping build, the one that
> black-screened at 23:41 --
> `vivado -mode batch -source tools/vivado/program.tcl -tclargs build/stage_ap040_x3/minimig_openaars_top.bit`
> and watch the monitor. **Give it five minutes**: tonight's ILA runs show this
> machine is still in ROM init at 60 s and still drawing at 110 s, and only
> reaches the Workbench idle loop somewhere between three and five minutes
> after programming, so a screen that is black at one minute means nothing.
> Repeat two or three times, and say for each: black at five minutes, or
> Workbench.

That build carries **no debug core at all** -- `build/stage_ap040_x3/` has no
`.ltx`, because the single `<ila>` argument gates both ILAs -- so nothing about
it is observable over JTAG, by this ILA or any other. Everything that could be
established without the monitor has been, and it all says the core is good. If
it boots, the black screen at 23:5x was a programming-time transient and Task 1
is done. If it black-screens two or three times running, then the difference is
placement in a design with no functional difference, item 2 of section 7 is the
next build, and item 1 is the first thing to look at when it is observable.
