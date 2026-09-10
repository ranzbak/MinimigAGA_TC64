# AGA/ECS chipset fixes present in MiSTer Minimig and absent here

Research note, 2026-09-10. Read-only survey; no RTL was changed.

- This tree: `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64`, branch `ap040-d3-enable-scheme`, chipset in `rtl/minimig/`.
- Reference: `~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer`, remote **`origin` = `MiSTer-devel/Minimig-AGA_MiSTer`** (canonical; the `apol` remote is apolkosnik's fork and was not used as the reference). Branch `origin/MiSTer`, head at survey time `002eef2c` "agnus: revert #232, delay vertical beam readback by one colour clock" (2026-09-08) — one commit newer than the "#235" head named in the task.
- The clone was fetched but never checked out; comparisons were made against `git archive origin/MiSTer rtl` exported to a scratch directory, **not** against its working tree, which sits on a detached `apol/ap040` head and is stale for several of these files.

## Summary

**34 candidate commits examined** across the whole `rtl/` history of `origin/MiSTer` (the full log is 120 commits over `rtl/`; build files, `sys/` updates, TG68K/FX68K drops, RTG and audio-DAC work were filtered out by reading their subjects and diffstats). Of those, **21 are chipset-behaviour commits** and 13 are not applicable to this platform. Breaking the 21 down:

- **12 commits carry fixes we lack** — 14 separate findings, because two of the commits fix two unrelated defects each. All confirmed by reading our code, not by hash.
- **1 further structural divergence** we lack, with no attributed defect (finding 2.1).
- **6 are pre-fork common ancestry and we already have them** (verified byte-identical or logically identical).
- **2 are a fix and its own revert** and cancel out — do not port either.
- The **13 not-applicable** ones are a different module here, have no consumer here, or are MiSTer-only plumbing (Group 4).

The three that matter most:

1. **`#235` Gary decodes the custom registers across the whole of `$C00000-$DFFFFF`, not just `$DFxxxx`** (`gary.v:200`). Any guest touching `$D8xxxx`, `$DBxxxx`, `$DDxxxx`, `$DExxxx` outside Gayle, or `$C0-$D7` when slow RAM does not cover it, writes a *real custom register* chosen by address bits 8:1. MiSTer traced a reproducible display-kill to WhichAmiga 1.4 writing `$00DD0080` = COP1LCH. One-line change, no timing consequence, highest value per unit of risk of anything in this list.
2. **`#230` CIA Timer A has no CNT input at all** (`cia_timera.v:32`, `assign count = eclk;`). CRA bit 5 is stored and ignored, so a timer told to count CNT edges counts the 709 kHz E-clock and underflows within 92 ms where real hardware never underflows. MiSTer's case is Crystal Kingdom Dizzy [cr FLT] hanging on a black screen. Timer B only decodes CRB bit 6, collapsing all four INMODE modes onto two.
3. **The seven robinsonb5 ("AMR") demo fixes that reached MiSTer through the MiST core and never reached the TC64 line** — Hybris sprites, Sanity Roots 2.0, Andromeda Nexus 7, Contraz Domination, Essence Crazy Sexy Cool, RAMJAM Copperslave, Desire Hamazing. These are the single largest cluster and they are all small, self-contained diffs against files that are otherwise close to identical between the trees.

### Why this gap exists

`upstream` here is `robinsonb5/MinimigAGA_TC64`, which is **archived at 2021** (its last commit is literally "Added archive message."; `upstream/master` is *not* an ancestor of our HEAD, and we lack e.g. `edc53d2` — see the "adjacent" section). Meanwhile robinsonb5 kept fixing the *MiST* Minimig core, and MiSTer pulled those fixes across between 2024 and 2026 with commit messages that say "ported from MiST" and "kudos to Allistair Robinson". So the fixes are by the same author as our upstream, but they travelled by a route that bypassed this fork entirely. Our tree in turn carries AMR border-blank work (`denise.v` `blank_d`, the reversed HDIWSTRT/HDIWSTOP comparison, `t_blank` including `blank`) that MiSTer does **not** have. The two trees hold different, partly overlapping subsets of the same author's fixes.

---

# Group 1 — Clearly missing and self-contained

Each of these touches one or two files that are otherwise near-identical between the trees. Port order below is roughly increasing risk.

## 1.1 Gary decodes custom registers across 2 MB instead of 64 KB

- **Defect, observable:** a CPU access anywhere in `$C00000-$DFFFFF` that is not slow RAM, RTC, IDE or Gayle lands on a custom register selected by address bits 8:1. Writing `$00DD0080` writes COP1LCH; the copper list pointer is destroyed and the display goes blank for the rest of the session. Reads from those holes return live custom-register contents.
- **MiSTer commit:** `74d6ce0a` "gary: decode the custom registers at $DFxxxx, not across all of $C0-$DF (#235)", 2026-08-28.
- **Their code:** `rtl/gary.v`, `assign sel_reg = cpu_address_in[23:16]==8'b1101_1111;`
- **Our code:** `rtl/minimig/gary.v:200`, still `cpu_address_in[23:21]==3'b110 ? ~(|t_sel_slow | sel_rtc | sel_ide | sel_gayle) : 1'b0`. Note our `gary.v` also decodes `sel_toccata`, but the Toccata base is autoconfigured into `$E9xxxx`/Zorro space and does not overlap, so the carve-out list is the same problem verbatim.
- **Status:** **we lack it.** Same defect, same line, no restructuring.
- **Risk/effort:** lowest in this document. One line. The four carve-outs become dead but harmless; they can be deleted in the same edit or left. `xbs` at `gary.v:220` and the `dbs` decode should be re-read once to confirm they stay consistent. No timing impact: the new expression is strictly narrower and shallower.
- **How to test here:** run WhichAmiga 1.4 (it probes `$00DD0080` for an A3000/A4000 DMAC) and confirm the display survives the DMAC probe. Cheaper regression: a CPU-side bench that writes `$FFFF` to `$00DD0080` and then reads back COP1LCH via `$DFF080`'s shadow behaviour, or simply reads `$00DD001C` and checks it does not mirror INTENAR.

## 1.2 CIA timer reload is not aligned to the E clock (Risky Woods)

- **Defect:** writing the timer high byte while stopped or in one-shot mode reloads the counter on the next 7 MHz tick instead of on the next E-clock edge, so the first interval after a reload is short by up to one E period. Audible as wrong music tempo and missing sound effects.
- **MiSTer commit:** `058288b4` "Fix from TC64: fixed CIA timing bug which more-or-less fixes Risky Woods music and sound effects. (#198)", 2025-07-21. The message credits "MiST-TC64" — i.e. robinsonb5's *MiST* core, not this repository.
- **Their code:** `rtl/cia_timera.v` and `cia_timerb.v` add `thi_load_latched` / `thi_load_eclk` and change `assign reload = thi_load_eclk | forceload | underflow;`
- **Our code:** `rtl/minimig/cia_timera.v:76,80` and `cia_timerb.v:74,78` — plain `thi_load`, no eclk gate.
- **Status:** **we lack it**, despite the commit subject saying "Fix from TC64".
- **Risk/effort:** small and mechanical; both files are otherwise only comment-divergent from MiSTer. Watch that our `cia_timera.v:41` (`else if (thi_load && oneshot)` starts the timer) still sees the *ungated* `thi_load`, as it does in MiSTer — the fix changes only `reload`, not the start condition.
- **How to test here:** Risky Woods, in-game music and effects. A finer probe is a CIA timer bench in simulation measuring the interval between the first two underflows after a high-byte write.

## 1.3 TOD mid-counter carry bug is not emulated (Pit-Fighter, Torvak the Warrior)

- **Defect:** real 8520 TOD propagates the carry from the low 12 bits into the upper 12 one tick late, and the alarm compare is therefore true across a two-tick window. Games that set an alarm on a boundary value never see it. Symptom: music does not play.
- **MiSTer commit:** `15dc9f37` "Minimig: Implemented ToD clock bug, fixes music for Pit-Fighter and Torvak the Warrior.", 2025-06-09 ("From MiST, credits to Alastair Robinson").
- **Their code:** `rtl/cia_timerd.v` splits `tod` into `tod[11:0]` incremented on `count`, `tod[23:12]` incremented by `todcarry` on `count_del`, and widens the alarm compare to `count_del || count_del2`.
- **Our code:** `rtl/minimig/cia_timerd.v:99` (`tod <= tod + 24'd1` in one piece), `:134`, `:138` (`irq` on `count_del` only).
- **Status:** **we lack it.**
- **Risk/effort:** small, one file, ~10 lines. It deliberately makes the counter *less* correct in the arithmetic sense; anything in our firmware or OS that reads TOD across the boundary will see the hardware-accurate glitch. That is the point, but it means an OS-clock regression check is worth doing.
- **How to test here:** Pit-Fighter or Torvak the Warrior — music present or absent is a binary result. Then boot Workbench and confirm the clock does not gain or lose (see the caution in "Adjacent" below — our tree also lacks robinsonb5's *later* TOD `count_ena` fix, and the two interact).

## 1.4 CIA CNT pin and INMODE count-source selects unimplemented (Crystal Kingdom Dizzy)

- **Defect:** `cia_timera` hardcodes `assign count = eclk` and has no `cnt` port, so CRA bit 5 (INMODE) is stored and never gates the count source. A timer configured to count CNT transitions counts E-clock instead and a 16-bit one-shot underflows within 92 ms. `cia_timerb` only decodes CRB bit 6, so INMODE 00/01 both mean PHI2 and 10/11 both mean cascade. MiSTer's case: Crystal Kingdom Dizzy [cr FLT] writes CRA from a stale `$FF`, INMODE=1 is accidental, the crack's level-6 handler never reads CIA-B's ICR, EXTER re-latches forever and the screen stays black.
- **MiSTer commit:** `b013ce3d` "CIA: implement the CNT pin and the Timer A/B INMODE count-source selects (#230)", 2026-08-27.
- **Their code:** `cia_timera.v`/`cia_timerb.v` gain a `cnt` port, a 3-stage synchroniser reset to `3'b111` (idle-high), `cnt_rise = cnt_sync[1] & ~cnt_sync[2]`, and `assign count = tmcr[5] ? cnt_rise : eclk;` (A) / all four modes decoded (B). `ciaa.v`/`ciab.v` gain `cnt_in`, and `minimig.v` ties both to a constant 1.
- **Our code:** `rtl/minimig/cia_timera.v:32` `assign count = eclk;` with no `cnt` port; `cia_timerb.v` decodes bit 6 only.
- **Status:** **we lack it.**
- **Risk/effort:** moderate. Four files plus one port in `minimig.v`. The behaviour change is almost entirely "a mode that used to count now correctly counts nothing", which is safe; the one live change is CRB mode 11 (cascade gated by CNT high), which with CNT idle-high collapses to plain cascade — same as before. Our `ciaa.v` has been restructured (keyboard factored out into `ciaa_ps2keyboard.v` by `edac4d5`) but the timer instantiations are unchanged, so the port additions land cleanly. Note MiSTer's own reasoning for tying CNT to a constant applies here too: CIA-A's CNT is KCLK and CIA-B's is a parallel-port handshake, neither of which this core models.
- **How to test here:** Crystal Kingdom Dizzy [cr FLT] — black screen versus running game. Cheaper: a bench that sets CRA bit 5 and confirms Timer A does not decrement over several hundred ms.

## 1.5 Sprite shifter loads one clk7 late (Hybris scoreboard)

- **Defect:** the sprite shift register is loaded from `load_del`, one 7 MHz tick after the position match, which puts the score digits on the wrong pixel column. Symptom on MiSTer was a broken Hybris scoreboard; the same change also had to pipeline the shifter output to keep hires sprites correct.
- **MiSTer commit:** `e3a8a914` "Fix Hybris scoreboard (#73) (#169)", 2024-01-20.
- **Their code:** `rtl/denise_sprites_shifter.v` — `load_del` generation commented out, shift register loaded on `load`, and `sprdata` taken from a new `sprdata_r` shift register that reintroduces one clk7 of delay on the *output* side.
- **Our code:** `rtl/minimig/denise_sprites_shifter.v:39,73-76,112,124` — the original `load_del` path, unpipelined output.
- **Status:** **we lack it.** See 2.1: this file has a *second*, independent MiSTer divergence (`clk7n_en`/`data16`), and the two must be considered together.
- **Risk/effort:** small diff, but this is the one place in the group where I would not port blind. The MiSTer author's own comment on the output pipeline is "Ugly - are we masking a copper timing problem here?", and the fix's correctness in our tree depends on whether our Denise horizontal phase matches theirs. Our `denise.v` `window`/`blank` handling already differs from theirs (our border-blank work), which is upstream of nothing here but signals the phase relationships are not identical.
- **How to test here:** Hybris — the scoreboard digits at the top of the screen. Then any hires-sprite title (Lemmings cursor, Workbench pointer at hires) to confirm the output pipeline did not shift sprites by a pixel.

## 1.6 Blitter B-hold clobbered by a phantom read of BLTCON1 (Contraz Domination)

- **Defect:** `clr.w bltcon1` performs a phantom read of a write-only register; the register decode momentarily sees line mode asserted and `bltbhold` is overwritten with `{16{shiftbout[0]}}`, wiping the B texture data mid-blit.
- **MiSTer commit:** `b4787057` "Fixes for Nexus 7 (Andromeda) and Domination (Contraz) demos (#182)", 2025-01-21 (first hunk).
- **Their code:** `rtl/agnus_blitter.v` — `else if (enable)` replaces `else if (bltbdat_wrtn)`.
- **Our code:** `rtl/minimig/agnus_blitter.v:411` still `else if (bltbdat_wrtn)`; `bltbdat_wrtn` is generated at `:387-393`.
- **Status:** **we lack it.** One-line change; `bltbdat_wrtn` becomes unused.
- **Risk/effort:** one line, but it widens when `bltbhold` is written from "on a BLTBDAT write" to "every enabled blitter cycle". Read the surrounding FSM once to satisfy yourself that `shiftbout` is stable on non-B cycles; MiSTer has shipped it since January 2025.
- **How to test here:** Contraz "Domination" demo. A regression sweep over any blitter-heavy title (Deluxe Paint fills, Workbench window drags) is cheap insurance.

## 1.7 BPLCON4 BPLAM applies outside the active display area (Andromeda Nexus 7)

- **Defect:** `bplxor` (the BPLAM colour-index XOR from BPLCON4) is applied continuously instead of only between the first BPL1DAT write and DIWSTOP. Symptom: a block of white lines in the "Shade Cluster" section of Andromeda's Nexus 7.
- **MiSTer commit:** `b4787057` (second hunk), 2025-01-21.
- **Their code:** `rtl/denise.v` splits the BPLCON4 latch: `bplxor` is cleared on reset **or** on `hpos[8:0]==hdiwstop[8:0]`, and loaded from `bplcon4[15:8]` only when `display_ena`; `esprm`/`osprm` keep their own always block.
- **Our code:** `rtl/minimig/denise.v:245-258` — one always block, `bplxor <= bplcon4[15:8]` unconditionally.
- **Status:** **we lack it.**
- **Risk/effort:** small, and it composes with our own `window`/`blank` divergence in the same file rather than colliding with it — MiSTer's version keys off `hdiwstop` and `display_ena`, both of which exist here with the same meaning. Confirm our `display_ena` is the same signal as theirs before porting (in our `denise.v` it is, and it is already used at `:467` in `t_blank`).
- **How to test here:** Andromeda "Nexus 7", Shade Cluster part.

## 1.8 Bitplane fetch does not stop when DDFSTRT == DDFSTOP on ECS/AGA (Sanity Roots 2.0)

- **Defect:** on OCS, `DDFSTRT == DDFSTOP` lets the fetch run to the hard stop; on ECS/AGA it must stop after one complete fetch cycle. We implement only the OCS behaviour, so ECS/AGA programs that use the degenerate window over-fetch. Symptom: the sprite/copper "chunky" section of Sanity's Roots 2.0 renders wrong.
- **MiSTer commit:** `7cd8a422` "Fix for demo Sanity: Roots 2.0 sprite-copper-chunky section (#184)", 2025-02-03 ("Kudos go to Allistair Robinson").
- **Their code:** `rtl/agnus_bitplanedma.v` adds `reg softena_off`, set to `soft_stop && soft_start && ecs` each `hpos[0]`, and ORed into the softena clear condition.
- **Our code:** `rtl/minimig/agnus_bitplanedma.v:349-357` — the pre-fix `softena` block.
- **Status:** **we lack it.**
- **Risk/effort:** ~6 lines in a block that is otherwise identical between the trees. The change is gated on `ecs` so OCS titles are untouched by construction.
- **How to test here:** Sanity "Roots 2.0", the sprite-copper-chunky section.

## 1.9 BPLxMOD not registered, and no scandouble-modulo delay (RAMJAM Copperslave)

- **Defect:** `bpl1mod_bscan`/`bpl2mod_bscan` are combinational, so a modulo written mid-line takes effect on the pointer arithmetic in the same colour clock rather than one clock later. Symptom: the RAMJAM "Copperslave" demo shows a modulo error.
- **MiSTer commit:** `6fc0d5e1` "Fixes for 'Copper Slave' and 'Hamazing' demos (thx to Robinsonb5) (#206)", 2026-01-01 (first hunk).
- **Their code:** `rtl/agnus_bitplanedma.v` turns the two wires into regs clocked on `clk7_en && hpos[0]`.
- **Our code:** `rtl/minimig/agnus_bitplanedma.v:68-69, 441-442` — still `wire`/`assign`.
- **Status:** **we lack it.**
- **Risk/effort:** ~8 lines, mechanical. It adds one colour clock of latency to modulo application, which is the intent. It interacts with nothing else in the file.
- **How to test here:** RAMJAM "Copperslave".

## 1.10 HAM generator sees pixels scrolled off the left of the display window (Desire Hamazing)

- **Defect:** `bpldata` is not masked against the display window, so the HAM generator reacts to bitplane data from outside the window — pixels scrolled off the left-hand side modify the HAM accumulator before the window opens. Symptom: the "Hambarger" scene of Desire's Hamazing renders wrong.
- **MiSTer commit:** `6fc0d5e1` (second hunk), 2026-01-01.
- **Their code:** `rtl/denise.v` — each of the eight `assign bpldata[n] = ...` gains `window_ena &&`.
- **Our code:** `rtl/minimig/denise.v:335-342` — unmasked.
- **Status:** **we lack it.**
- **Risk/effort:** eight lines, and `window_ena` already exists here at `denise.v:309-312`. **Caveat specific to our fork:** our `window` generation at `denise.v:299-306` is *deliberately different* from MiSTer's — robinsonb5 reversed the HDIWSTRT/HDIWSTOP comparison order here so that `HDIWSTART==HDIWSTOP` blanks correctly in `brdrblnk` mode. Masking `bpldata` with `window_ena` therefore couples this fix to a signal whose edge cases we changed on purpose. Port with that in mind, and re-check border-blank titles.
- **How to test here:** Desire "Hamazing", Hambarger scene; then a border-blank regression (whatever exercised `5630811` / `e3b8195` / `6e45b6f` in our own history).

## 1.11 Bitplanes can obscure sprites outside the display window (Essence Crazy Sexy Cool)

- **Defect:** `nplayfield` is fed to the sprite-priority logic unmasked, so playfield data from outside the display window wins priority over sprites that are legitimately drawn in the border (`brdsprt`).
- **MiSTer commit:** `099c5a42` "Fix for Crazy Sexy Cool demo by Essence (#202)", 2025-11-28 ("ported from MiST fix made by Robinsonb5").
- **Their code:** `rtl/denise.v` — `wire [2:1] nplayfield_masked = nplayfield & {window_ena,window_ena};` fed to `denise_spritepriority`.
- **Our code:** `rtl/minimig/denise.v:385` — `.nplayfield(nplayfield)` on the `denise_spritepriority` instance (the other `nplayfield` reference here, `denise.v:352`, is the `denise_playfields` instance where `nplayfield` is an *output* — it is not a second site to change, and MiSTer left it alone too).
- **Status:** **we lack it.**
- **Risk/effort:** two lines. Same `window_ena` caveat as 1.10.
- **How to test here:** Essence "Crazy Sexy Cool".

## 1.12 Blitter does not freeze when BLTCON1 disables fill mid-blit (Absolute Inebriation)

- **Defect:** real Agnus freezes the blitter when BLTCON1 is written to disable fill while an extra-cycle D-only fill blit is still running. We do not, so the blit completes and produces output the program did not expect. MiSTer's reported case is the Absolute Inebriation demo.
- **MiSTer commit:** `5578afdd` "Add blitter freeze when BLTCON1 disables fill in certain circumstances (#236)", 2026-09-01.
- **Their code:** `rtl/agnus_blitter.v` adds `parameter BLT_FROZEN = 5'b11111`, a `freeze_on_bltcon1` term (busy, BLTCON1 write, fill mode with `bltcon0[9:8]==2'b01`, and the incoming data clearing bits 0/3/4), a state-register override, and a `BLT_FROZEN` arm in the combinational next-state block that stalls all DMA and pointer arithmetic until a new BLTSIZE (or BLTSIZH on ECS) write.
- **Our code:** `rtl/minimig/agnus_blitter.v` — no `BLT_FROZEN`; state register at `:616-620`, parameters end at `:132`.
- **Status:** **we lack it.**
- **Risk/effort:** the largest single diff in Group 1 (~53 added lines) and the one that adds a new FSM state, so it is the most likely to affect synthesis and timing. Against that, our `agnus_blitter.v` and MiSTer's are otherwise very close: the only structural divergence I found is `first_line_pixel` (present in both, `:185` here) and whitespace. The `BLTSIZE`/`BLTSIZH` parameter names it references exist in our `regs.vh` decode. Newest fix in the set (nine days old at time of writing) and therefore the least field-proven.
- **How to test here:** the Absolute Inebriation demo. A blitter-fill regression sweep (any fill-heavy vector demo, Deluxe Paint flood fill) should follow.

## 1.13 VHPOSR reads one colour clock high

- **Defect:** the horizontal beam readback returns the internal `hpos`, which runs one colour clock ahead of what real Agnus reports, and the row that should report the htotal wrap reads 0 instead. Every horizontal beam probe reads +1.
- **MiSTer commit:** `06f30afb` "agnus: VHPOSR reads one colour clock high (#234)", 2026-08-28. Measured against the **vAmigaTS VPOS suite** on A500 ECS PAL: before, 191 of 304 probe rows read +1 CCK and 76 read 0; after, 268 of 304 read 0.
- **Their code:** `rtl/agnus_beamcounter.v`, combinational readback only: `data_out[15:0] = {vpos[7:0], |hpos[8:1] ? hpos[8:1] - 8'd1 : ersy ? 8'd0 : htotal[8:1]};` — the wrap case is gated on `ersy` because `hpos[8:1]==0` means "wrap" when free-running and "zero" when a genlock ERSY freeze holds the counter.
- **Our code:** `rtl/minimig/agnus_beamcounter.v:130` — `{vpos[7:0],hpos[8:1]}`. We do have `ersy` (`:61,169-171`) and `htotal` (`:250`), so both operands exist.
- **Status:** **we lack it.**
- **Risk/effort:** one expression, in an `always @(*)` block that cannot move the raster (MiSTer's commit message makes exactly this argument). Low risk. See 2.2 for why I would port this one *before* 1.14 and evaluate them separately.
- **How to test here:** the vAmigaTS VPOS suite, which is what MiSTer scored against — this is the most directly reproducible test in the whole document. The commit notes 36 copper-WAIT probe rows carry a second, independent `-4`/`-11` error that this change does not address, so do not expect a clean sweep.

## 1.14 VPOSR/VHPOSR vertical readback is one colour clock early (Hybris beam polling)

- **Defect:** the vertical part of the beam readback transitions one colour clock earlier than real Agnus. A program polling the beam across a scanline straddle sees a torn value. MiSTer's case is Hybris's one-pixel vertical jitter on the cannon/turret sprite.
- **MiSTer commits:** `2764b513` "agnus: delay vertical beam readback by one colour clock" (2026-09-07) and its merge `002eef2c` (2026-09-08). WinUAE `683311be` cited as the reference.
- **Their code:** `rtl/agnus_beamcounter.v` — two `clk7_en` registers `vpos_d1`/`vpos_rb`; `vpos_rb` replaces `vpos` in **both** the VPOSR and VHPOSR readbacks and nowhere else.
- **Our code:** `rtl/minimig/agnus_beamcounter.v:128,130` read `vpos` directly.
- **Status:** **we lack it.**
- **Risk/effort:** ~11 lines, self-contained, and by construction affects only the two readback expressions. Two 11-bit registers is a trivial area cost.
- **How to test here:** Hybris, cannon/turret sprite vertical jitter. Note MiSTer's own caveat: their CPU-polling reproduction has limits and hardware acceptance was recorded separately, so a negative result on our hardware is not strong evidence the port is wrong.

---

# Group 2 — Missing, but entangled with our fork's divergence

These should not be lifted commit-for-commit. Each needs a decision about our own structure first.

## 2.1 BPLxDAT and sprite DATA are latched a half colour clock later in MiSTer

- **What it is:** MiSTer's `denise_bitplanes.v` and `denise_sprites_shifter.v` register `data_in` into a `data16` reg on `clk7_en`, then commit it into `bplNdat` / `datla` / `datlb` on a second, *anti-phase* enable `clk7n_en = c1 & c3` generated in `denise.v`'s sprite/bitplane wrappers. Ours writes straight through on `clk7_en`. That is 98 diff lines in `denise_bitplanes.v` and part of the 49 in `denise_sprites_shifter.v`.
- **Provenance and confidence:** **low confidence.** `git log -S"clk7n_en"` attributes it to `cd072122` "Update sys. Re-organize the sources." (2020-05-04), a mass reorganisation with no description of the defect it addresses. I could not find an issue number, a demo, or a hardware behaviour to attach to it. It may be a real half-CCK phase correction, or it may be an artefact of the Cyclone V clocking that our Artix-7 build does not need.
- **Why it matters anyway:** finding 1.5 (Hybris sprite shifter) lives in the same file and its correctness depends on the shifter's load phase. Porting 1.5 into our un-relatched shifter is *not* the same change MiSTer made. Decide 2.1 before or alongside 1.5.
- **Suggested activity:** a simulation-only comparison of BPL1DAT-write-to-pixel latency between the two shifters, before touching either. No hardware needed.

## 2.2 Beam counter, DMA slot grid, and the #232/#233 churn

- MiSTer advanced the whole DMA slot grid by one colour clock in `7ce29808` (#232, 2026-08-27) to fix Hybris, then **reverted it** in `0bf21820` (2026-09-08) because it regressed TEK Rampage, and replaced it with the narrower vertical-readback fix that is finding 1.14. **Net effect on `agnus.v`, `agnus_bitplanedma.v` and `agnus_copper.v` is zero** — which is why `agnus_copper.v` diffs to zero lines against our tree. Do not port #232. It is listed here only so that nobody re-discovers it in the log and assumes it is a pending fix.
- Our `agnus_beamcounter.v` diverges from MiSTer's by 284 lines for reasons that are ours: we drive `long_frame` from `displaydual` to suppress long frames in RTG mode (`:350`), we export `hsyncpol`/`vsyncpol`, and MiSTer exports `field1`/`lace`/`hde` that we do not have. Findings 1.13 and 1.14 both land in this file and both are narrow enough to be unaffected by that divergence, but the file as a whole is not a candidate for wholesale sync.
- **Suggested activity:** treat 1.13 and 1.14 as two separate, independently testable ports into this file, and do not attempt to reconcile the file.

## 2.3 Paula PWM volume gating

- MiSTer's `paula_audio_channel.v` adds a 6-bit `volcnt` PWM volume counter and a second output `sample_okk`, described in-comment as "the correct way Paula really works" (`a0eaf831`, 2021-03-04, plus the A500/A1200 filter work in `61e9594b`). It is an accuracy improvement to volume behaviour, not a bug fix against a named title, and it is a *parallel* output path.
- Our tree took a different road: `paula_audio_sigmadelta.v` and our own filter/mixer work, and there is uncommitted work in `sim/audio_mixer/` in the working tree right now.
- **Status:** missing, but as a design choice rather than an omission. **Not recommended as a port.** Listed so the decision is explicit.

---

# Group 3 — Already present here, no action

Verified by reading our code, not by hash. All six are pre-fork common ancestry from the minimig-mist era, and all are byte-identical or logically identical in our tree.

| MiSTer commit | Subject | Where it is here |
|---|---|---|
| `98ce7f1d` (2016-02-15) | updated playfield offsets in PF2 priority | `denise_playfields.v` — file diffs to **0 lines**; the `if (aga) ... else {4'b0000,1'b1,...}` split is present |
| `bd8c3147` (2016-02-14) | undocumented Denise/Agnus behaviour when BPL=7 in ECS/OCS | `agnus_bitplanedma.v:255,273` (`aga & data_in[4]`, the `bpu` remap) and `denise.v:167-169,409` (`l_bpu` 7→6, `ham_sel` ungated) |
| `ae51f378` (2016-02-09) | fixed blitter line mode | `agnus_blitter.v:185,819-853,919-922` — `first_line_pixel` present. Note our version uses it in the FSM where MiSTer's original also threaded it into `agnus_blitter_adrgen.v`; `agnus_blitter_adrgen.v` diffs to **0 lines** between the trees, so both arrived at the same place |
| `3331bb2a` (2016-01-30) | fixed denise colortable for sprites (bplxor) | `denise.v:449` (`clut_data = plfdata ^ bplxor`) and `denise_colortable.v:27` (`select_xored = select` with the XOR commented out) |
| `6d1127b6` (2016-02-24) | Revert "added MikeJ blitter changes" | our blitter matches the post-revert form |
| `a107751b` (2016-02-16) | CPU waits for a free slot when turbo is disabled | `agnus.v:97,329,426,440` — present, and extended here with our own `turbo`/`floppy_speed` handling |

Also identical between the trees and needing no attention: `agnus_copper.v`, `agnus_refresh.v`, `agnus_audiodma.v`, `agnus_blitter_fill.v`, `agnus_blitter_minterm.v`, `agnus_blitter_barrelshifter.v`, `agnus_blitter_adrgen.v`, `denise_collision.v`, `denise_colortable.v`, `denise_hamgenerator.v`, `denise_playfields.v`, `denise_spritepriority.v`, `paula_intcontroller.v`, `paula_audio_volume.v`, `paula_audio_mixer.v`, `paula_floppy_fifo.v` — all diff to zero lines ignoring whitespace. **The copper in particular carries no MiSTer fix we lack.**

### Fixes we have that MiSTer does not

Recorded so nobody "syncs" them away:

- `denise.v:111-117` — `blank_d` rising-edge detect, because the delayed blank was clearing the display-window state again after the first BPL1DAT write (AMR).
- `denise.v:299-306` — HDIWSTOP tested before HDIWSTRT, so `HDIWSTART==HDIWSTOP` blanks correctly in `brdrblnk` mode (AMR).
- `denise.v:467` — `t_blank` includes `blank`; MiSTer comments it out.
- `paula_uart.v:36-43` — three-stage RX synchroniser (MiSTer has two).
- `agnus_diskdma.v:13,50` — turbo/floppy-speed-aware disk DMA slot.
- Our own Gayle IRQ work (`bec459d`, `4da2753`, `802007d`), border blank (`5630811`, `e3b8195`, `6e45b6f`), Paula channel swap (`549bb5b`), Agnus D-pointer increment (`ef21189`), Denise/Lisa colour table readback (`a4c6fe5`), Paula write-strobe reads returning `FFFF` (`e0a2409`).

---

# Group 4 — Not applicable to this platform

| MiSTer commit | Subject | Why not applicable |
|---|---|---|
| `d16cd845` (2026-08-28) | agnus: fix false interlace mode (`field1 = ~long_frame & lace`) | We have **no `field1` signal at all** — `grep -rn field1 rtl/minimig/` is empty, and `minimig.v` does not export it. `field1` is MiSTer's interlace-field flag for the HPS scaler. There is nothing here to be false. If we ever add an interlace-field output, apply the `& lace` guard from the start |
| `27acb141` (2026-08-29) | Gayle: fix Fast IDE mode for throttled 68020 (`longword_r`) | Our `gayle.v` is the original Jakub Bednarski module plus our own IRQ/FIFO work; MiSTer replaced theirs wholesale in `149d0607` with a new IDE module. No `longword` signal exists here. Different implementation, not a missing fix |
| `148931d0` (2026-08-28) | stock-speed throttle runs at half A1200 speed (#233) | MiSTer's `cooldown` reload constant in their `minimig.v`. Our speed control is the TC64 `turbo`/`cpu_speed` scheme. The *idea* (a divisor near 4.8, not 10, matches a real A1200) is worth knowing if anyone calibrates our throttle, but the code does not transfer |
| `c26772a2` (2026-08-27) | Akiko: PIO command register and DRIVEXMIT (#229) | `rtl/minimig/akiko.v` exists here but is **never instantiated** — no reference in `minimig.v`, and there is no CD32/CDTV support in this fork. Dead file |
| `2a600e4b`, `809b9558` | CD32/CDTV, A2065 Ethernet | Features, not fixes, and neither is wired here |
| `a89ac66a` (2024-12-17) | Use exact clock for NTSC mode | Altera PLL megafunction regeneration (`pll.v`, `pll_0002.v`). Our clocking is Xilinx MMCM. The *goal* transfers, the code does not |
| `dc5ee041` (2023-02-24) | RTC: support for seconds | MiSTer's HPS-fed RTC inside their `minimig.v`. We have our own RP5C01 work (`be772e0`, `883cd31`, `74c3112`) on a different interface |
| `2bec7c06`, `ff347772` | autoconfig rework, Toccata autoconfig | We rewrote autoconfig ourselves (`378ed16` and the current `ap040-d3-enable-scheme` Zorro-III work). Ours is ahead here, not behind |
| `1cee34bf`, `db567e2f` | CIA comments / TOD BCD comment cleanup | Comments only. `cia_int.v`'s entire 114-line diff against our tree is comments |
| `67af3189` | cpucfg/cachecfg flags re-arrange | MiSTer's HPS config word layout |

---

# Adjacent, out of scope, flagged for honesty

- **`edc53d2` (robinsonb5, 2021-03-10), "Tentative CIA fix for OS3.1.4 time gain problem"** — this is on our own `upstream/master` and **is not in our history** (`git merge-base --is-ancestor edc53d2 HEAD` fails; `upstream/master` is not an ancestor of HEAD at all, the archived upstream has 16 commits we never took). It changes `cia_timerd.v` `count_ena` so TOD counting is disabled from reset until the first access, and restarts on a control-register write with bit 7 clear. MiSTer does **not** have this fix. It touches the same block as finding 1.3, so if 1.3 is ported the two must be reconciled. Worth its own small activity: "audit the archived upstream's last 16 commits", separate from this document.
- **`0fbf23d9` (2025-03-24), "TG68K: Bugfix on skipFetch signal with bra.l and bsr.l instructions"** — CPU, not chipset, so outside the brief, but: our `rtl/tg68k/TG68KdotC_Kernel.vhd` does **not** contain the fix (no `long_start='0'` guard on the `bra.l` skipFetch, no "can't skip fetch" comments). Given the AP040 work in flight this may be moot for the 040 path but still live for 68000/68010 mode. Low confidence on impact; I did not analyse the instruction paths.

---

# What I did not examine, and where confidence is low

Stated plainly, because a false claim of coverage is worse than a gap.

- **I mined `origin/MiSTer`'s history over `rtl/` only.** Fixes that MiSTer took as part of a vendored subtree update (`sys/`, `pll/`, the FX68K and TG68K drops) were filtered out by subject and diffstat, not by reading their contents. If a chipset fix rode into MiSTer inside `cd072122` "Update sys. Re-organize the sources." or `f07d5a45` "Cleanup and reorganize the sources", I would have missed it. Finding 2.1 is exactly such a case and I found it only because the *file* diff was large, not because the log said anything.
- **I did not read `minimig.v`, `userio.v`, `akiko.v`, `cart.v`, `minimig_m68k_bridge.v`, `minimig_sram_bridge.v`, `minimig_bankmapper.v` or `paula_floppy.v` line by line.** Their diffs are 1020, 682, 826, 168, 156, 91, 36 and 358 lines respectively and are dominated by platform plumbing (HPS interfaces, SDRAM/DDR3, our Toccata and Zorro-III work, MiSTer's CDTV/A2065 decode). A chipset-behaviour fix could be hiding in `paula_floppy.v` in particular — floppy timing is chipset behaviour and I classified that file as platform on the strength of its interface diff. **Confidence low for `paula_floppy.v`.**
- **`ciaa.v` (298 lines) and `ciab.v` (196 lines)** I checked by filtering the MiSTer-only side of the diff for non-comment content. Almost all of it is comments and the `cnt_in` plumbing of finding 1.4. That filter would hide a change whose only trace is a modified line on *our* side. Medium confidence.
- **I did not compile, elaborate, simulate or run anything.** Every "we lack it" is a claim about source text. Every "how to test" is a proposal, not a result.
- **No demo or game was run in either tree.** The demo and game names in this document are MiSTer's attributions, reproduced so the findings are testable later; I did not verify that any of them actually misbehaves on our hardware. It is entirely possible that one of these defects is masked here by an unrelated difference in our timing.
- **The `#236` blitter freeze (1.12) is nine days old upstream** and I have no evidence of its field record beyond the commit itself.
- **Finding 2.1 has no attributed defect.** I am reporting a structural difference, not a known bug.
- **I did not survey the reverse direction systematically.** The "fixes we have that MiSTer does not" list is what I noticed while reading, not the output of a deliberate search.
