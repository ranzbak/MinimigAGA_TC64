# OSD host CPU: executable plan, stage 2a -- Phase 8.0 interrupt controller

**Goal.** Add a small, uniform interrupt controller to `rtl/host/cfide.vhd`
(Intel 8259 style, simplified): every source is edge-detected into a PENDING
bit, a MASK selects which may interrupt, one OR-ed line goes to the host CPU,
and the CPU reads PENDING to see which sources fired -- the read clears exactly
the bits it returned. A RAW register shows the current source levels without
side effects. The 832's existing interrupt register keeps working unchanged.
Decided by Paul on 2026-10-17 ("Implement 8.0"); parent plan
`doc/osd-riscv-plan.md` section 6.3 / Phase 8.0. Stage 1 is
`doc/osd-riscv-exec-1.md` (its Global Constraints still apply, with its UART
row corrected: a UART READ is never acked by cfide).

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Stage-1 constraints | everything in `doc/osd-riscv-exec-1.md` "Global Constraints" (worktree/branch, commit rules, tools, lane rule, bus contract, toolchain, vendor-neutral rule, the 832 stays, run directories) |
| Window | `addr(23)='1'` and `addr(7 downto 4) = X"3"` -> CPU byte addresses `0xFFFFFF30..3F` (window free today). 16-bit registers; register selected by `addr(3 downto 2)` |
| `IRQ_PENDING` `0xFFFFFF30` | read: returns PENDING and MASK and clears exactly the bits returned, once per access (masked-out events stay pending until unmasked). A source edge in the same cycle as the clear stays pending ("set wins"). Write: no effect |
| `IRQ_MASK` `0xFFFFFF34` | read/write, reset 0. CPU line = OR(PENDING and MASK) |
| `IRQ_RAW` `0xFFFFFF38` | read: current synchronised source levels, no side effect. Write: no effect |
| `0xFFFFFF3C` | reserved: reads 0, writes ignored |
| Sources (bit) | 0 vblank (`vbl_int`), 1 ADV7511 I2C INT (`i2c_int`), 2 Akiko request (`amiga_req`), 3..15 spare: new cfide input port `irq_src : in std_logic_vector(15 downto 3) := (others => '0')` for P1 (IDE/floppy) and later |
| Edge detect | per bit: 2-FF synchroniser into the controller's clock (cfide's interrupt logic runs on clk_28), then a rising edge sets PENDING. Same logic for every bit (uniform) |
| CPU interrupt | cfide `interrupt` output = legacy flag OR (or_reduce(PENDING and MASK)). Legacy register at `0xFFFFFFA0` unchanged in every respect (bit 0 enable on write, any access clears the legacy flag, same sources). With MASK = 0 (reset) behaviour is bit-identical to today, so 832 firmware is unaffected |
| Firmware rule (document) | level sources (ADV7511 INT, IDE requests) may stay high: after handling, read IRQ_RAW and handle again while the level is still high; on enabling a mask bit, check IRQ_RAW once. A debugger reading IRQ_PENDING consumes pending bits |
| Vendor-neutral | plain VHDL-93, no primitives; Quartus-safe |

---

### Task 1: Interrupt controller RTL in cfide + L2 test

