# Pipelined AP68040: distance to the reference core, and the tests that would prove parity

Date: 2026-09-21. Not committed; for Paul's review.

Cores compared (both cloned read-only into the session scratchpad; nothing was pushed or modified upstream):

| | repo / branch / commit | RTL under test | own test suite |
|---|---|---|---|
| **REFERENCE** | `apolkosnik/AP68040` `main` @ `8f72275` | `rtl/` (11 files + `primitives/dpram.v`, 12 947 lines) | `tb/run_tests.sh`, 29 legs + `run_fpu_frames.sh` |
| **PIPELINED** | `nonarkitten/AP68040` `pipelined` @ `71caa48` ("Milestone 17") | `rtl/` (11 files, 4 176 lines) | `tb/run_pipe_tests.sh`, 19 legs |
| local derivative | `lib/AP68040` `e2-fixes` @ `530fc72` | reference + project fixes (`ap040_fill_cdc.v`, cherry-picks) | `tools/test_ap040.sh` -> 13 legs |

Note on naming: the pipelined repo also carries the reference core as `rtl_old/` (an older snapshot, 6 155-line `ap040_core.v` vs the reference's 6 796). Everything below about "the pipelined core" means `rtl/`, and every reference citation is to `apolkosnik/AP68040 @ 8f72275` unless marked `rtl_old`.

## 0. Headline

The pipelined branch is a **six-stage pipeline skeleton with 17 instruction forms, three exception vectors, and no bus**. It is not a partially-complete 68040; it is the first ~5 % of one, built deliberately one opcode at a time with excellent per-milestone verification discipline. Relative to the reference:

- **Integer ISA**: 17 opcode forms of roughly 120; three EA modes of 18; Long size only. The reference test programs cannot execute their *first checking macro* (`chkl` = `CMP.L #imm,Dn` + `Bcc`) on it.
- **Exceptions**: illegal / TRAP #n / privilege (format $0) and address error on odd JMP/JSR targets (format $2). No VBR use, no trace, no interrupts, no bus/access error (format $7), no format $1/$3, RTE handles format $0 only, A-line and F-line take vector 4.
- **MMU, FPU, caches, external bus**: absent. There is no `ipl`, `berr`, `fc`, or any bus port on `ap040_pipe_core` (`rtl/ap040_pipe_core.v:146-169`); memory is a 4 096-word internal dual-port array.

On Paul's framing ("CPU and MMU are already working fast enough"): **that sentence cannot be about this branch's CPU or MMU**. There is no MMU in `rtl/` at all (`grep -i atc\|ttr\|walker rtl/` matches nothing but comments), and the CPU cannot run a compare-immediate. Whatever is fast enough is the reference/`lib/AP68040` core. If the plan was to graft the reference MMU onto the pipeline, that is possible in principle (section 4) but it is the single hardest item on the list, not a solved one.

The good news is structural: the pipeline's forwarding, stall/flush chain, gather machinery, and the "dynamic exception at EA-fetch time" pattern are the right shapes, and its milestone log (`AP040_IMPLEMENTATION_PLAN.md`) shows mutation-tested tests for every mechanism. Effort to parity is large but mostly *known* work, except for the four items in section 4.3.

## 1. Reference core: functional surface

### 1.1 Integer ISA
Decode is one `casez` over `ir[15:12]` in `S_DECODE` (`rtl/ap040_core.v:5320-6440`); each group is fully populated:

| group | what | where |
|---|---|---|
| 0x0 | ORI/ANDI/SUBI/ADDI/EORI/CMPI (incl. to CCR/SR), static bit ops, MOVEP, MOVES, CAS/CAS2, CHK2/CMP2 | `ap040_core.v:5321-5485`, MOVEP `:5323`, MOVES `:5395`, immediates `:5441` |
| 0x1-0x3 | MOVE.B/W/L, MOVEA, every source/destination EA | `:5486-5524`, MOVEA `:5509`, sizes `:903` |
| 0x4 | ILLEGAL, EXTB, LEA, CHK.W/L, MOVE from/to SR/CCR, NEGX/CLR/NEG/NOT, LINK.W/L, NBCD, SWAP, BKPT, PEA, EXT, MOVEM both ways, TAS, TST, MUL/DIV.L, JSR/JMP, TRAP, UNLK, MOVE USP, RESET, NOP (bus-sync), STOP, RTE, RTD, RTS, TRAPV, RTR, MOVEC | `:5526-5888` (ILLEGAL `:5527`, LEA `:5541`, CHK `:5544/:5560`, MOVE from SR `:5577`, MOVEM `:5727/:5800`, TAS `:5743`, MUL/DIV.L `:5785`, JSR/JMP `:5812/:5818`, TRAP `:5825`, RESET `:5836`, NOP `:5848`, STOP `:5850`, RTE `:5854`, RTD/RTS `:5864-5865`, TRAPV `:5866`, MOVEC `:5874`) |
| 0x5 | ADDQ/SUBQ, Scc all EAs, DBcc, TRAPcc | `:5889-5945` |
| 0x6 | Bcc/BSR/BRA .B/.W/.L | `:5946-5965` |
| 0x7 | MOVEQ | `:5966` |
| 0x8 | OR, DIVU/DIVS.W, SBCD, PACK/UNPK | `:5978-6071` |
| 0x9/0xD | SUB/ADD, SUBA/ADDA, SUBX/ADDX | `:6072-6136` |
| 0xA | A-line -> vector 10 | `:6137` |
| 0xB | CMP/CMPA/CMPM/EOR | `:6140-6199` |
| 0xC | AND, MULU/MULS.W, ABCD, EXG | `:6200-6268` |
| 0xE | shifts/rotates register, immediate, memory; bitfields | `:6269-6329`, bitfield states `S_BF0..S_BF_WCHECK` |
| 0xF | CINV/CPUSH, PFLUSH*, PTEST, FPU coprocessor space, MOVE16 (all four forms) | `:6330-6440` (CINV `:6333`, PFLUSH `:6350`, PTEST `:6366`, FPU `:6379`, MOVE16 `:6427/:6432`) |

EA engine: every 68020 mode including full extension word, base/outer displacement and memory indirect (`S_EA_DISP..S_EA_OD` `:401-410`; `S_EA_EXTW :2565`, `S_EA_MIND :2623`, `S_EA_ABS :2641`). Multiply/divide in `rtl/ap040_muldiv.v` (32/64-bit forms, overflow, `DIVZERO :2742/:2906`). ALU in `rtl/ap040_alu.v` (356 lines; count-0 / over-width shift semantics tested by `tb/tb_ap040_alu_arithmetic.v`).

### 1.2 Exceptions and stack frames
- `exc(vec, fmt, pc, addr)` task `:1705`; formats $0 (`go_illegal :1928`, `go_priv :1934`, TRAP `:5825`), $2 (address error `:1946/:2014`, CHK `:2776`, DIVZERO `:2742`, TRAPcc `S_TRAPCC :6473`, trace `:1888/:2303/:3282`, FP unimplemented `:1376-1385`), $3 (FP unsupported datatype, vector 55 `:1390-1416`), $7 (30-word access-error frame builder `aerr_word :1790-1798`, `S_AERR0 :3008`, SSW/FA/EA/CM/MA per `doc/tests-README`), $1 throwaway on M-bit interrupt `:3131-3143`.
- RTE validates the format word and takes FMTERR (vector 14) otherwise (`S_RTE_SR :3206`, `S_RTE_FMT :3211`, `:3229/:3239`), continues through $1 (`:3265`), consumes CM/EA for $7 restart (`S_RTE_SSW/S_RTE_EA`).
- Trace T1/T0 with the 68040 change-of-flow list (`:1340-1352`, `flow_t0_pend :783`), interrupts autovectored with IPL mask, NMI edge, STOP wake-up (`irq_take_lvl :1877/:1962/:2281`, `S_STOPPED :6461`), double bus fault -> halt (`S_HALT :6476`, `tb/tb_ap040_double_fault.v`).
- Restart model: a faulting instruction re-executes; EA register updates are rolled back, MOVEM continues from its saved EA (`:875` comment block, `S_MOVEM_EA`, `tb/asm/t_movem_restart.s`).
- Vector table: `rtl/ap040_defs.svh:55-75`.

### 1.3 MMU (`rtl/ap040_mmu.v`, 757 lines)
Header `:1-22` is accurate to the code: ITT0/1 + DTT0/1 with FC/S matching and cache mode (`ttr_match :103`, `:199-205`), split I/D ATCs 16 sets x 4 ways in one dpram row (`:124-140`, hits `:180-184`, attrs S/CM/M/W `:189-193`), 4K/8K pages (`tc_p :96`, set/tag select `:143-144`), three-level walk with URP/SRP (`:34-35`), indirect descriptors, U/M history writes and accumulated write protection (`atc_mmiss :224`, `need_walk :228`), nonresident entries after failed searches, fault reporting by `c_flt` pulse to the core's format-$7 builder (`ttr_fault/atc_fault :220-221`), PTEST with real search and MMUSR (`pt_* :53-60`, `w_buserr :264`), PFLUSH page/global/all over both ATCs (`pf_mode :63`), separate walker port with CDC and berr (`:82-88`, `rtl/ap040_walker_cdc.v`), page-crossing transfers split per page (`doc/tests-README`, `t_mmu` tests 40-44).

### 1.4 FPU (`rtl/ap040_fpu.v`, 2 371 lines)
FP0-7 extended, FPCR/FPSR/FPIAR (`:132-146`), hardware FMOVE/FABS/FNEG/FCMP/FTST/FADD/FSUB/FMUL/FDIV/FSQRT incl. FS/FD and FSGL variants (`:353-361`, `:373`), B/W/L/S/D/X conversion, FMOVEM register/control, FBcc/FScc/FDBcc/FTRAPcc (`S_FBCC :4859`, `S_FSCC0 :4884`, `S_FDBCC :4951`), FPCR rounding/precision, gradual underflow, SNAN/BSUN/DZ/OPERR/OVFL/UNFL/INEX status and enabled traps (vectors 48-54), FSAVE/FRESTORE NULL/IDLE/UNIMP rev $40/$41 (`S_FSAVE1 :4000`, `S_FREST1 :4073`, `AP040_FPU_REVISION` param), transcendentals/FMOVECR routed to vector 11 format $2 with FPSP-compatible UNIMP state, packed/denormal/unnormal -> vector 55 format $3. Documented gaps: BUSY frames, vector-55 FSAVE payload (`doc/tests-README`). With `AP040_HAS_FPU=0` every F-line op takes vector 11 (`:6379-6392`), which is what a 68LC040 does.

### 1.5 Caches (`rtl/ap040_cache.v`, 933 lines)
4 KB + 4 KB, 64 sets x 4 ways x 16-byte lines, physically tagged, write-through with update-on-hit (header `:1-28`), CACR IE/DE (`:38-39`), CINV/CPUSH with I/D select (`:41-44`; scope is over-invalidated to "all", `doc/tests-README`), DMA snoop of the D-cache (`s_stb/s_addr :89-90`, `tb/tb_ap040_cache_snoop.v` with read-during-write and clock-enable-ratio legs), cache-inhibit from TTR/page CM and Z2/Z3 windows (`c_nocache :54`, compat `cache_z*` `ap040_tg68k_compat.v:45-53`), misaligned/line-crossing bypass. I-cache is not snooped by CPU writes (real 040 behaviour).

### 1.6 Bus, supervisor, other
- `rtl/ap040_tg68k_compat.v`: TG68K-shaped 16-bit bus (`:54-69`), `clkena_in`, `ipl/ipl_autovector/berr`, FC on every cycle, `nresetout`, walker port, external cache maintenance sideband, posted stores (`AP040_POST_STORES :27`, `post_drain :66`), debug taps (`:96-104`). `rtl/ap040_bus16_adapter.v` splits 32-bit transfers with the sampled-IDLE contract (`tb/tb_ap040_bus16_gap.v`); `rtl/ap040_bus_timeout.v` turns a hung cycle into berr.
- Privilege on every privileged opcode (`go_priv` call sites), USP/ISP/MSP banking with M-bit, MOVEC full 040 matrix with write masks (`t_exceptions` "MOVEC matrix"), MOVES via SFC/DFC with the FC pins checked by the bench, RESET instruction (`S_RESET_HOLD :4971`).
- External evidence of completeness (repo README, not re-verified here): boots NetBSD/amiga and AmigaOS 3.x, 3 776/3 801 cputest slices.

## 2. Pipelined branch: functional surface

Stages: IF (`rtl/ap040_inst_fetch.v`), ID (`ap040_decode.v`), EA-calc (`ap040_ea_calc.v`), EA-fetch (`ap040_ea_fetch.v`, also hosts memory access, the exception-entry and RTE sequencers), EX (`ap040_execute.v`), WB (`ap040_writeback.v`); regfile fork with write-through and USP/ISP/MSP banking (`ap040_pipe_regfile.v:79-86`); unified 16-bit x 4 096-word dual-port array with a 1-entry posted write buffer standing in for both caches and the bus (`ap040_pipe_l1.v:167-186`). Top-level ports are `clk, nreset, ce` and debug taps only (`ap040_pipe_core.v:146-169`).

Everything the decoder recognises (`ap040_decode.v`):

| form | line | notes |
|---|---|---|
| MOVEQ | `:319` | |
| MOVE.L Dn,Dm | `:327` | size field matched raw `10` |
| ADD.L Dn,Dm | `:335` | |
| Bcc/BRA .B/.W/.L | `:343-346` | guess-taken, recover in EX |
| BSR .B/.W/.L | `:350-353` | |
| Scc.B Dn | `:362` | |
| DBcc Dn,label | `:370` | no target-parity check (deferred, plan s.6) |
| MOVE.L (An),Dn ; MOVE.L (d16,An),Dn | `:389`, `:399` | |
| JMP/JSR (An), (d16,An) | `:407-414` | |
| TRAP #n | `:419` | |
| MOVE to SR | `:444` | MOVE *from* SR/CCR, to CCR deliberately not built (plan s.6 2b) |
| MOVEC | `:452`, selectors `:461-467` | SFC/DFC/CACR/VBR/USP/ISP/MSP only; TC/ITT/DTT/URP/SRP/MMUSR -> illegal |
| RTS, RTE | `:488-489` | RTE format $0 only (`ap040_ea_fetch.v:236-238`) |
| NOP | `:491` | |
| everything else | `is_illegal :504-507` | -> vector 4, including $Axxx and $Fxxx |

ALU (`ap040_pipe_alu.v`, `ap040_pipe_defs.svh:57-89`) is the reference ALU forked: it has sized ADD/SUB/X, logic, NEG/NEGX/CLR/TST/EXT/EXTB/SWAP/TAS/BCD, single-bit shift/rotate primitives, and bit ops — but only `MOVE`/`ADD` are ever selected by decode, and only at size Long. No multiplier/divider module exists in `rtl/`.

Exceptions: format $0 push for vectors 4/8/32-47 and format $2 for vector 3 on odd JMP/JSR targets (`ap040_ea_fetch.v:161-238`, `:390-401`); dynamic privilege check on MOVE-to-SR/MOVEC/RTE (`eac_is_priv`); vector fetch at `vector*4` **relative to the PC_RESET window, VBR not consulted** (`:187-200`, plan s.6 2b); SR word synthesised with no T1/T0/IPL state (`:173`).

Verified by running `tb/run_pipe_tests.sh` in the clone: 19/19 pass (nop, moveq, add, bra, bcc, bccw, bccl, scc, dbcc, move_mem, move_disp, jmp, bsr, jsr, exc, sup, rts_rte, addrerr, l1_wbuf).

## 3. Gap table

Status is for the PIPELINED core. "partial" says what is missing. Evidence is the decisive file:line. Jev's independent verdict (section 7) is shown where it differed from mine.

### 3.1 Integer ISA

| feature | status | evidence / what partial lacks |
|---|---|---|
| MOVEQ | present | `ap040_decode.v:319` |
| MOVE all sizes/EAs, MOVEA | **partial** | `:327/:389/:399` — Long only; Dn,Dn / (An),Dn / (d16,An),Dn; no memory destination, no MOVEA. `tb_ap040_pipe_red_movew.v`: `$3010` takes vector 4 |
| ADD/SUB/ADDA/SUBA/ADDI/SUBI/ADDQ/SUBQ/ADDX/SUBX | **partial** | `:335` ADD.L Dn,Dm only; ALU ops exist, nothing selects them |
| CMP/CMPA/CMPI/CMPM | missing | no decode; ALU CMP op unused. This alone blocks every reference test macro |
| AND/OR/EOR/NOT + immediates incl. to CCR/SR | missing | no decode |
| NEG/NEGX/CLR/TST/NBCD/EXT/EXTB/SWAP | missing (Jev: partial, datapath exists) | ALU ops in defs `:66-77`, no decode |
| shifts/rotates reg/imm/mem, count semantics | missing (Jev: partial) | 1-bit primitives `ap040_pipe_alu.v:120-139`; no count loop, no decode; reference `S_SHIFT :2846` |
| BTST/BCHG/BCLR/BSET static+dynamic | missing | |
| MULU/MULS/DIVU/DIVS .W and .L, 64-bit forms, DIVZERO | missing | no muldiv module in `rtl/` |
| ABCD/SBCD/NBCD/PACK/UNPK | missing | ALU ops unused |
| EXG/LINK/UNLK/LEA/PEA | missing | |
| MOVEM all forms, MOVEP | missing | |
| Bcc/BSR/JMP/JSR/RTS/RTD/RTR/DBcc/Scc/NOP | **partial** | JMP/JSR only (An)/(d16,An); Scc Dn only; no RTD/RTR; DBcc odd-target fault deferred |
| TRAPV/TRAPcc/CHK/CHK2/CMP2 | missing | |
| TAS/CAS/CAS2 | missing | |
| bitfields (8 ops, reg+mem, page-crossing sizing) | missing | |
| MOVE16 | missing | |
| MOVE from SR/CCR, to CCR, MOVE USP, MOVES, RESET, STOP, BKPT, ILLEGAL | **partial** | only MOVE to SR and 7-selector MOVEC (`:461-467`) |
| EA modes | **partial** | Dn, (An), (d16,An) only. No An direct, (An)+, -(An), (d8,An,Xn), full ext word, memory indirect, abs.W/L, PC-relative, #imm (`ap040_ea_calc.v` has one adder: `operand_a + eac_imm`) |
| byte/word sizes | **partial** | ALU sized, core issues Long only; L1 port B is 32-bit only (`ap040_pipe_l1.v:183`), no byte lanes |

### 3.2 Exceptions

| feature | status | evidence |
|---|---|---|
| format $0 frame | present for vectors 4/8/32-47 (Jev: partial — interrupts, A/F-line absent) | `ap040_ea_fetch.v:161-200` |
| format $2 frame | **partial** | only odd JMP/JSR (`:390-401`); not Bcc/BSR/DBcc/RTS/RTE odd targets, CHK, DIVZERO, TRAPcc, trace, F-line |
| format $7 access error, SSW/FA/EA/CM/MA, restart | missing | nothing can fault a memory access |
| format $1 throwaway, format $3 | missing | |
| RTE format validation, FMTERR, $1/$7 handling | **partial** | format $0 assumed (`:236-238`). `tb_ap040_pipe_red_rte_fmt2.v`: pops 8 of 12 bytes |
| VBR-relative vector fetch | **partial** | register exists, fetch ignores it (`:187-200`). `tb_ap040_pipe_red_vbr.v` |
| privilege violation on all privileged ops | **partial** | MOVE to SR / MOVEC / RTE only |
| A-line -> 10, F-line -> 11 | missing | `is_illegal :504`. `tb_ap040_pipe_red_aline_fline.v` |
| trace T1/T0 | missing | no T bits in the synthesised SR (`:173`) |
| interrupts, IPL mask, NMI, M-bit stack switch, STOP | missing | no `ipl` port |
| bus error / double fault / halt / watchdog | missing | no `berr` port |
| reset: ISP/PC from vectors 0/1, RESET instr | **partial** | `PC_RESET` parameter, ISP resets to 0 (`ap040_pipe_regfile.v:108-110`). Shown live by the differential harness: A7 sequence starts `00000000` vs reference `0000007c` |

### 3.3 MMU

| feature | status | evidence |
|---|---|---|
| TTRs, ATCs (4K/8K), table walker, U/M bits, faults, PTEST/PFLUSH, MOVEC of TC/URP/SRP/TTR/MMUSR, walker port | **missing, all of it** | no module; MOVEC rejects the MMU selectors as illegal (`ap040_decode.v:461-467` and its comment). Plan s.6 item 4 says "reuse `rtl_old/ap040_mmu.v`" but nothing has been started |

### 3.4 FPU

| feature | status | evidence |
|---|---|---|
| registers, arithmetic, conversions, FBcc/FScc/FDBcc/FTRAPcc, FSAVE/FRESTORE frames | missing | no module, plan s.6 item 5 |
| LC040 behaviour (F-line -> vector 11 when no FPU) | missing | takes vector 4 — a boot blocker for AmigaOS's 68040.library/FPSP even before an FPU exists |

### 3.5 Caches

| feature | status | evidence |
|---|---|---|
| split 4-way I/D, tags, fill, CACR IE/DE | **partial** | flat unified array, no tags/miss/fill; CACR is a register nobody reads (plan s.5a) |
| CINV/CPUSH decode + scope + sideband | missing | plan s.5a: "can only ever be no-ops on this substrate" |
| DMA snoop, cache inhibit (TTR/CM/Z2/Z3 windows) | missing | |

### 3.6 Bus and integration

| feature | status | evidence |
|---|---|---|
| TG68K 16-bit bus, clkena, split transfers, FC, IPL, berr, nresetout | missing | `ap040_pipe_core.v:151-169` |
| posted stores with external ordering | **partial** | 1-entry buffer internal to the array (`ap040_pipe_l1.v`) |
| bus watchdog | missing | |
| clock-enable discipline | present | `ce` gates every stage |
| debug taps | **partial** | D0-D7/SR/CCR/per-stage PC; no address registers (the harness peeks `dut.u_regfile.areg`) |

### 3.7 Pipeline-specific properties (no reference equivalent)

| property | status | evidence |
|---|---|---|
| precise exceptions for the implemented faults | present (Jev: partial) | flush on `exc_reaching_ex` (`ap040_execute.v:311`), poison-instruction tests in `tb_ap040_pipe_exc.v` |
| restart model / EA rollback / MOVEM continuation | missing | nothing can fault mid-instruction yet |
| forwarding + write-through, A7 banking | present | `ap040_ea_fetch.v` header, `ap040_pipe_regfile.v:86` |
| guess-taken branches with recovery | present | milestones 4-5, 8, 11 |

Tally: 57 features judged — **6 present, 16 partial, 35 missing**.

## 4. Closing the gaps, in dependency order

Effort is person-weeks for an engineer who knows both trees, assuming the reference's decode/EA/exception logic is ported "by intent" as the plan prescribes. Treat as ±50 %.

### 4.1 Foundations (everything else depends on these)
1. **Byte/word sizes end to end** (0.5-1 wk): size field into ID/EA/EX/WB, byte lanes on the L1 port B, sign/merge rules. Simple in the ALU (already sized); the memory side needs a real byte-enable path.
2. **All EA modes** (1.5-2 wk): (An)+/-(An) need an An *write* from EA-fetch, and the "when does the update commit relative to a fault" decision (plan s.6 item 1) — that decision is the seed of the restart model, make it now, not later. Indexed/full-extension/memory-indirect need a multi-word gather and a second memory access inside EA-fetch (a second stall source; plan s.5 "test stall OVERLAP").
3. **Memory-destination operands and RMW** (1 wk): the write buffer exists; the read-modify-write sequencing does not.
4. **Vector fetch via VBR, A-line/F-line classification, reset ISP/PC from vectors 0/1** (0.5 wk): trivial, but they gate every later exception test. `tb_ap040_pipe_red_vbr.v`, `..._aline_fline.v` and the from-reset differential leg turn green here.

### 4.2 Integer ISA fill (mostly datapath + decode; the pipeline makes it only "somewhat harder")
5. CMP family, logic, NEG/CLR/TST/EXT/SWAP, ADD/SUB all forms, ADDQ/SUBQ, immediates incl. to CCR/SR (1.5 wk).
6. Shifts/rotates with a count loop (multi-cycle EX stall) and bit ops (1 wk).
7. LEA/PEA/LINK/UNLK/EXG/RTD/RTR/MOVE from SR/CCR/USP (0.5 wk).
8. MUL/DIV: port `rtl_old/ap040_muldiv.v`, add an EX-side multi-cycle stall, DIVZERO/overflow format $2 (1 wk).
9. MOVEM/MOVEP (1 wk): a multi-beat memory sequencer in EA-fetch; MOVEM is also the first instruction whose *restart* semantics (saved EA, CM bit) must be designed in — see 4.3.
10. BCD, TAS, CAS/CAS2, CHK/CHK2/CMP2, TRAPV/TRAPcc, bitfields, MOVE16 (2-3 wk): long tail; bitfields and CAS2 are the fiddly ones (reference `S_BF*`, `S_CAS2_*` are 30+ states).
11. Full MOVEC matrix, MOVES with FC, RESET, STOP (0.5 wk, but STOP needs interrupts).

### 4.3 The genuinely hard part: where the pipeline fights you
These are the items Jev's "how much harder in a pipeline" score put at 1.9-2.0 and where I agree:

12. **External bus + precise, restartable memory faults (format $7)** (3-4 wk). Today a load completes in a fixed two-cycle `mem_issue/mem_complete` handshake against a BRAM (`ap040_ea_fetch.v:403-404`). A real bus means variable-latency loads *and* stores that can fail after younger instructions have entered the pipe. The reference's answer is simple because it is sequential: fault -> build a 30-word frame -> restart. In the pipeline you need (a) a commit point after which a store can no longer fault, or a store buffer that can report a fault back to a still-uncommitted instruction, (b) rollback of An updates made by (An)+/-(An) in EA-fetch for the faulting *and every younger* instruction, (c) MOVEM's saved-EA continuation, (d) the SSW/FA/EA/CM/MA content. This is the item the plan defers with "needs a real BCU/MMU" (s.6 2b) and it is where I would expect months, not weeks, of debugging against NetBSD's `trap.c`, which the reference README warns already bit once (the WB3 double-apply note).
13. **Interrupts and trace as precise asynchronous exceptions** (1.5-2 wk): IPL sampled at an instruction boundary in a pipeline that has 3-4 instructions in flight; T0's change-of-flow list; the M-bit throwaway frame; STOP. Not conceptually hard, but every one of them interacts with item 12's commit point.
14. **MMU in the pipeline** (3-4 wk to port, more to make it fast): the reference MMU sits between the core's single memory port and the bus and stalls the whole FSM for a walk. The pipeline has *two* consumers (IF and EA-fetch) that will both want translation every cycle, so either two ATC lookup ports or a serialising arbiter; a walk that faults must be delivered as a precise format $7 on the right instruction (item 12 again); U/M bit writes must be ordered against posted stores; PFLUSH/PTEST must drain the pipe. If "fast enough" is the requirement, note the reference's own timing history: the ATC lookup path was the critical path (`ap040_cache.v:399` comment, 5.9 ns), and that was with one port.
15. **Split I/D caches with CINV/CPUSH, snoop, cache-inhibit** (2-3 wk): the plan's unified-array decision (s.5a) explicitly gives up on reproducing CINV/CPUSH semantics; a real Harvard cache re-introduces the staleness the array hides, and I-cache invalidation by CINV must flush the fetch stage. Snoop invalidation against in-flight loads is new work the reference does not have to do.
16. **FPU** (port 2 wk, integrate 2+ wk): `rtl_old/ap040_fpu.v` is a self-contained iterative unit; the pipeline needs a long-latency EX stall, FSAVE/FRESTORE frames, vector-11/55 delivery with the right stacked PC/EA (opclass 000/010 vs 011 differ, `ap040_core.v:1364-1416`), and the LC040 mode first.

### 4.4 Ordering summary
1 -> 2 -> 3 -> 4 -> 5-11 (parallelisable) -> 12 -> 13 -> 14 -> 15 -> 16. Roughly **20-28 person-weeks to integer+exception parity with a real bus**, plus **8-12 for MMU+caches**, plus **4-6 for FPU**, before any performance work. Do not start 14 before 12; an MMU without a precise fault path is untestable against `t_mmu.s`.

## 5. Tests that prove completeness

### 5.1 The reference's existing suite (what exists, how it runs, what it covers)
`tb/run_tests.sh` (needs iverilog + vasmm68k_mot; both installed here). Ran it in the clone on 2026-09-21: **29/29 legs pass**; the appended `run_fpu_frames.sh` reports `FAIL frames revision=64`. That failure is a harness defect in the GitHub tree, not the core: `tb_ap040_program.v` has no `FPU_REVISION` parameter, so `-P tb_ap040_program.FPU_REVISION=64` is ignored (iverilog prints the warning), the core stays at revision $41 and the program assembled with `-DREV40` fails its IDLE-frame revision check (`t_fpu_frames.s:55`, test 4). Worth telling apolkosnik; not verified whether his local tree differs.

| leg | mechanism | covers |
|---|---|---|
| `reset` | `tb_ap040_reset.v` | reset vectors, 16-bit adapter lanes/misalignment, wait states |
| `regfile`, `regfile_poison`, `regfile_bypass_control` | unit bench with a negative control | read-during-write bypass |
| `alu_arithmetic` | unit bench | ALU/shifter edge cases |
| `fpu_normalize` | unit bench | FPU normaliser |
| `double_fault`, `walker_cdc`, `bus16_gap`, `bus_timeout` | unit benches | halt path, walker CDC, split-transfer IDLE contract, watchdog |
| `cache_snoop` x9 (CE 1:1 and 4:1, read-during-write X model, injected faults, two negative controls) | unit bench | snoop invalidation, lookup guard |
| `integer` … `fpu` (10 programs via `tb_ap040_program.v`, each run at two wait-state profiles) | self-checking assembly, `$F100/$F102` protocol | see below |
| `run_fpu_frames.sh` | `t_fpu_frames.s`, `t_fpu_resume.s` at revisions $40/$41 | FSAVE/FRESTORE wire format, FPSP resume |

Program coverage (section headings in `tb/asm/*.s`): `t_integer.s` 887 lines, 36 sections, ~180 checks (all groups in 3.1 incl. EA modes, MOVEM predec-with-base, store into the fetch queue); `t_exceptions.s` 1 911 lines, 24 sections (TRAP, illegal/BKPT, A/F-line, FSAVE/FRESTORE decode, CHK, DIVZERO, TRAPV/TRAPcc, trace, MOVEC matrix, MOVE USP, MOVES, PTEST/PFLUSH/CINV/CPUSH privilege, user round trip, FMTERR, address error, interrupts, M-bit, level-sensitive IPL, immediate-group EA legality, physical bus error); `t_mmu.s` 1 605 lines, 28 sections (walk, history bits, PTEST, WP/invalid/fetch/super faults, page crossing, TTR, ATC+PFLUSH, MOVEM restart, 8K pages, NetBSD/NeXTSTEP shapes, IRQ-vs-MMU sweeps); `t_cache.s`, `t_atcprobe.s`, `t_bitfield_mmu.s`, `t_bitfield_cache.s`, `t_moves_fc.s`, `t_movem_restart.s`, `t_fpu.s` 5 298 lines, 60 sections.

Beyond this tree (per `doc/tests-README`, not present in either clone): `diff/` random-program differential vs qemu-system-m68k, `run_cputest.py` WinUAE cputest corpus replay (the 3 776/3 801 number), `tb_ap040_diagrom.v`. The local `lib/AP68040` (e2-fixes) has a smaller suite: 6 unit legs + 7 programs = the "13/13"; it lacks `t_atcprobe/t_movem_restart/t_moves_fc/t_fpu_frames/t_fpu_resume`, the regfile/ALU/FPU-normalise unit benches and the negative controls that GitHub `main` added on 2026-09-18.

### 5.2 Which reference tests can run against the pipelined core
- **As-is: none.** Every leg drives `ap040_tg68k_compat`'s 16-bit bus or a reference sub-module; the pipelined core has neither.
- **After a loader shim only (no RTL change): still none of the programs get past their first check.** I scanned every `tb/asm/t_*.s` for mnemonics outside the milestone-17 decoder (lower bound, operand modes ignored): `t_integer.s` 186 of 479 instruction lines blocked (`and.l`, `lea`, `cmp.l`, `movea.l`, …), `t_exceptions.s` 393/1 034, `t_mmu.s` 273/932, `t_fpu.s` 2 369/3 505. The check macros themselves (`chkl` = `cmp.l #imm,Dn`, `chkccr` = `move.w ccr,d6` + `andi.w`) are unimplemented, so no program can report a result.
- **Adaptable once 4.1-4.2 are done**: `t_integer.s` and the non-MMU half of `t_exceptions.s` run unchanged through the trace harness below (they need only a flat memory and the `$F100/$F102` write watch); `bench_loop.s` likewise. `t_mmu/t_atcprobe/t_bitfield_mmu/t_moves_fc/t_movem_restart` need 4.3 items 12+14; `t_cache/t_bitfield_cache` item 15; `t_fpu*` item 16.
- **Unit benches**: `tb_ap040_walker_cdc.v`, `tb_ap040_bus16_gap.v`, `tb_ap040_bus_timeout.v`, `tb_ap040_cache_snoop.v` test reference modules that the pipeline should *reuse* rather than rewrite, so they carry over verbatim if it does.
- **Gaps with no reference test either**: pipeline-only hazards (stall overlap with a second gather, forwarding into an EA computation, store-buffer-vs-load ordering, exception arriving while an older instruction is stalled in EA-fetch, interrupt sampled while a multi-beat MOVEM is mid-flight). The plan (s.5) records this class of bug already bit twice (milestones 10, 15). These need pipeline-specific directed tests; nothing in the reference suite exercises them because the reference cannot have them.

### 5.3 Definition of "complete"
Two oracles, in order of authority, matching the reference's own provenance policy:
1. **Differential against the reference core**: identical stimulus (program image, wait-state profile, IPL/berr injection script) on both cores; compare the *architectural trace* — the ordered sequence of (retired PC, D0-D7, A0-A7, SR, memory writes as (addr, size, data), exception vectors taken with their frame words). Timing is not compared. Parity = identical sequences to the end of the program. This is what `tests/` implements for the register half.
2. **cputest corpus** (`run_cputest.py`, 3 801 slices, per-instruction golden state from real silicon via WinUAE): the terminal criterion. Parity = the reference's 3 776 passing slices pass, and the same 25 documented generator defects fail. Running it needs the bus adapter (item 12) first.

A feature counts as complete when (a) its directed test below passes, (b) the reference program that covers it passes unchanged, and (c) the differential trace matches the reference over that program. (a) alone proves the mechanism, (b) proves the reference's corner cases, (c) proves you did not break something else.

### 5.4 Test cases per feature group
Notation: `instr ; pre -> post` with expected CCR as XNZVC. Each is a line in an assembly program in the reference's `chkl/chkccr` style once CMP/MOVE-from-CCR exist; until then the same cases are encodable as `tb_ap040_pipe_*.v` pokes.

**Sizes and EA modes**
- `MOVE.B (A0),D0 ; D0=$AAAAAAAA, [A0]=$80 -> D0=$AAAAAA80, N` ; same for .W (`red_movew`), .L; odd-address .W/.L (byte+word+byte split on the bus).
- `MOVE.L (A0)+,D0 ; A0=$1000 -> A0=$1004`; `MOVE.L -(A0),D0 -> A0=$FFC`; byte on A7 moves 2.
- `MOVE.L (8,A0,D1.W*4),D0` brief; `MOVE.L ([$10,A0],D1.L,$20),D0` post-indexed; `([bd,A0,Xn],od)` pre-indexed; `(bd,PC,Xn)`; `(xxx).W` sign-extended; `#imm` all sizes; `MOVE.L D0,(A1)+` memory destination; `MOVE.L (A0)+,(A1)+`.
- Fault-side: each An-updating mode with an injected berr on the access -> An unchanged after RTE (restart model), frame FA/EA per `t_movem_restart.s`.

**ALU** (per op, per size, register and memory destination): `ADD.W #1,D0 ; D0=$FFFF -> Z X C`; `ADD.L #1,D0 ; $7FFFFFFF -> N V`; `SUBQ.L #1,D0 ; 0 -> XNC`; `ADDX/SUBX/NEGX` with X=1 and Z sticky (`t_integer` "addx/subx"); `CMP.L` all flag combos, `CMPA.W` sign-extends, `CMPM (A0)+,(A1)+`; `AND/OR/EOR` clear V/C keep X; `NOT/NEG/CLR/TST` incl. `TST` on An/#imm/PC modes (020+ legal); `EXT.W/L`, `EXTB.L`, `SWAP`; `ABCD/SBCD/NBCD` with X and the undefined-N convention the reference chose (`t_integer` "BCD with"); `PACK/UNPK`.

**Shifts/rotates**: each of 8 ops x {reg count 0, 1, size-1, size, size+1, 63, 64 via Dn; imm 1-8; memory .W by one}; assert X/C per `t_integer` "shift/rotate count edges" (count 0 leaves X, clears C except ROXx which copies X to C; over-width results 0/sign with C from the last bit out).

**Bit ops**: `BTST/BCHG/BCLR/BSET` Dn and #imm, register (mod 32) and byte memory (mod 8), `BTST Dn,#imm` (`t_integer` line 582), Z from the *pre* state.

**MUL/DIV**: `MULU.W`, `MULS.W`, `MULU.L` 32x32->32 and ->64 (`Dh:Dl`, Dh==Dl case `t_integer:746`), `DIVU.W/DIVS.W` quotient overflow (V, dest unchanged), `DIVS.L` 32-bit overflow (`:737`), `DIVUL.L` 64/32, divide by zero -> vector 5 format $2 with PC of the next instruction stacked, CCR per 040 (`CHK flags :723`).

**Control flow**: Bcc every cc x B/W/L x taken/not; `BSR.B/W/L` return address; `JMP/JSR` every EA incl. PC-relative and memory-indirect; `RTS/RTD #d/RTR` (RTR restores CCR only); `DBcc` expiry, taken, and odd-target address error *before* the condition; `Scc` every cc to Dn and to memory byte; `TRAPcc/TRAPV` with and without operand words, stacked PC = next instruction; `CHK.W/L` in/out of bounds and negative (N tracks value sign); `CHK2/CMP2` bounds in register and memory, signed/unsigned pairs.

**System**: `MOVE from/to SR/CCR` (from SR privileged, user-mode -> vector 8; SR write mask $F71F / `AP040_SR_MASK`); `MOVE USP` both ways; `MOVEC` every 040 register with its write mask (`t_exceptions` "MOVEC matrix"); `MOVES` .B/.W/.L both directions with FC = SFC/DFC checked on the pins; `LINK.W/.L`, `UNLK`, `LINK A7`; `EXG` D/D, A/A, D/A; `MOVEM` reg->mem predec incl. base in list (initial value stored), mem->reg postinc incl. base in list (loaded value wins), word forms sign-extend into An, control modes; `MOVEP` .W/.L both ways at odd/even; `TAS` sets bit 7, flags from the pre value; `CAS.B/W/L` match/mismatch with Dc update, `CAS2` both orders; `MOVE16` all four forms, line-aligned, 16 bytes moved, address registers +16; `RESET` pulses `nresetout` and nothing else; `STOP #sr` privileged, loads SR, sleeps until an IPL above the mask, `STOP` with a traced T bit does not sleep (`tests-README`); `NOP` drains posted stores; `BKPT` -> vector 4; `ILLEGAL` -> 4; `$Axxx` -> 10; `$Fxxx` -> 11 (`red_aline_fline`).

**Exceptions and frames** (each: vector taken, format word, stacked SR/PC/address, SP delta, handler `RTE` resumes correctly)
- Format $0: TRAP #0-15, illegal, privilege, A/F-line, interrupts 25-31; stacked PC = next for TRAP/interrupt, own for illegal/priv/A/F-line.
- Format $2: address error on odd targets for JMP/JSR/Bcc/BSR/DBcc/RTS/RTE/RTD/RTR/exception vector (`ap040_core.v:1946/:2014/:3174/:3274`), CHK, DIVZERO, TRAPcc, trace, unimplemented F-line; instruction-address longword contents per case.
- Format $7: physical berr on read, on write, on fetch, on the RTE frame load (double fault -> halt), on a table walk; SSW bits TT/TM/SIZE/RW/LK/ATC/MA/CM; FA/EA relationship; WB3 never valid (restart model); MOVEM mid-list fault sets CM and EA; misaligned second-page fault sets MA (`t_mmu` 40-44, `t_atcprobe`).
- RTE: format $0/$2/$3/$7 pop sizes (`red_rte_fmt2`), $1 continuation (M-bit throwaway), unknown format -> FMTERR vector 14 format $0, odd PC in frame -> address error, RTE in user mode -> priv.
- Trace: T1 after every instruction; T0 after change of flow, and after the synchronising list (NOP, MOVE to SR, MOVEC, CINV/CPUSH/PFLUSH/PTEST, FMOVEM/FRESTORE, STOP); traced instruction that itself traps takes only the trap; traced STOP does not stop.
- Interrupts: IPL 1-7 vs mask 0-7 (level > mask, or 7 always), NMI edge (IPL 7 held does not re-interrupt), autovector 24+n, SR mask raised to n, M bit clear + format $1 throwaway on the interrupt stack, RTE through the $1 frame back to the master stack, level-sensitive IPL shapes from `t_exceptions` "level-sensitive IPL" and the IRQ-vs-MMU sweeps in `t_mmu` 161-164.
- Reset: ISP from vector 0, PC from vector 1, SR $2700, four longwords fetched before handler execution (`tests-README`); the from-reset differential leg.

**MMU**: enable TC.E with identity tables then remap a page (reads follow the new mapping), U set on first touch, M set on first write only, write to a clean page after ATC hit walks again for M (`atc_mmiss`), WP fault format $7 then fix and restart, invalid page fault, supervisor-only page from user (U bit set, M not, `tests-README`), instruction-fetch fault, 4K and 8K (LA bit 12 routing), TTR hit bypasses tables with WP and CM honoured, ATC hit vs miss observable via PTEST MMUSR (R/W/M/B bits), PFLUSH (An) page / PFLUSHA / non-global variants, RTE to user switches the fetch root, page-crossing misaligned transfers translate each byte separately, walker berr -> MMUSR B, nonresident entries installed after failed search and invalidated by PFLUSH/PTEST (`t_atcprobe.s`), NetBSD relocation/demand-paging shapes (`t_mmu` 154-155, 883-1000).

**Caches**: CACR IE/DE set/clear; self-modifying code stale until CINV I; DMA-style poke stale until CINV D / snoop; TTR CM inhibit bypass; byte/word extraction from a cached line; misaligned bypass; CPUSH == CINV on write-through; disable behaviour; snoop invalidation with CE 1:1 and 4:1 (`tb_ap040_cache_snoop.v`); MOVE16 line semantics against the cache.

**FPU**: `t_fpu.s`'s 60 sections are the spec; the LC040 subset first (every F-line -> 11, FSAVE/FRESTORE NULL frame legality), then registers/moves/conversions, then arithmetic with the FPCR rounding x precision matrix and the special-value corners (`t_fpu` 1606-1811), then frames (`t_fpu_frames.s` at both revisions), then FPSP resume (`t_fpu_resume.s`).

**Pipeline-specific** (no reference equivalent; directed `tb_ap040_pipe_*.v`): EX-forward into an EA computation (`MOVEA.L D0,A0 ; MOVE.L (A0),D1` back to back); store then load same address across the write buffer; a load stall overlapping a second instruction's gather (milestone 10's bug); exception on instruction k while k-1 is stalled in EA-fetch; interrupt sampled during a MOVEM; Bcc mispredict flushing a pending An update; CCR write-through into an immediately following Bcc for every ALU op class (not just Scc/MOVEQ); DBcc with the counter forwarded from EX.

