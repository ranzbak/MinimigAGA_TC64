# AP68040 — compatibility with MinimigAGA_TC64 / OpenAARS

Source examined: `~/work/fpga/Xilinx/artix7/minimig/AP68040` (commit 0e76761,
GPL v2+, Adam Polkosnik). A from-scratch MC68040 in Verilog with MMU, FPU and
split 4 KB I/D caches, extracted from the Minimig-AGA_MiSTer fork. Boots
AmigaOS 3.x and NetBSD on DE10-Nano; 3776/3801 of the WinUAE `cputest` 68040
corpus, the remaining 25 documented as generator defects.

## Verdict

**Yes, with two pieces of work — one trivial, one moderate.**

* **Interface:** designed as a drop-in for the TG68K port set. Our
  `rtl/soc/TG68K.vhd` wrapper drives `TG68KdotC_Kernel` with exactly that port
  set; the mapping is one-to-one bar four signals (below). The bus contract
  (`clkena_in` gating, `busstate` encoding, level acknowledge, IDLE between
  split sub-cycles) is the same Minimig contract this project's
  `sdram_ctrl`/`cpu_cache_new` already speak.
* **Resources:** as shipped it does **not** fit — 70.8k LUTs against the
  xc7a100t's 63.4k. The cause is a single 17-line file: `primitives/dpram.v`
  writes both RAM ports in one `always` block, which Vivado refuses to map to
  block RAM and dissolves into 43k LUTs of registers and muxes. The README
  says to substitute that file per flow. With a Xilinx-inferable or XPM
  TDP RAM the core is ≈ 28k LUTs with FPU, ≈ 18k without — comfortably inside
  the ≈ 49k LUTs this design has free.
* **Timing:** critical paths of 21–22 ns at 35–43 logic levels. Identical
  situation to the TG68K (19.4 ns): it runs under the 4-cycle `clkena` window
  at 28.36 MHz effective, and needs the same multicycle scheme —
  [../constraints/fix-04](../constraints/fix-04-tg68k-blanket-multicycle.md)
  should be done in a hierarchy-agnostic way *before* this swap.
* **Toolchain:** compiles clean with `iverilog -g2012` and Vivado 2023.2
  (`read_verilog -sv`, `ap040_defs.svh` on the include path). Self-test suite
  needs `vasmm68k_mot`, which is installed here.

## Interface mapping

Our wrapper's kernel instance is at `rtl/soc/TG68K.vhd:330-358`. Against
`ap040_tg68k_compat`:

| `TG68KdotC_Kernel` (ours) | `ap040_tg68k_compat` | Note |
|---|---|---|
| `clk`, `nReset`, `clkena_in` | same | same semantics: core advances only on `clkena_in` |
| `data_in[15:0]`, `data_write[15:0]` | same | 16-bit bus, 32-bit core split by `ap040_bus16_adapter` |
| `addr_out[31:0]` | same | |
| `nWr`, `nUDS`, `nLDS` | `nwr`, `nuds`, `nlds` | |
| `busstate[1:0]` | same | 00 fetch, 01 idle, 10 read, 11 write — identical encoding |
| `longword` | same | |
| `IPL`, `IPL_autovector` | `ipl`, `ipl_autovector` | autovector input ignored — always autovectored, fine for Amiga |
| `berr` | same | AP040 uses it: format $7 access error. TG68K ignores it |
| `nResetOut`, `FC` | `nresetout`, `fc` | |
| `VBR_out` | `vbr_out` | used at `TG68K.vhd:201` for the NMI vector |
| `CACR_out[3:0]` | `cacr_out[31:0]` | take the low bits; check what `TG68K.vhd` does with it |
| `CPU[1:0]` (68000/010/020 select) | **none** | the AP040 is always a 68040; see "CPU mode" below |
| `skipFetch` | **none** | debug output, `open` in our wrapper except pass-through |
| `clr_berr` | **none** | `open` in our wrapper already |
| `regin_out` | **none** | `open` already |

Extra AP040 ports and where this project can feed them:

| AP040 port | Source in this project | If left unconnected |
|---|---|---|
| `cache_snoop_stb`, `cache_snoop_addr` | `sdram_ctrl.v` already generates `snoop_act` / `snoop_adr` for `cpu_cache_new` (`:288-291`) — same signal, same clock domain | D-cache never sees chipset DMA writes: chip RAM must then be marked non-cacheable (the `cache_z*` windows do that) |
| `cache_z2_ena`, `cache_z3_base0/1`, `cache_z3_ena0/1` | `minimig/autoconfig` `board_configured[3:0]` and the Z3 base registers, already routed into `TG68K.vhd` as `z2ram_ena`/`z3ram_ena` | nothing cacheable: cache silent, correct but slow |
| `walker_*` (table-walk memory port) | 32-bit read/write single-access requester on the same address router as the CPU master — chip RAM via the SDRAM CPU port, fast RAM via the DDR3 line port | walk never acks → watchdog turns it into a bus error; MMU unusable. **AmigaOS needs it**: `68040.library` enables the MMU at boot for cache-mode control, and MuFastROM/MMULib remap Kickstart through it. Tie off only for the first bring-up with `68040.library NOMMU` |
| `cache_allow_all` | tie 0 | — |
| `cache_maint_*`, `mmu_*`, `debug_*` | leave open | — |

