# Board session: GDB on the RISC-V OSD CPU (Phase 5.4, Task 8)

Written 2026-10-20. Paul runs this at the board; **nothing in it was run on hardware**, and the bridge has never talked to a real Platform
Cable (the XVC rehearsal was not run, `tools/rvdebug/README.md` "XVC dress rehearsal (not run)"). So the first real check is the bridge
self-test in step 3, and the abort rules below are meant seriously. Time needed: about 30 minutes without the `load` step, much more with it
(see step 5.5).

The picture:

```text
GDB (xPack 16.3) --3333--> OpenOCD 0.12 --remote_bitbang 33582--> rv_jtag_bridge.tcl in Vivado --hw_server--> Platform Cable --> XC7A100T
                                                                                                     BSCANE2 USER4 -> VexOsd_DMT debug module
```

All commands are for zsh (or bash), one terminal per long-running program. `P5`, `OUT` and `GDB` are set in each terminal that needs them:

```
P5=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build
OUT=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5dbg_42f7cbb
GDB=$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gdb
```

## 0. What this is

| | |
|---|---|
| Image | the **lab bitstream** `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5dbg_42f7cbb/minimig_openaars_top.bit` |
| md5 | `990199ce7b0ca771b5c83c1c59192814` (`$OUT/bit.md5`) |
| Build | C2 = `42f7cbb`, `rv_debug = 1` (VexRiscv debug module `VexOsd_DMT` behind `BSCANE2` USER4); the record is `findings/osd-riscv/debug.md` |
| Card | **the same card set as B**: the card copy of `ab-board-test.md` section 1 (`RV32OSDA.BIN`, `MINMGAR*.CFG`). The card is not changed by this session; do not put anything on it |
| Firmware for GDB | `$OUT/fw/RV32OSDA.elf` (+ `RV32OSDA.BIN`, `SHA256SUMS`): the ELF of the card's `RV32OSDA.BIN` (sha256 `17bf2563788e3b62d2cedc170c448654617537779f21edab5b2feeb9240ed66f`, osd-riscv `6ea1b76`) |
| Normal image | **B stays the normal image** (`build/stage_p5b_87577e2`, `rv_debug = 0`). The lab image is for this session only |
| Recovery | power-cycle the board and program B again with the command of `ab-board-test.md` section 3 ("Load B"). Nothing here touches the flash or the card, so a power cycle alone returns the board to what the flash holds |

What the session can and cannot do: GDB stops and inspects the **OSD CPU** (the VexRiscv that runs the OSD firmware). It does not stop the
Amiga, but the OSD CPU also serves the Amiga's floppy and HDF disk access: **while it is halted the Amiga's disk service stalls**. Workbench
goes on only while it does no disk access; an Amiga stuck on a disk access during a halt is expected and resumes on `continue`. So do not leave the
CPU halted long. **Two steps reboot the Amiga on purpose: `load` + `continue` (5.4) and `monitor reset halt` + `continue` (5.5)**, because the OSD
firmware's start-up (`_start`, `main`, `ColdBoot()`) resets the Amiga and reloads Kickstart. An Amiga reboot back to Workbench after those two steps
is the expected outcome, not a failure.

## 1. Before you start

1. Close **every** Vivado hardware manager and every other program that uses the cable. `hw_server` owns the Platform Cable: a second owner makes the
   bridge fail at the target step. Check:
   ```
   pgrep -a hw_server; pgrep -a vivado
   ```
   Expected: no output. Anything listed that you do not need: close it (Vivado: File, Close Hardware Manager, or quit Vivado).
2. Card copy in the board (the one of `ab-board-test.md` section 1, **not** the live card).
3. Serial log of the OSD CPU, terminal 1, started **before** the bitstream is loaded so the boot lines are in the log. The options are those of
   `ab-board-test.md` section 2:
   ```
   picocom -b 115200 -d 8 -y n -p 1 -f n --imap crcrlf,lfcrlf --logfile ~/rvdbg-tty.log /dev/ttyUSB0
   ```
   Leave with Ctrl-A Ctrl-X. The log keeps raw CRs: `tr '\r' '\n' < ~/rvdbg-tty.log | less`.
