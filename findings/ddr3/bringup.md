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

---

# Read-path rework

Date 2026-09-05. The blocking defect above is fixed. `REQP-1580` is gone, the
read path works on the board, and the full 256 MB passes all five BIST
patterns.

## What changed

Only the **read capture** in `lib/core_ddr3_controller/src_v/phy/xc7/ddr3_dfi_phy.v`.
The write path (command registers, the 20 OSERDESE2 for DQ/DQS/DM, the IOBUF
ring) is untouched — it was proven correct on hardware and stays byte-for-byte
upstream.

1. **The 16 DQ ISERDESE2 no longer use the DQS strobe.** They are now
   `INTERFACE_TYPE("NETWORKING")`, `DATA_WIDTH(8)`, `DATA_RATE("DDR")`, with
   `CLK` = `clk_ddr_i` (400 MHz BUFG) / `CLKB` = `~clk_ddr_i`, `CLKDIV` =
   `clk_i` (100 MHz BUFG), `OCLK`/`OCLKB` tied low (unused in this mode),
   `BITSLIP` tied low, `IOBDELAY("IFD")` still fed from the per-lane DQ
   IDELAYE2. That is plain **oversampling off the controller's own clocks**:
   800 Msps, a sample every 1.25 ns, eight samples per 100 MHz cycle. With the
   DRAM DLL off at CK = 100 MHz a read beat is 5 ns, so there are four
   oversamples per beat and two beats per cycle. No clock-capable strobe pin is
   needed, which is the whole point: B20/A20 and A23/A24 are byte-group strobe
   pins and can drive neither BUFIO nor BUFR.
2. **The two DQS input IDELAYE2 were deleted.** The IOBUFDS pair stays (DQS is
   still driven during writes); their `O` pins are left unconnected.
   `cfg_i[19:16]` (`DLY_DQS_RST` / `DLY_DQS_INC`) and the `DQS_TAP_DELAY_INIT`
   parameter keep their names and bit positions — so the VIO probe map and
   `tools/vivado/ddr3_bist.tcl` are unchanged — but they are now **no-ops**.
   The 16 per-lane DQ IDELAYE2 stay and are the fine trim, 78 ps a tap,
   through `cfg_i[23:20]`.
3. **`RDSEL` (`cfg_i[3:0]`) has a new, exact meaning.** Each cycle the PHY also
   keeps the previous cycle's eight samples, giving a 16-sample sliding window
   per DQ bit (index 0 = oldest). Then

   ```
   sel   = RDSEL[2:0] + (RDSEL[3] ? 4 : 0)      // 0 .. 11
   beat0 = window[sel]                          // earlier beat -> rddata[15:0]
   beat1 = window[sel + 4]                      // later beat   -> rddata[31:16]
   ```

   `RDSEL[2:0]` walks the sample point across the eye in 1.25 ns steps (0..3
   inside one beat, 4..7 the same four phases one beat later, which is how the
   beat pairing is corrected) and `RDSEL[3]` adds a further half cycle. The
   reachable range is 13.75 ns, more than one `clk_i` cycle, so it overlaps the
   whole-cycle steps of `RDLAT`. `RDLAT` (`cfg_i[10:8]`) is unchanged: `clk_i`
   cycles from `dfi_rddata_en` to `rddata_valid`. `cfg_valid_i` semantics are
   unchanged. The beat order in `dfi_rddata_o` is unchanged. The timing diagram
   is in the PHY file above the assembly.

Cost, out-of-context synthesis of `ddr3_top` for `xc7a100tfgg676-2`:
**1132 -> 1194 Slice LUTs (+62)**, 697 -> 821 registers (+124, the 128-bit
sample history), 16 ISERDESE2 unchanged, IDELAYE2 18 -> 16.
Post-place `report_drc -checks {REQP-1580}` with the real board pinout:
**16 violations before, 0 after**.

## Hardware result (stage A2) — this is the source of truth

Board, JTAG, `tools/vivado/ddr3_bist.tcl`:

