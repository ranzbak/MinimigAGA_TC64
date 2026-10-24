# fw/ctrl/arch: start-up, trap entry and interrupts of the RISC-V firmware

The architecture layer of the OSD firmware on the RISC-V host CPU (VexRiscv
RV32IMC, `rtl/host/rv_hostcpu.v`): the start-up code, the trap entry, the C
trap dispatcher, the interrupt API (`irq.h`, the calls the firmware's
sources were written against) and the linker script.

| File | What it is |
|---|---|
| `crt0.S` | `_start` (section `.text.start`, the first byte at 0x2000): gp, sp, clear `.bss`, `mtvec = trap_entry`, constructors, `mie.MEIE`, `mstatus.MIE`, `main`, then spin |
| `trap.S` | `trap_entry` (mtvec, direct mode): saves ra, t0-t6, a0-a7 (64 bytes), calls `rv_trap(mcause, mepc, mtval)`, restores, `mret` |
| `trap.c` | `rv_trap`: mcause `0x8000000B` calls `(*_InterruptVector)()`, anything else calls `rv_exception`; weak `rv_exception` (prints `EXC mcause=.. mepc=.. mtval=..`, spins) and weak `rv_putc` (cfide UART) |
| `irq.h`, `irq.c` | `SetIntHandler`, `GetInterrupts`, `EnableInterrupts`, `DisableInterrupts`, `irq_save` / `irq_restore`, `_InterruptVector`, the default handler; the interrupt controller API `IrqInstall`, `IrqSetHandler`, `IrqSetMode`, `IrqEnable`, `IrqDisable`, `IrqRaw` |
| `csr.h` | `csr_read` / `csr_write` / `csr_set` / `csr_clear`, `mstatus` / `mie` / `mcause` constants |
| `firmware.ld` | the firmware image: 0x2000 up to below 0x70000, stack top 0x2000 |

Editor: the worktree's `.clangd` gives clangd the include paths and RISC-V flags for this tree, `fw/ctrl_boot`, `fw/dhrystone_rv` and the `sim/` test sources (`clangd --check=<file>`).

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

Include `arch.mk` after `toolchain.mk`. It builds `crt0.S`, `trap.S`
(as `trap_entry.o`), `trap.c` and `irq.c` with the firmware flags, with
`-MMD -MP` header dependencies (touching `irq.h` or `csr.h` rebuilds them),
and gives the link flags for `firmware.ld`. It needs `TOP` (the repository
root) and `ARCH_B` (a build directory; the objects go to `$(ARCH_B)/arch/`).
`arch.mk` defines rules, so set `.DEFAULT_GOAL` after the include. In a
Makefile two levels below the repository root, e.g. `fw/<project>/Makefile`
(`OBJS` = your own objects):

```make
TOP     := $(abspath $(CURDIR)/../..)
include $(TOP)/tools/riscv/toolchain.mk
ARCH_B  := build
include $(TOP)/fw/ctrl/arch/arch.mk
.DEFAULT_GOAL := RV32OSDA.BIN

CFLAGS := $(RV_CFLAGS_FW) -I$(ARCH)

firmware.elf: $(ARCH_OBJS) $(OBJS) $(ARCH_LD)
	$(RV_CC) $(RV_LDFLAGS_FW) $(ARCH_LDFLAGS) -o $@ $(ARCH_OBJS) $(OBJS) $(RV_LIBS_FW)
RV32OSDA.BIN: firmware.elf
	$(RV_OBJCOPY) -O binary $< $@
```

`arch.mk` defines `ARCH` (this directory), `ARCH_OBJS`, `ARCH_LD`,
`ARCH_CFLAGS`, `ARCH_ASFLAGS` and `ARCH_LDFLAGS` (`-nostartfiles -T
firmware.ld -Wl,--no-warn-rwx-segments`: the script puts code and data in one
RWX load segment, the whole image is loaded into RAM; without the option
binutils 2.45 warns on every link). `$(RV_LIBS_FW)` stays last on the link
line. A bench that needs a hex image uses `bash tools/riscv/bin2hex.sh in.bin
out.hex` (one big-endian word per line, file byte i in lane i, last word
zero-padded). The boot ROM (`fw/ctrl_boot`) loads `RV32OSDA.BIN` to 0x2000
and jumps there.

### Memory layout (`firmware.ld`)

| Address | Content |
|---|---|
| `0x0000-0x1FFF` | boot BRAM; the stack grows down from `__stack_top` = 0x2000 into it |
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

The calls the firmware uses (`SetIntHandler`, `EnableInterrupts`,
`DisableInterrupts`, ...):

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

## Interrupt controller API (`irq.h`)

cfide's interrupt controller (`0xFFFFFF30..3C`, 16-bit registers, 16 sources)
sits beside the legacy INTERRUPT register and drives the same CPU line. With
`MASK = 0` (reset) it does nothing. The legacy API above stays as it is and
is the path as long as `IrqInstall()` was not called.

| Register | Address | Access |
|---|---|---|
| `HW_IRQ_PENDING` | `0xFFFFFF30` | read: PENDING and MASK; clears the EDGE bits it returns (once per access) |
| `HW_IRQ_MASK` | `0xFFFFFF34` | read/write, reset 0 |
| `HW_IRQ_RAW` | `0xFFFFFF38` | read: synchronised source levels, no side effect |
| `HW_IRQ_MODE` | `0xFFFFFF3C` | read/write, reset 0: bit set = LEVEL, clear = EDGE |

