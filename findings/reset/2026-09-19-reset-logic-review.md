# Why a failed boot stays failed — a review of the reset logic

Written for Paul, 2026-09-19, after: "a failed boot attempt doesn't recover and
stays failed when an error occurs, during kickstart load from the SD-card
especially things just don't reset as they should."

Read-only review. No RTL or firmware was changed.

## The short answer

Two independent faults meet in the middle.

**The firmware never undoes what it did on the way in.** `ColdBoot()` opens by
putting the Amiga CPU into reset *and* halt and disabling the 832's interrupts,
and only releases them on the success path.

**Nothing else can undo it either.** The register holding the Amiga CPU in
reset is writable only by the 832 firmware, and the 832 itself cannot be
restarted by anything reachable from the running machine.

So a boot that fails early leaves the 68k held in reset, with the only agent
that could release it having already given up. Nothing in the design notices.

## Fault 1 — `ColdBoot()`'s early exits leak state

`fw/ctrl_832/main.c:140`:

```c
int ColdBoot() {
    int result = 0;
    OsdDoReset(SPI_RST_USR | SPI_RST_CPU | SPI_CPU_HLT, SPI_RST_CPU | SPI_CPU_HLT);
    DisableInterrupts();
    ClearError(ERROR_ALL);
    if (MMC_Init()) {
        if (FindDrive()) {
            ...
            result = ApplyConfiguration(1, 1);          // loads the kickstart
            OsdDoReset(SPI_RST_USR | SPI_RST_CPU, 0);   // releases RST + HLT
            SetIntHandler(inthandler);
            EnableInterrupts();
        }
    }
    return result;
}
```

Three distinct failures:

1. **No card, or no filesystem.** `MMC_Init()` or `FindDrive()` returning false
   falls straight out of the bottom. The second `OsdDoReset` never runs, so
   `SPI_RST_CPU` and `SPI_CPU_HLT` stay asserted, and `EnableInterrupts()` never
   runs to match the `DisableInterrupts()` at entry. The Amiga is held halted
   and the 832 is left with interrupts off, permanently.
2. **A failed kickstart load releases the CPU anyway.** `ApplyConfiguration`
   returns 0 when `UploadKickstart` fails (`fw/ctrl_832/config.c:449`), but
   control continues to the release regardless. The 68040 is let loose on RAM
   with no valid ROM in it. This is the "doesn't reset as it should" case.
3. **The caller ignores the result.** `main.c:259` is
   `if(!ColdBoot()) BootPrintEx("ROM loading failed");` and then falls into the
   main loop. No retry, no safe state — and in case 1 the OSD cannot help,
   because there is no card to load anything from.

The asymmetric `DisableInterrupts()` / `EnableInterrupts()` is the tell that the
early exits were never considered.

## Fault 2 — the reset that matters is a one-way latch

`rtl/minimig/userio_osd.v:46-48, 433`:

```verilog
output reg usrrst = 1'b0,
output reg cpurst = 1'b1,     // Amiga CPU held in reset at FPGA config
output reg cpuhlt = 1'b1,
...
if (spi_reset_ctrl_sel) begin if (dat_cnt == 0) {cpuhlt, cpurst, usrrst} <= wrdat[2:0]; end
```

That `always` block has **no reset term**. `cpurst` takes its value from FPGA
configuration and is thereafter changed only by an SPI write from the 832
firmware. It is not cleared by `reset`, `sys_reset`, `rst_ext`, or the board
`reset_n`. And `_cpu_reset = ~(cpurst | sys_reset)` (`minimig.v:1249`), so while
`cpurst` stands the 68k cannot run, no matter what else is reset.

The 832 that owns that register is itself on a latch. Its `nReset` is
`reset_out`, which is `sdram_ctrl`'s `init_done` (`rtl/sdram/sdram_ctrl.v:268`)
— set once after SDRAM init and never cleared again except by `RESET_N` going
low or the PLL losing lock (`minimig_virtual_top.v:375`). Consequences:

- **An Amiga reset does not restart the 832.** `usrrst`, `kbdrst` (Ctrl-A-A),
  `sys_reset` and the 68k `RESET` instruction have no path to `reset_out`;
  `minimig`'s own `rst_out` is left unconnected (`minimig_virtual_top.v:1162`).