| Measurement | Result |
|---|---|
| Routed DRC `REQP-1580` | **gone** |
| LFSR grid over 64 KB | passes at **rdlat 5, rdsel {6, 7, 10, 11, 12, 13}** and **rdlat 6, rdsel {0, 1}**; everything else fails |
| All five patterns, full **256 MB**, at rdlat 5 / rdsel 11 | **0 errors** |
| DQ IDELAY sweep at that point | clean from tap **0 to 22** (about 1.7 ns), fails from tap 23 |

Those `rdsel` codes are one window, not several: in `sel` terms rdlat 5 gives
sel 6, 7, 8, 9 (rdsel 6/10 -> sel 6, 7/11 -> sel 7, 12 -> 8, 13 -> 9), and
rdlat 6 rdsel 0, 1 is the same sel 8, 9 seen one cycle later. So the eye is
four consecutive oversamples wide — a full 5 ns beat — and **rdsel 11 (sel 7)
is its centre**. The DQ IDELAY margin of 22 taps on top of that is comfortable.

**Module defaults are therefore `TPHY_RDLAT(5)` / `RDSEL_INIT(4'd11)` with
`DQ_TAP_DELAY_INIT(0)`**, set in `rtl/ddr3/ddr3_top.v` and mirrored in the PHY's
own parameter defaults.

## Simulation, and where it disagrees

`sim/ddr3_island` was extended for this work:

* a **DQ/DQS skew model**: the Micron model's DQ and DQS outputs reach the FPGA
  through a transport delay of `DQS_SKEW_PS` (parameter, `+SKEW_PS=<ps>`),
  standing in for tDQSCK with the DLL disabled (1 ns .. 10 ns in the datasheet)
  plus flight time. Only the memory -> FPGA direction is delayed, so the model's
  own write-timing checks still see a clean bus; the direction comes from the
  PHY's DQ/DQS tristate controls. `run.sh` runs 1000, 4000 and 8000 ps in
  parallel and writes `xsim_run_skew<ps>.log`.
* an **automatic alignment sweep**: rdlat 3..7 x rdsel 0..15, BIST pattern 3
  (LFSR) over 4 KB at each point, printed as `GRID` lines in exactly the format
  `tools/vivado/ddr3_bist.tcl`'s `grid` mode prints, then all five patterns over
  64 KB plus the external-port test.

The sweep reproduces the expected physics: the passing window is four
consecutive oversamples wide and **moves with the skew** by the right amount
(1 ns -> 4 ns shifts it by 2 samples, 4 ns -> 8 ns by 3 more; 1.25 ns a sample).
Exploratory grids (256-byte range, the same shape as the 4 KB ones):

```
skew 1000 ps   rdlat 5: rdsel 12..15 pass      rdlat 6: rdsel 0..3 pass    (sel 8..11)
skew 4000 ps   rdlat 5: rdsel 14,15 pass       rdlat 6: rdsel 2..5 pass    (sel 10,11 / 2..5)
skew 8000 ps   rdlat 6: rdsel 5..7, 9..12 pass                             (sel 5..8)
```

