# fw/ctrl_rv/arch: start-up, trap entry and interrupts of the RISC-V firmware

The architecture layer of the OSD firmware on the RISC-V host CPU (VexRiscv
RV32IMC, `rtl/host/rv_hostcpu.v`): the start-up code, the trap entry, the C
trap dispatcher, the interrupt API (the one `fw/ctrl_832/interrupts.h` has)
and the linker script.

| File | What it is |
|---|---|
| `crt0.S` | `_start` (section `.text.start`, the first byte at 0x2000): gp, sp, clear `.bss`, `mtvec = trap_entry`, constructors, `mie.MEIE`, `mstatus.MIE`, `main`, then spin |
| `trap.S` | `trap_entry` (mtvec, direct mode): saves ra, t0-t6, a0-a7 (64 bytes), calls `rv_trap(mcause, mepc, mtval)`, restores, `mret` |
| `trap.c` | `rv_trap`: mcause `0x8000000B` calls `(*_InterruptVector)()`, anything else calls `rv_exception`; weak `rv_exception` (prints `EXC mcause=.. mepc=.. mtval=..`, spins) and weak `rv_putc` (cfide UART) |
| `irq.h`, `irq.c` | `SetIntHandler`, `GetInterrupts`, `EnableInterrupts`, `DisableInterrupts`, `irq_save` / `irq_restore`, `_InterruptVector`, the default handler |
| `csr.h` | `csr_read` / `csr_write` / `csr_set` / `csr_clear`, `mstatus` / `mie` / `mcause` constants |
| `firmware.ld` | the firmware image: 0x2000 up to below 0x70000, stack top 0x2000 |

## Toolchain

xPack `riscv-none-elf-gcc` 15.2.0-1 in `~/opt/xpack-riscv-none-elf-gcc-15.2.0-1`.
Setup, checksum and the Ubuntu fallback are in
[`tools/riscv/README.md`](../../../tools/riscv/README.md); in short, from the
repository root:

```sh
bash tools/riscv/fetch-xpack.sh          # installs into ~/opt
bash tools/riscv/check-toolchain.sh      # must pass
```

Every Makefile includes `tools/riscv/toolchain.mk`, which gives `RV_CC`,
`RV_OBJCOPY`, the flags `RV_CFLAGS_FW` / `RV_LDFLAGS_FW` and `RV_LIBS_FW`
(`-lgcc`, always last on the link line). Another install:
`RV_GCC_DIR=/path/to/toolchain` (and `RV_PREFIX=` if its tools are not
`riscv-none-elf-*`).

## Linking firmware with these files

Assemble `crt0.S` and `trap.S`, compile `trap.c` and `irq.c` with the
firmware flags, link everything with `firmware.ld` and without the C
library's start files. In a Makefile (`TOP` = the repository root):

```make
include $(TOP)/tools/riscv/toolchain.mk
ARCH    := $(TOP)/fw/ctrl_rv/arch
CFLAGS  := $(RV_CFLAGS_FW) -I$(ARCH)

build/crt0.o:       $(ARCH)/crt0.S ; $(RV_CC) $(RV_ARCH) -c -o $@ $<
build/trap_entry.o: $(ARCH)/trap.S ; $(RV_CC) $(RV_ARCH) -c -o $@ $<
build/trap.o:       $(ARCH)/trap.c ; $(RV_CC) $(CFLAGS) -c -o $@ $<
build/irq.o:        $(ARCH)/irq.c  ; $(RV_CC) $(CFLAGS) -c -o $@ $<

firmware.elf: build/crt0.o build/trap_entry.o build/trap.o build/irq.o $(OBJS)
	$(RV_CC) $(RV_LDFLAGS_FW) -nostartfiles -T $(ARCH)/firmware.ld -o $@ $^ $(RV_LIBS_FW)
RV32OSDA.BIN: firmware.elf
	$(RV_OBJCOPY) -O binary $< $@
```

(`trap.S` and `trap.c` need different object names.) The boot ROM
(`fw/ctrl_boot_rv`) loads `RV32OSDA.BIN` to 0x2000 and jumps there.

### Memory layout (`firmware.ld`)

| Address | Content |
|---|---|
| `0x0000-0x1FFF` | boot BRAM; the stack grows down from `__stack_top` = 0x2000 into it (as on the 832) |
| `0x2000` | `.text`: `_start` first (`ASSERT(_start == 0x2000)`), then all code |
| | `.rodata`, `.init_array` (constructors, priority order), `.data`, `.sdata` |
| | `.sbss`, `.bss` (NOLOAD, cleared by crt0) |
| `_end` | `ASSERT(_end < 0x70000)`: `AUDIO_BUFFER` starts at 0x70000 |

The whole binary is loaded into RAM, so `.data` is used in place (no copy).
`__global_pointer$` = start of `.sdata` + 0x800; crt0 loads gp before any C
code. Symbols crt0 uses: `__stack_top`, `__global_pointer$` (weak),
`__bss_start`, `__bss_end`, `__init_array_start`, `__init_array_end`. crt0
uses nothing else, so it also runs from another layout (the L2 bench links it
into the boot BRAM with `sim/host_bridge/sw/rom.ld`, which has no
`__global_pointer$`: gp = 0 and the linker makes no gp-relative code).

## Traps

`trap_entry` saves the caller-saved registers on the interrupted stack and
calls `rv_trap`. The callee-saved registers are saved by the C code itself
where it uses them; nothing changes gp or tp. The hardware clears
`mstatus.MIE` on entry and `mret` restores it, so traps do not nest.