### Bus contract details worth checking on our side

From the `ap040_bus16_adapter.v` header: all outputs registered and change only
on `clkena_in` edges; one stable request at a time; exactly one qualified
completion advances one 16-bit sub-cycle; split transfers insert a sampled
IDLE cycle; "the Minimig RAM/cache controllers return a level acknowledge and
do not accept a new address until their chip-select drops".

Our `TG68K.vhd:457` builds `clkena` from `clkena_in AND (state="01" OR
ena7RD/WR&clkena_e/f OR ramready OR sel_undecoded OR akiko_ack)` — a qualified
completion, as required. `ramready` is `cpuena = ccachehit` from
`cpu_cache_new`, a level — as required. The C2P/Akiko path and the chipset
7 MHz bus state machine (`S_state`) live in the wrapper, not the kernel, so
they carry over unchanged. Expect this to work first time; the compat layer was
written against MiSTer's `cpu_wrapper.v`, which is the same Gubener lineage
as ours with a different clock-enable spelling (`~cpu_req | chipready |
ramready | fastchip_ready`).

### CPU mode

Today `cpu_config[1:0]` from the OSD selects 68000/68020 behaviour inside
TG68K (`minimig_virtual_top.v:561`) and the wrapper uses `cpu(1)` for 32-bit
address decode (`TG68K.vhd:246, 323, 505, 546`). With the AP040 there is no
mode input: keep `cpu(1)=1` behaviour in the wrapper (32-bit decode, AGA
longword chip access) and either drop the OSD choice or make it select between
the two cores at build time. Running both cores in the same bitstream is not an
option on this device (see resources).

## Resources — measured, Vivado 2023.2, xc7a100tfgg676-2, out-of-context

Reports in [synth-reports/](synth-reports/).

| Configuration | LUTs | of 63,400 | FFs | BRAM18 | DSP | worst path |
|---|---|---|---|---|---|---|
| MMU + FPU + cache (as shipped) | **70,832** | **112 %** | 25,234 | 4 | 20 | 21.3 ns, 43 levels |
| MMU + cache, no FPU | 60,566 | 96 % | 22,376 | 4 | 4 | 22.0 ns, 40 levels |
| "minimal" (`HAS_MMU=0`, no cache, no FPU) | 28,912 | 46 % | 10,073 | 0 | 4 | 21.0 ns, 35 levels |

For reference the current bitstream uses 14,375 LUTs (22.7 %), 43.5 BRAM
tiles, 18 DSPs.

### Where the LUTs go

Hierarchical breakdown of the no-FPU build:

```
core                      16,542     (sequencer 11,487 · regfile 4,186 · muldiv 871)
g_cache.cache             31,799     of which  ctag_ram   31,629   <-- dissolved RAM
mmu                       12,085     of which  atc_ram    11,707   <-- dissolved RAM
FPU (full minus no-FPU)   10,266     + 16 DSPs
```

`ctag_ram` (128 × 94 bits) and `atc_ram` are both instances of
`rtl/primitives/dpram.v`:

```verilog
always @(posedge clock) begin
    if (wren_a) mem[address_a] <= data_a;
    if (wren_b) mem[address_b] <= data_b;
    q_a <= mem[address_a];
    q_b <= mem[address_b];
end
```

Vivado:

```
WARNING: [Synth 8-4767] Trying to implement RAM 'mem_reg' in registers.
  Block RAM or DRAM implementation is not possible; see log for reasons.
  1: RAM has multiple writes via different ports in same process.
     If RAM inferencing intended, write to one port per process.
RAM "mem_reg" dissolved into registers
```

Note `AP040_HAS_MMU=0` does **not** remove the MMU instance — only the cache is
`generate`-gated (`ap040_tg68k_compat.v:314`) — so the "minimal" build still
carries the 11.7k-LUT dissolved ATC. That is why it is larger than
`core` alone.

### The fix, and the projected sizes

Replace `primitives/dpram.v` — the README explicitly invites this — with
either the Xilinx-inferable form (one `always` per port):

