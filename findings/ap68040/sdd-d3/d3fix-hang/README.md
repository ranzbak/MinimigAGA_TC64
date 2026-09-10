# The D3 timing fix hangs an instruction fetch (2026-09-10)

`build/stage_ap040_d3fix` (commit `ac9b725`) gave the crossing real margin
(`clk_114 -> clk_38` 0.273 -> 1.275 ns, verified independently on the routed
design) and **does not boot**, deterministically. All twelve simulation legs
pass. The pre-fix build booted and then corrupted memory intermittently; this
one dies every time, so it is logic, not marginality.

## What the captures show

Taken on `build/stage_ap040_d3fix_ila` (the debug twin, itself timing-healthy:
crossing +1.250, one violated path, the pre-existing SDRAM capture).
`capture-method.tcl` programs the board and then re-arms in a loop, so the
transition from running to halted is bracketed.

* **`last-alive.csv`** -- the decisive one. Its final samples:

      pc = $00FC5C6C   ir = 522E   flags = busy
      cpustate = 0x00  ->  clkena 0, slower 00, ramcs ACTIVE (low), bstate 00

  `bstate = 00` is an **instruction fetch**, the chip select is **asserted**,
  the `slower` throttle has expired, and **`clkena` never fires again**. The
  core freezes mid-fetch with the select still active: the completion never
  arrives.

* **`first-halted.csv`** and **`halted-steady.csv`** -- roughly half a second
  later, and thereafter: `dbg_flags = E` = {fault, in_exc, halted},
  `pc = $400B7732`, `ir = 4E75` (RTS). That is the aftermath: the core's bus
  timeout turned the missing acknowledge into an access fault, the fault
  handler faulted in turn, and the core halted. Same signature as the stage-B
  failure when the walker had no path to memory.

  `tg68_adr` reads `$00DFF09A` throughout, which is **not** the failing
  access -- it is the last value latched in the address register before the
  enable died, and it stays there because the register only updates on
  `clkena`. Chasing it as the fault address is a dead end; it also makes an
  address-triggered ILA fire permanently once the core is halted, which is why
  the capture loop above ran to its limit instead of stopping.

## What this rules in and out

* **Not the router gating.** This is the CPU's own fetch, not the walker's or
  the fill router's access, so `bus_step` is not implicated.
* **Implicated: the release retiming.** `ac9b725` changed
  `clkena <= cpu_ce_phase AND bus_release` (combinational, at `cpu_ph2`) into
  `clkena_r <= cpu_ph AND bus_release` (registered, sampled at `cpu_ph`), i.e.
  the completion is sampled one `clk_114` edge earlier. For this fetch the
  completion is not merely delayed, it is never seen.
* **Not D1's failure.** D1 stalls inside expansion.library's ConfigDev walk.
  This is a Kickstart-resident fetch at `$00FC5C6C`.
* **Simulation cannot see it**: the bench models the enable cadence itself and
  passed all twelve legs including the mutants.

## Next step

Read the completion path with this signature in hand -- a CPU fetch to the
SDRAM side, select asserted, `slower` expired -- and establish whether
`ramready`/`mem_ready` is genuinely held until consumed, or whether sampling it
an edge earlier can lose it outright. Do not re-assert that it is a level;
prove it from `sdram_ctrl.v` and `cpu_cache_new.v`. Two claims of exactly this
shape have already been wrong this week.