| Bit | Name | Source | Configure as |
|---|---|---|---|
| 0 | `IRQ_VBLANK` | vertical blank | EDGE |
| 1 | `IRQ_I2C` | I2C master transfer event | LEVEL; the handler must read `0xFFFFFFA0` (`GetInterrupts()`), the only thing that clears it (a write does not) |
| 2 | `IRQ_AKIKO` | Akiko request | EDGE |
| 3 | `IRQ_ADV7511` | ADV7511 INT pin | LEVEL |
| 4 | `IRQ_SDCARD` | SD card peripheral (`rtl/host/sdcard_spi.v`, `irq_src(4)`) | LEVEL; `sdc_init()` (`../sdc.c`) installs it |
| 5..15 | | spare (`irq_src`: IDE, floppy, later) | as the device needs |

```c
#include "irq.h"

static void vbl(void)   { /* once per frame */ }
static void adv(void)
{
    /* read the ADV7511 interrupt status over I2C and clear it there: the
       pin (and with it this interrupt) stays up until then */
}

void irq_setup(void)
{
    IrqSetHandler(IRQ_VBLANK, vbl);      /* EDGE is the reset mode of every bit */
    IrqSetHandler(IRQ_ADV7511, adv);
    IrqSetMode(IRQ_ADV7511, 1);          /* LEVEL: set the mode before the enable */
    IrqEnable(IRQ_VBLANK);               /* installs the dispatcher (IrqInstall) */
    IrqEnable(IRQ_ADV7511);
}

void irq_later(void)
{
    IrqDisable(IRQ_ADV7511);             /* a masked EDGE event stays pending */
    uint32_t levels = IrqRaw();          /* source levels, no side effect */
    (void)levels;
}
```

* `IrqSetHandler(bit, h)`: handler for one bit (table of 16; NULL: the
  bit is masked off at its first event, so a LEVEL source cannot lock the
  dispatcher). `IrqSetMode(bit, level)`: 1 = LEVEL,
  0 = EDGE. `IrqEnable(bit)` / `IrqDisable(bit)`: set / clear one MASK bit.
  Each of the three read-modify-writes runs inside `irq_save` /
  `irq_restore`. Bits above 15 are ignored.
* `IrqInstall()` installs the dispatcher with `SetIntHandler`, so the legacy
  INTERRUPT register is then disabled (an `IRQ_I2C` handler only accesses it
  to clear the I2C source). It is idempotent and `IrqEnable()` calls it, so
  no source can fire before the dispatcher is there. After `IrqInstall()` do
  not use `EnableInterrupts()`: the dispatcher answers a legacy flag (a
  trap where PENDING reads 0) by disabling the legacy register again.
  `SetIntHandler(h)` with any other handler (or NULL) also clears MASK, so
  a legacy handler, which never reads PENDING, cannot be driven by the
  controller. The dispatcher loops: read `HW_IRQ_PENDING`
  (already masked by the hardware), call the handler of every set bit in
  bit order (bit 0 first), read again, stop when a read returns 0. A later
  `SetIntHandler()` replaces the dispatcher (the legacy path again).
* Pulse sources (vblank, Akiko) stay EDGE: one event per rising edge, the
  PENDING read clears it. Level sources (`IRQ_ADV7511`, `IRQ_I2C`, IDE
  requests) are configured LEVEL: the PENDING bit follows the source, a read
  does not clear it and the CPU line stays asserted until the device is
  serviced, so no `IrqRaw()` re-check is needed. The handler of a LEVEL
  source must make the source go away (clear it in the device, or
  `IrqDisable` the bit).
* A LEVEL handler can be called once more right after its line dropped (the
  controller sees the line through a synchroniser): it must tolerate a call
  with nothing left to do.
* An EDGE event for a masked bit stays pending and is delivered once on
  `IrqEnable`; this includes an event latched since reset (vblank pulses
  with `MASK = 0` are latched), so the first `IrqEnable(IRQ_VBLANK)` can
  call the handler at once. Reading `HW_IRQ_PENDING` yourself (a debugger) consumes the
  pending EDGE bits.
* Switching a bit's mode: EDGE to LEVEL drops an unread EDGE event (the bit
  then follows the line); LEVEL to EDGE needs the line to fall and rise
  again before the next event (a high line starts clear). Set the mode
  before enabling the bit.
* The dispatcher loops over PENDING reads; no test tells the loop from a
  single pass (the interrupt line would re-enter the trap at once), so it is
  a latency optimisation only.
* Never read the UART at `0xFFFFFFF0` (cfide does not ack it; bus deadlock).
* The firmware runs on the controller since the SD card engine (Task 9):
  `main.c` `IrqSetupSources()` puts vblank on `c64keys_inthandler` and the
  Akiko request on `akiko_inthandler` (both EDGE), `sdc_init()` the SD
  peripheral on `IRQ_SDCARD` (LEVEL). The legacy register stays off.
* This core has no `wfi` (`CsrPluginConfig.small` decodes it as an illegal
  instruction: mcause 2, mtval `0x10500073`; checked with the L1 `exc`
  program). A wait for an interrupt polls a RAM flag (`sdc_wait()`).

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
| `irq_c` (`tests/irq_c.c`) | constructors ran; crt0 left MIE/MEIE set; the default handler clears the line; `SetIntHandler`; an event while `DisableInterrupts()` is lost; `irq_save`/`irq_restore` nesting; switching handlers while events keep coming; an event swept over every cycle of a `SetIntHandler(h1 -> h2)` call never reaches h2 before `EnableInterrupts()` (a copy of `irq.c` that changes the pointer before it disables the register fails it: `sim/rv_l1/README.md`, "irq_c check 10") |
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
