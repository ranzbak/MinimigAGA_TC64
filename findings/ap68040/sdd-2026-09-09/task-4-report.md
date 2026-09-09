# Task 4 report — one cadence source, the chip-select contract, and the five-phase experiment

**Outcome: DONE_WITH_CONCERNS.** The cadence has one source, shared by RTL and
bench; the address/select contract is enforced on both RAM ports in both its
halves, and both halves are shown to have teeth; the five-phase experiment
**refutes** the `slower` hypothesis — five phases with `"0111"` untouched pass
the bench cleanly. The RTL is left at four phases and `slower` is untouched, as
the brief's step 3 directs.

---

## 1. The cadence module

`rtl/sdram/cpu_enable_cadence.v` (new, 78 lines, most of them the comment that
says why it exists).

```verilog
module cpu_enable_cadence (
    input  wire [ 4-1:0] phase,       // sdram_state, 0..15
    output wire          ena_cpu,     // next enaWRreg
    output wire          ena7rd,      // next ena7RDreg
    output wire          ena7wr       // next ena7WRreg
);
assign ena_cpu = (phase == 4'd2) || (phase == 4'd6) ||
                 (phase == 4'd10) || (phase == 4'd14);
assign ena7rd  = (phase == 4'd6);
assign ena7wr  = (phase == 4'd14);
endmodule
```

Purely combinational, no state, no reset. It produces the **next** value of each
enable from the **current** phase, because that is how `sdram_ctrl` has always
registered them (`case(sdram_state) ph2: enaWRreg <= 1'b1;` makes `enaWRreg`
high during ph3). Consumers keep their own registers, so nothing about the
timing moved and the module costs no flops.

The header records the two things a reader has to know before touching the
phase list: what the five-phase variant is and why it needs `chipset_done`, and
that the *spacing* is what `cpu.xdc`'s multicycle exceptions and `TG68K.vhd`'s
`slower` shift register both depend on.

### Consumer 1 — `rtl/sdram/sdram_ctrl.v`

The `case(sdram_state)` in the write/read control block is gone; the three
registers stay exactly where they were:

```verilog
cpu_enable_cadence cadence (
    .phase   (sdram_state    ),   // LATENCY=3
    .ena_cpu (cadence_ena_cpu),
    .ena7rd  (cadence_ena7rd ),
    .ena7wr  (cadence_ena7wr )
);

always @ (posedge sysclk) begin
    if(!reset_sdstate) begin
        enaWRreg  <= #1 1'b0;  ena7RDreg <= #1 1'b0;  ena7WRreg <= #1 1'b0;
    end else begin
        enaWRreg  <= #1 cadence_ena_cpu;
        ena7RDreg <= #1 cadence_ena7rd;
        ena7WRreg <= #1 cadence_ena7wr;
    end
end
```

The reset arm is unchanged, so `reset_sdstate` still forces all three low. The
`ph0..ph15` localparams stay (the rest of the module uses them); the module
takes the raw 4-bit `sdram_state`, which is the same encoding.

### Consumer 2 — `sim/ddr3_cpu/ddr3_cpu_tb.sv`

The bench keeps its own sixteen-phase counter `ph` and its own three registers —
that is the part that models where `sdram_ctrl` puts its flops — and drops the
hand-copied phase list:

```systemverilog
cpu_enable_cadence cadence (.phase(ph), .ena_cpu(cad_ena_cpu),
                            .ena7rd(cad_ena7rd), .ena7wr(cad_ena7wr));
always @(posedge clk) begin
  if (!sdctl_rst) begin ph <= 4'd0; ena28 <= 1'b0; ... end
  else begin
    ph        <= ph + 4'd1;
    ena28     <= cad_ena_cpu;
    ena7RDreg <= cad_ena7rd;
    ena7WRreg <= cad_ena7wr;
  end
end
```

**No restructuring of `sdram_ctrl`'s state machine was needed** — the extraction
is exactly the case statement, nothing else moved.