```verilog
module dpram #(parameter AW = 8, parameter DW = 8) (
    input clock,
    input [AW-1:0] address_a, input [DW-1:0] data_a, input wren_a, output reg [DW-1:0] q_a,
    input [AW-1:0] address_b, input [DW-1:0] data_b, input wren_b, output reg [DW-1:0] q_b
);
    (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[address_a];
    end
    always @(posedge clock) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[address_b];
    end
endmodule
```

or `xpm_memory_tdpram` with `READ_LATENCY_A/B = 1`. One caveat to verify in
simulation: the original gives read-during-write-on-the-other-port the
*new* data (both writes precede both reads in one process). The template above
and RAMB primitives give the *old* data on a cross-port collision. The cache
header says port B invalidates while port A serves lookups; a same-cycle
collision on the same row would then see stale validity for one cycle. Run
`tb/` after the swap — `tb_ap040_cache_snoop.v` exists for exactly this.

**Measured after the swap** (placed and routed, [synth-reports/util_routed.rpt](synth-reports/util_routed.rpt)): **28,694 LUTs, 7,391 FFs, 10 BRAM tiles, 20 DSPs** for the full configuration. Projection that was made before that run:

| Configuration | LUTs (est.) | + current design (14.4k − TG68K) | of 63,400 |
|---|---|---|---|
| MMU + FPU + cache | ≈ 28k | ≈ 39k | ≈ 62 % |
| MMU + cache, no FPU | ≈ 18k | ≈ 29k | ≈ 46 % |

Fits with margin either way. The FPU costs 10.3k LUTs and 16 DSPs; the device
has 240 DSPs, so that is not a constraint.

## Timing

Measured post-route numbers and the clock-rate options are in
[performance.md](performance.md); the synthesis-only figures below stand.

All three builds show 21–22 ns worst paths with 35–43 logic levels and
65–70 % routing (out-of-context estimate). At the 8.815 ns `clk_114` period
that is −12 to −13 ns single-cycle — the same class as the TG68K's 19.4 ns
path ([constraints/fix-04](../constraints/fix-04-tg68k-blanket-multicycle.md)).
Under the existing 4-cycle `clkena` scheme the budget is 35.3 ns, so it closes
with the same kind of multicycle exception. The core itself says "the whole
core advances only when ce (clkena_in) is high".

Two consequences:

1. The blanket TG68K exceptions in `wizard.xdc:5-15` are written against
   `openaars_virtual_top/tg68k/pf68K_Kernel_inst/*` and would silently stop
   matching. Rewrite them by *enable domain*, not by instance name, first.
2. Effective CPU clock stays 28.36 MHz. The gain over TG68K is the 040
   instruction set, the internal caches and the FPU, not clock rate. Option C
   in the TG68K discussion (clock the CPU island at `dll_28` directly) applies
   equally here and would remove the exceptions entirely.

## Integration plan, in order

1. Land [constraints/fix-04](../constraints/fix-04-tg68k-blanket-multicycle.md)
   with enable-domain scoping so the constraint survives the swap.
2. Replace `primitives/dpram.v`; re-run `tb/run_tests.sh`; re-synthesise
   out-of-context and confirm ≈ 28k LUTs / 4 RAMB18 for the full build.
3. New wrapper `rtl/soc/AP040.vhd` (or a Verilog sibling of `TG68K.vhd`):
   same external ports as `TG68K.vhd`, instantiates `ap040_tg68k_compat`, wires
   `cache_snoop_*` from `sdram_ctrl`'s existing snoop signals, `cache_z*` from
   autoconfig, `walker_*` tied off for a first bring-up (MMU faults become bus
   errors — acceptable for AmigaOS).
4. `cpu(1)` fixed high in the wrapper; OSD CPU option becomes build-time or is
   removed.
5. Add the eleven `rtl/*.v` plus the replacement `dpram.v` to the Vivado
   project as SystemVerilog (`.svh` include), `-I rtl` for the sim flow.
6. Bring-up on AmigaOS 3.x with `68040.library NOMMU`, then the walker port
   (B3) so the library runs with the MMU and Kickstart can be remapped into
   fast RAM.
7. Only then consider the FPU: +10k LUTs, +16 DSPs, and it adds the 8-word
   extended-precision paths to the timing picture.

## What was not checked

* Actual place-and-route closure of the combined design — only OOC synthesis
  of the core. Expect the router to need the pblock in `wizard.xdc:56-61`
  revisited.
* Behavioural correctness on this project's chipset — the AP68040 tree's own
  tests run against the core alone; the MiSTer-side co-simulation benches
  that drive a real chipset are not in this checkout.
* Read-during-write semantics after the `dpram.v` replacement (see caveat).
