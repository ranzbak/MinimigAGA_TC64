# Evaluation of doc/AP040_FPU_COMPARISON_20260926.md (Adam Polkosnik) against our pipelined core

Written 2026-09-26. Subject: `lib/AP68040-pipelined` at **9efe490**, the tip of `minimig-pipelined` per PLAN.md STATUS. Adam's `rtl/ap040_ranzbak/*` maps to our `rtl/*`. His line numbers are off by about 1 to 2 against ours; the code is the same.
No repository file was edited. Probe programs, assembled binaries and logs are in the session scratchpad (`.../scratchpad/probe/`). I ran two iverilog probes: `p2probe` on the FPU_REAL program bench (HAS_FPU=1) and `lcprobe` on the plain program bench (HAS_FPU=0). Their results are quoted below.

Authority order applied (Paul): M68040UM text > a source verified on real 040 hardware for that case (WinUAE cpu_level 4 / cputest) > PRM > other.

## Summary table

| # | Finding | Verified in our tree | Already known on our side | Manual verdict | Amiga impact | Fix / cost | Proving test |
|---|---|---|---|---|---|---|---|
| P1 | A memory-indirect FP EA is rejected (vector 11, format $4) instead of executed | **Yes.** decode.v:1251, 1275, 1318, 1330, 1359, 1437 all require `mi == MI_NONE`. Probe: FDIV.W `([$3100.w])` gives `$402C`, EA=$3100. FMOVE.L out `([..])` gives `$402C`. FScc `([..])` gives `$002C` | **Yes.** STATUS: "Still open in M10: a MEMORY-INDIRECT FP effective address (format $4; where `t_fpu.s` now stops, test 241)". Also M10.1 text (l.305), l.815, l.852 | **Adam is right (rule 1).** UM 10.7.2 pp. 10-30..10-34 give <ea>-calc/execute timings for `([bd,An,Xn])`, `([bd,An,Xn],od)`, `([bd,An],Xn)`, `([bd,An],Xn,od)` for every FP class: arithmetic <ea>,FPn; FMOVE FPn,<ea>; FMOVE(M) control; FMOVEM; FScc; FSAVE; FRESTORE. UM 2.1 p. 2-2 describes the indirect fetch in the <ea>-calc stage. PRM FMOVE p. 5-75/5-78 lists these modes as legal. UM A.5.1 p. A-6: "an MC68040 cannot correctly handle a stack format $4" | **Low-medium.** Compilers do not emit these modes. A hand-coded program that does would get vector 11 format $4 on the FPU image. Our RTE refuses format $4 when HAS_FPU=1 (ea_fetch.v:974), and the FPSP's F-line entry is expected to pass a non-$2 frame on as a real F-line, so the result is a guru rather than silent corruption. **Affects every HAS_FPU=1 pipelined image** (m14b_fpu, timing_fpu_ctr). The LC040 images are affected only by N1 | Decode: drop the six `mi == MI_NONE` terms. EA-fetch: gate P_START->P_FPU (ea_fetch.v:2346) on `(!need_smi‖dn_smi)&&(!need_dmi‖dn_dmi)`, issue only T_SMI/T_DMI (not T_SLD/T_DLD) for CL_FPU, and fetch the pointer **once** for the forms that set `d.dst = d.src`. `fp_addr` already takes `s_addr_c`/`d_addr_c`, which include `rd_data + src_add`. **M** | `t_fpu.s` §47 test 241 onward (compat leg, `tb/mk_tfpu.py`). New `pipe_asm/fpureal_mi.s` covering each class, `readonce` on the pointer, a pointer-fetch berr giving format $7, and packed through MI giving $30DC with the final EA. Mutants: entry not gated on `dn_smi`; `od` dropped; pointer read twice |
| P2 | FMOVE.P FPn,Dn gives the wrong exception (static `$402C`, dynamic `$002C`; should be vector 55 `$30DC`) | **Yes.** Static: decode.v:1395 excludes fmt 011 from the reject list, so it keeps format $4. Dynamic: fmt 111 hits decode.v:1399 `fp_op_hw(x1[6:0])`, where x1[6:0]=0, so it gets F-line $0. Probe confirms `$402C` / `$002C` | **Yes.** D22 row: "Still out, and recorded: PACKED into a data register, which is the datatype fault (vector 55) and keeps format $4 for now". Same note in the code at decode.v:1396-1397 | **Adam is right, on rule-2 evidence.** UM 9.6.2 p. 9-22/9-23: a packed *destination* gives vector 55, "post-instruction exception … format $3". The UM says nothing about Dn legality. PRM p. 5-78 says Dn "only if <fmt> is byte, word, long, or single", which points to F-line. WinUAE `put_fp_value` (fpp.cpp:2024-2040): "68040+ generates unimplemented effective mode exception even if destination EA is Dn…" raises `fp_unimp_datatype` with EA=0. Rule 2 beats rule 3 | **Negligible.** Assemblers reject `fmove.p fp0,d0` and no compiler emits it. It matters for cputest/`t_fpu` parity only. Same on both images | Decode: opclass 011 with Dn and fmt 011/111 becomes CL_FPU with no memory beats. The unit already flags packed as `unsupp`, and the frame's EA is 0 (`fp_ea_v`=0). The dynamic form needs Dk read through `reg_c`. **S** | Add to `fpureal_busy.s` (or a new `fpureal_pk.s`): `$F200,$6C00` and `$F200,$7C00` expect `$30DC`, EA 0, next PC, and a $4160 BUSY frame. Mutant: remove the new arm, which brings back `$402C` |
| P2b *(ours, not in Adam's doc)* | Opclass 011 illegal-EA path consults `fp_op_hw(x1[6:0])`, but for opclass 011 those bits are the **k-factor**, not an opmode | **Yes.** decode.v:1399 applies to both 010 and 011. Probe: `$F200,$7C10` (P{D1}→D0) gives `$202C`; `$F208,$7C10` (→A0) gives `$202C`; `$F208,$6C05` (→A0, k=5) gives `$202C` | **No.** D22 reasons only about opclass 010 (`fabs`/`fint` sources) | WinUAE `put_fp_value2` (fpp.cpp:1827): An gives `fpu_noinst`, so F-line `$002C`. Packed→Dn gives 55 (P2). PRM p. 5-79: the k-factor field "should be set to all zeros" for other formats, and nowhere makes it an opmode. Adam's reference (`ap040_core.v:4308-4360`) never asks `op_in_hw` for opclass 011 | Negligible (malformed encodings). It is a correctness bug in our decode that cputest FMOVE.P/An rounds could hit | Gate the `fp_op_hw` split on `x1[15:13]==3'b010`. Opclass 011 illegal EAs are always F-line $0, except packed→Dn (P2). **S** | Same program as P2: `$F208,$7C10` and `$F208,$6C05` expect `$002C` at the instruction's own PC; `$F200,$7C10` expects `$30DC`. Mutant: restore the unconditional `fp_op_hw` |
| N1 *(ours, found while probing P1)* | **LC040 build:** format $4's EA field for a memory-indirect FP operand holds the **pointer address**, not the operand address | **Yes.** ea_fetch.v:1015 stacks `s_addr_c`, but the exception is taken before any T_SMI read, so it is `eac src_ea` = base+bd. Probe (HAS_FPU=0): `fdiv.w ([$3100.w]),fp5` stacks EA $3100 (should be $3200); `([$3100.w],4)` stacks $3100 (should be $3204); `fdiv.w $3200` stacks $3200 (correct) | **No.** D18 covers the format but not MI | **UM A.5.1 p. A-6 (rule 1):** "the calculated effective address of the operand … using the addressing mode in which the effective address is calculated". An LC040 F-line emulator trusts this field | **Low.** Only an FPU emulator on an LC040 image, running code that uses memory-indirect FP modes. It **does affect the shipped `_lc040` image** | Let CL_EXC with `exc_fmt==4` wait for the MI pointer read (the same `need_smi` gating as P1, on the exception arm). Shares P1's change. **S** once P1 is done | `lcprobe`-style program in the plain `prog:` leg: `([bd])`, `([bd],od)`, `([bd,An],Xn,od)` with EA fields checked absolutely. Mutant: skip the wait |
| A1 | FP0-FP7 are resettable register arrays, not banks with a validity mask; destination read late | Yes: `compat/ap040_fpu.v:136-138`, reset at :592. Adam's newer unit uses MLAB banks plus `fr_valid` (`apolkosnik-AP68040/rtl/ap040_fpu.v:147-169`) | Implicitly: we lifted lib/AP68040's unit unchanged (plan decision 2). Adam's banked version is a later refactor (7431dcb) | n/a (implementation) | None functionally, because our FP instructions serialise (no FP dispatch while `fp_bg`). **Relevant to Q22**: the FPU image is 44,231 LUTs, 231 over budget, and distributed-RAM FP registers could win back some of that | Port the banked register file plus validity mask (Xilinx: LUTRAM, not MLAB). **M.** Measure routed, not OOC | Existing suite (220 legs), fpsp legs, Kickstart FPU leg md5 unchanged |
| A2 | Separate normalizers, not a shared LZC/shifter | Yes, as lifted | Same as A1 | n/a | None functionally; area only | Port with A1 if Q22 needs it. **M** | Same as A1 |
| A3 | `fm_rdata` is indexed by `fm_sel` (ours) vs `src_r` (his) | Yes: `compat/ap040_fpu.v:153` | Not a gap: both integrations match their own unit | n/a | None. It is a trap only if someone swaps units without the adapter | Nothing. Keep in mind for convergence (see the AP040 reference-integration memory) | n/a |
| A4 | S/D denormal ETEMP carries {sign,$3F80/$3C00,0.fraction}; his unit does not | Yes: D24, fdc835c | **Yes, D24.** This is **our fix**, which his branch lacks | WinUAE layout (rule 2) plus the FPSP `src_sd_dnrm` consumer. UM silent | Positive for us: 68040.library returns exact 2^-127 and 2^-74 | Nothing on our side. Worth offering upstream | `fpureal_busy.s` payload checks; mutant BU5 |
| A5 | Revision $41 frames hardcoded; his core has `AP040_FPU_REVISION` ($40 option) | Yes: `ea_fetch.v:1579/1601/1624/2631-2632` | Not recorded | UM 9.8: one version byte per part. The mask set we model is $41 | None: 68040.library and FPSP handle $41 | Optional parameter. **S**, low value | fpureal_sv/busy with the parameter at $40 |
| V | Validation table: `t_fpu` FAIL code 98 at the first indirect FDIV; frames and resume PASS | Consistent with our records (STATUS; l.852: stops at test 241, `--diag` $402C; the `compat:t_fpu_resume` / `t_fpu_frames` legs pass) | Yes | n/a | n/a | n/a | n/a |

## Per-finding evidence

### P1: memory-indirect FP effective addresses

*Claim:* Our decoder admits memory FP operands only with `mi == MI_NONE`, so `([bd..])` forms take vector 11 format $4 (FScc takes format $0).

*Our code:*
- `rtl/ap040_decode.v:1251`: FScc, `(d.src.kind == EK_MEM && d.src.mi == MI_NONE && …)`. Otherwise decode.v:1258-1261 turns it into plain F-line (format $0). This is why Adam's FScc probe sees `$002C`.
- `:1275`: FSAVE/FRESTORE.
- `:1318`: opclass 010 source.
- `:1330`: opclass 011 store.
- `:1359`: opclass 100/101 control registers. The comment at `:1370-1372` names it: "a LEGAL one this core does not sequence -- a memory-indirect EA -- keeps the format $4 frame".
- `:1437`: FMOVEM.
- The comment at `:1301-1306` records the gap: "a functional gap with an FPU -- recorded in PLAN.md M10.1 -- on a form no compiler emits".

*Probe (FPU_REAL bench, `p2probe.s`):*

| case | result |
|---|---|
| 6 `fdiv.w ([$3100.w]),fp5` | `$402C`, EA field $3100 |
| 7 `fmove.l fp5,([$3104.w])` | `$402C`, EA $3104 |
| 8 `fsne ([$3104.w])` | `$002C` |

This matches Adam's numbers.

*Known:* STATUS line 8, M10.1(b) paragraph (l.305), l.815, l.826, l.852, l.1193. It is the documented reason `t_fpu.s` stops at test 241. Section 9 has no question about it.

*Manual:*
- M68040UM 10.7.2 (PDF text l.18214 ff., pp. 10-30..10-34) has timing rows for every memory-indirect mode in every FP table, including FScc, FSAVE and FRESTORE. The hardware executes them.
- UM 2.1 p. 2-2: "For memory indirect addressing modes, the <ea> calculate stage initiates an operand fetch from the intermediate indirect memory address".
- UM A.5.1 p. A-6: "an MC68040 cannot correctly handle a stack format $4". So on an FPU build format $4 is not even a valid frame, and our own RTE rejects it (`ea_fetch.v:974`, `rte_fmt_ok` excludes $4 when HAS_FPU=1).

Adam is right.

*Amiga impact:* SAS/C, GCC and vbcc do not generate memory-indirect modes for FP operands, so compiled code is unaffected. Hand-written assembly using them is rare, but it crashes on our FPU image where a real 040 runs it. The FPSP's F-line entry expects a format $2 frame for its own work and hands anything else to the OS F-line vector; I did not trace 68040.library for this. It blocks `t_fpu.s` §47-§50 (§48-50 cover the FRESTORE lifecycle and the M10.3 store-exception checks).

*Fix sketch (M):*
1. Decode: remove the six `mi == MI_NONE` terms.
2. EA-fetch: the pointer machinery already exists for integer instructions:
   - `need_smi`/`need_dmi` (`ea_fetch.v:465-466`)
   - `next_rd` issuing T_SMI/T_DMI (:521-522)
   - capture into `s_addr`/`d_addr` (:2312-2313)
   - `s_addr_c`/`d_addr_c` (:557-558)

   CL_FPU jumps to P_FPU at `:2346` without waiting for `ops_done`. Add `(!need_smi || dn_smi) && (!need_dmi || dn_dmi)` to that transition. Keep `needs_ld_src`/`needs_ld_dst` false for CL_FPU, since P_FPU sequences its own operand beats. `fp_addr <= fp_mem_dst ? d_addr_c : s_addr_c` (:2360) and `fp_addr0` (:1649) then carry the final EA.
3. Watch: stores, FScc, FSAVE and FMOVEM stores set `d.dst = d.src`, so `need_smi` and `need_dmi` would both fire and read the pointer twice. Suppress `need_smi` when `fp_mem_dst`.
4. A pointer-read access fault should take format $7 through the existing integer path.
5. Timing: the P_START entry term is on the M14-tightened path, so check the routed build.

*Test:* The proving oracle is `t_fpu.s` §47 test 241 onward via `tb/mk_tfpu.py`. Add a new `pipe_asm/fpureal_mi.s` with the following, each with an absolute value:
- FDIV.W `([bd.w])` gives 2.
- FADD.X `([bd,A0],D1*4,od)` (12-byte operand).
- FMOVE.D FPn,`([bd,A0,D1])`.
- FMOVEM.X both ways.
- FMOVE.L FPCR,`([..])`.
- FSNE `([..])`.
- FSAVE/FRESTORE `([..])` in supervisor mode.
- FMOVE.P `([..])` gives `$30DC` with EA = the final address.
- `readonce <pointer>`.
- A berr on the pointer gives format $7.

Mutants: the P_FPU entry not gated on `dn_smi`; `od` ignored; `need_smi` not suppressed on stores (caught by `readonce`).

### P2: packed store to Dn

*Claim:* `$F200,$6C00` gives `$402C` and `$F200,$7C00` gives `$002C`; both should be vector 55 `$30DC`.

*Our code:* `decode.v:1390-1396`. The opclass 011 reject list is `(d.src.kind == EK_DREG && !fp_ireg && x1[12:10] != 3'b011)`:
- Static packed (011) is not in the list, so it falls through with M10.0's format $4.
- Dynamic packed (111) is in the list, and `:1399 fp_op_hw(x1[6:0])` with x1[6:0]=0 (FMOVE) gives format $0.

Probe cases 1, 2 and 9 give `$402C`, `$002C` and `$402C` (static with k=1).

*Known:* D22 decision column: "Still out, and recorded: PACKED into a data register, which is the datatype fault (vector 55) and keeps format $4 for now". The code at decode.v:1396-1397 says the same.

*Manual and authority:*
- UM 9.6.2 (pp. 9-22/9-23): a packed destination is an unsupported data type, and "for opclass 011 … a post-instruction exception … format $3 … vector number 55". It does not discuss Dn.
- PRM FMOVE p. 5-78: Dn "*Only if <fmt> is byte, word, long, or single", which read strictly is an illegal EA (F-line).
- WinUAE (`fpp.cpp:1814-1827` and `put_fp_value` :2024-2040) says explicitly: "68040+ generates unimplemented effective mode exception even if destination EA is Dn …". It calls `fp_unimp_datatype` with EA=0, which is format $3 / vector 55. `cputest.cpp:7073` runs with `fpu_no_unimplemented = true`, the mode in which this path is live.
- Rule 2 over rule 3: vector 55, format $3, EA 0, next PC.

Adam is right. Our D22 already concluded the same and only deferred the work.

*Impact:* Negligible. It is illegal per the PRM, assemblers refuse it, and compilers never emit it. The FPSP would then store the 12-byte result using the frame's EA field, which is 0 for Dn. I have not verified this: no FPSP source is available locally. That is hardware-faithful but useless, so nothing real depends on it.

*Fix (S):* Add an arm before the reject block: opclass 011, `EK_DREG`, fmt 011/111 becomes `d.cls = CL_FPU`, with no memory beats and `reg_c` = Dk for 111. `fp_ea_v` (`ea_fetch.v:1898`) is 0 for a Dn destination, so the unsupp frame's EA is 0 by D19's rule. Check that FSAVE afterwards yields the $4160 BUSY frame with T=1 and ETEMP = source (WinUAE `fp_unimp_datatype` opclass 3 arm, fpp.cpp:1041-1046).

### P2b (ours): `fp_op_hw` applied to opclass 011

*Claim (new):* decode.v:1399 decides format $0 vs format $2 from `fp_op_hw(x1[6:0])` for opclass 011 as well as 010. In opclass 011, x1[6:0] is the k-factor (static) or `Dk<<4` (dynamic), so the result depends on the k-factor.

*Probe:*

| case | encoding | ours | expected |
|---|---|---|---|
| 3 | `$F200,$7C10` (P{D1}→D0) | `$202C` | `$30DC` (P2) |
| 4 | `$F208,$7C10` (P{D1}→A0) | `$202C` | `$002C` |
| 5 | `$F208,$6C05` (P{#5}→A0) | `$202C` | `$002C` |

Also affected: any non-packed Dn/An/imm/PC-relative destination with nonzero low bits, which the PRM says "should" be zero.

*Evidence:* WinUAE `put_fp_value2` (`fpp.cpp:1827`): An returns 0, which gives `fpu_noinst` (F-line format $0). There is no FPSP-opmode concept in opclass 011. Adam's reference agrees (`apolkosnik-AP68040/rtl/ap040_core.v:4308-4360`: opclass 011 illegal EAs always `go_fp_fline`).

*Fix (S):* Condition the `fp_op_hw` split on `x1[15:13] == 3'b010`.

### N1 (ours): LC040 format $4 EA for memory-indirect operands

*Claim (new):* With HAS_FPU=0, `ea_fetch.v:1015` stacks `s_addr_c`. The exception fires before any T_SMI read, so the EA field is base+bd+index, i.e. the **pointer's** address.

*Probe (`lcprobe.s`, plain prog bench):*

| instruction | stacked EA | correct EA |
|---|---|---|
| `fdiv.w ([$3100.w]),fp5` | $3100 | $3200 |
| `fdiv.w ([$3100.w],4),fp5` | $3100 | $3204 |
| `fdiv.w $3200,fp5` (control) | $3200 | $3200 |

*Manual:* UM A.5.1 p. A-6 (rule 1): "The effective address field of the format $4 stack frame contains the calculated effective address of the operand … using the addressing mode in which the effective address is calculated". Step 1: "the effective address is calculated, if required".

*Impact:* Low. Only an LC040 FPU-emulation F-line handler running code that uses MI FP modes. It is live in the `_lc040` image.

*Fix:* Share P1's gating. The exception arm for `exc_fmt == 4` waits for `dn_smi`/`dn_dmi`. Note the pointer read must then be a real, faultable access; the UM A.5.1 step 2 wording allows this.

### A1-A5, V: arithmetic-unit notes and validation

These are descriptive, not regressions; see the table.

A4 is a point **in our favour**: our D24 denormal ETEMP layout is WinUAE's, and it is required by the FPSP's `src_sd_dnrm`. His branch still has the raw image.

A1/A2 are the only ones with value to us, as LUT savers for Q22. The value is unmeasured, so measure it routed, per section 1.3's warning about out-of-context (OOC) numbers.

## Side observation (not from Adam's doc; for Paul)

D19's manual column says the UM "does not say which PC is stacked" for vector 55. But UM 9.6.2 p. 9-22 does say that opclass 000/010 unsupported data types are **pre-instruction, format $0**, and only opclass 011 is format $3.

D19 follows the cputest-v24 hardware frames: FABS.P #imm gives `…30,DC…`, i.e. format $3. So this is a UM-text-vs-hardware conflict. Under the authority order as stated, UM text wins, which would contradict hardware captures and the passing FPSP bench.

This needs an explicit ruling rather than a silent choice. I recommend recording it in D19 as "UM 9.6.2 says $0; hardware and cputest v24 say $3; follow hardware", because the rule-1 text is contradicted by silicon.