### Proof the bench really uses it

Two independent checks:

* The four-phase legs' timestamps moved from the five-phase reference (table in
  §3) — if the bench were still on its old copy they would not have.
* The five-phase experiment (§5) reproduced the task-3 five-phase log **to the
  picosecond** on all seven phase markers. That is a stronger check than "the
  numbers moved": it says the shared module at 2/5/8/11/14 is bit-identical in
  behaviour to the bench's old hand-written list, so the extraction did not
  quietly change the cadence.

## 2. How the file reaches the Vivado project

`rtl/sdram/sdram_ctrl.v` is **not** listed in `tools/vivado/build.tcl` — it has
been in `project_1/project_1.xpr`'s `sources_1` fileset since long before that
script existed, so there was no pattern to copy for "a file that lives next to
sdram_ctrl". `project_1.xpr` is untracked and does not pick up new files on its
own, so a new RTL file that nothing adds is simply not compiled.

The AP040 block (`build.tcl` ~line 81-95) does it with the guarded `add_src`
helper, and that is what the new file uses too — `tools/vivado/build.tcl`, added
just above the AP68040 section:

```tcl
add_src $R/rtl/sdram/cpu_enable_cadence.v
```

`add_src` is idempotent (it checks `get_files -quiet -of_objects [get_filesets
sources_1]` first), so the next `vivado -mode batch -source tools/vivado/build.tcl`
adds it to the project and every run after that changes nothing. **No Vivado was
run in this task**, so the project on disk does not have the file yet; the
controller's next build is what puts it there. If someone opens the GUI project
and synthesises without running `build.tcl` first, synthesis stops with
"module cpu_enable_cadence not found" — a hard error, not a silent black box.

Every other source list that already carried `sdram_ctrl.v` or the DDR3 CPU
bench got the file too:

| List | Line added |
|---|---|
| `sim/ddr3_cpu/run.sh` | `echo "verilog work \"$R/rtl/sdram/cpu_enable_cadence.v\"" >> $PRJ`, before `cpu_cache_new.v` |
| `sim/sdram_timing/run.sh` | added to the iverilog file list next to `sdram_ctrl.v` |
| `bench/cpu_cache_sdram_verilator/Makefile` | added to `HDL_FILES` next to `sdram_ctrl.v` |
| `rtl/sdram/sdram.qip` | `set_global_assignment -name VERILOG_FILE ... cpu_enable_cadence.v` (the Quartus/DE10 path) |

The two non-xsim lists were not exercised in this task (no iverilog or verilator
run was in scope); the module compiles standalone under `iverilog -g2012`, which
is the flow `sim/sdram_timing` uses.

## 3. Four-phase gate (step 1)

Both legs run one at a time, `LD_LIBRARY_PATH` shim, no `-stack`, no Vivado
synthesis. Logs archived at `.superpowers/sdd/plan-v2-with-ddr3/task-4-logs/`.

| Leg | Result | Notes |
|---|---|---|
| `./run.sh` (TG68K) | `DDR3 CPU TB: 2 passed, 0 failed` | `tg68k_4ph.log` |
| `./run.sh --ap040` | `DDR3 CPU TB: 2 passed, 0 failed` | `ap040_4ph.log`; fills 83 / 1 undecoded / 5 adapter / 0 berr — identical to the five-phase reference |

### Phase timestamps, four phases vs the five-phase reference

Reference = the task-3 logs saved aside before the first run, at
`.superpowers/sdd/plan-v2-with-ddr3/task4-fivephase-ref/`.

TG68K (`./run.sh`), picoseconds:

| Phase | 5-phase ref | 4-phase now | Δ |
|---|---|---|---|
| 1 | 66,522,397 | 67,042,482 | +0.8 % |
| 2 | 182,765,802 | 208,011,962 | +13.8 % |
| 3 | 533,391,242 | 639,946,962 | +20.0 % |
| 4 | 607,525,392 | 729,331,062 | +20.0 % |
| 5 | 616,692,992 | 740,473,222 | +20.1 % |
| 7 | 708,651,072 | 851,542,222 | +20.2 % |
| 8 | 721,485,712 | 868,149,682 | +20.3 % |