### 5.5 Written vs specified
Written and run (`findings/ap040-pipelined/tests/`, see its README):
- `tb_ap040_pipe_trace.v`, `tb_ap040_ref_trace.v`, `compare_trace.py`, `asm/diff_smoke.s`, `run_all.sh`: the differential harness. Result on 2026-09-21: **parity from PC $402 over 29 retired instructions** (SR, D0-D2, A0, A7 event order and final state identical), **divergence from reset** (A7 `00000000` vs `0000007c`: the pipelined core does not load ISP from vector 0). Two harness bugs found and fixed during bring-up (fixed-width `reg` string truncation of long paths; the pipelined commit lands one edge before `dbg_wb_valid` presents the instruction, so registers must be sampled pre-NBA on that posedge).
- Four red benches (`red_movew`, `red_rte_fmt2`, `red_vbr`, `red_aline_fline`): each fails today with the message that names the gap; each passes only when the feature exists.

Specified only: everything in 5.4 beyond those; the `ap040_regfile` 16-register debug tap the reference dumper needs to compare all registers; a memory-write trace column; the IPL/berr injection script for the differential harness; cputest replay against the pipeline (needs the bus).

I did not run the reference suite against the local `lib/AP68040` (Paul's 13/13 claim is taken at face value) and I did not run cputest.

## 6. Not verified
- That `apolkosnik/AP68040 main` and Paul's `lib/AP68040 e2-fixes` behave identically on the shared legs; only file-level diffs were listed (all 11 RTL files differ; local adds `ap040_fill_cdc.v`).
- Reference README claims (NetBSD/AmigaOS boot, cputest 3 776/3 801): not reproduced; `run_cputest.py` and `diff/` are not in the repo.
- `run_fpu_frames.sh` failure root cause beyond the missing `FPU_REVISION` parameter (I did not try adding the parameter).
- Pipelined core: I read the decoder, EA-fetch, execute and regfile in full at the cited lines but did not read `ap040_writeback.v` or all of `ap040_pipe_core.v`; `PROG_WORDS` semantics ("instructions issued", `ap040_inst_fetch.v:25-29`) were taken from the comment and confirmed only by the harness running to its cycle budget with `PROG_WORDS=$7FFFFFFF`.
- Whether `dbg_wb_valid` can stay high across a stall and duplicate a PC in the trace: the dumper collapses consecutive duplicates defensively; not confirmed either way.
- Effort estimates in section 4 are judgement, not measurement.
- Any claim about the reference's *timing* (the 5.9 ns ATC path comment) is quoted from the source comment, not re-synthesised.

## 7. How Jev (TypeSafe System One) was used
Docs read first: `docs.typesafe.ai/llms.txt`, `api.md`, `primitives.md`, `confidence.md`; HTTP API called directly with `urllib` (`scratchpad/jev.py`; key read from the secrets file at call time, never printed or written anywhere). Model answered as `jev-1.13.0`.

- **Volume**: 11 requests, 173 questions (2 smoke + 57 features x 3), 63 369 input / 4 344 output tokens, 13 s wall time for the batch.
- **Primitives**: per feature, a **Choice** present/partial/missing for the pipelined excerpt (grep hits with file:line, up to 14 lines, plus the feature definition), a **Noul** "does the reference excerpt implement it", and a **Score** 0-2 "how much harder in a six-stage pipeline than a sequential FSM" (ordered degree, so Score was the right fit). Six features per request, all three questions per feature in the same request as the docs recommend.
- **Agreement**: 49/57 Choice verdicts matched my prior reading (written before the run). Median confidence 0.98. The 8 disagreements: `neg_clr_tst`, `shift_rotate` — Jev said partial because the ALU datapath exists; fair, I adopted "missing (decode) / datapath present". `exc_fmt0` — Jev said partial because the definition listed interrupts and A/F-line; Jev was right by the definition, my "present" was implicitly scoped. `trace` (0.60), `fpu_absent_trap` (0.26), `restart_model` (0.10), `branch_pred` (0.38), `regfile_forward` (0.61) — low confidence and, on re-reading the excerpts, driven by comment lines mentioning the keyword; I kept my verdicts. Low-confidence answers were an accurate flag for "the excerpt is ambiguous", which is the property that made it useful.
- **Reference Noul**: > 0.5 for every real feature; correctly low (0.08/0.25) for the two pipeline-only properties the reference does not have, and 0.28 for posted stores where the excerpt was thin. Used as a sanity check on my inventory, nothing more.
- **Hardness Score**: the top of the list (`restart_model` 2.0, `exc_fmt7` 1.99, `mmu_fault` 1.98, `precise_exc` 1.93, `mmu_walk` 1.92, `bus_error` 1.90) is exactly section 4.3, and the bottom (`moveq`, `cmp_family`, `neg_clr_tst` ≈ 1.0) is section 4.2. It agreed with engineering judgement; it did not change it.
- **Did it save effort?** For the 35 "missing" rows, yes — a zero-hit grep plus a 1.00-confidence "missing" closed each row without a read. For the 16 "partial" rows, no: deciding *what* is missing needed the code, and Jev's answer only confirmed the label. I did not use Jev for the test-section blocking analysis (5.2) because a deterministic mnemonic scan is strictly more reliable there, nor for effort estimates. Net: worth it as a cheap second reader over a large table; not a substitute for reading the decoder.

## 8. Reuse analysis: lifting the reference MMU, FPU and caches into the pipeline

Follow-up (same day) to Paul's question: can the pipelined core reuse apolkosnik's MMU and FPU instead of building its own? Paul confirms "CPU and MMU fast enough" referred to the reference core. Sections 4.3/4.4 costed those blocks as if written from scratch; this section re-costs them on the reuse assumption. Same clones as above; the reference file is `apolkosnik/AP68040 @ 8f72275 rtl/`. Note that the pipelined repo's own `rtl_old/` copies are behind the reference by 97 (MMU), 447 (FPU), 484 (cache) and 1 167 (core) diff lines, so "reuse" should mean the GitHub reference or `lib/AP68040`, not `rtl_old/`.

### 8.1 MMU: lifts almost entirely as-is

`rtl/ap040_mmu.v` is a **standalone translation stage with a level-held request interface**, not a piece of the sequencer. Its port list (`ap040_mmu.v:26-93`) has four groups and none of them carries core-sequencing context:

| group | ports | coupling |
|---|---|---|
| control registers | `tc urp srp itt0 itt1 dtt0 dtt1` (`:33-39`) | plain inputs from the MOVEC set; the pipeline's MOVEC needs the 8 MMU selectors it currently rejects (`ap040_decode.v:461-467`) |
| core-side memory request | `c_req c_write c_instr c_size c_addr c_wdata c_fc` in, `c_ack c_rdata c_flt` out (`:42-51`) | level-held request until `c_ack` (`:365-371`: "the core holds the request stable until ack"); `c_flt` is a one-`ce` pulse that consumes the request (`:51`) |
| PTEST / PFLUSH sideband | `pt_* pf_* ` with `pt_done/pf_done/pt_mmusr` (`:53-66`) | request/done; the MMU expects the core to be *stalled* for the duration (`:148-149`: "the PFLUSH/PTEST sweep while the core is stalled behind pf_req/pt_req") |
| downstream | `m_*` to the cache/bus, `walker_*` to its own port, `phys_addr/cache_inhibit/m_nocache` (`:69-93`) | unchanged |

Inside, everything Paul listed is self-contained: TTR matching is a function (`ttr_match :103`, evaluated combinationally `:199-205`); the ATC is one dpram row per {bank,set} with a free-running one-clock lookup pipe and a freshness check (`:157-173`), so translation latency is one clock when the ATC hits and `tc_e` is set, zero for TTR hits or `tc_e=0` (`pass_ok :345-347`); the table walker is its own FSM `W_IDLE..W_DROP` (`:241-254`) with U/M writeback and the deferred-`c_flt`-after-descriptor-write rule (`:671-697`); PTEST and PFLUSH run inside that FSM (`:444-461`, `:535`, `:573-581`). PLOAD is a 68030 instruction; the 040 has none and neither core implements one. Jev classified all 48 ports as datapath (32) or handshake (16), none as sequencer-coupled; I agree after reading them.

What the reference core does around the MMU, and therefore what does NOT lift:

- **Format-$7 context capture** is in the core, not the MMU: `aerr_start` (`ap040_core.v:1715-1760`) reads `mem_instr/mem_addr/m_addr_r/mem_write/m_size/m_cross/lk_cyc/r_m_ret/mm_resume/mm_start_ea/fc_ovr_v` to fill `aer_fa/aer_wr/aer_sz/aer_ma/aer_cm/aer_ea/aer_tt/aer_tm/aer_m16` — every one of those is the reference sequencer's idea of "what am I in the middle of". The 30-word frame builder (`aerr_word :1790`, `S_AERR0..S_AERR_WR :3008-3070`) is portable; its *inputs* are not.
- **EA-register rollback** `u0_*/u1_*` (`:886-888`) and MOVEM's saved-EA/`CM` continuation are core state.
- **Single memory port**: the reference has one `mem_*` port shared by the fetch queue (`epf_* :636-712`) and operand access, arbitrated by the FSM. The MMU is built for exactly one outstanding request.

### 8.2 MMU integration work that reuse does not remove

1. **Two consumers, one MMU.** The pipeline's IF reads L1 port A every non-stalled cycle (`ap040_pipe_core.v:458-466`) and EA-fetch uses port B (`:468-472`, driven from `ap040_ea_fetch.v`). The lifted MMU has one `c_*` port. Options: (a) one MMU + an arbiter that serialises IF and EA-fetch requests — cheapest, and it is what the reference effectively does, but it turns every data access into an IF bubble and vice versa (the reference's `memlat_portwait` counter exists precisely to measure this cost, `tb_ap040_program.v:709-711`); (b) two MMU instances, one per consumer, sharing nothing — simple and fast, but the ATCs diverge (two walkers can both set U/M, PFLUSH/PTEST must hit both, the walker port needs an arbiter, and `atc_v`/round-robin state is duplicated); (c) split the module: keep TTR + ATC lookup per consumer (the lookup is ~60 lines, `:143-205`) and share one walker/PTEST/PFLUSH FSM behind a small request mux. (c) is the right answer for "fast enough" and is a refactor of the reference file, not a rewrite: ~1 week. The 68040 itself has separate I and D ATCs; the reference already banks them by `c_instr` inside one array (`a_tag :144`), so the split falls along an existing seam.
2. **Precise fault delivery.** `c_flt` consumes the request and says nothing about *which instruction* it belonged to. In the pipeline the EA-fetch requester knows (it has `eac_pc`, the instruction, its EA and the An-update it would commit), so the fault must be turned into the existing "dynamic exception at EA-fetch time" shape (`eac_is_priv`/`eac_is_addrerr`, `ap040_ea_fetch.v:390-401`) with a new `eac_is_accerr` and a format-$7 push instead of $0/$2. That is the same commit-point problem as section 4.3 item 12 and reuse does not touch it. A fault on an **IF** request is different: it must not be raised until that instruction reaches EA-fetch/EX (a fetch past a mispredicted branch faults harmlessly in the reference too, via `epf_err :653` re-issue-on-demand); the pipeline needs a "poisoned fetch" bit travelling IF→ID→EA-calc→EA-fetch. New work, ~1 week, plus the frame content (`aerr_start`'s fields recomputed from pipeline state) ~1 week.
3. **Stores.** The pipeline posts stores through a 1-entry buffer (`ap040_pipe_l1.v:183-186`). A posted store that then faults in the MMU has already left the instruction that issued it. Either stores translate *before* posting (translate in EA-fetch, post the physical address — then the buffer sits below the MMU and the reference cache's `c_post_ok` path `ap040_cache.v:59` can be reused) or the buffer must be able to report a fault back to a retired instruction, which the 68040 handles with WB1-3 in the $7 frame and the reference deliberately does not (`README` "restart model"). Translate-before-post is the only sane choice; it costs one ATC lookup per store in EA-fetch. Design decision, ~0.5 week.
4. **PFLUSH/PTEST/MOVEC-to-TC drain.** The MMU assumes the core is stalled during a sweep; the pipeline must drain in-flight instructions before `pf_req/pt_req` and before writing `tc/urp/srp/ttr` (a younger instruction already translated under the old map must not retire). The reference has the same list for T0 tracing (`ap040_core.v:1340-1352`); the pipeline gets a `serialise` decode bit and a drain-then-issue state in EA-fetch. ~0.5 week.
5. **Walker vs posted stores.** The reference holds `walker_req` behind a draining posted store (`ap040_tg68k_compat.v:80` comment) so a descriptor read cannot pass a pending write to the same table. The pipeline's buffer needs the same interlock. Small.
6. **Interface the lifted MMU needs from the pipeline**, concretely: per consumer, a level-held `{req, write, instr, size, addr, wdata, fc}` that stays stable until `ack` or `flt` (the L1 port A today is *not* level-held — IF re-addresses every cycle; it needs a request register), the seven MOVEC registers, a `serialise/drain` handshake for `pf/pt`, and a fault sink that carries the requester's instruction tag. Nothing else.

Timing caveat, since "fast enough" is the point: the reference's own comments record that the ATC-compare→`c_ack` path was the critical path (5.9 ns, "over 50 logic levels") until the shortcut was removed on both the MMU (`ap040_mmu.v:365-371`) and the cache (`ap040_cache.v:395-405`). The lifted MMU keeps that fix, but the pipeline must not reintroduce it by making a stall decision combinationally from `c_ack` in the same cycle as the lookup. Registering the ack costs the extra cycle the reference already pays.

### 8.3 FPU: the datapath lifts, the sequencing does not

`rtl/ap040_fpu.v` is also a separate module, but its port list (`:30-131`, 63 ports) splits three ways, and Jev's classification (27 sequencer / 29 datapath / 7 handshake) matches mine:

| group | ports | lifts? |
|---|---|---|
| command | `req op_class opmode src_fmt src_r dst_r din[95:0]` → `done accepted unimp unsupp exc_req exc_vec dout[95:0] fpcc` (`:36-56`) | **yes**: a pulse-request, pulse-done unit with a 96-bit left-aligned operand window in and out. Every arithmetic op, conversion, FCMP/FTST, FPCR precision/rounding, and the exception *decision* live behind this port |
| control registers + FMOVEM raw port | `cr_sel cr_we cr_wdata cr_rdata bsun_req bsun_enable ia_we ia_wdata fm_sel fm_we fm_wdata fm_rdata` (`:58-72`) | **yes**, plain register access |
| FSAVE/FRESTORE state, pending-exception frame, FPSP resume | `fpu_used fstate_* fsave_ack frestore_* pend_capture cur_vec frestore_e1_pend frestore_cusavepc frestore_resume fp_reset` (`:73-125`, 27 ports) | **the module side lifts unchanged**, but each port is the other half of a core-side sequence (`S_FSAVE1 :4000`, `S_FREST1 :4073`, `S_FSAVE_U/UD/B/BD`, `S_FREST_U/UD/B/BD`) that reads or writes the frame words on the stack |

What the reference core does around the FPU, i.e. the part reuse does not give you (roughly 1 100 lines of `ap040_core.v`): coprocessor-space decode and EA legality per opclass (`:6379-6392`), `S_FPU_DEC..S_FPU_WR` (`:4209-4700`) — extension-word decode, fetching a B/W/L/S/D/X/P memory operand into the 96-bit window (`S_FPU_RD/RD2`), storing `dout` back with the (An)+/-(An) update, `S_FPU_CR*`/`S_FPU_MVM*` for FMOVE/FMOVEM of control registers and register lists, `S_FBCC/S_FSCC0/S_FDBCC` (`:4859-4970`) and FTRAPcc, and the exception dispatch: `go_fp_fline` for vector 11 with the opclass-dependent stacked PC/EA (`:1364-1385`), `go_fp_unsupp` for vector 55 format $3 (`:1390-1416`), arithmetic traps `exc(fpu_exc_vec, 4'd0, pc, pc_i)` (`:4614`), the rule that (An)+/-(An) updates *stand* on unimp/unsupp (`:4593-4611`), and the deferred-exception path.

The one piece of reference behaviour that is already pipeline-shaped and worth copying rather than re-inventing: **background release**. `accepted` (`:47-52`) fires once operand classification is past and no unimp/unsupp can follow; the core then sets `fpu_bg` and continues integer execution (`:4617-4625`), retiring the result inside the FPU and converting a late `exc_req` into a *pending pre-instruction exception* at the next FPU dispatch (`:2170-2181`, `fpu_pend_exc`). That is exactly the long-latency-unit contract a pipeline wants: FP arithmetic is an EX-side unit that stalls only on a structural hazard (next FP op while busy) or a data hazard (FMOVE reading a register still in flight — the FPU shadows those, `ap040_fpu.v:146`).

What has to change to sit in the pipeline:
1. Decode: the F-line group in `ap040_decode.v` (today: `is_illegal`), with the LC040 fallback (vector 11) as the first deliverable — this makes the core bootable by AmigaOS/NetBSD before any FP hardware is wired.
2. EA-fetch: a 96-bit operand path (memory formats up to 12 bytes = three L1/bus beats) and the (An)+/-(An) rules above; the FMOVEM list sequencer.
3. EX: the `req/accepted/done` unit with a busy interlock; FScc/FBcc/FDBcc read `fpcc`, which is a live register inside the FPU — a forwarding hazard against an in-flight background op (the reference avoids it by not dispatching another FP op until `fpu_bg` clears).
4. Exceptions: vector 11/55/48-54 delivery through the existing exception-entry sequencer (format $2 and $3 pushes are new; $0 exists), with the opclass-dependent PC/EA fields.
5. FSAVE/FRESTORE: the 20 `fstate_*/frestore_*` ports need a multi-beat stack read/write sequencer (NULL 4 bytes, IDLE 28, UNIMP 52, BUSY 96 — `tb/asm/t_fpu_frames.s`) and, being on the T0 synchronising list, a pipeline drain.

### 8.4 Caches: reusable, but the unified-array decision must be reversed

`rtl/ap040_cache.v` sits between the MMU's `m_*` and the bus (`ap040_tg68k_compat.v:376-412`), takes physical addresses plus `c_nocache` from the MMU (`ap040_cache.v:47-54`), and exposes only CACR enables, `cinv_*`, the snoop strobe and the bus (`:38-90`). It is a **memory-side** module with the same level-held single-request contract as the MMU; it lifts as-is *below* a lifted MMU with zero interface change — the chain core→MMU→cache→bus16 is already wired in `ap040_tg68k_compat.v` and can be copied.

But it is a real split, tagged, filling cache, and the pipelined branch's `ap040_pipe_l1.v` is a flat 4 096-word array standing in for *both* caches *and* memory (plan s.5a). The two cannot coexist: the array has no miss, so nothing ever reaches a bus, and the array is the only thing IF and EA-fetch know how to talk to. Reversing the decision means (a) turning port A/port B into the two level-held request ports of 8.2 item 6 (IF gets a fetch queue or at least a request register; EA-fetch already has a two-state FSM that can hold), (b) putting MMU→cache→bus behind them, (c) deleting the array. The reference cache is then one instance shared by both consumers — which is the same arbitration question as the MMU (8.2 item 1) and should be solved once: whatever arbiter serialises IF/EA-fetch into the MMU also serialises them into the cache. Splitting the reference cache into two instances (I and D) is possible — it already banks by `c_instr` — but its snoop/CINV/`c_post_ok` paths would be duplicated; not worth it until the arbiter is measured.

Two things the plan gave up on that come back for free with the real cache: CINV/CPUSH become observable (self-modifying-code staleness, `t_cache.s`), and CACR IE/DE actually gate something. One thing that does not: the reference's I-cache is not snooped by CPU writes, and the pipeline's IF may hold *already-fetched* words that a CINV must also discard — a fetch-stage flush on `cinv_ic`, new and small.

### 8.5 Revised effort table (person-weeks, ±50 %)

| block | from scratch (sect. 4) | lift (port + wire) | integration the lift does not remove | with reuse, total | where reuse helps |
|---|---|---|---|---|---|
| MMU: TTR, ATC, walker, PTEST/PFLUSH, MOVEC regs | 3-4 (port) + more to make fast | 0.5 | 1 two-consumer split (8.2.1) + 2 precise IF/EA fault delivery and $7 context (8.2.2) + 0.5 translate-before-post (8.2.3) + 0.5 drain/serialise (8.2.4) | **4.5** | the whole translation machine; none of the fault plumbing |
| Bus + format $7 + restart model (item 12) | 3-4 | 0.5 (bus16 adapter, watchdog, walker CDC lift as-is) | 2.5-3.5 (commit point, An rollback, MOVEM continuation — unchanged) | **3-4** | adapters only |
| Caches: split I/D, CINV/CPUSH, snoop, inhibit | 2-3 | 0.5 | 1 reverse the unified array + request ports (8.4) + 0.5 IF flush on CINV | **2** | tags/fill/snoop/inhibit — all of it |
| FPU datapath, control regs, FMOVEM port | 2 (port) + 2 (integrate) | 0.5 | 1 decode + LC040 vector-11 mode; 1.5 EA-fetch 96-bit operand path + (An)± rules; 1 EX unit + `fpcc` hazard + background release | **4** | every arithmetic/conversion/rounding/exception decision |
| FPU frames: FSAVE/FRESTORE, unimp/unsupp/arith exception delivery, FPSP resume | included above | 0 (module side is already there) | 1.5 frame sequencers (4 sizes) + 1 vector 11/55 with opclass PC/EA + $2/$3 pushes | **2.5** | frame *contents* and revision quirks; not the stack traffic |
| Interrupts, trace, STOP (item 13) | 1.5-2 | 0 | 1.5-2 (unchanged) | **1.5-2** | nothing to reuse |
| **Subtotal, these blocks** | **12-16 (MMU+cache+bus) + 4-6 (FPU) + 1.5-2 = 17.5-24** | 2 | 15.5-18 | **17.5-20** | |
| Integer ISA + sizes + EA modes (4.1-4.2) | 11-14 | — | — | 11-14 | unchanged (the reference's decode is a 6 800-line FSM; porting "by intent" is what the plan already does) |
| **Total to parity** | **~29-38** | | | **~29-34** | |

Reading the table: reuse removes roughly 4-6 person-weeks and, more importantly, removes the *risk* in the MMU/FPU/cache internals (walker corner cases, FPSP frame layouts, snoop guards — each of which has a 100-1 600-line reference test already). It removes almost nothing from the integration column, because that column is the pipeline's own commit-point / precise-fault / drain problem, and it is the same problem for a lifted MMU as for a new one. The critical path is unchanged: 4.1 → 4.2 → bus+$7 (item 12) → MMU lift → cache lift → FPU lift → interrupts/trace. The MMU lift should be scheduled *immediately after* item 12, not before, because 8.2.2 is item 12's fault path with a second source.

### 8.6 Jev in this section
One script (`scratchpad/jev_ports.py`), 2 requests, 111 Choice questions (one per MMU/FPU port, criteria datapath/handshake/sequencer, state = the port declaration with its comment), 30 532 input / 4 854 output tokens. MMU: 32 datapath, 16 handshake, 0 sequencer — matches my reading. FPU: 27 sequencer, all of them the `fstate_*/frestore_*/pend_*` group, which is the right cut; the low-confidence ones (`bsun_req/bsun_enable/ia_we` at 0.14-0.35) are ports whose comment gives no context, and I classified those myself from the core side (`ia_we` is the FPIAR write on dispatch — datapath; `bsun_*` is the BSUN-trap decision — handshake). It was a fair use: 111 one-line judgements in 20 s that I only had to spot-check, and the aggregate (0 vs 27 sequencer-coupled ports) is the one number 8.1 and 8.3 turn on.

## 9. Decision (2026-09-21): keep the 68040's own six stages

Paul's goal: the same staged pipeline as the real 68040 -- instruction fetch, decode, EA calculate, EA fetch, execute, write-back. The pipelined branch already has exactly this, one file per stage (section 2). So the structure needs no rework; the work is filling it, and sections 3-8 still size that.

Following the real chip also settles two open choices above:

- **8.2.1, two translation consumers**: the 68040 has separate instruction and data ATCs (64 entries, 4-way each), so the target is one ATC port each for IF and EA-fetch. For now, with the single shared cache port (8.4), one ATC port behind the same arbiter is enough. When the caches are split, the second ATC port comes with them: two instances of the lookup side of `ap040_mmu.v` sharing one table walker, which is serialised.
- **8.4, caches: DEFERRED (Paul, 2026-09-21).** Keep the cache arrangement as it is and don't split I/D. Memory is not the bottleneck right now; the CPU is. One thing at a time. As a result, IF and EA-fetch share one cache port. That is a structural hazard: when both want memory in the same cycle, EA-fetch wins and IF stalls. An instruction prefetch buffer in IF (the real 040 has one) absorbs most of that. Revisit split caches only if a profile shows IF starving on port conflicts.

It also shapes item 12 (format $7). The real $7 frame has WB1-WB3 status/address/data fields because the chip's write-back stage can hold up to three pending writes when an access faults. With the same stage split, those fields come straight from the write-back stage and no extra bookkeeping is needed. Software that restarts from a $7 frame (68040.library, Enforcer, VMM) then sees the frames it expects.

Effort: deferring the caches removes 2 person-weeks from the table in 8.5 (so about 27-32 in total) and keeps the LUT count close to the current cache.

**Priority**, since CPU throughput is the goal: the integer ISA, sizes and EA modes (4.1-4.2) come first. They were already the head of the critical path, and they are what makes ordinary code run through the pipeline instead of a multi-cycle FSM.
