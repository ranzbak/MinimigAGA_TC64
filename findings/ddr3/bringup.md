# DDR3 stage-A hardware bring-up — result

Date 2026-09-04. Bitstream: island + BIST + VIO, `build/stageA/minimig_openaars_top.bit`
(built by the task-2 agent, commit `dab4a64`). Run over JTAG with
`tools/vivado/ddr3_bist.tcl`. Board: QMTECH XC7A100T core board, MT41K128M16 on bank 16,
DLL-off, controller at 100 MHz.

## Outcome: BLOCKED. The DDR3 read path does not work on this board.

The DRAM initialises and accepts commands; writes happen; the **first beat** of each
read burst is captured correctly; **beats 2-8 are corrupted**. No delay setting fixes it.
Root cause is a structural 7-series ISERDES clocking topology in the vendored PHY, not a
calibration problem and not the DRAM.

## Evidence

| Test | Result | Reading |
|---|---|---|
| PLL lock, `init_done` | both 1 | clocking and the DLL-off init sequence work |
| BIST pattern 4 (all-0 then all-1), full 256 MB | **0 errors** | constant-per-line data is invariant under beat scrambling, so it passes trivially |
| BIST patterns 0/1/2/3 (address, 55/AA, walking-1, LFSR), 1 MB | **~35k-65k of 65k lines fail** | any data that varies across the 8 beats fails |
| `first_err_xor` (low 32 bits of expected xor read) | 0x00000001, 0x00010000, 0x55550000, 0xffff0000, 0xb4510000 | low 16 bits (first beat / DQ lane 0) match; the error is in the upper bits (later beats) |
| Read-alignment grid, rdlat x rdsel at DQS tap 27 | only rdlat 4, rdsel in {5,7,13,15} pass **address-as-data over 64 KB** (a low-address, near-constant-per-line case); everything else fails; full 256 MB fails at all of them | rdsel picks which shifted sample is beat 0; some values align beat 0, none recover beats 2-8 |
| DQS delay sweep, all 32 taps, LFSR, 64 KB | **flat 4096/4096 fail at every tap** | the failure is delay-independent: not a data-window problem |
| Routed DRC | **REQP-1580 x16** on `u_phy/u_serdes_dq_in*` | the tool names the exact defect (see below) |

## Root cause

`lib/core_ddr3_controller/src_v/phy/xc7/ddr3_dfi_phy.v`, the 16 DQ input ISERDESE2
(line 1464+): `INTERFACE_TYPE("MEMORY")`, `DATA_WIDTH(4)`, `DATA_RATE("DDR")`,
`CLK = dqs_delayed_w` (the DQS strobe through an IDELAYE2, i.e. a byte-clock-region
resource), while `OCLK = clk_ddr_i` and `CLKDIV = clk_i` come from **BUFG**. 7-series
requires, for MEMORY-mode ISERDES phase alignment, that CLK/OCLK/CLKDIV share the buffer
type or use a BUFIO/BUFR combination. Mixing a strobe-region CLK with BUFG OCLK/CLKDIV is
the REQP-1580 topology and produces exactly this signature: the first captured beat is
right, the serial-to-parallel gearing of the rest is not phase-aligned. Upstream runs this
same PHY on a Digilent Arty at 100 MHz where the placement happens to align; on this board
and pinout it does not.

## What this does and does not prove

* **DLL-off works on this MT41K128M16.** Init completes, writes land, the first beat reads
  back correctly for arbitrary data. The Micron simulation warning ("DLL off not fully
  modeled") notwithstanding, the part behaves in DLL-off at 100 MHz.
* **The small-LUT controller and its command/DFI path work.** Only the fabric read-capture
  gearing is broken.
* Utilisation of the whole island was +2,017 LUTs, well within budget; the small-core
  premise holds if the PHY read path is fixed.

## Options (a scope decision for the owner)

1. **Rework the PHY read capture to a supported topology** (BUFR on the DQS byte region
   driving OCLK/CLKDIV, or BUFIO/BUFR per byte lane). Keeps the ~600-2k-LUT DLL-off
   approach. This is real 7-series I/O clocking work in a 2,790-line PHY and is the exact
   area upstream flags as weak; medium-hard, outcome uncertain.
2. **Use Xilinx MIG for the DDR3 PHY (or the whole controller).** Proven on this exact part
   and board (QMTECH ships a MIG example), calibrated read capture that just works. Costs
   ~5k LUTs, the cost DLL-off was chosen to avoid, but the earlier analysis showed MIG
   fits (about 70 % LUTs). Reverses design decisions D2/D3.
3. **Shelve DDR3, keep the SDRAM core.** The fast-RAM isolation benefit does not appear
   without DDR3.

Recommendation: given the board already has a working MIG example and how much the
structural PHY defect would cost to chase, **option 2** unless the LUT budget is the
overriding constraint, in which case **option 1**. Either way the cache backend, the CDC,
the BIST, the wrapper plumbing and the constraints from this session are reusable, only
the PHY block changes.

## Reusable assets from this bring-up

* `tools/vivado/ddr3_bist.tcl` - program, run BIST patterns, sweep DQS/DQ delay, and grid
  rdlat x rdsel over the VIO. Modes: `program`, `<patterns> <range_log2>`, `align <rdlat> <rdsel>`,
  `dqs_sweep <n>`, `dq_sweep <n>`, `grid`.
* The VIO probe map is in the task-2 island commit and the `.ltx` in `build/stageA/`.
