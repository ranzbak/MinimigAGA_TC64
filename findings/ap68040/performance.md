# AP68040 — how fast can it realistically go here?

Companion to [compatibility.md](compatibility.md). Measured with Vivado 2023.2
on the xc7a100tfgg676-2, full configuration (MMU + FPU + caches), RAM primitive
replaced by [synth-reports/dpram_xilinx.v](synth-reports/dpram_xilinx.v),
placed and routed out-of-context at a 20 ns target
([synth-reports/pnr.tcl](synth-reports/pnr.tcl)).

## Measured

| | value | source |
|---|---|---|
| LUTs / FFs / BRAM18 / DSP | 28,694 (45 %) / 7,391 / 20 / 20 | [util_routed.rpt](synth-reports/util_routed.rpt) |
| Worst routed path | **21.0 ns**, 39–40 levels (14–15 CARRY4), 66 % routing | [worst_routed.rpt](synth-reports/worst_routed.rpt) |
| Single-cycle Fmax, standalone | **≈ 47 MHz** | 20 ns target, WNS −1.0 |
| Endpoints with datapath > 17.63 ns (2 × 8.815) | 1,148 of 5,000 worst | [histogram.txt](synth-reports/histogram.txt) |
| Endpoints with datapath > 26.45 ns (3 × 8.815) | **0** | same |
| Endpoints with datapath > 35.26 ns (4 × 8.815) | 0 | same |

The critical path is `core/state_reg → core/epf_ftail_reg[*]`: the exception
prefetch queue's next-fetch address, a 32-bit add chained behind the state
decode. Same family of path in every configuration synthesised.

For comparison, the TG68K kernel in the current bitstream has a 19.4 ns worst
path under the same 4-cycle regime
([../constraints/verification-vivado.md](../constraints/verification-vivado.md)).

## What the CPU runs at today

28.36 MHz effective. `clk_114` with `clkena_in` = `enaWRreg`, pulsed on 4 of
the 16 SDRAM phases (`sdram_ctrl.v:343-356`), then further gated by the
wrapper on bus readiness. The core advances only on those pulses, so its
paths get 35.3 ns.

Upstream MiSTer does it differently: `cpu_wrapper.v:204` uses
`clkena_in = ~cpu_req | chipready | ramready | fastchip_ready` — every clock
when no bus request is pending — and the AP68040 fork's own comment
(`ap040_tg68k_compat.v:111`, "2^21 cycles at 28 MHz ≈ 75 ms") shows the 040
core is clocked at 28 MHz single-cycle there. Same effective rate as here; the
difference is only in how it is expressed.

## Options, honestly ranked

### 1. `clkena` every 3 `clk_114` instead of 4 — 37.8 MHz, +33 % — recommended

The histogram says every path in the core fits 26.45 ns with 5.4 ns to spare.
That margin covers the congestion the core will see inside the real design (the
number above is standalone at 45 % of the device).

Two ways to express it:

**a. Keep `clk_114`, change the enable pattern.** `enaWRreg` at 5 of the 16
phases (spacing 3-3-3-3-4) gives an average of 35.4 MHz; the multicycle
exception becomes `-setup -start 3 / -hold -start 2` on the core island,
because the *minimum* spacing is what the constraint must cover. Cheap to try;
touches `sdram_ctrl.v` only. The chipset side (`ena7RD/WRreg`, 7 MHz) is
untouched.

**b. Give the core its own clock.** A fifth MMCM output at 113.4375 / 3 =
37.8125 MHz, core on that clock with `clkena_in` = bus handshake only. Every
core path becomes an honest single-cycle 26.45 ns path and the multicycle
exceptions disappear — this is "option C" from the TG68K discussion, and it is
the cleaner of the two. The `ap040_bus16_adapter` already registers everything
on `clkena_in` edges; the crossing to the 113 MHz memory side is a fixed 1:3
sibling-clock relationship that Vivado times automatically, plus the same
`-setup -end 3 / -hold -end 3` slow→fast rule the design already uses for
`dll_28 → clk_114` ([../constraints/fix-02](../constraints/fix-02-dll28-hold-multicycle.md)).

### 2. Own clock at 40–45 MHz — +40–60 % — possible, more work

Standalone Fmax is 47 MHz; budget for the real design and jitter and 40–42 MHz
is the practical ceiling with this core as written. Non-integer ratio to
113.4 MHz (5:2 at 45.4 MHz) means the bus handshake needs a real CDC —
request/acknowledge toggles through synchronisers — rather than a sibling-clock
multicycle. Doable; the adapter's "one stable request until ack" contract is
exactly what a two-flop handshake wants. Expect a week of bring-up, not a day.

### 3. `clkena` every 2 — 56.7 MHz — no

1,148 of the 5,000 worst endpoints exceed 17.63 ns. That is not a handful of
paths to fix; it is the sequencer's decode depth. Would need the author to
re-pipeline the core.

### 4. Speed grade -3 — +10–15 %

xc7a100t is available in -3. Roughly 47 → 53 MHz standalone. Only matters on
top of option 2; irrelevant under option 1, where the 3-cycle budget is not the
limit.

## What the clock does *not* buy

The memory system is the other half. Every 16-bit bus sub-cycle costs one
`clkena` regardless of core clock, `sdram_ctrl` grants the CPU port at most
one access per 4-cycle slot, and a line fill is eight sub-cycles. Raising the
core clock speeds up whatever hits in the 040's internal 4 KB I / 4 KB D
caches (2-cycle hit, no bus traffic) and leaves bus-bound code where it is.

That is also the real argument for the swap: TG68K has no internal cache and
pays a bus sub-cycle for every fetch, so the 040 at the *same* 28 MHz already
does more per second. How much more is unmeasured — `tb/run_tests.sh` has a
`bench_loop` target that would give a cycles-per-instruction figure for the core
alone; comparing it against TG68K on the same loop is the first thing to do
before committing to either option.

## See also

[ddr3-fast-ram.md](ddr3-fast-ram.md) — moving fast RAM and the RTG framebuffer
to the board's 256 MB DDR3 removes the CPU from the SDRAM slot round entirely,
which is a larger win than any of the clock options above.

## Order of work

1. Compatibility items 1–2 in [compatibility.md](compatibility.md) (multicycle
   scoping by enable domain; RAM primitive).
2. Bring it up at the existing 28.36 MHz enable — proves integration, no
   timing risk.
3. Option 1a (enable every 3) as a one-line experiment in `sdram_ctrl.v` plus
   the constraint change; measure.
4. Option 1b (sibling 37.8 MHz clock) as the clean form once 1a has shown the
   memory side keeps up.
5. Option 2 only if 1b is not enough and after the SDRAM read path
   ([../constraints/fix-12](../constraints/fix-12-sdram-read-capture-clock.md))
   is fixed — it is the interface that will be stressed.
