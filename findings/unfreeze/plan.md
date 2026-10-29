# Free-running pipelined core (no freeze during memory operations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Today the pipelined AP68040 core stops completely while any access on the wrapper's master channel (`m_*`) is outstanding, and a store costs about 8.7 clocks. After this plan the pipelined core runs on every clk_38 edge and stalls on its own acknowledges, as its design intends and as apolkosnik's MiSTer wrapper runs it (eefc5367). The reference core is unchanged.

**Architecture:** One `clkena` register in `rtl/soc/TG68K.vhd` (`clkena_r <= cpu_ph AND bus_release`) enables everything today: the core, the MMU walker bridge and the 16-bit adapter. A new generic, `ap040_free_core`, gives the pipelined core its own enable. That enable is constant `'1'`, because `cpu_ph` already marks every clk_38 edge, so without `bus_release` the enable is high on all of them. The walker bridge and the adapter keep `clkena`. Two of their answers are levels that only clear on the next `clkena` edge: the adapter's `mem_ack`, and the walker's `wk_ack`/`wk_berr`. A free-running core would take such a level twice. So the core sees them qualified by `bce_q` (= `clkena` one clk_cpu edge ago), which makes each one a single-clock pulse. The router's `x_ack_r` is already a single-clock pulse. Everything stays inside `TG68K.vhd`, the tops and the build script. No submodule changes.

**Tech Stack:** VHDL (`rtl/soc/TG68K.vhd`), Verilog (tops), SystemVerilog + Vivado 2023.2 xsim (`sim/ddr3_cpu`), vasm (68k test program), Vivado 2023.2 build and JTAG.

**Spec:** this conversation's decision (Paul, 2026-09-26): "spending our energy at keeping the core from freezing during memory operations is the best place to start". Evidence and alternatives: `findings/ap040-pipelined/upstream-mister-optimizations.md` (P1, P2, C9, R1, "Direction"), and `findings/ap040-pipelined/PLAN.md` M11.2 and the M14 closing row ("the biggest remaining cost on SysInfo's loop is the core FROZEN while m_* drains a store (13.8 % on the SoC bench), which needs TG68K.vhd's master-channel handshake to tolerate a free-running core").

---

## Why, in numbers (the baseline this plan must beat)

`sim/ddr3_cpu/run_perf_si_ddr3_cur_9efe` is SysInfo 4.4's SPEED loop on the SoC bench (the real `TG68K.vhd`, `sdram_ctrl`, the DDR3 island, IE+DE, MMU off), tree 5.0-040-pipelined with core 9efe490, rerun 2026-09-26. It is identical to the post-M14 run `run_perf_si_ddr3_m14_4fbc` clock for clock:

```text
PERF ddr3_cpu: 6790 clocks, 2541 instructions, CPI 2.672
PERF   frozen (enable low, m_* busy): store 935 (13.8%)  other 24 (0.4%)
PERF   retire 2541 (37.4%)  store-hold 495 (7.3%)  EX busy 120 (1.8%)  EAF->EX transit 1270 (18.7%)
PERF   data-read wait 619 (9.1%)  EA-fetch other 405 (6.0%)  EA-calc/ID 165 (2.4%)  queue-only 206 (3.0%)
PERF   core port transfers: fetch 8  read 120  store 164;  m_* channel: writes 165
```

The same loop on ideal memory runs at CPI 1.68, and a 25 MHz 68040 runs it at about 1.6. Stores cost (935 + 495) / 164 ≈ 8.7 clocks each. Reads that miss the M14 fast path because a store is in flight cost about 5.2 clocks each. The 68040 buffers its stores at no cost to the pipeline (IEEE Micro, Feb/Jun 1990).

## What changes, and what does not

| Thing | Today | After (`ap040_free_core = 1`) |
|---|---|---|
| Pipelined core + MMU + caches (`ap040_pipe_tg68k_compat`, `clkena_in`) | `clkena` (frozen while `m_*` is outstanding) | `'1'`: every clk_38 edge |
| Walker bridge FSM (TG68K.vhd `wk_st`) | `clkena` | `clkena` (unchanged) |
| 16-bit adapter (`bus16`) | `clkena` | `clkena` (unchanged) |
| `slower`, chipset FSM, `chipset_done`, `x_ack_r`, `q_req`, `x_fresh` | `clkena`/`clkena_r` | unchanged |
| Core's `m_ack` | `x_ack AND NOT wk_go` | `(a16_ack AND bce_q OR x_ack_r) AND NOT wk_go` |
| Core's `m_rdata` | `a16_rdata` when `a16_ack`, else `x_rdata_r` | `a16_rdata` when `a16_ack AND bce_q`, else `x_rdata_r` |
| Core's `walker_ack` / `walker_berr` | `wk_ack` / `wk_berr` | `wk_ack AND bce_q` / `wk_berr AND bce_q` |
| Reference core (`g_ref`) | all of the above on `clkena` | unchanged; the generic is refused for it |

**The invariant the whole crossing rests on.** Read `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` lines 140-205 and `TG68K.vhd` near `q_req` (about line 845). The clk_38 → clk_114 multicycle of 2, the `q_req`/`x_fresh` masks and the `sel_undecoded_d` argument all assume one thing: **x_\* changes only on a clk_38 edge where `clkena_r` is high.** Today that holds because the frozen core cannot change anything elsewhere. With a free core it should still hold. While no request is outstanding, `bus_release` is high, so `clkena_r` is high on every clk_38 edge. While a request is outstanding, the cache holds `m_*` until the acknowledge edge, and that edge has `clkena_r` high. Task 1 turns this from an argument into a sim assertion (FC-1). **If FC-1 ever fires with the free core, stop: the XDC derivation no longer holds.**

## Global Constraints

