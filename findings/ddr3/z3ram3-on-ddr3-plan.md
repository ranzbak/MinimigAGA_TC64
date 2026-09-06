# Plan: DDR3 as an additional Zorro-III board (the Z3RAM3 slot)

Date 2026-09-06. Status: **plan only, nothing implemented, nothing built.**

## Goal

DDR3 fast RAM must be *extra* memory, added on top of what the SDRAM already
provides, not a replacement for part of it.

Today (HAVEDDR3=1, OSD Fast RAM = Maximum) the OS sees 26 MB:

| Region | Backing | Size |
|---|---|---|
| Chip | SDRAM | 2 MB |
| Zorro-II board 0 ($200000) | SDRAM | 8 MB |
| Zorro-III board 1 ($40000000) | **DDR3** | 16 MB |
| Zorro-III board 3 ("leftover") | disabled (design.md D8) | 0 |

Without DDR3 the same core gives 30 MB: the same first three rows on SDRAM
plus the 4 MB leftover board. DDR3 therefore currently *costs* 4 MB, because
`TG68K.vhd` routes one and the same Zorro-III decode to either backend:

```vhdl
sel_ddr         <= (sel_z3ram OR sel_z3ram2) AND have_ddr;
sel_z3ram_sdram <= (sel_z3ram OR sel_z3ram2 OR sel_z3ram3) AND NOT have_ddr;
```

Target after this change (16 MB DDR3 board first; 64 MB is a two-line follow-up):

| Region | Backing | Size |
|---|---|---|
| Chip | SDRAM | 2 MB |
| Zorro-II board 0 | SDRAM | 8 MB |
| Zorro-III board 1 ($40000000) | SDRAM | 16 MB |
| Zorro-III board 2 (only if `ram_64meg`) | SDRAM | 32 MB |
| Zorro-III board 3, base assigned by the OS | **DDR3** | 16 MB (later 64 MB) |

Total 42 MB, and the SDRAM side is bit-identical to the 30 MB configuration
the board already runs reliably. The 4 MB SDRAM leftover is given up in the
DDR3 build (its slot is what DDR3 takes); it could return later as a 4th board
in the unused `acdevice = 3'b100` slot, see "Later".

## Why the Z3RAM3 slot, and why a dynamic base

* Board 3 already exists in the autoconfig chain (`acdevice = 3'b011`,
  ROM entry `z3base3`, enable `ziiiram3_active = board_configured[3]`,
  `sel_z3ram3` in TG68K). No new chain mechanics are needed.
* Board 3 is disabled today because of a known bug, and that bug is the one
  thing this plan has to fix anyway: the OS assigns Zorro-III bases from its
  own free list (it put the 4 MB board at $08000000; the bench in
  `sim/autoconfig` reproduces this), while `TG68K.vhd` *guesses* the base:

  ```vhdl
  sel_z3ram3_dec <= '1' WHEN cpuaddr(31 downto 30) = "01" and cpuaddr(26) = z3ram2_ena
                             and cpuaddr(24) = not z3ram2_ena and z3ram3_ena = '1' ...
  ```
  i.e. $41000000 (or $44000000 with board 2), never what the OS wrote.

* **None of the RAM boards latch their assigned base.** `minimig_autoconfig.v`
  stores only the Toccata's (`board_base_addr[4]`); boards 0-3 rely on the
  OS's allocator being predictable. Boards 0 and 1 get away with it ($200000
  and $40000000 are always the first free slots). This plan latches board 3's
  base and decodes against it. Making boards 1 and 2 dynamic too is the same
  three lines each and is listed under "Later" so that the SDRAM path stays
  untouched for the first bring-up.

## Changes, file by file

### 1. `rtl/minimig/minimig_autoconfig_rom.v` -- board 3 advertises the DDR3 size

Add a parameter `Z3RAM3_DDR3` (default 0) and pick the `z3base3` entry from
it in the `initial` block. Today's entry is a 4 MB Zorro-III memory board
without the extended-size flag:

```verilog
ram[z3base3+'h2/2] = 4'b0111;   // 4MB
ram[z3base3+'h8/2] = 4'b0010;   // Memory card, not silenceable, reserved
ram[z3base3+'ha/2] = 4'b1000;   // 0111 - 2 meg   (logical size, inverted)
```

With `Z3RAM3_DDR3 = 1` use the same shape as board 1 (`z3base`), which the
OS already accepts as a 16 MB board:

```verilog
ram[z3base3+'h2/2] = 4'b0000;   // size code 000 = 16 MB with the extended-size flag
ram[z3base3+'h8/2] = 4'b0000;   // memory, not silenceable, extended size
ram[z3base3+'ha/2] = 4'b1111;   // logical size = physical size
```

Keep product ID / serial distinct from board 1 (they already are: 0x11 / #3).

For 64 MB later: `'h2/2 = 4'b0010` (code 010 = 64 MB extended). Nothing else
in the ROM changes.

### 2. `rtl/minimig/minimig_autoconfig.v` -- latch the base, stop resizing board 3

* New parameter `Z3RAM3_DDR3`, passed down to `Autoconfig_ROM`.
* New output `z3ram3_base [7:0]` = A31-A24 of the assigned base.
* In the register-44 handler (`case(acdevice)` at the `9'h044` arm), for
  `3'b011` add:

  ```verilog
  board_base_addr[3] <= data_in[15:8];
  ```

  Byte choice: the OS configures a Zorro-III PIC sitting in the Zorro-II
  configuration block by writing register 44 with A31-A24 in the **upper**
  data byte (Zorro III spec 8.2, `doc/amiga/zorro3.pdf`). A 68k byte write to
  the even address $44 also lands on D15-D8, and TG68K replicates bytes on
  both halves, so `[15:8]` is right for a word write and for a byte write
  alike. (The Toccata code takes `[7:0]` from the $48 write; with replication
  both halves carry the same byte, which is why that works.) This is
  *verified on hardware* in bring-up step H2 before anything depends on it.

* The board-1 44 handler currently rewrites board 3's logical-size nibble
  (`roma_wr <= {3'b011, 6'h05}; ramsize <= |slowram_config ? 4'b1000 : 4'b0111`).
  Guard that write with `!Z3RAM3_DDR3` (or write `4'b1111`), otherwise the
  16 MB board is offered with a 2/4 MB logical size.
* `ac_next` and the shut-up handler need no change: with `Z3RAM3 = 1` the
  chain already goes 0 -> 1 -> (2) -> 3 -> Toccata -> NULL.

### 3. `rtl/minimig/minimig.v` -- plumb it out

* Parameter `Z3RAM3_DDR3` on `minimig`, passed to `minimig_autoconfig`.
* Output `z3ram3_base [7:0]`, wired from the autoconfig instance
  (next to `board_configured` / `toccata_base_addr`, ~line 1125-1146).

### 4. `rtl/soc/TG68K.vhd` -- decode board 3 from the latched base, route it to DDR3

New port:

```vhdl
z3ram3_base : in std_logic_vector(7 downto 0) := (others => '0');
```

New generic `z3ram3_size_log2 : integer := 24` (16 MB; 25 = 32 MB, 26 = 64 MB).

Decode (replaces `sel_z3ram3_dec`; the board is size-aligned, so compare the
bits above the size):

```vhdl
-- 16 MB: compare cpuaddr(31 downto 24) = z3ram3_base
-- 64 MB: compare cpuaddr(31 downto 26) = z3ram3_base(7 downto 2)
sel_z3ram3 <= '1' WHEN cpuaddr(31 downto z3ram3_size_log2) =
                       z3ram3_base(7 downto z3ram3_size_log2 - 24)
                   AND z3ram3_ena = '1' ELSE '0';
```

Concretely in today's file: line 271 defines `sel_z3ram3_dec` (the guess) and
line 275 has `sel_z3ram3 <= sel_z3ram3_dec AND NOT have_ddr;` with a comment
explaining why the board is dead under DDR3. Delete `sel_z3ram3_dec` and its
declaration, and assign `sel_z3ram3` directly from the compare above --
**without** the `NOT have_ddr` term; the backend choice is made in the
routing lines below, not in the select.

`z3ram3_ena` is already the registered `ziiiram3_active`, so an unconfigured
board (base register 0) is never selected. `sel_undecoded` already includes
`sel_z3ram3`, so a base of $08000000 (`sel_32 = '1'`) is decoded, not
auto-completed. Give `sel_z3ram3` precedence over the hard-wired `sel_z3ram` /
`sel_z3ram2` (AND them with `NOT sel_z3ram3`) so an OS placement inside a
range the fixed decodes cover can never hit two backends.

Routing:

```vhdl
sel_ddr         <= sel_z3ram3 AND have_ddr;
sel_z3ram_sdram <= sel_z3ram OR sel_z3ram2 OR (sel_z3ram3 AND NOT have_ddr);
```

`haveddr3 = false` is then exactly today's SDRAM core, except that board 3 is
finally decoded where the OS put it (the D8 bug fixed for the SDRAM build
too). The SDRAM `ramaddr` remap for `sel_z3ram3` (bank-0 leftover mapping,
lines ~350-356) is unchanged and only reachable when `NOT have_ddr`.

DDR3 address: today `ddraddr <= cpuaddr(25 downto 1)` (identity, design.md
D6). Board 3 can sit anywhere, so the DDR3 address is the offset inside the
board, which for a size-aligned board is just the low bits:

```vhdl
-- ONE concurrent assignment.  Two assignments to slices of the same signal
-- (a zero fill plus a partial overwrite) are two drivers of a std_logic
-- signal: legal-looking, resolves to 'X' in simulation, and synthesis
-- either errors or ANDs the drivers.  Build the value in one expression.
ddraddr <= (25 downto z3ram3_size_log2 => '0')
           & cpuaddr(z3ram3_size_log2 - 1 downto 1);
```

For `z3ram3_size_log2 = 26` the zero-fill slice is null and this is the
identity map again (write it as a `generate` or `if z3ram3_size_log2 = 26`
branch if the tool refuses the null aggregate). `cpu_cache_new`'s 14-bit tag over
`cpu_adr[25:12]` covers 64 MB, so nothing below TG68K changes for any of the
three sizes. Everything else on the DDR3 side (`ddrcs`, `mem_ready`,
`chipset_cycle`, the `fromddr` mux, the ILA taps) keys off `sel_ddr` and is
untouched.

### 5. `rtl/soc/minimig_virtual_top.v` / `minimig_openaars_top.v`

* `.Z3RAM3(...)`: board 3 is always offered now. Replace
  `(haveddr3 || Z3RAM3_FORCE_OFF) ? 1'b0 : 1'b1` with `Z3RAM3_FORCE_OFF ? 1'b0 : 1'b1`
  (keep the diagnostic knob; it is committed and harmless).
* `.Z3RAM3_DDR3(haveddr3)` on `minimig`.
* Wire `z3ram3_base` from `minimig` to the new TG68K port, next to
  `ziiiram3_active` (lines ~631-634).
* Pass `z3ram3_size_log2 => 24` to TG68K (a top-level parameter so 64 MB is a
  build-time switch together with the ROM nibble).

### 6. Documentation

* `findings/ddr3/design.md`: D6 (identity map) becomes "offset inside board
  3"; D8 is superseded (board 3 is the DDR3 board); update the architecture
  diagram (`sel_z3ram3 -> ddr_cs`).
* `rtl/minimig/minimig_autoconfig.v` header comment on Z3RAM3.
* `tools/vivado/ila_fastram_capture.tcl` header: the first DDR3 access is no
  longer the Kickstart relocation at $40000000 (see "Interaction with the
  crash" below).

## Verification before any synthesis

### S1. `sim/autoconfig/autoconfig_tb.sv` (Icarus, `run.sh`)

The bench already models the OS allocator (`z3big` pool from $40000000,
`z3small` from $08000000) and both write orderings (WRPOL 0/1). Extend it:

* Instantiate with `Z3RAM3 = 1, Z3RAM3_DDR3 = 1`: check the ROM now offers
  board 3 as 16 MB (`ac_reg` of 02/08/0a) and that the model allocates it from
  the big pool ($41000000 with no board 2, $44000000 with `ram_64meg`).
* After the chain completes, `z3ram3_base == base[31:24]` for **both**
  WRPOL orderings (this is the test of the `[15:8]` byte choice under the
  bench's model of the bus).
* Regression: `Z3RAM3_DDR3 = 0` still offers 4 MB and lands at $08000000, and
  the Toccata base is still correct (the earlier 44/48 bug).

### S2. TG68K decode bench (extend `sim/ddr3_cpu`)

`sim/ddr3_cpu` runs under xsim (mixed language) and instantiates the **real**
`rtl/soc/TG68K.vhd` (`ddr3_cpu_tb.sv` line ~188) next to `ddr3_fastram`
(~275); `run.sh` swaps in `mutant/TG68K_mutant.vhd` for the mutant run.
Things in that bench that this change invalidates and that must be updated
first, or the bench fails for the wrong reason:

* the `TG68K` instantiation needs the new `z3ram3_base` port and the
  `z3ram3_size_log2` generic -- in the bench **and** in
  `mutant/TG68K_mutant.vhd` (a copy of the entity; regenerate the mutant
  from the new file, do not hand-patch it);
* the bench's DDR3 accesses go to board 1 (`ziiiram_active`, $40000000) and
  its header (line ~32) states `cpuAddr = ddraddr = cpuaddr(25 downto 1),
  identity mapped`. Move them to board 3: drive `ziiiram3_active = 1` and
  `z3ram3_base`, and change the expected `cpuAddr` to the offset inside the
  board;
* `run_pass` / `run_mutant` compare against logs (`xsim_run_pass.log`,
  `xsim_run_mutant.log`); refresh the golden output once the above is done
  and read the diff, do not just overwrite it.

Then add a test that drives `ziiiram3_active = 1`, `z3ram3_base = 8'h41`
(and once `8'h08`) and checks:

* an access at base + offset asserts `ddrcs` with `ddraddr = offset(25:1)`
  (upper bits zero for 16 MB);
* an access at $40000000 asserts `ramcs`, not `ddrcs` (board 1 is SDRAM now);
* an access at base with `ziiiram3_active = 0` asserts neither and completes
  through `sel_undecoded` (no hang);
* the existing pass/mutant scripts (`run_pass`, `run_mutant`) still hold.

### S3. Full-core sim smoke (optional, cheap)

Whatever bench boots Kickstart far enough to see autoconfig
(`sim/tg68vswf68ksim` if it does): confirm the OS writes 44 for board 3 and
the latched base matches the address it subsequently touches.

## Hardware bring-up (after S1/S2 pass; no synthesis before that)

* **H1** Build HAVEDDR3=1 with the ILA build variant, program **by
  reprogramming, not soft reset** (design.md lessons). OSD Fast RAM = Maximum.
* **H2** Verify the base byte: `ShowConfig` (or ATK's board list) shows the
  DDR3 board's address; the ILA gets one extra probe on `z3ram3_base` (or the
  full latched 16-bit word for the first build) and must read the same
  A31-A24. If it reads the low byte instead, the fix is `data_in[7:0]` --
  one line -- and step S1's bus model was wrong, so fix the bench too.
* **H3** `avail`: expect 2 + 8 + 16 + 16 = 42 MB (plus 32 if `ram_64meg`).
* **H4** ATK raw test on $40000000-$40FFFFFF (now SDRAM): must be as solid as
  the 30 MB build. ATK raw test on the DDR3 board's range: the existing
  behaviour (passes when run after boot).
* **H5** Workbench copy of a large file to RAM: and back, then again after
  30 minutes warm (design.md verification item 4).

## Interaction with the open DDR3 crash

The intermittent Guru (8000_0004 / 8000_0008, task at DDR3 offset $32E8) is
in the shared DDR3 path (`ddr3_fastram` / cache / CDC / island), which this
plan does not touch. Be explicit about what the restructure does to it:

* Exec adds memory in autoconfig order, so early allocations (Kickstart
  relocation, the DH0 handler's task) will land in board 1 -- SDRAM -- after
  this change. The crash will very likely **stop showing at boot without
  having been fixed**; it moves to whenever the OS first spills into board 3.
* So the crash investigation stays open and should continue in parallel with
  the capture already proposed: trigger on `ddr_ready` rising with the
  trigger position near 0, so the buffer covers the first burst of CPU traffic
  the moment the settling counter in `ddr3_fastram.v` releases the CPU
  (`init_done -> 2-flop sync -> 255-cycle counter -> reset/ddr_ready`). After
  the restructure that first burst happens later in the boot; the trigger is
  the same.
* H4's DDR3-range ATK test is the regression check for the path itself.

## Order of work for whoever implements this

Each step is a separate commit; the benches gate the next step.

1. `minimig_autoconfig_rom.v` + `minimig_autoconfig.v` (sections 1-2).
   Run S1 (`sim/autoconfig/run.sh`, Icarus). Commit.
2. `minimig.v` plumbing (section 3). Compiles in S1's iverilog run only if
   the bench pulls in minimig.v -- it does not, so check with a quick
   `xvlog` or the S2 build.
3. `TG68K.vhd` (section 4) and both tops (section 5). Run S2
   (`sim/ddr3_cpu/run.sh`, xsim; note the `libtinfo.so.5` shim and
   "no `-stack`" rules in `tools/vivado/build.tcl`'s header apply to every
   Vivado 2023.2 invocation on this machine). Commit.
4. Docs (section 6). Commit.
5. Only then H1-H5. Use `tools/vivado/build.tcl` for the normal build and
   `tools/vivado/build_bist.tcl` as the template if an ILA/VIO variant is
   wanted; `build_no_ddr3.tcl` / `build_no_ddr3_clean.tcl` are the
   `HAVEDDR3=0` diagnostics and stay as they are.

Do not touch `rtl/ddr3/*`, `rtl/sdram/cpu_cache_new.v` or the DDR3
constraints for this change; if a step seems to need it, the step is wrong.

## Later (not in this change)

* 64 MB DDR3 board: ROM nibble `'h2/2 = 4'b0010` and `z3ram3_size_log2 = 26`.
  Beyond 64 MB needs the `cpu_cache_new` tag widened (design.md stage C).
* Boards 1 and 2 decoded from latched bases too (same latch in the 44
  handler, same compare in TG68K); removes the last hard-wired guesses.
* The 4 MB SDRAM leftover back as a 4th board in the free `3'b100` slot.
* `fw/ctrl_832` OSD memory menu, if it wants to show the DDR3 size.

## Risks

| Risk | Where it shows | Mitigation |
|---|---|---|
| Wrong data byte for A31-A24 | H2: board address vs latched base disagree | S1 exercises both orderings; H2 checks on hardware; one-line fix |
| OS places board 3 inside a fixed decode's range | two backends selected | `sel_z3ram3` has precedence; S2 covers $41000000 |
| Board 3 offered while board 2 also exists (`ram_64meg`) | base $44000000 | S1 case with `ram_64meg = 1` |
| SDRAM path regresses for board 1 | H4 on $40000000 | it is the 30 MB build's path, unchanged; S2 asserts `ramcs` |
| Crash appears "fixed" by relocation | H3-H5 look clean | stated above; keep the ddr_ready capture on the list |