| mcause | Meaning | Goes to |
|---|---|---|
| `0x8000000B` | machine external interrupt: cfide's INTERRUPT line (via one register in `rv_hostcpu.v`) | `(*_InterruptVector)()` |
| `2` | illegal instruction; mtval = the instruction word (VexRiscv) | `rv_exception` |
| `4` / `6` | misaligned load / store; mtval = the address | `rv_exception` |
| other | (no other trap is enabled on this core) | `rv_exception` |

The default `rv_exception` prints `EXC mcause=XXXXXXXX mepc=XXXXXXXX
mtval=XXXXXXXX` on the cfide UART and spins. Firmware may define its own
(`rv_exception` and `rv_putc` are weak). One that returns resumes at mepc, so
it must step it first: `csr_write(mepc, mepc + 4)` (or + 2 if the low two
bits of the instruction are not `11`). `sim/rv_l1/tests/exc.c` does this.

## Interrupt API (`irq.h`)

The same calls as `fw/ctrl_832/interrupts.h`:

```c
#include "irq.h"

static void vbl_handler(void)
{
    GetInterrupts();            /* any access to 0xFFFFFFA0 clears the line */
    /* ... */
}

SetIntHandler(vbl_handler);     /* disables the INTERRUPT register, then installs */
EnableInterrupts();             /* INTERRUPT = 1 */
...
uint32_t s = irq_save();        /* CPU critical section: mstatus.MIE off */
/* ... */
irq_restore(s);                 /* MIE back on only if it was on at irq_save */
```

* The INTERRUPT register (cfide, `0xFFFFFFA0`): write bit 0 = enable;
  any access, read or write, clears the pending line; an event (VBL, I2C,
  Amiga request) sets the line only if the register is enabled at that
  moment. An event while disabled is lost.
* A handler must access the register (`GetInterrupts()`), or the trap
  re-enters at once.
* `SetIntHandler(h)` writes 0 (disable, clear) before it changes the
  pointer, so the old handler never runs after the call returns; call
  `EnableInterrupts()` afterwards. `SetIntHandler(NULL)` installs the default
  handler, which only calls `GetInterrupts()`.
* crt0 sets `mie.MEIE` and `mstatus.MIE` before `main`; `irq.c`'s
  constructor (priority 101) installs the default handler, which leaves the
  register disabled. Nothing reaches a handler until `EnableInterrupts()`.
* `irq_save()` / `irq_restore()` nest; they mask only the CPU, the INTERRUPT
  register keeps its line pending until the next access.

## Tests

From the repository root. L1 (iverilog, `rv_hostcpu` + memory model, seconds):

```sh
make -C sim/rv_l1 tests
bash sim/rv_l1/run.sh irq       # irq, irq_sig, irq_c, exc at WS 0/3/8 + the trap.S mutant
```

ends with `=== IRQ PASS (13 runs)`. These programs are also in
`bash sim/rv_l1/run.sh all`. They are linked as firmware: these files and
`firmware.ld`, behind `sim/rv_l1/sw/boot_fw.S` (a boot ROM stand-in that
clears x1-x31 and jumps to 0x2000).

| Program | Checks |
|---|---|
| `irq_sig` (`tests/irq_sig.S`, handler `tests/irq_sig_h.c`) | x1, x3-x30 hold distinct patterns, x31 is the only scratch register; 50 events at pseudo-random distances (IRQ_AT 20..275 cycles) while the loop checks every register each iteration; the C handler counts, clears, re-arms and overwrites every caller-saved register. Pass: count 50 (and still 50 after 64 more iterations), no register changed |
| `irq_c` (`tests/irq_c.c`) | constructors ran; crt0 left MIE/MEIE set; the default handler clears the line; `SetIntHandler`; an event while `DisableInterrupts()` is lost; `irq_save`/`irq_restore` nesting; switching handlers while events keep coming |
| `exc` (`tests/exc.c`) | `.word 0xffffffff`, a misaligned `lw`, a misaligned `sh`: mcause 2/4/6, mepc = the instruction, mtval = 0xffffffff / the address; the `rv_exception` override steps mepc and returns; load target and stored memory unchanged |

L2 (Vivado xsim, the real bridge and cfide, about a minute):

```sh
RUNTAG=t11 bash sim/host_bridge/run.sh t_irq     # SLAT=8 SJIT=0 by default
```

`t_irq` (`sim/host_bridge/sw/t_irq.c`) installs a handler, enables the
register and has the bench pulse cfide's `vbl_int` 20 times (one `clk_28`
cycle each, 2000 `clk_114` apart); the handler counts with `GetInterrupts()`.
Pass: 20 handler calls, no extra one. `t_irq` is also in
`bash sim/host_bridge/run.sh all`.

### Teeth: trap.S without the restore of t3

`make -C sim/rv_l1 tests` also builds `irq_sig_mut`: `irq_sig` linked with a
copy of `trap.S` whose `lw t3, 16(sp)` line is deleted (`build/arch/trap_mut.S`).
`run.sh irq` runs it once (WS=3) and expects `=== FAIL 11c` (exit code
0x100 + 28: x28 = t3 changed). Recorded 2026-10-16:

```
PASS irq_sig_mut ws=3 romws=1 x=0 d=0 cycles=10057 (expected FAIL 11c)
```

The mutant fails at the first event; the real `trap.S` passes all 50 at WS
0, 3 and 8.