- Never `git push`. Never write the SPI flash; JTAG (volatile) loads only, and only when Paul is at the board and says so.
- Never stage the five always-dirty files (`fw/ctrl_832/version.h`, `fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`, `fw/ctrl_boot_832/rom_prologue.vhd`, `sim/hostcpu-i2c-bridge/i2c_bridge_tb_behav.wcfg`, `tools/vivado/ila_fastram_check.py`). Always `git add <explicit paths>`. The two generated 832 firmware files DO go into the bitstream, so build in the main checkout, not in a worktree.
- Only the QMTech target (`fpga/openaars`, `project_1`) is built and must keep working.
- Do not modify any submodule (`lib/AP68040`, `lib/AP68040-pipelined`, `rtl/tg68k`, `EightThirtyTwo`). Every change is in `rtl/soc/TG68K.vhd`, `rtl/soc/minimig_virtual_top.v`, `rtl/soc/minimig_openaars_top.v`, `tools/vivado/build_ap040.tcl`, `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` (comments only), `sim/ddr3_cpu/*`, `findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh` and `findings/unfreeze/*`.
- `ap040_free_core` defaults to **0** everywhere. With 0, the design must be behaviourally identical to today; Task 3 proves it clock for clock.
- sim/ddr3_cpu: legs strictly ONE AT A TIME, ALWAYS with `RUNTAG=<word>` (ten reference logs are tracked), ALWAYS with `PIPELINED=1 PIPE_DIR=<main checkout>/lib/AP68040-pipelined` (run.sh's default `PIPE_DIR` is the sibling clone, not the submodule). Judge the summary line `DDR3 CPU TB: 2 passed, 0 failed`, never the program's own `PASS`. Never edit `run.sh` while a leg is running. Read `memory/sim-ddr3-cpu-bench-traps.md` first. A default leg takes 15-20 minutes; the perf leg about 5.
- Vivado: `env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal ...`, never `-stack`; use `LC_ALL=C LANG=C` if xsim is running at the same time. Builds never run two at once (they share `project_1`).
- Board work (video, OSD, disks, demos, power cycling) is Paul's. Before blaming the core for a demo, retry with Turbo chip/kick off. No HDMI right after a JTAG load can just need a board power cycle.
- **Stop rules.** (a) FC-1 fires with the free core: stop and report. (b) A free-core leg fails and the cause is not a bench artefact from the traps memory within one investigation: stop and report. (c) The perf leg's CPI with the free core is not at least 3 % below 2.672: stop and report before building. (d) Routed timing with the free core has more failing endpoints than the matching `ap040_free_core = 0` build: stop and report.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

The five inputs or conditions most likely to bite that no single task's main test covers, and where each is pinned:

1. **Chipset DMA running flat out while the free core posts stores into chip RAM.** Posted-store ordering against DMA must hold. Pinned: Task 4 runs `--snoop` with `DMA_OVERLAP=1` on the free core.
2. **A clock ratio other than 3.** The bench supports `CPU_RATIO=4`, and `cpu_ph` is ratio-dependent. Pinned: Task 4 runs one `CPU_RATIO=4 --ap040` leg on the free core (informative; the board uses 3).
3. **Reset while an access is outstanding.** `bce_q` and the walker and adapter all reset together, and nothing may take a stale acknowledge after reset. Pinned: Task 3 gives `bce_q` an asynchronous reset; Task 6's checklist has an OSD reset under load on the board.
4. **An interrupt or STOP while a posted store is draining.** The core now runs through that window. Pinned: Kickstart boot to the idle STOP, plus cputest ct040_01, on the board (Task 6).
5. **An MMU table walk while a posted store is still draining.** `walk_hold(post_busy)` must keep ordering; the walker's `wk_ack` is now qualified. Pinned: Task 4 runs `--mmu` on the free core, plus the walker mutant.

---

## Files

| File | Change | Task |
|---|---|---|
| `sim/ddr3_cpu/ddr3_cpu_tb.sv` | monitors FC-1..FC-4; `+FCTEST` handling; status codes 30-33; `FREECORE` generic | 1, 2, 3 |
| `sim/ddr3_cpu/asm/freecore_test.asm` | new: back-to-back adapter/router accesses, caches off | 2 |
| `sim/ddr3_cpu/asm/build_68k_test.sh` | `-m68040` for `freecore_test.asm` too | 2 |
| `sim/ddr3_cpu/run.sh` | `--fcprog`, `FREECORE=1`, `FCMUTANT=ack\|walk\|data` | 2, 3, 4 |
| `rtl/soc/TG68K.vhd` | generic `ap040_free_core`; `bce_q`; `pc_*` signals; `g_pipe` port map; assert | 3 |
| `findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh` | pass `-d FREECORE` | 4 |
| `rtl/soc/minimig_virtual_top.v`, `rtl/soc/minimig_openaars_top.v` | pass the generic down | 5 |
| `tools/vivado/build_ap040.tcl` | `FREE_CORE=<0/1>` build switch | 5 |
| `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` | comments only: the invariant is now asserted in sim, and the clkena fan-out note | 5 |
| `findings/unfreeze/results.md`, `findings/unfreeze/hw-checklist.md` | new | 4, 5, 6 |

Shell shorthands used by every task (set them once per shell):

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
export LD_LIBRARY_PATH=$HOME/lib/tinfo5
ROOT=$PWD
P="PIPELINED=1 PIPE_DIR=$ROOT/lib/AP68040-pipelined"
S=/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/7a74dad0-cd96-4d4d-94c2-f7d9a512b738/scratchpad/sysinfo/SysInfo/SysInfo
# if $S is gone: mkdir -p /tmp/si && (cd /tmp/si && 7z x /home/paul/work/amiga/SysInfo.lha) && S=/tmp/si/SysInfo/SysInfo
```

---

### Task 1: The free-core monitors in sim/ddr3_cpu, green on today's tree

**Files:**
- Modify: `sim/ddr3_cpu/ddr3_cpu_tb.sv` (next to `mux_excl_errs`/`ack_ena_errs`, about lines 1310-1345; the summary block about line 1719)

**Interfaces:**
- Consumes: VHDL architecture signals of `TG68K`, reached as `tg68k.<name>` (the bench already does this: `tg68k.wk_go`, `tg68k.x_ack_r`, `tg68k.m_req`, `tg68k.clkena_r`). Task 1 uses `tg68k.clkena`, `tg68k.x_req`, `tg68k.x_we`, `tg68k.x_instr`, `tg68k.x_size`, `tg68k.x_addr`, `tg68k.x_wdata`, `tg68k.m_req`, `tg68k.m_ack`, `tg68k.wk_req`, `tg68k.wk_ack`, `tg68k.wk_berr`.
- Produces: counters `fc1_errs`, `fc2_errs`, `fc2w_errs`, `fc3_errs`, `fc4_stale`, and the lines `DDR3 CPU TB: FAIL ...` for each non-zero error counter. Task 3 re-points the ack/ce names at `tg68k.pc_*` through the macros below, so the monitors watch exactly what the core takes.

- [ ] **Step 1: Create the branch**

```bash
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64
git switch -c unfreeze 5.0-040-pipelined
git status --short   # only the five always-dirty files and untracked clutter
```

- [ ] **Step 2: Add the monitors**

Insert after the `ack_ena_errs` `always` block:

```systemverilog
//-----------------------------------------------------------------
// Free-core monitors (findings/unfreeze/plan.md).  All on clk_cpu edges
// after reset.  FC_CE/FC_ACK/FC_WACK/FC_WBERR are what the CORE takes; until
// Task 3 they are the shared names, afterwards TG68K's pc_* signals.
//   fc1_errs  x_* changed on a clk_cpu edge where clkena was low.  cpu.xdc's
//             clk_38 -> clk_114 multicycle and the q_req/x_fresh masks rest
//             on "x_* changes only where clkena_r is high".  A free core must
//             not break it; if this fires, the crossing derivation is void.
//   fc2_errs  the core took m_ack on two consecutive clk_cpu edges.  No
//             completion is that fast (q_req is masked for two clk_114 edges
//             after every take), so two in a row is one answer taken twice.
//   fc2w_errs the same for the walker's answer (walker_ack or walker_berr).
//   fc3_errs  FREECORE only: an acknowledge visible to the core with no
//             request of its own up (e.g. a stale adapter ack left over from
//             a walker access).
//   fc4_stale informational: clk_cpu edges where the adapter's mem_ack is
//             high, the core's request is up, and the core must NOT take it
//             (bce_q low).  Zero means a stale level never met a waiting
//             core in this leg, i.e. an ack mutant cannot be observed here.
//-----------------------------------------------------------------
`ifndef FC_CE
`define FC_CE    tg68k.clkena
`define FC_ACK   tg68k.m_ack
`define FC_WACK  tg68k.wk_ack
`define FC_WBERR tg68k.wk_berr
`endif
integer fc1_errs = 0, fc2_errs = 0, fc2w_errs = 0, fc3_errs = 0, fc4_stale = 0, fc_takes = 0;

// Every input is captured on the clk (clk_114) NEGEDGE.  clk_cpu's edges
// coincide with clk edges, and clkena_r and x_ack_r change on the very clk
// edge a clk_cpu edge lands on (TG68K.vhd: "clkena_r is high through
// (T+2,T+3) and the kernel advances at T+3"), so reading them at posedge
// clk_cpu is a scheduling race.  The last clk negedge before a clk_cpu edge
// holds exactly what the kernel samples at that edge.
reg        sh_ce = 1'b0, sh_ack = 1'b0, sh_wack = 1'b0, sh_wberr = 1'b0;
reg        sh_mreq = 1'b0, sh_wkreq = 1'b0, sh_ena = 1'b0;
reg        sh_a16 = 1'b0, sh_bce = 1'b0, sh_wkgo = 1'b0;
reg [68:0] sh_x;
always @(negedge clk) begin
  sh_ce    <= (`FC_CE    === 1'b1);
  sh_ack   <= (`FC_ACK   === 1'b1);
  sh_wack  <= (`FC_WACK  === 1'b1);
  sh_wberr <= (`FC_WBERR === 1'b1);
  sh_mreq  <= (tg68k.m_req  === 1'b1);
  sh_wkreq <= (tg68k.wk_req === 1'b1);
  sh_ena   <= (tg68k.clkena === 1'b1);
  sh_x     <= {tg68k.x_req, tg68k.x_we, tg68k.x_instr, tg68k.x_size,
               tg68k.x_addr, tg68k.x_wdata};
`ifdef FREECORE
  sh_a16   <= (tg68k.a16_ack === 1'b1);
  sh_bce   <= (tg68k.bce_q   === 1'b1);
  sh_wkgo  <= (tg68k.wk_go   === 1'b1);
`endif
end

reg [68:0] fc_x_prev;
reg        fc_x_prev_ena = 1'b0, fc_x_prev_v = 1'b0;
reg        fc_take_prev = 1'b0, fc_wtake_prev = 1'b0;
wire fc_take  = sh_ce && sh_mreq  && sh_ack;
wire fc_wtake = sh_ce && sh_wkreq && (sh_wack || sh_wberr);

always @(posedge clk_cpu) begin
  if (!tg68_rst) begin
    fc_x_prev_v   <= 1'b0;
    fc_take_prev  <= 1'b0;
    fc_wtake_prev <= 1'b0;
  end else begin
    // FC-1: sh_x differs from the previous edge's sample, so x_* changed at
    // the previous clk_cpu edge -- where the enable was fc_x_prev_ena.
    if (fc_x_prev_v && (sh_x !== fc_x_prev) && !fc_x_prev_ena) begin
      if (fc1_errs < 8)
        $display("FAIL: FC-1 x_* changed on a clk_cpu edge with clkena low (t = %t)", $time);
      fc1_errs = fc1_errs + 1;
    end
    fc_x_prev     <= sh_x;
    fc_x_prev_ena <= sh_ena;
    fc_x_prev_v   <= 1'b1;
    // FC-2
    if (fc_take && fc_take_prev) begin
      if (fc2_errs < 8)
        $display("FAIL: FC-2 m_ack taken on two consecutive clk_cpu edges (t = %t)", $time);
      fc2_errs = fc2_errs + 1;
    end
    if (fc_wtake && fc_wtake_prev) begin
      if (fc2w_errs < 8)
        $display("FAIL: FC-2 walker answer taken on two consecutive clk_cpu edges (t = %t)", $time);
      fc2w_errs = fc2w_errs + 1;
    end
    fc_take_prev  <= fc_take;
    fc_wtake_prev <= fc_wtake;
    if (fc_take) fc_takes = fc_takes + 1;
`ifdef FREECORE
    // FC-3
    if ((sh_ack && !sh_mreq) || (sh_wack && !sh_wkreq)) begin
      if (fc3_errs < 8)
        $display("FAIL: FC-3 an acknowledge visible to the core with no request up (t = %t)", $time);
      fc3_errs = fc3_errs + 1;
    end
    // FC-4
    if (sh_a16 && !sh_bce && sh_mreq && !sh_wkgo)
      fc4_stale = fc4_stale + 1;
`endif
  end
end
```

Sanity check of the sampling before trusting the monitors: the summary's `m_ack takes seen` count must be in the thousands on every leg (every instruction fetch with caches off, every line fill and store crosses `m_*`). A count of zero, or one far below the leg's traffic, means the negedge samples are misaligned: fix the sampling before going on, because FC-2 and FC-3 would pass vacuously.

In the summary block, after the `ack_ena_errs` check, add:

```systemverilog
  if (fc1_errs != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d x_* changes on an edge with clkena low (FC-1: the crossing invariant)", fc1_errs);
    nfail = nfail + 1;
  end
  if (fc2_errs != 0 || fc2w_errs != 0) begin
    $display("DDR3 CPU TB: FAIL  acknowledges taken twice (FC-2): m_ack %0d, walker %0d", fc2_errs, fc2w_errs);
    nfail = nfail + 1;
  end
  if (fc3_errs != 0) begin
    $display("DDR3 CPU TB: FAIL  %0d acknowledges visible with no request (FC-3)", fc3_errs);
    nfail = nfail + 1;
  end
  $display("INFO: free-core monitors: %0d m_ack takes seen; FC-4 stale adapter acks met by a waiting core: %0d",
           fc_takes, fc4_stale);
```

(FC-3 and FC-4 sit inside `` `ifdef FREECORE ``, which nothing defines until Task 3, and they use `tg68k.bce_q`, which exists only after Task 3.)

- [ ] **Step 3: Run the four baseline legs, one at a time, and check that the monitors are quiet**

```bash
cd $ROOT/sim/ddr3_cpu
env $P RUNTAG=uf1a ./run.sh --ap040
env $P RUNTAG=uf1b ./run.sh --mmu
env $P RUNTAG=uf1c ./run.sh --snoop
env $P RUNTAG=uf1d ./run.sh --ap040 --chipbus
for t in uf1a uf1b uf1c uf1d; do echo "== $t"; grep -hE 'DDR3 CPU TB: [0-9]+ passed|FAIL: FC-' $(ls -t *${t}*.log run_*${t}*/xsim.log 2>/dev/null | head -1); done
```
Expected: each leg ends `DDR3 CPU TB: 2 passed, 0 failed`, with no `FAIL: FC-` line. The frozen core cannot violate FC-1 or FC-2 by construction, so any failure here is a monitor bug: fix the monitor, not the RTL. (Where RUNTAG puts the log: the traps memory, item 8.)

- [ ] **Step 4: Check that the existing `--ackmutant` still fails**

```bash
env $P RUNTAG=uf1m ./run.sh --ackmutant 2>&1 | tail -3
```
Expected: run.sh reports that the mutant failed as required. Note whether FC-2 fired. That's informative, not required, because the frozen core samples only on `clkena` edges.

- [ ] **Step 5: Commit**

```bash
cd $ROOT
git add sim/ddr3_cpu/ddr3_cpu_tb.sv
git commit -m "sim/ddr3_cpu: free-core monitors FC-1..FC-4 (the crossing invariant, one take per answer)

Green on the frozen core (4 legs); they exist for findings/unfreeze/plan.md.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: A directed program: answers from both sides of the wrapper, back to back

**Files:**
- Create: `sim/ddr3_cpu/asm/freecore_test.asm`
- Modify: `sim/ddr3_cpu/asm/build_68k_test.sh` (the `CPUOPT` line), `sim/ddr3_cpu/run.sh` (flag `--fcprog`), `sim/ddr3_cpu/ddr3_cpu_tb.sv` (`+FCTEST`, codes 30-33)

**Interfaces:**
- Consumes: the bench's mailbox protocol (`$1000` status: 1 = pass, else a code; `$1010` = phase), the undecoded address `$42000000`, which the adapter auto-completes with `$FFFFFFFF` (`ddr3_cpu_test.asm` phase 14), the DDR3 board at `$41000000`, and chip scratch at `$8000`.
- Produces: `./run.sh --fcprog` (implies `--ap040`, variant `fcprog_ap040`), plusarg `+FCTEST`, and tb variable `fctest`, which skips the pattern backdoor check and placement exactly as `mmutest` does.

- [ ] **Step 1: Write the program**

```asm
;-----------------------------------------------------------------------------
; freecore_test.asm -- sim/ddr3_cpu program for findings/unfreeze/plan.md.
; Back-to-back accesses whose answers come from different sides of
; rtl/soc/TG68K.vhd: the 16-bit adapter (the undecoded hole, auto-completed
; with $FFFF; chip-RAM words when run with --chipbus) and the router (the
; DDR3 board; chip-RAM longwords).  With a free-running core a stale adapter
; acknowledge, or the read-data mux choosing the adapter's old data, hands
; one access's answer to the next.  Caches OFF, so every access -- the
; instruction fetches too -- crosses m_*.
; Codes: 30 adapter then DDR3 read   31 DDR3 then adapter read
;        32 chip word then DDR3 read 33 DDR3 store, adapter access, DDR3 load
;        99 unexpected exception
;-----------------------------------------------------------------------------
MBOX      equ $00001000
STACKTOP  equ $00007000
DDRBASE   equ $41000000
UNDECODED equ $42000000
CHIPSCR   equ $00008000
          ifnd      NLONGS
NLONGS    equ 64
          endif

          org       $0
          dc.l      STACKTOP
          dc.l      START
          rept      254
          dc.l      EXCEPT
          endr

START:    moveq     #0,d0
          move.l    d0,MBOX
          move.l    d0,MBOX+4
          move.l    d0,MBOX+16
          movec     d0,cacr              ; caches off: everything crosses m_*
          movec     d0,tc

; phase 1: seed DDR3 with $D0000000+off and chip scratch with $C0000000+off
          moveq     #1,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          movea.l   #CHIPSCR,a1
          moveq     #0,d1
          move.w    #NLONGS-1,d6
seed:     move.l    d1,d2
          or.l      #$D0000000,d2
          move.l    d2,(a0)+
          move.l    d1,d2
          or.l      #$C0000000,d2
          move.l    d2,(a1)+
          addq.l    #4,d1
          dbra      d6,seed

; phase 2: adapter answer, then a router answer straight behind it
          moveq     #2,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p2:       move.l    UNDECODED,d3
          move.l    (a0)+,d4
          cmp.l     #$FFFFFFFF,d3
          bne       f30
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f30
          addq.l    #4,d1
          dbra      d6,p2

; phase 3: router answer, then the adapter's
          moveq     #3,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p3:       move.l    (a0)+,d4
          move.l    UNDECODED,d3
          cmp.l     #$FFFFFFFF,d3
          bne       f31
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f31
          addq.l    #4,d1
          dbra      d6,p3

; phase 4: a chip-RAM WORD (the adapter under --chipbus), then DDR3
          moveq     #4,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          movea.l   #CHIPSCR,a1
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p4:       move.w    2(a1),d3             ; low word = off
          move.l    (a0)+,d4
          cmp.w     d1,d3
          bne       f32
          move.l    d1,d5
          or.l      #$D0000000,d5
          cmp.l     d5,d4
          bne       f32
          addq.l    #4,a1
          addq.l    #4,d1
          dbra      d6,p4

; phase 5: DDR3 store (posted), adapter write and read, DDR3 load of it
          moveq     #5,d7
          move.l    d7,MBOX+16
          movea.l   #DDRBASE,a0
          moveq     #0,d1
          move.w    #NLONGS-1,d6
p5:       move.l    d1,d2
          or.l      #$E0000000,d2
          move.l    d2,(a0)
          move.w    d2,UNDECODED
          move.l    UNDECODED,d3
          move.l    (a0)+,d4
          cmp.l     #$FFFFFFFF,d3
          bne       f33
          cmp.l     d2,d4
          bne       f33
          addq.l    #4,d1
          dbra      d6,p5

          moveq     #1,d7
          move.l    d7,MBOX
done:     bra.s     done

f30:      moveq     #30,d7
          bra.s     report
f31:      moveq     #31,d7
          bra.s     report
f32:      moveq     #32,d7
          bra.s     report
f33:      moveq     #33,d7
report:   move.l    d1,MBOX+4            ; which longword
          move.l    d7,MBOX
halt:     bra.s     halt
EXCEPT:   moveq     #99,d7
          move.l    d7,MBOX
          bra.s     halt
```

- [ ] **Step 2: Assemble it for the 68040**

In `build_68k_test.sh`, replace

```bash
if [ "$SRC" = "mmu_walk_test.asm" ]; then CPUOPT=-m68040; fi
```
with
```bash
if [ "$SRC" = "mmu_walk_test.asm" ] || [ "$SRC" = "freecore_test.asm" ]; then CPUOPT=-m68040; fi
```

Run: `cd $ROOT/sim/ddr3_cpu/asm && BIN=/tmp/fc.bin SRC=freecore_test.asm ./build_68k_test.sh`
Expected: `ls -l` shows a binary of roughly 1.3 KB, with no vasm errors.

- [ ] **Step 3: Wire `--fcprog` into run.sh**

Next to the `--mmu` flag parsing (about lines 77-80):

```bash
IS_FC=0
if [ "$1" = "--fcprog" ];    then IS_FC=1;                   shift; set -- --ap040 "$@"; fi
```

In the variant naming (about line 128): `if [ "$IS_FC" = "1" ]; then VARIANT=fcprog_ap040; fi`

Replace the program build `if [ "$IS_MMU" = "1" ]; then ... else ... fi` (about line 203) with:

```bash
if [ "$IS_MMU" = "1" ]; then
    BIN="$W/prog.bin" SRC=mmu_walk_test.asm "$D/asm/build_68k_test.sh" \
        -DCACRVAL="$CACRVAL"
elif [ "$IS_FC" = "1" ]; then
    BIN="$W/prog.bin" SRC=freecore_test.asm "$D/asm/build_68k_test.sh"
else
    BIN="$W/prog.bin" "$D/asm/build_68k_test.sh" \
        -DPATBYTES=$PATBYTES -DMISLINES=$MISLINES -DCNTN=$CNTN -DCACRVAL="$CACRVAL" $C32PH \
        ${P7LOOPS:+-DP7LOOPS=$P7LOOPS} ${P2CBLOCK:+-DP2CBLOCK=$P2CBLOCK}
fi
```

After `if [ "$IS_MMU" = "1" ]; then PLUS="$PLUS +MMUTEST"; fi` add:
`if [ "$IS_FC" = "1" ]; then PLUS="$PLUS +FCTEST"; fi`

Add to the header's leg list: `#   ./run.sh --fcprog     AP68040, freecore_test.asm (findings/unfreeze/plan.md)`.

- [ ] **Step 4: Teach the bench `+FCTEST` and codes 30-33**

In `ddr3_cpu_tb.sv`: next to `integer mmutest = 0;` add `integer fctest = 0;`, and next to `mmutest = $test$plusargs("MMUTEST");` add `fctest = $test$plusargs("FCTEST");`. In the places that skip work for the MMU program, replace `mmutest` with `(mmutest || fctest)`:
- `if (mmutest) begin` before the DDR3 pattern check (about line 1646). Change its message to `"INFO: MMU walker or free-core program -- no pattern in the DDR3 to check"`.
- `if (!turbochipram || mmutest)` (placement, about line 1826). Make its display `(mmutest || fctest) ? "MMU or free-core program" : ...`.
- the two `!mmutest` terms at about lines 1853 and 1857, which become `!(mmutest || fctest)`.

In the status `case`, before `32'd99`:

```systemverilog
      // findings/unfreeze/plan.md, freecore_test.asm
      32'd30 : final_report(30, "adapter answer, then a DDR3 read: wrong value");
      32'd31 : final_report(31, "DDR3 read, then an adapter answer: wrong value");
      32'd32 : final_report(32, "chip-RAM word, then a DDR3 read: wrong value");
      32'd33 : final_report(33, "DDR3 store, adapter access, DDR3 load: wrong value");
```

- [ ] **Step 5: Run it on today's (frozen) core, both chip paths, one at a time**

```bash
cd $ROOT/sim/ddr3_cpu
env $P RUNTAG=uf2a ./run.sh --fcprog
env $P RUNTAG=uf2b ./run.sh --fcprog --chipbus
for t in uf2a uf2b; do echo "== $t"; grep -hE 'program phase|DDR3 CPU TB|FAIL: FC-' $(ls -t *${t}*.log run_*${t}*/xsim.log 2>/dev/null | head -1); done
```
Expected: phases 1-5 appear and each run ends `DDR3 CPU TB: 2 passed, 0 failed`. If code 32 fails only with `--chipbus`, check the bench's chip RAM handling of `$8000+` writes before suspecting the RTL.

- [ ] **Step 6: Prove the program can fail**

Temporarily change `or.l #$D0000000,d5` in phase 2 to `or.l #$D0000001,d5`, and run `env $P RUNTAG=uf2m ./run.sh --fcprog`.
Expected: `FAIL` with code 30 ("adapter answer, then a DDR3 read"). Revert the change; `git diff sim/ddr3_cpu/asm/freecore_test.asm` must show only the Step 1 file.

- [ ] **Step 7: Commit**

```bash
cd $ROOT
git add sim/ddr3_cpu/asm/freecore_test.asm sim/ddr3_cpu/asm/build_68k_test.sh sim/ddr3_cpu/run.sh sim/ddr3_cpu/ddr3_cpu_tb.sv
git commit -m "sim/ddr3_cpu: --fcprog, adapter and router answers back to back (codes 30-33)

Green on the frozen core with and without --chipbus.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The generic, off by default and identical to today

**Files:**
- Modify: `rtl/soc/TG68K.vhd` (generic list about line 55; signal declarations next to `x_ack` about line 428; the master-mux block after `m_rdata <= x_rdata;` about line 1515; the `g_pipe` port map lines `clkena_in` about 1393, `walker_ack`/`walker_berr` 1443/1445, `m_ack`/`m_rdata` 1492/1493)
- Modify: `sim/ddr3_cpu/ddr3_cpu_tb.sv` (the TG68K instance, about line 799; the `FC_*` macros), `sim/ddr3_cpu/run.sh` (`FREECORE`)

**Interfaces:**
- Consumes: `clkena`, `a16_ack`, `a16_rdata`, `x_ack_r`, `x_rdata_r`, `wk_ack`, `wk_berr`, `wk_go`, `m_ack`, `m_rdata`, `reset`, `clk_cpu` (all existing).
- Produces: generic `ap040_free_core : integer := 0`, and architecture signals `bce_q`, `a16_take`, `pc_ce`, `pc_ack`, `pc_rdata`, `pc_wk_ack`, `pc_wk_berr`. Each line that a mutant edits carries a marker comment `-- FC-ACK`, `-- FC-DATA` or `-- FC-WALK`, which Task 4's `sed` keys on. run.sh gets `FREECORE=1`, which adds `-d FREECORE` and the variant suffix `_free`.

- [ ] **Step 1: Add the generic** (after `ap040_pipelined : integer := 0;`)

```vhdl
		-- 1 (pipelined core only; findings/unfreeze/plan.md): the core runs on
		-- every clk_cpu edge instead of being frozen while an m_* access is
		-- outstanding.  The answers it takes from the clkena-gated side -- the
		-- adapter's mem_ack and the walker's wk_ack/wk_berr, LEVELS that clear
		-- only on the next clkena edge -- are qualified to one clock each.
		-- 0: the core shares clkena, exactly as before.
		ap040_free_core    : integer := 0;
```

- [ ] **Step 2: Declare the signals** (after `SIGNAL x_rdata ...`)

```vhdl
	-- ap040_free_core: what the pipelined core sees (see the master mux)
	SIGNAL bce_q      : std_logic := '0';               -- clkena one clk_cpu edge ago
	SIGNAL a16_take   : std_logic;
	SIGNAL pc_ce      : std_logic;
	SIGNAL pc_ack     : std_logic;
	SIGNAL pc_rdata   : std_logic_vector(31 downto 0);
	SIGNAL pc_wk_ack  : std_logic;
	SIGNAL pc_wk_berr : std_logic;
```

- [ ] **Step 3: Drive them** (directly after `m_rdata <= x_rdata;`)

```vhdl
		-- ap040_free_core (findings/unfreeze/plan.md).  a16_ack and wk_ack/
		-- wk_berr are set and cleared only on clkena edges, so a level can
		-- outlive the clk_cpu edge it was meant for.  A core that runs every
		-- clk_cpu edge would take it again as the answer to the access it
		-- started meanwhile -- the desync that made ap040_pipe_tg68k_compat.v
		-- re-gate ce_core to clkena_in (its comment at :160).  bce_q is high in
		-- the one clk_cpu cycle after an enabled edge, the only cycle in which
		-- such a level is fresh.  x_ack_r is a one-clk pulse already.  The same
		-- fix as apolkosnik's MiSTer wrapper, eefc5367.  The walker keeps the
		-- unqualified x_ack/x_rdata: it runs on clkena and samples only there.
		PROCESS(clk_cpu, reset)
		BEGIN
			IF reset = '0' THEN
				bce_q <= '0';
			ELSIF rising_edge(clk_cpu) THEN
				bce_q <= clkena;
			END IF;
		END PROCESS;

		a16_take   <= a16_ack AND bce_q;                                       -- FC-ACK
		pc_ce      <= clkena WHEN ap040_free_core = 0 ELSE '1';
		pc_ack     <= m_ack  WHEN ap040_free_core = 0 ELSE
		              (a16_take OR x_ack_r) AND NOT wk_go;
		pc_rdata   <= m_rdata   WHEN ap040_free_core = 0 ELSE
		              a16_rdata WHEN a16_take = '1'  ELSE                      -- FC-DATA
		              x_rdata_r;
		pc_wk_ack  <= wk_ack  WHEN ap040_free_core = 0 ELSE wk_ack  AND bce_q;   -- FC-WALK
		pc_wk_berr <= wk_berr WHEN ap040_free_core = 0 ELSE wk_berr AND bce_q;   -- FC-WALK
```

And, at architecture level (outside any process or generate), the guard:

```vhdl
	ASSERT ap040_free_core = 0 OR ap040_pipelined /= 0
		REPORT "TG68K: ap040_free_core = 1 needs ap040_pipelined = 1 (the reference core samples only on clkena)"
		SEVERITY failure;
```

- [ ] **Step 4: Point `g_pipe` at them.** In the `g_pipe` port map only, never in `g_ref`:

```vhdl
					clkena_in      => pc_ce,
					-- ...
					walker_ack     => pc_wk_ack,
					walker_berr    => pc_wk_berr,
					-- ...
					m_ack             => pc_ack,
					m_rdata           => pc_rdata
```

Then run `grep -n "clkena_in" lib/AP68040-pipelined/rtl/compat/ap040_pipe_tg68k_compat.v`. Expected: the port declaration, comments, and `wire ce_core = clkena_in;` only. If `clkena_in` feeds anything other than `ce_core`, stop and report, because the plan's premise that the compat layer uses the enable only as the core's enable would be wrong.

- [ ] **Step 5: The bench's generic and the monitor macros**

In `ddr3_cpu_tb.sv`, next to the `CHIP32_GEN` localparam:

```systemverilog
// FREECORE builds the wrapper with ap040_free_core = 1 (findings/unfreeze/plan.md)
`ifdef FREECORE
localparam integer FREE_CORE_GEN = 1;
`else
localparam integer FREE_CORE_GEN = 0;
`endif
```
On the pipelined `TG68K #(...)` instance line (about line 799) add `.ap040_free_core(FREE_CORE_GEN)`. Replace the Task 1 macro block (the `` `ifndef FC_CE `` guard and its four lines) with the core's own view, which is valid for both generic values:

```systemverilog
`define FC_CE    tg68k.pc_ce
`define FC_ACK   tg68k.pc_ack
`define FC_WACK  tg68k.pc_wk_ack
`define FC_WBERR tg68k.pc_wk_berr
```

In `run.sh`, next to the `NOCHIP32` variant line: `if [ -n "$FREECORE" ]; then VARIANT="${VARIANT}_free"; fi`. On the `xelab` line, next to `${NOCHIP32:+-d NOCHIP32}`, add `${FREECORE:+-d FREECORE}`. In the header: `#   FREECORE=1 ./run.sh ...  the wrapper's ap040_free_core = 1 (findings/unfreeze/plan.md)`.

- [ ] **Step 6: Prove "off" is today, clock for clock**

```bash
cd $ROOT
env INT=$ROOT PIPE_DIR=$ROOT/lib/AP68040-pipelined SYSINFO=$S \
    bash findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh si_uf3_off
grep '^PERF ddr3_cpu' sim/ddr3_cpu/run_perf_si_uf3_off/xsim.log
```
Expected: `PERF ddr3_cpu: 6790 clocks, 2541 instructions (2541 micro-ops), CPI 2.672`, exactly as in `run_perf_si_ddr3_cur_9efe`. Any other number means the generic's "off" is not today: fix that before going on. (The perf runner elaborates `TG68K.vhd` with its default generics, i.e. off.)

Then run the Task 1 and Task 2 legs again with the generic off:

```bash
cd $ROOT/sim/ddr3_cpu
env $P RUNTAG=uf3a ./run.sh --ap040
env $P RUNTAG=uf3b ./run.sh --mmu
env $P RUNTAG=uf3c ./run.sh --fcprog
env $P RUNTAG=uf3d ./run.sh --fcprog --chipbus
```
Expected: all four end `2 passed, 0 failed`, with no FC failures. The `program phase` timestamps equal those of the matching Task 1/2 legs (uf1a, uf1b, uf2a, uf2b); a change that should be neutral must not move timing (traps memory).

- [ ] **Step 7: Commit**

```bash
cd $ROOT
git add rtl/soc/TG68K.vhd sim/ddr3_cpu/ddr3_cpu_tb.sv sim/ddr3_cpu/run.sh
git commit -m "TG68K: ap040_free_core generic (default 0): the pipelined core's own enable, one-clock acknowledges

Off is today: SysInfo loop 6,790 clocks identical, legs and phase timestamps identical.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The free core in simulation: every leg, the mutants, and the number

**Files:**
- Modify: `sim/ddr3_cpu/run.sh` (`FCMUTANT`), `findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh` (pass `-d FREECORE`)
- Create: `findings/unfreeze/results.md`

**Interfaces:**
- Consumes: `FREECORE=1` and the marker comments from Task 3; `--fcprog` from Task 2; the FC monitors from Task 1.
- Produces: `FCMUTANT=ack|walk|data` (requires `FREECORE=1`, must fail); the perf number that stop rule (c) and Task 6's board A/B are judged against.

- [ ] **Step 1: FCMUTANT in run.sh**

Model it on `--ackmutant` (its flag at about lines 61-67, its TG68K copy at about lines 268-275): a copy of TG68K.vhd with one `sed`, plus a check that the `sed` changed something. Put it where the `--ackmutant` copy is made, using the same variable names that block uses for the work directory, the repo root and the TG68K source path (shown here as `W`, `R`, `TG68K_SRC`):

```bash
# FCMUTANT=ack|walk|data (with FREECORE=1): undo one of the free core's
# qualifications in a copy of TG68K.vhd (findings/unfreeze/plan.md).  MUST fail.
if [ -n "$FCMUTANT" ]; then
    [ "${FREECORE:-0}" = "1" ] || { echo "FCMUTANT needs FREECORE=1" >&2; exit 2; }
    IS_MUTANT=1; VARIANT="${VARIANT}_fcm_${FCMUTANT}"
    TG68K_SRC="$W/TG68K_fcm_${FCMUTANT}.vhd"
    case "$FCMUTANT" in
      ack)  sed '/-- FC-ACK/s/a16_ack AND bce_q/a16_ack/' "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC" ;;
      data) sed "/-- FC-DATA/s/a16_take = '1'/a16_ack = '1'/" "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC" ;;
      walk) sed '/-- FC-WALK/s/ AND bce_q//' "$R/rtl/soc/TG68K.vhd" > "$TG68K_SRC" ;;
      *) echo "FCMUTANT: ack, walk or data" >&2; exit 2 ;;
    esac
    if cmp -s "$R/rtl/soc/TG68K.vhd" "$TG68K_SRC"; then
        echo "FCMUTANT=$FCMUTANT: the sed changed nothing; fix run.sh" >&2; exit 2; fi
fi
```
(The `VARIANT` suffix must be applied before the work directory `W` is derived from it. If run.sh derives `W` first, split the block: suffix before, copy after.)

- [ ] **Step 2: Every leg on the free core, one at a time**

```bash
cd $ROOT/sim/ddr3_cpu
F="$P FREECORE=1"
env $F RUNTAG=uf4a ./run.sh --ap040
env $F RUNTAG=uf4b ./run.sh --mmu
env $F RUNTAG=uf4c ./run.sh --snoop
env $F RUNTAG=uf4d ./run.sh --ap040 --chipbus
env $F RUNTAG=uf4e ./run.sh --fcprog
env $F RUNTAG=uf4f ./run.sh --fcprog --chipbus
env $F RUNTAG=uf4g DMA_OVERLAP=1 ./run.sh --snoop          # Review Focus 1
env $F RUNTAG=uf4h CPU_RATIO=4 ./run.sh --ap040            # Review Focus 2, informative
for t in uf4a uf4b uf4c uf4d uf4e uf4f uf4g uf4h; do
  echo "== $t"; grep -hE 'DDR3 CPU TB: [0-9]+ passed|FAIL: FC-|FC-4 stale' $(ls -t *${t}*.log run_*${t}*/xsim.log 2>/dev/null | head -1)
done
```
Expected: every leg `2 passed, 0 failed`, no `FAIL: FC-`. Record each leg's FC-4 count. **FC-1 firing triggers stop rule (a).** If `uf4h` (ratio 4) fails while the ratio-3 legs pass, record it in results.md and carry on: the board runs ratio 3.

- [ ] **Step 3: The mutants must fail**

```bash
env $F FCMUTANT=ack  RUNTAG=uf4ma ./run.sh --fcprog --chipbus
env $F FCMUTANT=data RUNTAG=uf4md ./run.sh --fcprog --chipbus
env $F FCMUTANT=walk RUNTAG=uf4mw ./run.sh --mmu
```
Expected: each reports a failure (an FC-2/FC-3 line, a program code, or the stall watchdog), and run.sh says the mutant failed as required. **A surviving mutant is not automatically a bench hole:**
- If `ack` or `data` survives and FC-4 was 0 in the matching Step 2 leg, the stale level never met a waiting core at this ratio. Record it in results.md as "unobservable in sim/ddr3_cpu at ratio 3, qualification kept as the guarantee", with the FC-4 counts as the evidence. That is the same standard as upstream's equivalent-mutant notes.
- If a mutant survives while FC-4 > 0, the bench has no teeth: stop and report.

- [ ] **Step 4: The number**

In `findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh`, on the `xelab` line add `${FREECORE:+-d FREECORE}` next to `-d REALSDRAM`. Then:

```bash
cd $ROOT
env FREECORE=1 INT=$ROOT PIPE_DIR=$ROOT/lib/AP68040-pipelined SYSINFO=$S \
    bash findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh si_uf4_on
grep '^PERF' sim/ddr3_cpu/run_perf_si_uf4_on/xsim.log
```
(`perf_probe_ddr3.sv` is compiled with the same defines, and the bench's `FREE_CORE_GEN` follows `-d FREECORE`.)
Expected: `frozen ... store 0` (the core's enable is never low), the leg passes, and CPI below 2.672. **Stop rule (c):** if CPI is above 2.592 (less than 3 % better), stop and report the full PERF block.

- [ ] **Step 5: Write results.md**

`findings/unfreeze/results.md` must contain:
- the PERF blocks for `si_uf3_off` and `si_uf4_on` side by side, with the per-bucket change;
- the leg table from Steps 2-3 (leg, pass/fail, FC-4 count);
- the mutant outcomes, with any "unobservable" note and its evidence;
- one paragraph on where the frozen clocks went. They go partly to retire and partly to store-hold or read-wait, and the split says how much the store buffer (P2 in the upstream survey) is still worth.

- [ ] **Step 6: Commit**

```bash
cd $ROOT
git add sim/ddr3_cpu/run.sh findings/ap040-pipelined/tests/perf/run_ddr3_perf.sh findings/unfreeze/results.md
git commit -m "Free core in sim: all legs green, mutants, SysInfo loop CPI 2.672 -> <measured>

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
(Replace `<measured>` with the number from Step 4.)

---

### Task 5: Build switch, constraint notes, routed A/B

**Files:**
- Modify: `rtl/soc/minimig_virtual_top.v` (parameter next to `ap040_pipelined` at line 38; the TG68K instance next to line 658), `rtl/soc/minimig_openaars_top.v` (parameter next to line 38; the instance next to line 503), `tools/vivado/build_ap040.tcl` (the `pipe_gen` line, about line 372), `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` (comments only), `rtl/soc/TG68K.vhd` (one comment line)

**Interfaces:**
- Consumes: TG68K generic `ap040_free_core` (Task 3).
- Produces: build switch `FREE_CORE=<0|1>`, default 0, pipelined builds only; images `build/stage_unfreeze_off` and `build/stage_unfreeze_on`.

- [ ] **Step 1: Pass the generic down**

`minimig_virtual_top.v`: add `parameter ap040_free_core = 0,` after `parameter ap040_pipelined = 0,`, and `.ap040_free_core(ap040_free_core),` after `.ap040_pipelined(ap040_pipelined),`.
`minimig_openaars_top.v`: add `parameter AP040_FREE_CORE = 0,` after `parameter AP040_PIPELINED = 0,`, and `.ap040_free_core(AP040_FREE_CORE),` after `.ap040_pipelined(AP040_PIPELINED),`.

- [ ] **Step 2: build_ap040.tcl**

Before the line `set pipe_gen " AP040_PIPELINED=1 ..."`:

```tcl
    # FREE_CORE=1 in the environment: the pipelined core runs free of the bus
    # wait (findings/unfreeze/plan.md); default 0.
    set free_core [expr {[info exists ::env(FREE_CORE)] && $::env(FREE_CORE) eq "1" ? 1 : 0}]
```
and make that line:
```tcl
    set pipe_gen " AP040_PIPELINED=1 AP040_HAS_MMU=$pmmu AP040_HAS_FPU=$pfpu AP040_FREE_CORE=$free_core"
```
After the pipelined branch's closing `}`, refuse the combination for a reference build:
```tcl
if {[info exists ::env(FREE_CORE)] && $::env(FREE_CORE) eq "1" && ![info exists free_core]} {
    error "build_ap040.tcl: FREE_CORE=1 needs the pipelined core (AP040_PIPE_DIR is none)"
}
```

- [ ] **Step 3: Comments that must stay true**

No constraint changes. In `cpu.xdc`:
- after the paragraph "The master channel x_* is clk_38 and changes only at T ..." (about line 147), add: `# With ap040_free_core = 1 the core is not frozen, and this no longer follows from the core's enable; it holds because the core changes m_* only where clkena_r is high (no request outstanding, or its completion edge). sim/ddr3_cpu asserts it on every leg (FC-1, findings/unfreeze/plan.md).`
- after "the clkena net that fans out to 7,391 kernel clock-enable pins" (about line 224), add: `# With ap040_free_core = 1 the pipelined core's enable is constant and that net drives only the walker bridge and the adapter.`
In `TG68K.vhd`, at the end of the `q_req` comment block (about line 858), add the same FC-1 sentence as a `--` comment.

- [ ] **Step 4: Build OFF, then ON (never two at once)**

```bash
cd $ROOT
V="env LD_LIBRARY_PATH=$HOME/lib/tinfo5 /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nolog -nojournal"
AP040_PIPE_MMU=1 AP040_PIPE_FPU=1 FREE_CORE=0 $V -source tools/vivado/build_ap040.tcl -tclargs build/stage_unfreeze_off 0
AP040_PIPE_MMU=1 AP040_PIPE_FPU=1 FREE_CORE=1 $V -source tools/vivado/build_ap040.tcl -tclargs build/stage_unfreeze_on 0
```
Run each in the background and wait for it to finish. Expected: each prints `re-synthesising (generics or sources changed)` and leaves `minimig_openaars_top.bit` in its directory.

- [ ] **Step 5: Compare timing and size**

```bash
for d in build/stage_unfreeze_off build/stage_unfreeze_on; do
  echo "== $d"
  grep -E '^\s*clk_38 ' $d/timing_summary.rpt | head -2
  grep -E '^\s*clk_114\s+clk_38\s' $d/timing_summary.rpt
  grep -E 'Slice LUTs' $d/*utiliz*.rpt | head -1
done
```
Expected: `off` matches `build/stage_chip32_on` within placement noise (clk_38 about +0.65, clk_114→clk_38 about +0.18, only the 16 known SDRAM endpoints failing). `on` has no more failing endpoints than `off`; that's stop rule (d). The constant enable should cost fewer LUTs than `off`, not more. Record both builds' numbers in results.md.

- [ ] **Step 6: Commit**

```bash
cd $ROOT
git add rtl/soc/minimig_virtual_top.v rtl/soc/minimig_openaars_top.v tools/vivado/build_ap040.tcl fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc rtl/soc/TG68K.vhd findings/unfreeze/results.md
git commit -m "FREE_CORE build switch; A/B images stage_unfreeze_off/_on (timing in results.md)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Board A/B (Paul) and closing the loop

**Files:**
- Create: `findings/unfreeze/hw-checklist.md`
- Modify: `findings/unfreeze/results.md`, `findings/ap040-pipelined/SESSION-HANDOVER.md` (one Backlog line)

**Interfaces:**
- Consumes: the two images from Task 5; the sim numbers from Task 4.
- Produces: the recommendation for Paul on whether `FREE_CORE=1` becomes the default. It stays 0 until he says so.

- [ ] **Step 1: Write the checklist.** Paul runs it; loading uses `tools/vivado/program.tcl` (see SESSION-HANDOVER "Programming").

`findings/unfreeze/hw-checklist.md` lists, for **each** image (off, then on), with the same SD card, the same OSD settings (FAST Maximum, Boards all, Turbo chip/kick off) and the same Startup-Sequence (`C:DDR3First` either in both or in neither):
1. Cold boot to Workbench (power cycle first, not JTAG-then-reset).
2. SysInfo SPEED three times: write down all three results.
3. cputest `ct040_01_B-01`: pass/fail.
4. An OSD reset while SysInfo SPEED is running (Review Focus 3): does it come back to Workbench?
5. The demanding demo set from the chip32 A/B (Turbo off): solid, or where it breaks.
6. RTG screen after a cold start.
7. Idle ten minutes: no freeze, HDMI still up.

- [ ] **Step 2: Record Paul's results** in results.md, as a table of image × check, with the SysInfo SPEED ratio on/off computed from the mean of the three runs.

- [ ] **Step 3: Handover.** In `SESSION-HANDOVER.md`'s Backlog, add one line with the real numbers filled in: `**Free-running pipelined core: findings/unfreeze/ (plan, results). Sim CPI 2.672 -> X; board SysInfo A -> B; FREE_CORE default: (Paul's decision). Next in line: the store buffer (upstream survey P2).**`

- [ ] **Step 4: Commit**

```bash
cd $ROOT
git add findings/unfreeze/hw-checklist.md findings/unfreeze/results.md findings/ap040-pipelined/SESSION-HANDOVER.md
git commit -m "findings/unfreeze: board A/B results

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Follow-ups (not in this plan)

- **The store buffer** (upstream survey P2: four entries, as in apolkosnik d06c1959, Dhrystone -14..-18 % there). It is worth measuring only after this plan, because results.md's bucket split shows how much store-hold and read-wait remain.
- **The core suite's random clock-enable mode** (upstream survey R1). It lives in the submodule's benches, which this plan does not touch. The SoC bench runs the board's real enable, plus DMA contention and a second clock ratio, which is the case that matters here. Worth adding to `lib/AP68040-pipelined` separately.
- **Running the adapter and walker side every clock too.** Not needed for the gain and not in scope: they talk to the 7 MHz chipset and the walker, which `clkena` suits.
- **`FREE_CORE=1` as the default, and removing the knob.** Paul's call after Task 6.