AP68040 (`./run.sh --ap040`), picoseconds:

| Phase | 5-phase ref | 4-phase now | Δ |
|---|---|---|---|
| 1 | 74,790,867 | 77,373,662 | +3.5 % |
| 2 | 472,999,677 | 575,139,082 | +21.6 % |
| 3 | 1,425,892,362 | 1,757,547,922 | +23.3 % |
| 4 | 1,613,475,562 | 1,989,981,842 | +23.3 % |
| 5 | 1,634,552,227 | 2,016,215,282 | +23.4 % |
| 7 | 1,900,950,342 | 2,347,059,862 | +23.5 % |
| 8 | 1,933,213,242 | 2,387,397,302 | +23.5 % |

Four enables instead of five is a 20 % lower enable rate, so ≈ +20 % on a
purely enable-bound program is exactly right; the AP68040's +23.5 % is larger
because a slower enable also rounds each memory handshake up to the next enable,
which is the effect D2 exists to remove. Phase 1 barely moves because it is
mostly the fixed DDR3 init wait before the CPU is released.

## 4. The contract, and the assertion

Stated exactly, from `rtl/sdram/sdram_ctrl.v:226` / `:240` and
`rtl/ddr3/ddr3_fastram.v:20-23` / `:220`:

> `cpuAddr[25:1]` must be stable **one cycle before** `cpustate[2]` goes low.

and — the half the headers imply but do not spell out — both controllers do

```verilog
always @(posedge sysclk) cpuAddr_r <= cpuAddr;   // unconditional, every clock
```

and it is `cpuAddr_r`, not the live address, that is latched into `slot1_addr` /
`slot2_addr` (`sdram_ctrl.v:622-627`, `:748-752`) and into `cdc_addr` /
`burst_first` (`ddr3_fastram.v:342-345`) when the sixteen-phase round finally
reaches the CPU's slot — which can be many clocks after the select opened. So
the address must also **hold for as long as the select is low**. After `cpuena`
nothing is required: the wrapper's next enable is what moves the address, and
that is the same edge the select closes on.

Both halves are one rule: *while `cpustate[2]` (resp. `ddrcs`) is low, the
address equals the address of the previous clock.*

### Status: extended, as the addendum allows

Task 3's assertion (`sim/ddr3_cpu/ddr3_cpu_tb.sv`, the "memory port's
address/select contract" block) covered only the falling edge. It was **not**
duplicated; the same block gained the held-low half and a second counter,
`port_hold_errs`, with its own summary paragraph:

```
DDR3 CPU TB: FAIL  %0d cycles with the address moving while a chip select was low;
       the controllers re-register cpuAddr every clock, so the access ends up
       reading or writing the wrong line
```

`port_hold_errs` increments `nfail`, so it fails the **summary line**
(`DDR3 CPU TB: N checks failed`), which is what `run.sh`'s mutant guard tests.

### Both halves have teeth — shown, not argued

Each half was broken on its own in a copy of the wrapper fed in through `PREB1`
(no working-tree source was touched), at reduced region sizes for speed.

| Mutant | What it breaks | Result |
|---|---|---|
| **late chip select** — `ramcs`/`ddrcs` take a registered `slower(0)`, so the select closes one cycle after the address moves | the setup half | `DDR3 CPU TB: FAIL 335 chip selects opened without a settled address`, `4 checks failed`, exit 1 — `teeth_latecs.log` |
| **late address** — a four-deep pipeline on `ramaddr`/`ddraddr` only, so the address moves one cycle *inside* the select-low window | the hold half | `DDR3 CPU TB: FAIL 7651 cycles with the address moving while a chip select was low`, `3 checks failed`, exit 1 — `teeth_lateaddr.log` |