4. Check the tools exist (the output of each line is given):
   ```
   ls -l /usr/bin/openocd /usr/bin/picocom "$GDB"
   openocd --version 2>&1 | head -1
   "$GDB" --version | head -1
   md5sum "$OUT/minimig_openaars_top.bit"
   (cd "$OUT/fw" && sha256sum -c SHA256SUMS)
   ```
   Expected: a line starting `Open On-Chip Debugger 0.12`, `GNU gdb (xPack GNU RISC-V Embedded GCC x86_64) 16.3`,
   `990199ce7b0ca771b5c83c1c59192814  .../minimig_openaars_top.bit`, `RV32OSDA.elf: OK`, `RV32OSDA.BIN: OK`.
   Anything else: **stop** and report it.

## 2. Program the lab bitstream, boot to Workbench

Power-cycle the board first (a JTAG load does not reset the peripherals), terminal 1 (picocom) already running. Then, in terminal 2, exactly the
command that loads B in `ab-board-test.md` section 3, with the lab path:

```
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -nolog -source /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/vivado/program.tcl -tclargs /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5dbg_42f7cbb/minimig_openaars_top.bit
```

Expected last line: `=== DONE: <bit path> loaded, DONE pin = 1 ===`. Anything other than `DONE pin = 1`: power-cycle and try once more; a second failure:
**abort** and paste what Vivado printed.

Then the board boots as B does: ttyUSB0 shows the RV boot lines (`ab-board-test.md` row 1), Kickstart, Workbench.

**Sanity check, the OSD must work as on B:** open the OSD (button or F12), move through a page, close it. If the board does not boot or the OSD is
dead, the lab image is not usable: **abort**, go to step 6 for the recovery (program B), and paste the ttyUSB0 log.

The programming Vivado exits by itself. Check `pgrep -a hw_server` afterwards: if a `hw_server` is still listed, that is fine for step 3 (the
bridge connects to `localhost:3121`), but no Vivado window may be open.

## 3. The bridge, and its self-test (the first real check)

Terminal 3. The bridge starts Vivado in batch mode, opens the hardware manager in JTAG mode (**it does not program anything**), runs the self-test
and then serves OpenOCD on `127.0.0.1:33582`:

```
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build
env LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log ~/rvbridge.log -source /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
```

Optional environment (put it inside the `env` word list, before `LD_LIBRARY_PATH`): `RBB_PORT=<port>` for another port (then OpenOCD needs
`-c "set RBB_PORT <port>"` before `-f`), `JTAG_FREQ=<Hz>` for another TCK. Default TCK is the cable's Vivado default (6 MHz); the bridge prints it.

**Look at the output (and `~/rvbridge.log`) for these lines, in this order:**

```
rvb: rv_jtag_bridge: hw_server localhost:3121, target pattern '*', remote_bitbang 127.0.0.1:33582
rvb: target <the cable's target name> open in JTAG mode, PARAM.FREQUENCY <Hz>
rvb: raw self-test: scan_ir_hw_jtag 6 -> '<hex>' (IR capture 0x11), scan_dr_hw_jtag 32 -> '<hex>' (IDCODE 0x13631093)
=== RVBRIDGE SELF-TEST PASS: IDCODE 0x13631093, IR capture 0x11, BYPASS ok
=== RBB BRIDGE listening 127.0.0.1:33582
```

What to expect exactly:

- **IDCODE `0x?3631093`**: the low 28 bits are the XC7A100T's, the top nibble is the silicon version. The XC7A100T normally reads `0x13631093`; the
  bridge accepts any version nibble (the simulation model's `0x03631093` is not the board's value).
- IR capture ends in the bits `01` (the IEEE 1149.1 mandatory pattern); `0x11` is what an XC7 shows (`010001`). A different value in the upper
  bits of the 6 does not fail the test but belongs in your paste-back.
- `BYPASS ok`: 8 bits shifted in come back delayed by one.