**But the model and the board disagree by exactly one beat.** In simulation the
window at rdlat 5 sits at sel 8..11; on the board it sits at sel 6..9 — 4
oversamples = 5 ns = one DDR beat earlier. The cause is the Micron model's
DLL-off behaviour, which it itself warns about ("Load Mode 1 DLL off mode is not
fully modeled"): its read data comes out at a strobe phase that a real
DLL-disabled part does not reproduce. **So the bench is not used to pick
`RDLAT` / `RDSEL`; hardware is.** What the bench does prove, and what it now
asserts, is:

* the reworked capture assembles bursts correctly at *some* alignment at every
  skew (all five patterns over 64 KB, zero errors, plus the external port),
* the window is one beat wide and moves with tDQSCK as predicted, so the
  hardware sweep is the right procedure, and
* the module defaults are within one beat of a sample point that works in
  simulation — the residual is exactly the modelling error above.

The bench therefore runs its own data-integrity passes at `SIM_RDLAT` /
`SIM_RDSEL` (5 / 15, the board's alignment plus one beat) and only *reports* the
module defaults. Both constants are next to each other at the top of
`ddr3_island_tb.sv` with this note.

Two smaller findings from the sweeps, worth knowing before reading a grid:

* Isolated single zeros in a grid row (a lone passing cell with failing
  neighbours, e.g. rdlat 3 rdsel 0) are **artefacts, not windows**. When the
  capture is X, `ddr3_bist`'s `xor_w != 128'b0` evaluates to X, `if (x)` is
  false, and the line is silently counted as good. Only a contiguous run of
  three or four passing cells is a real eye. This cannot happen on hardware,
  where there is no X, but it does happen in simulation.
* `rdsel` codes 8..15 duplicate 4..11 in `sel` terms, so a window will often
  appear twice in a row. That is the `RDSEL[3]` half-cycle bit doing its job,
  not a second eye.

## What the supervisor should do on a new board or after a rebuild

1. `tools/vivado/ddr3_bist.tcl <bit> "3" 16 program grid` — the LFSR grid over
   64 KB, rdlat 3..7 x rdsel 0..15. Expect one contiguous run of about four
   passing `rdsel` at one `rdlat` (plus its alias at `rdlat+1`, `rdsel` 0..1).
2. Take the centre of that run and apply it:
   `tools/vivado/ddr3_bist.tcl <bit> "3" 16 align <rdlat> <rdsel>`. If it is not
   `5 11`, update `TPHY_RDLAT` / `RDSEL_INIT` in `rtl/ddr3/ddr3_top.v`.
3. `tools/vivado/ddr3_bist.tcl <bit> "0 1 2 3 4" 28 align <rdlat> <rdsel>` —
   all five patterns over the full 256 MB. This is the acceptance test; it
   currently gives 0 errors.
4. `tools/vivado/ddr3_bist.tcl <bit> "3" 16 align <rdlat> <rdsel> dq_sweep 32` —
   the DQ IDELAY margin. Expect a clean run of taps from 0; if the clean run
   does not start at 0, centre `DQ_TAP_DELAY_INIT` in it. On this board it is
   0..22, so 0 is fine and no trim is needed.
5. `dqs_sweep` is now **meaningless** (the DQS delay lines are gone) and will
   show a flat result. Do not read anything into it.

---

# Masked-write (DM lane) BIST modes

Date 2026-09-05. Written for the Zorro-III fast-RAM data-corruption
investigation: the island passes all five original patterns over the full
256 MB, but the Amiga crashes (`Ramlib Program failed (error #80000008)`,
privilege violation, during the Workbench boot sequence) once programs are
loaded into DDR3 fast RAM.

## Why the existing patterns cannot see this

Patterns 0..4 only ever write **whole 16-byte lines with all 16 byte enables
set**, so `mem_wr_o` is always `16'hFFFF` and the DDR3 **DM (data mask) lanes
are never driven**. The CPU path is different: `cpu_cache_new`'s write buffer
issues 16-bit and byte writes, and `rtl/ddr3/ddr3_fastram.v` turns
`sdr_dqm_w` into a partial byte-enable mask. So on hardware the DM lanes are
exercised for the first time by the CPU, and a broken DM path corrupts exactly
the bytes a program's code and pointers live in — which is what a privilege
violation on a freshly loaded program looks like.

Two new BIST patterns exercise that path with no CPU involved.

## Pattern 5, "masked"

Per 16-byte line at byte address A, with `B = LFSR-32(A)` and `F = ~B`:

1. write the whole line with `B`, all 16 byte enables,
2. write the **same** line with `F` and only the byte enables of `M(A)` set,
3. read the line back and compare against `expected = (F & M) | (B & ~M)`,
   bytewise.

`M(A)` cycles with the line index `c = A[8:4]`, so one full cycle is 32 lines
= 512 bytes and `range_log2 >= 9` covers every mask:

| c | M | what it proves |
|---|---|---|
| 0..15 | `1 << c` | a single byte written, the other 15 held |
| 16..23 | `3 << 2*(c-16)` | one 16-bit word (the CPU's common case) |
| 24 / 25 | `0x5555` / `0xAAAA` | alternating bytes, both phases |
| 26..29 | `0x000F` / `0x00F0` / `0x0F00` / `0xF000` | one 32-bit word |
| 30 / 31 | `0x00FF` / `0xFF00` | the two halves of the line |

Every byte position is therefore both written-under-mask and held-under-mask
within 512 bytes: a DM lane stuck **active** shows up as a corrupted background
byte, a DM lane stuck **inactive** as a foreground byte that never arrived.
`M` is never 0 (a request with no byte enables is not a write).

## Pattern 6, "wordwr"

Mimics the cache write buffer precisely: **one 16-bit word per request**, two
byte enables set. Per line: background `B` with all enables, then eight
separate requests writing word k (k = 0..7) of `F` with byte enables
`3 << 2*k`, then read back and compare against `F`. A word write that lands on
the wrong word, or that writes more or fewer than its two bytes, leaves
background behind and is caught.

Both patterns run **line at a time** (background, masked write(s), verify)
rather than write-everything then verify-everything, and both honour
`mode = 1` (verify only), which re-reads the same expectation without
rewriting and so proves the masked data actually reached the array.

`pattern_i` is 3 bits and 5/6 fit in it, so **the vio_ddr3 probe map and the
`.ltx` are unchanged**; `tools/vivado/ddr3_bist.tcl` passes the numbers
straight through (its BIST poll timeout was widened, pattern 6 issues 5x the
requests of pattern 0).

## Simulation

`sim/ddr3_island` gained tests 12..15 and a `+MASKONLY` plusarg that runs only
them (no 80-point alignment grid). Reference log: `sim/ddr3_island/xsim_run_masked.log`,
produced by `./run.sh 4000 -- MASKONLY`, at the middle skew (4000 ps) and the
simulation alignment `SIM_RDLAT`/`SIM_RDSEL` = 5/15, which is the same physical
sample point as the board's rdlat 5 / rdsel 11 (see "Read-path rework" above
for the one-beat model discrepancy). All seven checks pass:

```
PASS: BIST pattern 5 (masked byte-enable write) clean          errors=0 lines=256
PASS: BIST pattern 5 verify-only (masked data retained) clean  errors=0 lines=256
PASS: BIST pattern 6 (16-bit word writes) clean                errors=0 lines=256
PASS: BIST pattern 6 verify-only (word-written data retained)  errors=0 lines=256
PASS: DM negative control: pattern 5 flags the stuck DM lane   errors=1 xor=00ff0000
```

The negative control forces `ddr3_dm[0]` low for one masked line at address 0
(`M = 0x0001`, only byte 0 should change). With DM[0] stuck the DRAM writes the
low byte of all eight beats, so bytes 2,4,..,14 hold `F` where `B` was
expected; of the low 32 bits of the XOR only byte 2 is wrong, giving exactly
`0x00FF0000`. That is the proof that the mode really drives DM and really
notices when DM misbehaves.

## What the supervisor should run on the board

Diagnostic bitstream (island + BIST + VIO, `DDR3_BIST_VIO=1`):
`build/stageA3/minimig_openaars_top.bit` with its `.ltx`, built by
`tools/vivado/build_bist.tcl`.

```
# masked, full 256 MB, at the board alignment
tools/vivado/ddr3_bist.tcl build/stageA3/minimig_openaars_top.bit "5" 28 program align 5 11

# wordwr, full 256 MB (the cache write-buffer shape)
tools/vivado/ddr3_bist.tcl build/stageA3/minimig_openaars_top.bit "6" 28 align 5 11
```

Reading the result:

* **0 errors on both** - the DM path is sound and the fast-RAM corruption is
  above the island: the cache backend's byte-enable construction, the CDC, the
  wrapped-burst read order, or the TG68K handshake.
* **errors on 5 but not 6** - the failing masks are the exotic ones; read
  `first_err_addr`, take `c = addr[8:4]` and look the mask up in the table
  above to see which byte enables are broken.
* **errors on both** - the DM lanes / write path itself. `first_err_xor`
  (low 32 bits of expected XOR read) says which of bytes 0..3 moved when they
  should not have, or failed to.

---

# Wrapper bus-cycle classification bug

Date 2026-09-05. This is the defect behind "the island passes every BIST
pattern over the full 256 MB but the Amiga still sees garbage in fast RAM"
that the masked-write section above was written to chase. It is not in the
island at all. It is in `rtl/soc/TG68K.vhd`, one missing term.

Fixed in commit `9e03809`. Regression bench: `sim/ddr3_cpu`.

## Symptom

With `build/stageB2` (`HAVEDDR3=1`, Zorro-III fast RAM on the DDR3):

* the board autoconfigures and the OS accepts it, but `avail` reports only the
  **2 MB Zorro-II** board -- the 16 MB Zorro-III one contributes nothing,
* the exec **MemHeader at 0x40000000 is garbage**: the OS walks it, does not
  like what it finds, and drops the board,
* reads come back **stale** -- the value the CPU gets is a value that address
  held at some earlier moment, not the one the island just returned,
* one boot got far enough to load a program into fast RAM and died with a
  **privilege violation** (`Ramlib Program failed (error #80000008)`),
* meanwhile `tools/vivado/ddr3_bist.tcl` gives 0 errors on all seven BIST
  patterns over the full 256 MB, including the masked-write ones, and
  `sim/ddr3_full` passes every check.

## Recorder evidence

`tools/vivado/ila_fastram_capture.tcl` armed on the first `cpuena` after
`ddr_ready`, storage-qualified to cycles that carry information (a CPU select
or a non-idle backend). `build/stageB2/boot.csv`, 288 stored samples of a real
Workbench boot:

| Observation | Value |
|---|---|
| Distinct CPU byte addresses in the whole capture | **8**: 0x0, 0x2, 0x4, 0x6, 0x8, 0xa, 0x10, 0x12 |
| What those addresses are | bytes 0..0x13 of the board: `ln_Succ`, `ln_Pred`, `ln_Type`/`ln_Pri`, `ln_Name`, `mh_Attributes`, `mh_First` |
| Acknowledged read data at byte 0x0 | `0000`, `4000` **and** `ffff` |
| Acknowledged read data at byte 0x2 | `0000`, `0044` **and** `ffff` |

Two things to read off that. First, **header-only traffic**: over an entire
boot the CPU never touched anything past offset 0x13 of a 16 MB board. The OS
reads the header, decides the board is nonsense, and never allocates from it --
which is exactly what "avail shows 2 MB" means.

Second, **the data changes under the acknowledge**: the same longword of the
same header, read with `cpuena` high, is acknowledged with three different
values in one capture. The island had not changed the DRAM between those
reads; what changed was *when* the CPU was allowed to latch `fromddr`.

## Mechanism

Task 4 moved the Zorro-III selects out of `sel_ram` and into a new `sel_ddr`:

```vhdl
sel_ddr         <= (sel_z3ram OR sel_z3ram2) AND have_ddr;
sel_z3ram_sdram <= (sel_z3ram OR sel_z3ram2 OR sel_z3ram3) AND NOT have_ddr;
sel_ram         <= '1' WHEN (sel_z2ram = '1' OR sel_z3ram_sdram = '1' OR ...
```

`ramcs`/`ddrcs`, `datatg68` and `mem_ready` were all updated to know about the
new select. `chipset_cycle` was not:

```vhdl
chipset_cycle <= '1' when (sel_ram = '0' OR sel_nmi_vector = '1')
                 AND sel_akiko = '0' and sel_undecoded = '0' else '0';
```

With `haveddr3 = true`, `sel_ram` is `'0'` for every Zorro-III access, so
**every DDR3 access was classified as a 7 MHz chipset bus cycle**. Two
consequences, and the second is the damaging one.

1. The `S_state` machine starts a real 68000-style chipset cycle for it:
   `as` low, `addr`/`data_write` driven, `dtack` sampled. Harmless in itself
   (nothing on the chipset bus answers at 0x40000000), but it means the machine
   is *running* whenever the CPU is doing fast RAM.

2. That machine grants `clkena`:

   ```vhdl
   clkena <= '1' WHEN (clkena_in = '1' AND (state = "01"
             OR (ena7RDreg = '1' AND clkena_e = '1')
             OR (ena7WRreg = '1' AND clkena_f = '1')
             OR mem_ready = '1' OR sel_undecoded_d = '1' OR akiko_ack = '1'));
   ```

   `mem_ready` is the only term qualified with `ddr_ena`/`ddr_ready`/`sel_ddr_d`.
   `clkena_e` and `clkena_f` are set by the chipset state machine and gated only
   by the 7.09 MHz strobes `ena7RDreg`/`ena7WRreg`. Because the chipset machine
   free-runs at its own cadence while the CPU is being released by the DDR3
   acknowledge, `S_state` drifts out of step with the accesses and issues
   `clkena` at essentially arbitrary points -- including in the middle of a
   DDR3 read that has not come back yet. The kernel then latches whatever
   `datatg68` (= `fromddr`, since `sel_ddr_d` is high) holds at that instant:
   the previous word delivered on that port, or the untouched output of the
   cache. Writes are retired the same way, before the write buffer has taken
   them.

That is precisely "reads return stale data" and "the same address acknowledges
three different values". It is invisible to every BIST pattern and to
`sim/ddr3_full`, because both of those drive the island (or `ddr3_fastram`'s
CPU port) directly and never go through the wrapper's cycle classification.

## Fix

`rtl/soc/TG68K.vhd`, commit `9e03809`:

```vhdl
-- A DDR3 (Zorro III) access is a memory cycle released by the DDR3 acknowledge,
-- never a 7 MHz chipset cycle.
chipset_cycle <= '1' when ((sel_ram = '0' AND sel_ddr = '0') OR sel_nmi_vector = '1')
                 AND sel_akiko = '0' and sel_undecoded = '0' else '0';
```

A DDR3 access is now a memory cycle in exactly the sense an SDRAM access is:
the chipset machine stays idle for it and the only thing that can release the
CPU is `mem_ready`, i.e. `ddr_ena AND sel_ddr_d AND ddr_ready`.

`haveddr3 = false` is unaffected: `sel_ddr` is constant `'0'` there and the
expression collapses to what it always was.

## The new bench: `sim/ddr3_cpu`

The lesson of this bug is that **no simulation existed of the thing that broke**.
`sim/ddr3_island` proves the controller and the PHY; `sim/ddr3_full` proves the
cache backend, the CDC and the byte lanes by driving `ddr3_fastram`'s CPU port
with hand-written tasks. Neither contains a TG68K, so neither can see how the
wrapper decides what kind of bus cycle an address deserves.

`sim/ddr3_cpu` closes that gap. It is a mixed VHDL/Verilog xsim bench (same
flow as `sim/ddr3_full`, extended with the VHDL half of the design) in which

* the DUT is the **real** `rtl/soc/TG68K.vhd` with `haveddr3` true, the real
  `TG68KdotC_Kernel` and `akiko` inside it, wired to the real
  `rtl/ddr3/ddr3_fastram.v`, `rtl/ddr3/ddr3_top.v` and the Micron DDR3 model
  exactly as `rtl/soc/minimig_virtual_top.v` wires them (`cpustate` bit 2
  replaced by `ddrcs`, `fromddr`/`ddr_ena`/`ddr_ready`, `cpu_cache_ctrl` from
  `CACR_out`),
* `ena7RDreg`/`ena7WRreg`/`enaWRreg` are generated with the real `sdram_ctrl`
  cadence (16 sysclk per 7.09 MHz period; `enaWRreg` at ph2/6/10/14,
  `ena7RDreg` at ph6, `ena7WRreg` at ph14), so the chipset strobes that
  released the CPU in the broken design are present and ticking,
* autoconfig state is post-boot: `ziiram_active` and `ziiiram_active` high,
  so 0x40000000 is a live Zorro-III board, `cpu = "11"` so the 32-bit space
  decodes,
* only the **SDRAM side is a model** -- a behavioural 128 kB word memory
  holding the 68k program, its vectors, its stack and a mailbox, answered on
  both the `fromram`/`ramready` port and the chipset bus (the reset vector
  fetches happen before `turbochip_d` is set and really do go out as chipset
  cycles).

A real 68k program (`asm/ddr3_cpu_test.asm`, assembled with the
`sim/tg68vswf68ksim` vasm flow) then

1. writes a pattern over the fast RAM with **byte, word and longword stores**,
   four values per 16-byte cache line,
2. reads it back with byte, word and longword loads (`cpu_cache_new` has no
   write allocate and does not update tags on writes, so every one of these is
   a real DDR3 line fill),
3. writes and re-reads longwords at offsets 2, 6, 10 and 14 of each line --
   **misaligned in the line**, and the one at 14 straddles into the next line,
   which is the case `longword_en` excludes from the single-request path,
4. writes an **exec MemHeader** at 0x40000000 (`ln_Succ`, `ln_Pred`, `ln_Type`,
   `ln_Name`, `mh_Attributes`, `mh_First`, `mh_Lower`, `mh_Upper`, `mh_Free`)
   and reads every field back, `mh_Free` with its own failure code,
5. runs a **running-counter loop**: store the next counter at the next address,
   then immediately read back both the previous location and the one just
   written (back-to-back write then read),

and writes a pass code, or a failure code plus the first mismatch address,
expected and got, to a mailbox at 0x00001000 in the bench RAM. The bench prints
`DDR3 CPU TB: PASS` or `FAIL code N` with those three values, traces a phase
marker so a timeout still says how far the program got, and then **checks the
DRAM independently** through the Micron model's backdoor (`memory_read`, with
the vendored core's RBC address decode) so a program that "passed" out of its
own cache cannot hide a DRAM that never received the data.

The pattern region is **1 kB (64 cache lines) rather than the full 64 kB**, and
the misaligned and counter regions are 16 lines and 64 longwords. The whole
chain is simulated down to the ISERDES/OSERDES, so every DDR3 write is a real
100 MHz round trip and the read-back phase is 68k-instruction bound at about
6.7 us of simulated time per cache line; the default sizes come to roughly
0.8 ms of simulated time and 15-20 minutes of wall clock, and 64 kB would be
about an hour a run. The sizes are a command-line argument
(`PATBYTES=... MISLINES=... CNTN=... run.sh`), passed to both vasm and the
bench so the two cannot disagree.

### It has teeth

`mutant/TG68K_mutant.vhd` is the wrapper with the `AND sel_ddr = '0'` term
removed -- the code as it stood before `9e03809`. `./run.sh --mutant` compiles
that copy instead of the real file (the committed `rtl/soc/TG68K.vhd` is never
touched). Both logs are checked in.

Real file, `xsim_run_pass.log`:

```
INFO: program phase 1 at  67042482.0 ps
INFO: program phase 2 at 208011962.0 ps
INFO: program phase 3 at 639946962.0 ps
INFO: program phase 4 at 729331062.0 ps
INFO: program phase 5 at 740402702.0 ps
INFO: program phase 6 at 847064202.0 ps

DDR3 CPU TB: PASS  (68k program completed all phases)

INFO: checking the DDR3 array through the Micron model backdoor
PASS: DDR3 array contents match the pattern (independent backdoor read)

DDR3 CPU TB: 2 passed, 0 failed
```

Mutant, `xsim_run_mutant.log`:

```
INFO: program phase 1 at  67042482.0 ps
INFO: program phase 2 at 212172642.0 ps

DDR3 CPU TB: FAIL code 2  pattern read-back, BYTE load
       first mismatch address : 40000000
       expected               : 000000c0
       got                    : 00000000
       last phase reached     : 2

INFO: checking the DDR3 array through the Micron model backdoor
       DRAM mismatch at 40000042: expected 0010 got 000a
       DRAM mismatch at 40000046: expected 0011 got 000b
       DRAM mismatch at 4000004a: expected 0012 got 000c
       ...
FAIL: DDR3 array contents wrong in 439 places (independent backdoor read)
```

Two things in that mutant log are worth reading carefully, because both are
also what the board did.

* The **first** byte of the read-back, at `0x40000000`, is already wrong: the
  program wrote `0xC0` there and reads `0x00`. That is the byte the OS reads
  first when it walks the MemHeader.
* The independent backdoor read shows the mutant does not only mis-read, it
  **loses writes**. From cache line 4 onwards the DRAM holds pattern values
  that are progressively behind the ones the program stored (`expected 0010 got
  000a`, and the gap grows), because the spurious `clkena` retires a write
  before `cpu_cache_new` has taken it. The first three lines happen to be
  intact -- the free-running chipset state machine needs a few accesses to
  drift into the wrong phase, which is exactly why a short BIST-style burst
  never caught this and a running OS did.

### Running it

```
export LD_LIBRARY_PATH=<shim with libtinfo.so.5>
sim/ddr3_cpu/run.sh              # real wrapper   -> xsim_run_pass.log,   PASS
sim/ddr3_cpu/run.sh --mutant     # pre-fix copy   -> xsim_run_mutant.log, FAIL
```

Each takes roughly 15-20 minutes; they build and assemble into separate
directories (`run_pass/`, `run_mutant/`) and can run at the same time.  For a
quick change-and-see loop the region sizes and a port trace are on the command
line:

```
PATBYTES=64 MISLINES=2 CNTN=8 TRACE=1 sim/ddr3_cpu/run.sh     # ~6 minutes
```

`TRACE=1` prints every DDR3 chip-select, every acknowledge and every island
request (`TRACE CPU ... sel/ack`, `TRACE REQ ...`), which is what identified
the two bench bugs below.

### Two things that bit while writing it, worth knowing

* **The PHY read alignment must be left at the module defaults here.**
  `sim/ddr3_island` drives `phy_cfg_valid` with `rdsel` 15 because it inserts a
  DQ/DQS transport delay to stand in for tDQSCK; `sim/ddr3_full` and this bench
  insert no skew, so the right setting is `phy_cfg_valid = 0`, i.e.
  `TPHY_RDLAT(5)` / `RDSEL_INIT(11)` out of `ddr3_top.v`.  Driving the island
  bench's value here moves the sample point off the eye: every write still
  lands in the DRAM correctly and every read comes back as the wrong beat, so
  the backdoor check passes on data the CPU cannot read.  That failure looks
  uncannily like the wrapper bug and is not.
* **A `time` literal above 2^31 must be sized.** `localparam time TIMEOUT =
  2_500_000_000;` is an unsized decimal, therefore 32-bit *signed*, therefore
  negative, and `#TIMEOUT` is then zero delay -- the bench "timed out" at 4 ns
  and reported a DRAM full of X. `64'd2_500_000_000` is correct.

## What to take from this

The island benches and the BIST answer "does the memory work". They cannot
answer "does the CPU wrapper treat this address as memory". Any future change
that moves a select between `sel_ram`, `sel_ddr` and the chipset path must be
re-checked against **all four** places that consume those selects --
`ramcs`/`ddrcs`, `datatg68`, `mem_ready` and `chipset_cycle` -- and
`sim/ddr3_cpu` is the bench that will notice when one is missed.