- **Model:** Opus.
- **Files:** modify `rtl/host/cfide.vhd` (or create `rtl/host/irqctl.vhd` instantiated by cfide -- implementer's choice; if a new file, add it everywhere cfide.vhd is listed: `grep -rl cfide.vhd` over tools/, rtl/, sim/, fpga/ -- Vivado scripts, `rtl/host/host.qip`, bench file lists); `sim/host_bridge/sw/t_irqctl.c` (+ Makefile/run.sh wiring, `all` matrix); `sim/host_bridge/tb_host_bridge.v` (drive `vbl_int`, `amiga_req` and the `irq_src` spare inputs from the bench; pulse and level modes); `sim/host_bridge/README.md`.
- **Test first (`t_irqctl`, L2, real cfide):**
  1. after reset: MASK = 0, PENDING = 0, RAW = 0; legacy path: enable `0xFFFFFFA0` bit 0, one vblank pulse -> one CPU interrupt (unchanged behaviour).
  2. legacy disabled, MASK = bit 0: N vblank pulses spaced apart -> N interrupts; handler reads PENDING = 0x0001 each time; a second read returns 0.
  3. two sources fire close together (vblank + spare bit 5) -> one read returns both bits; both cleared.
  4. "set wins": the bench raises spare bit 6 exactly in the cycle the PENDING read clears (bench aligns on the bridge's hw access) -> bit 6 is still pending afterwards (the next read returns it). Sweep the alignment over several offsets.
  5. masked source: bit 7 fires with MASK bit 7 = 0 -> no CPU interrupt and a PENDING read returns 0 for bit 7 (and does not clear it); setting MASK bit 7 then raises the interrupt and the next read returns bit 7.
  6. level source held high: spare bit 8 held high -> exactly one PENDING event (one edge), RAW bit 8 = 1 while high; drop and raise again -> a second event.
  7. an IRQ_RAW read has no side effect on PENDING; writes to PENDING/RAW/0x3C have no effect.
  8. mutant: a run-copy that clears all of PENDING on read (drops "set wins") must FAIL test 4.
- **Regression:** `sim/spi_cdc/host832/run.sh` (E832 path per stage-1 constraints) 7/7, `sim/spi_cdc/run.sh`, `sim/host_bridge/run.sh all` (all existing tests), `boot`, `boot_nofile`, `mutant`, plus `sim/gayle/run.sh` and `sim/osd_keyq/run.sh` if they compile cfide. New RUNTAGs.
- **Pass gate:** t_irqctl PASS at SLAT 8 with EXTRA_WS 0 and 3; mutant FAIL; all regressions PASS; no new warnings; controller LUT/FF reported (small OOC of cfide alone if cheap, else an estimate from the synthesis log of a cfide-only run).

### Task 2: Firmware API in `fw/ctrl_rv/arch`

- **Model:** Sonnet.
- **Depends on:** Task 1.
- **Files:** `fw/ctrl_rv/arch/irq.h`, `irq.c`, `README.md`; L2 test `sim/host_bridge/sw/t_irqapi.c` (+ Makefile/run.sh wiring).
- **API (add; keep `SetIntHandler/GetInterrupts/EnableInterrupts/DisableInterrupts` unchanged):** register defines `HW_IRQ_PENDING/MASK/RAW`, bit names `IRQ_VBLANK 0`, `IRQ_I2C 1`, `IRQ_AKIKO 2`; `void IrqSetHandler(unsigned bit, void (*h)(void))` (table of 16), `void IrqEnable(unsigned bit)` / `void IrqDisable(unsigned bit)` (read-modify-write MASK inside `irq_save/irq_restore`), `uint32_t IrqRaw(void)`; `void IrqInstall(void)` installs a dispatcher through `SetIntHandler` that loops: `p = HW_IRQ_PENDING` (already masked by hardware; the read clears what it returns), call each set bit's handler in bit order (bit 0 first), repeat while a new read is non-zero; document the level-source rule (handler re-checks `IrqRaw()`).
- **Test (L2):** handlers for vblank and two spare bits, counts match bench pulses; a level-source handler that re-checks RAW handles a source that stays high across two requests; the legacy `SetIntHandler` path still works when the dispatcher is not installed.
- **Pass gate:** t_irqapi PASS; L1 `run.sh all` and `irq` still pass; L2 `all` passes; README copy-pasteable (Paul's rule).

### Task 3: Documentation

- **Model:** Sonnet.
- **Files:** `doc/osd-riscv-plan.md` section 6.3 (replace the 8.0 sketch with this design and the measured cost), section 8 Phase 8 (8.0 done on branch), decision 12.9 (Paul 2026-10-17: implement 8.0 now; uniform edge-detected sources; read clears the returned bits); `doc/osd-riscv-exec-1.md` Global Constraints memory-map row (add the 0xFFFFFF3x window).
- **Pass gate:** text matches the RTL and API exactly (register addresses, bit numbers, semantics).