**Abort rule.** This is the first time the bridge meets real Vivado, so the self-test is the explicit check of two things nobody has seen work:
(a) the bit order (the first bit shifted is the LSB of `-tdi` and of the returned TDO), (b) `runtest_hw_jtag` and end-state carry-over.

- A line `=== RVBRIDGE SELF-TEST FAIL ...`, or no `SELF-TEST PASS` line within about 2 minutes, or `no hardware target matches`, or `N targets match`,
  or any `rvb: ERROR`: **abort the session here.** Do not start OpenOCD. Ctrl-C the bridge, then paste `~/rvbridge.log` (whole) and say which line stopped it.
  A wrong IDCODE in the raw line points at the bit order; the log shows the hex strings Vivado returned.
- A pass whose IDCODE you consider odd (not `0x?3631093`): cannot happen, the bridge exits on it.
- **If the self-test passes but later steps look unreliable** (OpenOCD errors such as `Unsupported DTM version`, `JTAG scan chain interrogation
  failed`, or random read failures): stop OpenOCD, Ctrl-C the bridge, and retry **once** with a slower TCK:
  ```
  cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build
  env JTAG_FREQ=3000000 LD_LIBRARY_PATH=$HOME/lib/tinfo5 LC_ALL=C /opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -nojournal -log ~/rvbridge-3mhz.log -source /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build/tools/rvdebug/rv_jtag_bridge.tcl
  ```
  The line `rvb: target ... PARAM.FREQUENCY 3000000` must show the new value (a line `WARNING: PARAM.FREQUENCY ... not set` means Vivado refused it:
  paste it). Paste both logs.

Leave the bridge running. While it runs, every minute with traffic it logs `rbb: HH:MM scans in the last minute: n`.

## 4. OpenOCD

Terminal 4:

```
cd /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-p5build
openocd -f tools/openocd/minimig-rv-bscan.cfg -d2 -l ~/openocd.log
```

Expected in the output (the log has the same lines; `-d2` adds debug lines, the file gets very long, that is intended):

```
Info : Initializing remote_bitbang driver
Info : Connecting to 127.0.0.1:33582
Info : remote_bitbang driver initialized
Info : JTAG tap: xc7.tap tap/device found: 0x13631093 (mfg: 0x049 (Xilinx), part: 0x3631, ver: 0x1)
Info : [cpu.0] datacount=... progbufsize=...
Info : [cpu.0] Examined RISC-V core; found 1 harts
Info : [cpu.0] XLEN=32, misa=0x...
Info : Listening on port 3333 for gdb connections
```

(`ver: 0x1` or another version: fine.) The two lines that matter: **`Examined RISC-V core; found 1 harts`** and **`Listening on port 3333`**.

The OpenOCD config is `tools/openocd/minimig-rv-bscan.cfg`: `remote_bitbang` to port 33582, TAP `xc7.tap`, `riscv use_bscan_tunnel 6 1`.

**Abort rule.** `Error:` lines, `Unsupported DTM version`, `JTAG scan chain interrogation failed`, `Unexpected idcode`, `double-check your JTAG setup`, or no
`found 1 harts` within about 3 minutes (the autoprobe is 672 bits and every scan goes through `hw_server`; the first attach is slow): Ctrl-C OpenOCD,
Ctrl-C the bridge, paste `~/openocd.log` and `~/rvbridge.log`. One retry at `JTAG_FREQ=3000000` (step 3) is allowed before you give up.

Check the Amiga while attached: the OSD CPU may be stopped by OpenOCD at attach (OpenOCD halts the hart to examine it and resumes it). If Workbench
or the OSD is frozen (a halted CPU stalls disk access) **after** `found 1 harts` and before GDB is connected, note it and go on: GDB's `continue` resumes.

## 5. GDB