One earlier attempt is worth recording because it is a trap: removing
`fl_bstate <= "01"` from the fill router's `FL_SEL` (so the select is not closed
when `fl_busaddr` advances) corrupted memory and hung, but produced **zero**
contract failures. The reason is that with `mem_ready` stuck high, `bus_ready`
goes high and the next `clkena` reloads `slower`, so the select still closed on
the same edge the address moved — the mutation broke the fill and kept the
alignment. A mutant that fails is not automatically a mutant that fails *for the
reason you meant*.

## 5. The five-phase experiment (step 3)

One variable. `rtl/sdram/cpu_enable_cadence.v`'s `ena_cpu` list changed from
2/6/10/14 to 2/5/8/11/14 — four lines, nothing else in the tree touched.
`slower` left at `"0111"`. `ena7rd`/`ena7wr` untouched at ph6/ph14. `clkena`
untouched. Then `./run.sh --ap040`.

**The assertion did NOT fire. The run passed.**

```
INFO: program phase 1 at 74790867.0 ps
INFO: program phase 2 at 472999677.0 ps
INFO: program phase 3 at 1425892362.0 ps
INFO: program phase 4 at 1613475562.0 ps
INFO: program phase 5 at 1634552227.0 ps
INFO: program phase 7 at 1900950342.0 ps
INFO: program phase 8 at 1933213242.0 ps

DDR3 CPU TB: PASS  (68k program completed all phases)

INFO: checking the DDR3 array through the Micron model backdoor
PASS: DDR3 array contents match the pattern (independent backdoor read)

INFO: cache line fills -- 83 over the channel (1 of them undecoded, auto-completed), 5 down the adapter, 0 bus errors

DDR3 CPU TB: 2 passed, 0 failed
```

(`task-4-logs/ap040_5ph.log`.) No `port_setup_errs`, no `port_hold_errs`, no
`ack_idle_errs`, no `ack_dry_errs`, fill counters identical to the four-phase
and to the task-3 reference.

Every one of those seven timestamps is **identical to the task-3 five-phase
reference log** (`task4-fivephase-ref/xsim_run_pass_ap040.log`), to the
picosecond. That is the independent confirmation that the extracted module at
five phases is behaviourally the same cadence the bench used to write by hand.

### Verdict: the `slower` hypothesis is refuted

Per the brief's step 3, this stops the experiment. The cadence was put back to
four phases (`git diff` on `cpu_enable_cadence.v` is empty against the step-1
commit), **`TG68K.vhd` was not touched at all**, and step 4's `"0011"` reload
and its six-plus-two-leg gate were not run.

Why the mechanism does not hold up, now that the numbers are in — the plan's
sentence is "at a three-cycle spacing the select opens on the very cycle the
next enable can release the CPU". Tracing the actual shift register: `clkena` at
cycle *N* loads `"0111"`, so `slower(0)` is 1 at *N+1*, *N+2*, *N+3* and 0 at
*N+4* — the select opens at *N+4*. At **four** phases the next enable is also at
*N+4*, so the coincidence the note worries about is what the **booting** design
already does. At five phases the enables are at *N+3* and *N+6*, so the select
opens *between* them and the coincidence is gone. `"0011"` would restore it (open
at *N+3*). So the hypothesis has the sign backwards, and the bench agrees: with
five phases the contract is never violated, on either port, in either half, over
83 line fills and the whole pattern program.

That does **not** explain why the five-phase bitstream hangs in
expansion.library's ConfigDev walk. It does say the next lever is somewhere this
bench cannot see — the plan's own list of what the bench does not model
(chipset-bus timing, autoconfig, the real Kickstart) is where to look, and that
is the controller's call, not this task's.

## 6. Files changed and commits

**Commit 777b8a0** — *One source for the CPU enable cadence, and the other half
of the address contract*