- **The board reset button does recover, but indirectly**: it pulls `reset_n`,
  which clears `init_done`, which restarts the 832, which re-runs `ColdBoot()`
  and rewrites `cpurst`. That is the only in-band escape, and it works by
  restarting the whole host rather than by resetting the Amiga.
- **There is no watchdog.** `grep -rni watchdog rtl/ fw/` finds nothing. The 832
  bridge FSM (`rtl/host/832_bridge.vhd:190-207`) has no ack timeout either, so a
  lost `hw_ack`/`ram_ack` wedges the host CPU with no recovery at all.

## Why the kickstart case specifically "doesn't reset as it should"

The OSD's Reset (`OsdReset()`, `fw/ctrl_832/osd.c:818`) sends `OSD_CMD_RST` with
`0x1` — `usrrst` only. That resets the Amiga, but it does **not** reload the
kickstart: the ROM is uploaded by `ApplyConfiguration`, which runs only from
`ColdBoot()` or the explicit OSD "load config" / "load kickstart" actions
(`menu.c:941, 2198`). So after a failed ROM load, resetting the Amiga restarts a
machine whose ROM is still missing or half-written, which looks exactly like
"reset does nothing".

## Recommendations, cheapest first

1. **Make `ColdBoot()` symmetric** (firmware, small, no RTL). One exit that
   always releases `SPI_CPU_HLT`/`SPI_RST_CPU` and always re-enables interrupts,
   whatever happened. A machine at a black screen with a working OSD is far
   better than one wedged with the CPU halted.
2. **Do not release the CPU onto a ROM that failed to load** (firmware). Case 2
   is the opposite error to case 1: here the right move is to keep the CPU
   halted, show the error, and stay in the OSD so the user can choose another
   kickstart — already possible from the menu.
3. **Retry instead of giving up** (firmware). `main.c:259` should loop: report,
   wait, re-attempt `MMC_Init()`/`FindDrive()`. A card inserted after power-up is
   currently never noticed.
4. **Give `cpurst`/`cpuhlt` a reset term** (RTL, one line each). Powering up held
   in reset is deliberate and should stay; being unclearable by any reset in the
   system is not. At minimum the board `reset_n` should return them to their
   configuration defaults, so the reset button is a real reset rather than a 832
   restart that happens to work.
5. **A watchdog on the 832** (RTL + firmware). The host CPU is a single point of
   failure for the whole machine and nothing notices when it stops. A counter the
   firmware must kick, forcing `reset_out` low on expiry, would turn every
   "wedged, power-cycle it" into a self-recovery.

## Other reset weaknesses found on the way

Not causes of this bug, but they belong in the same review:

- **`sys_reset` release is gated on video timing.** `minimig_syscontrol.v:44-45`
  advances its 3-bit counter only on `sof` (Agnus start-of-frame), so reset is
  held for 4 frames rather than a fixed number of clocks. The beam counters are
  free-running so this works today, but a reset whose release depends on the
  video system still running is fragile.
- **The board reset generator is clocked by a clock it cannot restart.**
  `gen_reset` runs on `clk_28` from the `amiga_clk` MMCM whose `RST` is tied
  `1'b0` (`amiga_clk_xilinx.v:64`). An MMCM that loses lock takes the reset
  generator with it, and only a power cycle recovers.
- **`minimig_m68k_bridge` has an `_cpu_reset` input whose only use is commented
  out** (`minimig_m68k_bridge.v:138-139`). Its halt state and latched strobes are
  never reset — a candidate for "things don't reset as they should" in its own
  right, and worth a closer look.
- **Several chipset blocks have no reset at all**: `amber`, `gary`,
  `minimig_sram_bridge`, `minimig_bankmapper` (`minimig.v:790-1008`).
- **The ADV7511 init is one-shot** — `i2c_sender.resend` is tied `1'b0`
  (`minimig_openaars_top.v:443`). Worked around in firmware with
  `adv7511_poll()`; the RTL path still cannot re-run its own init.
- **The DDR3 island is deliberately board-reset-only** (`ddr3_top.v:30-34`) and
  its CDC destination reset is tied off (`ddr3_fastram.v:416`). An Amiga reset
  mid-request leaves the handshake wherever it was; `cache_rst` invalidates the
  cache but not the backend FSM.