Terminal 5. The ELF is absolute; GDB is started without `-cd` and without relative `-x` (a relative `-x` after `-cd` was found broken in
Task 2). Logging is switched on first, so the transcript lands in `/home/paul/gdb.log` (written out in full: GDB's `set logging file` is not relied on to expand `~`):

```
"$GDB" -nx "$OUT/fw/RV32OSDA.elf"
```

At the `(gdb)` prompt, paste the setup block (the symbols were checked against the ELF with this GDB without any target):

```
set pagination off
set confirm off
set width 0
set remotetimeout 300
set logging file /home/paul/gdb.log
set logging overwrite on
set logging enabled on
target extended-remote 127.0.0.1:3333
```

Expected: `Remote debugging using 127.0.0.1:3333` (and a `0x... in ?? ()` or a function name at the stopped pc; `target extended-remote` halts the hart).
The ELF is the firmware at `0x2000` (entry), so symbols resolve when the hart is in the OSD firmware.

### 5.1 Read-only first (halt only briefly: the Amiga's disk service stalls while the CPU is halted)

```
monitor halt
info registers
bt
info symbol $pc
x/s 0x142f4
x/16wx 0x142f4
x/wx &osd_rdy_timeouts
x/bx &DebugMode
continue
```

Expected: `monitor halt` answers with the hart's halted state (`target halted due to debug-request, current mode: Machine` and the `pc`);
`info registers` lists x0..x31 and `pc`; `pc` lies in `0x2000..0x136b8` (the firmware's `.text`) or in the boot ROM (low addresses, below the firmware);
`bt` shows frames (`main`, probably `HandleUI`, `OsdGetCtrl`, ... or a wait loop; an incomplete backtrace is normal for -O1 code);
`x/s 0x142f4` prints `"Firmware version: %s"` and `x/16wx 0x142f4` starts `0x6d726946 0x65726177 0x72657620 0x6e6f6973` (that is the same text in
RAM as in the ELF; any other value means the card's `RV32OSDA.BIN` is not the one this ELF belongs to: **write it down, it invalidates the later
steps**); `x/wx &osd_rdy_timeouts` prints the live count (normally `0x00000000`); `continue` prints `Continuing.`

**After the `continue`: the OSD must work** (open it, close it) and the Amiga must have kept running (an Amiga that waited on a disk access during the halt resumes on `continue`). If not, note what you saw. Press Ctrl-C in GDB
to get the prompt back (`Program received signal SIGINT`).

Repeat `monitor halt` / `info registers pc` / `continue` three times; the pc will differ.

### 5.2 A breakpoint on a key press

`OsdShow` (`osd.c`) is called when the menu key opens the OSD (`menu.c` line 686, `OsdShow(DISABLE_KEYBOARD)`; with DebugMode on it is also called
at line 671 when the OSD closes, and by `InfoMessage`/`ErrorMessage`); `HandleUI` is hit every main-loop pass and is
**not** a useful choice. A hardware trigger is used (VexRiscv has two; a software breakpoint inside a cached line may never be fetched, the lesson of
Task 2):

```
hbreak OsdShow
continue
```

Expected: `Hardware assisted breakpoint 1 at 0xe316: file osd.c, line 800.`, then `Continuing.` The OSD CPU keeps running; nothing happens yet.
**Now press the OSD key** (F12 or the OSD button) once. Expected in GDB:

```
Breakpoint 1, OsdShow (mode=...) at osd.c:800
```

(or `Thread 1 hit Breakpoint 1`). The OSD does not open (the CPU is stopped there); the Amiga screen keeps going unless it needs the disk (it resumes on `continue`). Do not leave the CPU stopped long. Then:

```
bt
info registers pc ra
delete
continue
```

`bt` shows `OsdShow` called from `HandleUI` (or `menu.c` code). After `continue` the OSD must open and work normally. **Abort rule for this step**: if the
breakpoint never hits after two OSD key presses, press Ctrl-C in GDB, `monitor halt`, `info registers pc`, `delete`, `continue`, note it and go on.

### 5.3 Timing probe (decides step 5.4)

Every memory read goes through `hw_server`. Measure its speed before a `load` is tried:

```
monitor halt
shell date +%T
x/256wx 0x2000
shell date +%T
continue
```

Write down the two times from the terminal (shell output is not in `gdb.log`). 256 words are 1 KB; the firmware image is 93,032 bytes (about 23,300 words, 91 times as much). A write is likely
slower than a read.

- Under 5 seconds for the 256 words: the `load` below takes about 8 minutes or less. Go on.
- 5 to 20 seconds: the `load` takes about 8 to 30 minutes. Go on only if you want to wait.
- Over 20 seconds: **skip 5.4** (do not try the `load`), go to 5.5, and say so in the paste-back.

### 5.4 Load the same ELF over the running image, then continue

Equal bytes are written, and GDB sets the pc to the ELF entry, so this also exercises `fence.i` after a write through the debug module. The firmware
**restarts from its entry point** (`0x2000`, C start-up `_start` -> `main` -> `ColdBoot()`) instead of continuing where it was; `.data` and `.bss` are
reinitialised by the start-up code and the boot ROM is not run again. **`ColdBoot()` resets the chipset and the Amiga CPU, re-initialises the SD card,
reloads the configuration and the Kickstart ROM and then releases the Amiga: the Amiga cold-boots** (seconds of black screen, Kickstart, Workbench from
the HDF again, as after a normal OSD boot). That is the expected outcome here, not a failure.

**Not covered by the simulation proof.** The sim session (`sim/rv_dbg/gdb/session.gdb`) does `monitor reset halt` first and then loads a small, different
image. "`load` of the large image over the running firmware, with no reset before it, then start at 0x2000" runs on the board only; the SPI chip selects, an
SD transaction in flight or a pending interrupt are not reset before it (`ColdBoot` re-initialises most of that; unproven). Expected: the firmware restarts,
the Amiga reboots. Recovery if it does not: step 5.5 (`monitor reset halt`, `continue`), and if that fails, power-cycle and program the lab bitstream
again (or B, step 6).

```
monitor halt
shell date +%T
load
shell date +%T
info registers pc
continue
```

Expected: `Loading section .text, size 0x136b8 lma 0x2000`, then `.rodata`, `.init_array`, `.data`, a `Start address 0x2000`, `Transfer rate: ... bytes/sec`,
and `pc` = `0x2000` (as `_start`) before the `continue`. No `Error`, no `Remote communication error`. The simulation moved 205 bytes/s through the
bridge; the board may be faster or slower. Watch `~/rvbridge.log` in another window: scans per minute rise during the load.
Ctrl-C in GDB aborts a `load` that takes too long (the firmware is then half-written: finish with step 5.5 `monitor reset halt` and `continue`, which
restarts it from the boot ROM and the card, so a half-written image is replaced).

After the `continue`: wait for the Amiga to reboot (ttyUSB0 shows the SD and Kickstart boot lines; allow 60 seconds, about a normal boot). Then Workbench
must be back and the OSD must open and close. If the Amiga does not come back or the OSD is dead after 60 seconds, do 5.5 now, whatever the plan said.

### 5.5 Optional, last: `monitor reset halt`

Restarts the OSD CPU through the debug module's ndmreset; the **boot ROM runs again and loads `RV32OSDA.BIN` from the card**, so the OSD firmware
restarts from scratch and runs `ColdBoot()` as in 5.4: **the Amiga is reset and reboots** (Kickstart reloads, Workbench again). That is expected.

```
monitor reset halt
info registers pc
continue
```

Expected: `pc` is the boot ROM's reset vector (a low address, below `0x2000`) before the `continue`; after it the ttyUSB0 log shows the boot lines again
(`Initializing SD card`, ... `file "RV32OSDA.BIN" found`) wait up to 60 seconds for Workbench; the OSD must work. If the boot hangs, note the last ttyUSB0 line; power-cycle and program B (step 6).

## 6. Detach and stop

In GDB:

```
set logging enabled off
detach
quit
```

(`set logging enabled off` is optional; the log is complete either way.) `detach` resumes the hart. OpenOCD keeps running after `detach`.
Then, in this order:

1. Terminal 4: Ctrl-C in OpenOCD. It closes the connection with `Q`; the bridge logs `=== RBB BRIDGE connection 1 closed (Q): bytes ..., scans ...`.
2. Terminal 3: Ctrl-C in the bridge (Vivado), which stops it. Check that nothing is left: `pgrep -a hw_server; pgrep -a vivado`. A `hw_server` still
   running is harmless but holds the cable: close it with `kill <pid>` (that PID only, from the `pgrep` output) before opening any hardware manager.
3. Terminal 1: leave picocom with Ctrl-A Ctrl-X.
4. **Check the OSD still works** (open, move, close) and Workbench is alive. If not, power-cycle and load B (`ab-board-test.md` section 3, "Load B"); the
   state of the lab image after a debug session is not guaranteed.

Recovery at any point: Ctrl-C everything, power-cycle the board, "Load B" from `ab-board-test.md` section 3. Nothing in this protocol writes the card or the
flash.

## 7. What to paste back

1. `~/rvbridge.log` (and `~/rvbridge-3mhz.log` if the retry ran). **First, grep it** and paste the output of both commands with the log:
   ```
   grep -n -i -e 'shift split' -e 'forced by a timer' ~/rvbridge.log
   grep -n -e 'SELF-TEST' -e 'raw self-test' -e 'connection .* closed' ~/rvbridge.log
   ```
   **Any `WARNING: ... shift split` line (the bridge prints `DR shift split` or `IR shift split`) or `forced by a timer N` with N > 0 invalidates the DMI results of that session**: a shift was split by the bridge's
   100 ms timer (OpenOCD stalled inside a scan), which corrupts a tunnel scan (`Unsupported DTM version`, wrong memory values). Say so in the step
   notes and repeat the session. `forced by a timer 0` in every connection close line is the clean result. Also paste the line `IDCODE read-ahead N (M bad)`:
   `M` must be 0.
2. `~/openocd.log`.
3. The GDB transcript `/home/paul/gdb.log`. The `shell date +%T` outputs go to the terminal, not into this log: copy the times by hand into the step table.
4. The ttyUSB0 log `~/rvdbg-tty.log`.
5. One line per step, "ok" or what happened, with the two time stamps of steps 5.3 and 5.4:

   | Step | ok / what happened |
   |---|---|
   | 1 before (tools, checksums) | |
   | 2 program lab bitstream, boot, OSD works | |
   | 3 bridge self-test (IDCODE line, `SELF-TEST PASS`) | |
   | 4 OpenOCD (`found 1 harts`, port 3333) | |
   | 5.1 read-only (halt, registers, `bt`, `x/s 0x142f4`, continue) | |
   | 5.2 `hbreak OsdShow` hit on the OSD key | |
   | 5.3 timing probe, times | |
   | 5.4 `load` of the same ELF, times, Amiga reboot to Workbench, OSD alive after | |
   | 5.5 `monitor reset halt` (or "not run") | |
   | 6 detach, stop, OSD still works | |

## 8. STOP

**Nothing after this point needs the agents until Paul returns the logs.** The controller stopped at this document: the 5.4 gate ("session log in
`findings/osd-riscv/debug.md`") is filled from the files of step 7 into `debug.md` section "Board session". Do not run anything from here on
against the lab image other than what this protocol says; a failed session is a finding, not a reason to rebuild.

## Files named by this protocol

(`ls -l` of each is in `.superpowers/sdd/osd-riscv-exec-5b/task-8-report.md`.)

| Path | What |
|---|---|
| `$OUT/minimig_openaars_top.bit`, `$OUT/bit.md5` | lab bitstream, md5 `990199ce...` |
| `$OUT/fw/RV32OSDA.elf`, `$OUT/fw/RV32OSDA.BIN`, `$OUT/fw/SHA256SUMS` | firmware of the card, for GDB (the `.BIN` is `objcopy -O binary` of the ELF, as the firmware Makefile does; `cmp` with the card's `.BIN`: equal) |
| `$P5/tools/vivado/program.tcl` | programs the bitstream (`ab-board-test.md` section 3) |
| `$P5/tools/rvdebug/rv_jtag_bridge.tcl` (with `rbb_core.tcl`) | the bridge |
| `$P5/tools/openocd/minimig-rv-bscan.cfg` | OpenOCD config (`remote_bitbang`, port 33582) |
| `$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gdb` | GDB 16.3 |
| `/usr/bin/openocd`, `/usr/bin/picocom` | OpenOCD 0.12.0, serial terminal |