| File | Change |
|---|---|
| `rtl/sdram/cpu_enable_cadence.v` | **new** — the phase list, combinational |
| `rtl/sdram/sdram_ctrl.v` | case statement → module instance; registers unmoved |
| `sim/ddr3_cpu/ddr3_cpu_tb.sv` | hand-copied list → module instance; hold half of the assertion + `port_hold_errs` + its summary paragraph |
| `sim/ddr3_cpu/run.sh` | new file in the `.prj` |
| `sim/sdram_timing/run.sh` | new file in the iverilog list |
| `bench/cpu_cache_sdram_verilator/Makefile` | new file in `HDL_FILES` |
| `rtl/sdram/sdram.qip` | new file in the Quartus list |
| `tools/vivado/build.tcl` | `add_src` for the new file |
| `sim/ddr3_cpu/xsim_run_pass.log`, `xsim_run_pass_ap040.log` | the two four-phase gate logs |

**Commit b7680d4** — *The slower hypothesis for D1 is refuted: five phases pass
the contract* — `findings/ap68040/plan-v2-with-ddr3.md` only: the Log paragraph
and the D1 row status text. No RTL in it, so commit 777b8a0 (the refactor) is
separable if the experiment record ever has to be dropped.

`.superpowers/` is in `.gitignore` (as it was for tasks 1-3), so this report,
`task-4-logs/` and `task4-fivephase-ref/` live in the working tree and are not
committed.

Not staged, left alone as instructed: `fw/ctrl_832/version.h`,
`sim/hostcpu-i2c-bridge/*.wcfg`, `tools/vivado/ila_fastram_check.py`,
`EightThirtyTwo`, and every untracked scratch file. The other
`sim/ddr3_cpu/xsim_run_*.log` files (`mmu`, `lwmutant`, `mmumutant`,
`chipbus`, `nofill`, `fillmutant`, `mutant`) were **not** re-run and are
therefore left as they were — see the concerns.

## 7. Self-review

* **One cadence source** — yes; both consumers instantiate it; `sdram_ctrl`'s
  state machine was not restructured, only the case statement moved.
* **File reaches the project** — `add_src` in `build.tcl`, plus all four other
  source lists. Stated explicitly in §2 that no Vivado ran, so the `.xpr` gets
  it on the controller's next build.
* **Four-phase legs green with moved timestamps** — yes, both, table in §3.
* **Assertion extended or justified** — extended (the hold half), and both
  halves proven live by separate mutants rather than asserted to work.
* **Five-phase result recorded either way** — recorded as refuted, with the log.
* **Commits separable** — yes: RTL+bench refactor first, experiment record
  second, no RTL in the second.
* **`clkena` untouched** — confirmed; `git diff` never touched `rtl/soc/TG68K.vhd`
  in either commit. The mutants that do touch it are `PREB1` copies in the
  scratch directory, not in the tree.
* **Nothing beyond the brief** — the two teeth mutants are the one addition, and
  they exist to make "the assertion did not fire" mean something.

## 8. Concerns

1. **The five-phase build still does not boot and this task did not find out
   why.** The one written-down hypothesis is now excluded. The bench is a
   better instrument than it was — it has the contract, on both ports, in both
   halves — and it still says nothing is wrong at five phases. The next
   candidate has to come from something the bench does not model.
2. **Only two of the eight legs were re-run.** Step 4's full set was gated on
   the assertion firing, and it did not, so `--chipbus`, `--mmu`, `--lwmutant`,
   `--mmumutant`, `--fillmutant` and `--nofill` still carry their pre-task-4
   logs in the tree. The cadence module is a behaviour-preserving refactor at
   four phases and the two legs that were run cover both cores and the fill
   channel, so I do not expect surprises — but the six stale logs are stale, and
   a full sweep before the next bitstream would be cheap insurance.
3. **`fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` is still at `-setup -start 3 /
   -hold -start 2`**, which is D1's tighter value and is harmless at four
   phases. The brief said to leave it; it is left. It is now the only place in
   the tree that still assumes five phases.
4. **The Quartus/DE10 and verilator lists were updated but not exercised.** The
   module compiles under `iverilog -g2012`; nobody ran the DE10 flow.
