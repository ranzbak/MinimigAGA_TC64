# OSD host CPU -> VexRiscv: executable plan, stage 1 (Phases 1 and 2)

**Goal.** Put a VexRiscv RV32IMC (4 KB I-cache) behind the existing host bus
of `EightThirtyTwo_Bridge`, selectable by generic with the 832 as the
default, and prove in simulation -- before any firmware port or full build --
that it runs: lanes, hw window, four-phase hw handshake, interrupts, traps,
a ported boot ROM that loads a firmware file from a FAT16 card image, the
firmware-unit programs, and Dhrystone. Parent plan: `doc/osd-riscv-plan.md`
(sections 3, 6.2, 7.2, 8 Phases 1-2; decisions in section 12).
Measurements behind the choice: `findings/osd-riscv/tiny-cores.md`.

**Architecture summary.** `rtl/host/vexriscv/VexOsd*.v` (generated from a
committed SpinalHDL config) sits inside `rtl/host/rv_hostcpu.v`, which turns
the core's I-cache line refills and uncached data accesses into the 832's
one-transaction req/ack bus with big-endian lanes on memory and unswapped
lanes on the hw window. `rtl/host/832_bridge.vhd` instantiates either the 832
or `rv_hostcpu` (+ its own boot ROM entity) and keeps one state machine for
both, now with a four-phase hw handshake. Benches: L1 `sim/rv_l1/`
(iverilog, CPU block + memory model), L2 `sim/host_bridge/` (xsim, real
bridge + cfide + hostcache + SDRAM and SD-card models). Firmware:
`fw/ctrl_boot_rv/` (boot ROM), `fw/ctrl_rv/arch/` (crt0, trap, IRQ),
`fw/dhrystone_rv/`.

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Worktree / branch | `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv`, branch `osd-riscv`. Use absolute paths. One commit per task, only the task's files (`git add <paths>`); never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`. Commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` (or the implementer's own model line). |
| Part / clock | `xc7a100tfgg676-2`; host clock `clk_114` period **8.815 ns** (113.4375 MHz); `clk_28` = clk_114 / 4 (benches: `T114 = 8.8154`, clk_28 derived as in `sim/spi_cdc/host832/tb_832_dmode.v`). |
| Tools | Vivado **2023.2** `/opt/Xilinx/Vivado/2023.2/bin/{vivado,xvlog,xvhdl,xelab,xsim}` with `LD_LIBRARY_PATH=$HOME/lib/tinfo5`, `LC_ALL=C`; never `-stack`. **No full builds**: OOC synthesis/implementation and simulation only. iverilog 12 `/usr/local/bin/iverilog -g2012` + `vvp -N` for Verilog-only benches (run independent vvp jobs in parallel; xsim runs one at a time). |
| CPU byte memory map | `0x00000000-0x00001FFF` boot BRAM 8 KB R/W (reset vector `0x0`, boot trap entry `0x20`, firmware stack top `0x2000`); `0x00002000-0x007FFFFF` SDRAM via hostcache (`prg_start = 0x2000` = firmware `_start`; `AUDIO_BUFFER` `0x70000`; Amiga RAM at `addr ^ 0x680000`); `addr[23]=1` -> cfide, 16-bit, value at offset 0 of each 16-byte window: `0xFFFFFFE0` SPI DATA (8-bit), `0xFFFFFFE4` SPI CS, `0xFFFFFFE8` SPI SPEED, `0xFFFFFFF0` UART TX (8-bit write only: cfide holds the write until the transmitter is free, so no poll is needed; there is no TX-ready bit, and a UART **read** is never acked by cfide (its support state machine serves UART writes only): it deadlocks the CPU, so firmware must never read `0xFFFFFFF0`; the L1 model fails a run that does -- corrected 2026-10-16, the earlier text claimed a TX-ready bit 8), `0xFFFFFFD0` TIMER, `0xFFFFFFC0` PLATFORM, `0xFFFFFFB0` AUDIO, `0xFFFFFFA0` INTERRUPT (bit 0 = enable on write; any access clears the pending line), `0xFFFFFF9x` keyboard, `0xFFFFFF8x` Akiko, `0xFFFFFF7x` RTC, `0xFFFFFF6x` I2C, `0xFFFFFF5x` VPOS, `0xFFFFFF4x` XADC. Sim-only MMIO (L1 model; in L2 cfide acks it as an unmapped register and the bench snoops it): `0xFFFFFF00` TIME stamp (write), `0xFFFFFF04` DONE (write exit code), `0xFFFFFF08` IRQ_AT (write N: raise an interrupt event N cycles later; L1 only), `0xFFFFFF0C` SCRATCH (16-bit R/W; L1 only). |
| Lane rule | Byte-select `sel[i]` = byte at A+i, and byte A+0 is bits 31:24 on memory (`rtl/sdram/sdram_ctrl.v:621`, `fw/ctrl_boot_832/rom_epilogue.vhd:17`). `rv_hostcpu` swaps the four data bytes for `addr[23]=0` in both directions and passes `sel` = core mask unchanged; for `addr[23]=1` no swap. (`sim/spi_cdc/host832/tb_832_dmode.v`'s SDRAM model maps `hostsel[3]` to `hostWR[31:24]`: it is not the reference; follow sdram_ctrl.) |
| Bus contract (832 req/ack) | Master holds `req`, `addr[31:2]`, `q[31:0]`, `sel[3:0]`, `wr` stable until it samples `ack=1`; `d[31:0]` is valid in the `ack` cycle; in the cycle after `ack`, `req` is 0 or a new request; the slave accepts a request only when `ack=0` in that cycle (as the bridge's `waiting` state: `cpu_ack='0' and cpu_req='1'`). One transaction in flight. |
| VHDL bridge generics / ports | `EightThirtyTwo_Bridge`: existing `debug : boolean := false` (832 only, unchanged); new `cpu_riscv : boolean := false`, `rv_debug : natural := 0` (0 none, 1 BSCANE2 tunnel -- Artix only, 2 pin TAP), `rv_extra_ws : natural := 0` (bench only). New ports `rv_jtag_tck, rv_jtag_tms, rv_jtag_tdi : in std_logic := '0'; rv_jtag_tdo : out std_logic`. Existing ports and the register names `hw_req`, `wr` (XDC cells `hostcpu/hw_req_reg`, `hostcpu/wr_reg`) unchanged. |
| Verilog CPU block | `module rv_hostcpu #(parameter DEBUG = 0, parameter EXTRA_WS = 0)` (ports in Task 4). Generated cores: `VexOsd` (DEBUG 0), `VexOsd_DMT` (1), `VexOsd_DMJ` (2) in `rtl/host/vexriscv/`. Boot ROM entity for the RV: `OSDBoot_rv_ROM` (same generics/ports as `OSDBoot_832_ROM`). |
| VexRiscv pin | `https://github.com/SpinalHDL/VexRiscv` commit `baf7dc82f855eddaf5b0a20a6802c526f127e38a` (2026-09-24), SpinalHDL 1.13.0, Scala 2.12.18, sbt per upstream `project/build.properties`. Clone cache outside the repo: `VEX_SRC ?= $HOME/opt/vexriscv-src`. Run sbt with `-java-home /usr/lib/jvm/java-17-openjdk-amd64` (JDK 23, the default, fails: "bad constant pool index"). |
| Toolchain pin | xPack `riscv-none-elf-gcc` **15.2.0-1** (GCC 15.2.0, binutils 2.45, newlib 4.5.0), `https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz`, sha256 `aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758`, installed at `$HOME/opt/xpack-riscv-none-elf-gcc-15.2.0-1`. Every Makefile includes `tools/riscv/toolchain.mk`: `RV_GCC_DIR ?= $(HOME)/opt/xpack-riscv-none-elf-gcc-15.2.0-1`, `RV_PREFIX ?= riscv-none-elf-`, `RV_CC = $(RV_GCC_DIR)/bin/$(RV_PREFIX)gcc` etc. Fallback: `RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf-` (Ubuntu 13.2). Arch flags `RV_ARCH = -march=rv32imc_zicsr_zifencei -mabi=ilp32`. Firmware/boot ROM flags `-Os -ffunction-sections -fdata-sections -fno-builtin -funsigned-char -ffreestanding -nostdlib -Wl,--gc-sections ... -lgcc`; test programs may use newlib-nano (`--specs=nano.specs`). |
| Vendor-neutral rule | Everything under `rtl/` is plain Verilog-2001 / VHDL-93(-2008) without vendor primitives, except `rtl/host/xilinx/rv_bscane2.v` (BSCANE2), instantiated only when `rv_debug = 1`, listed only in Vivado scripts, never in `rtl/host/host.qip`. Default generics select no vendor feature. Generated `VexOsd*.v` must contain no vendor primitive (grep gate). |
| The 832 stays | `cpu_riscv=false` keeps the 832 path; its only behaviour change is the four-phase handshake. Regression = `sim/spi_cdc/host832/run.sh` with `E832=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo/RTL` (the worktree's submodule is not initialised). `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/dhrystone_832` are read-only. |
| Run directories | Bench outputs go to `run_${RUNTAG:-wt}` inside the bench directory (gitignored per bench `.gitignore`); never reuse a RUNTAG across code changes when comparing. |

---

### Task 1: Pin the RISC-V toolchain

- **Phase / depends on:** plan 2.1 (pulled first: every later test program
  needs it) / none.
- **Model:** Sonnet.
- **Files (create):** `tools/riscv/toolchain.mk`, `tools/riscv/fetch-xpack.sh`,
  `tools/riscv/check-toolchain.sh`, `tools/riscv/README.md`.
- **Interfaces:** `toolchain.mk` defines `RV_GCC_DIR`, `RV_PREFIX`, `RV_CC`,
  `RV_AS`, `RV_LD`, `RV_OBJCOPY`, `RV_OBJDUMP`, `RV_SIZE`, `RV_ARCH`,
  `RV_ARCH_IM = -march=rv32im_zicsr_zifencei -mabi=ilp32`, `RV_CFLAGS_FW`
  (firmware flags above), `RV_LDFLAGS_FW`. `fetch-xpack.sh [dest]` downloads
  the tarball into `$HOME/opt/`, verifies the sha256, unpacks, refuses to
  overwrite an existing directory.
- **Test first:** `check-toolchain.sh` (exit 0 = OK) checks, for
  `RV_GCC_DIR`/`RV_PREFIX` from the environment or the defaults:
  1. `$(RV_CC) $RV_ARCH -print-multi-directory` prints `rv32imc/ilp32`, and
     with `RV_ARCH_IM` prints `rv32im/ilp32`;
  2. the rv32im `libgcc.a` (`-print-libgcc-file-name` with `RV_ARCH_IM`)
     disassembles without any 16-bit instruction (`objdump -d` lines with a
     4-hex-digit opcode field) and without `lr.w|sc.w|amo*.w`;
  3. a 10-line C file with `csrr`/`fence.i` inline asm compiles and links
     with `-nostdlib -lgcc` for both arch strings.
- **Steps:** write the check; run it against Ubuntu 13.2 (expected: 1-3 pass
  or a documented failure -- record it); install xPack with
  `fetch-xpack.sh`; run the check against xPack; write README (versions,
  sha256, multilib list, override examples, the CH32V `~/bin` 14.2 build is
  not to be used).
- **Commands:**
  `bash tools/riscv/fetch-xpack.sh && bash tools/riscv/check-toolchain.sh &&
  RV_GCC_DIR=/usr RV_PREFIX=riscv64-unknown-elf- bash tools/riscv/check-toolchain.sh`
- **Pass gate:** xPack: all three checks OK. Ubuntu fallback: result
  recorded in README (pass or the exact failing check). The toolchain is
  outside the repo; nothing under `$HOME/opt` is committed.

### Task 2: Vendor VexRiscv (Scala config, regeneration script, generated Verilog)

- **Phase / depends on:** plan 1.1 / none.
- **Model:** Opus.
- **Files (create):** `rtl/host/vexriscv/GenOsd.scala`,
  `rtl/host/vexriscv/regen.sh`, `rtl/host/vexriscv/VERSION`,
  `rtl/host/vexriscv/README.md`, generated `rtl/host/vexriscv/VexOsd.v`,
  `VexOsd_DMT.v`, `VexOsd_DMJ.v`.
- **Configuration (start from this; it is the measured `GenTiny` IC4K
  configuration of tiny-cores.md 5.2 plus `mtvec` RW, illegal-instruction and
  misaligned-access traps, three debug variants):**

```scala
package vexriscv.demo

import spinal.core._
import spinal.lib.cpu.riscv.debug.DebugTransportModuleParameter
import vexriscv.plugin._
import vexriscv.ip.InstructionCacheConfig
import vexriscv.{VexRiscv, VexRiscvConfig, plugin}
import scala.collection.mutable.ArrayBuffer

// MinimigAGA host CPU: RV32IMC, 4 KB I$, uncached dBus, standard M-mode traps.
// debug 0 = VexOsd (none), 1 = VexOsd_DMT (DM, tunnel for an external BSCANE2),
// 2 = VexOsd_DMJ (DM with its own TAP on pins).
object GenOsd extends App {
  def cpu(debug: Int) = {
    val plugins = ArrayBuffer[Plugin[VexRiscv]](
      new IBusCachedPlugin(resetVector = 0x00000000l, prediction = NONE,
        compressedGen = true, injectorStage = true,
        config = InstructionCacheConfig(cacheSize = 4096, bytePerLine = 32,
          wayCount = 1, addressWidth = 32, cpuDataWidth = 32, memDataWidth = 32,
          catchIllegalAccess = false, catchAccessFault = false,
          asyncTagMemory = false, twoCycleRam = false, twoCycleCache = true)),
      new DBusSimplePlugin(catchAddressMisaligned = true, catchAccessFault = false),
      new CsrPlugin(CsrPluginConfig.small(0x00000020l).copy(
        mtvecAccess = CsrAccess.READ_WRITE, withPrivilegedDebug = debug != 0)),
      new DecoderSimplePlugin(catchIllegalInstruction = true),
      new RegFilePlugin(regFileReadyKind = plugin.SYNC, zeroBoot = false),
      new IntAluPlugin,
      new SrcPlugin(separatedAddSub = false, executeInsertion = true),
      new LightShifterPlugin,
      new HazardSimplePlugin(bypassExecute = true, bypassMemory = true,
        bypassWriteBack = true, bypassWriteBackBuffer = true,
        pessimisticUseSrc = false, pessimisticWriteRegFile = false,
        pessimisticAddressMatch = false),
      new MulPlugin,
      new MulDivIterativePlugin(genMul = false, genDiv = true,
        mulUnrollFactor = 1, divUnrollFactor = 1),
      new BranchPlugin(earlyBranch = false, catchAddressMisaligned = false))
    if (debug != 0) plugins += new EmbeddedRiscvJtag(
      p = DebugTransportModuleParameter(addressWidth = 7, version = 1, idle = 7),
      debugCd = ClockDomain.current.copy(reset = Bool().setName("debugReset")),
      jtagCd = if (debug == 1) ClockDomain(clock = Bool().setName("jtag_tck")) else null,
      withTunneling = debug == 1, withTap = debug == 2)
    val c = new VexRiscv(VexRiscvConfig(plugins = plugins.toList))
    c.setDefinitionName(Seq("VexOsd", "VexOsd_DMT", "VexOsd_DMJ")(debug))
    c
  }
  for (d <- Seq(0, 1, 2))
    SpinalConfig(targetDirectory = "gen_osd").generateVerilog(cpu(d))
}
```

- **`regen.sh`:** `set -euo pipefail`; `VEX_SRC=${VEX_SRC:-$HOME/opt/vexriscv-src}`;
  clone if missing, `git -C $VEX_SRC fetch` only if the pinned commit is
  absent, `git -C $VEX_SRC checkout --detach <pin>`, refuse a dirty tree
  except for the copied Scala file; copy `GenOsd.scala` to
  `$VEX_SRC/src/main/scala/vexriscv/demo/`; run
  `sbt -java-home ${JAVA17:-/usr/lib/jvm/java-17-openjdk-amd64} -batch "runMain vexriscv.demo.GenOsd"`
  in `$VEX_SRC`; copy `gen_osd/VexOsd*.v` into the script's directory
  (ignore the `*.bin` RAM-init files if any are produced, or commit them if
  the Verilog `$readmemb`s them -- check); print the sha256 of each output.
- **Test first:** before regenerating, write the gate checks into `regen.sh
  --check`: (a) the three files exist and `iverilog -g2012 -o /dev/null
  <file>` parses each; (b) `grep -E '\b(BSCANE2|BUFG|RAMB|DSP48|IBUF|OBUF|altsyncram|altera_)\b'`
  finds nothing; (c) `VexOsd.v` has no `jtag`/`debugReset` port,
  `VexOsd_DMT.v` has `jtagInstruction_*` + `jtag_tck` + `debugReset` +
  `ndmreset`, `VexOsd_DMJ.v` has `jtag_tck/tms/tdi/tdo` + `debugReset` +
  `ndmreset`; (d) all three have `externalInterrupt`, `timerInterrupt`,
  `softwareInterrupt`, the `iBus_cmd_*`/`iBus_rsp_*` (cached: `address`,
  `size`, `data`) and `dBus_cmd_*`/`dBus_rsp_*` ports of tiny-cores
  `tb_vexc.v`.
- **Steps:** write files; run `regen.sh`; if `ClockDomain(clock =
  Bool().setName("jtag_tck"))` does not elaborate outside a component, use
  `ClockDomain.external("jtag", withReset = false)` and record the real port
  name; run `regen.sh` a second time and `diff` the outputs (only the
  generator header may differ; if more differs, find why); README: what the
  files are, the pin, JDK 17 requirement and the JDK 23 failure, ~1.3 GB
  `~/.sbt` + `~/.cache/coursier`, ~2 min per run, the exact port lists per
  variant, the BSCANE2-to-`jtagInstruction` mapping for Task 14 (`tdi`<-TDI,
  `enable`<-SEL, `capture`<-CAPTURE, `shift`<-SHIFT, `update`<-UPDATE,
  `reset`<-RESET, TDO<-`tdo`, `jtag_tck`<-TCK; verify against SpinalHDL's
  `spinal.lib.blackbox.xilinx.s7.BSCANE2.toJtagTapInstructionCtrl`), and the
  rule "edit `GenOsd.scala`, run `regen.sh`, commit Scala + Verilog
  together".
- **Commands:** `bash rtl/host/vexriscv/regen.sh && bash rtl/host/vexriscv/regen.sh --check`
- **Pass gate:** `--check` passes; second regeneration byte-identical apart
  from the header comment; VERSION holds the commit hash, SpinalHDL and sbt
  versions and the JDK path.

### Task 3: OOC size and timing of the three core variants (Vivado 2023.2)

- **Phase / depends on:** plan 1.3 / Task 2.
- **Model:** Sonnet.
- **Files (create):** `tools/vivado/ooc_hostcpu/run.tcl`,
  `tools/vivado/ooc_hostcpu/wvex.v`, `tools/vivado/ooc_hostcpu/go.sh`,
  `tools/vivado/ooc_hostcpu/README.md`, `findings/osd-riscv/ooc-2023.2.md`.
- **Interfaces:** `run.tcl` and `wvex.v` adapted from
  `findings/osd-riscv/tinycores/wrap/run.tcl` and `wvex.v` (registered-I/O
  wrapper `wtop`, core instance `u_core`, defines `VEXMOD`, `DM`, `ICACHE`;
  for `VexOsd_DMT` bring `jtagInstruction_*` and `jtag_tck` out as wrapper
  ports, `jtag_tck` constrained as an async 50 ns clock like `tck`).
  `go.sh <name> <variant> <period>` runs
  `/opt/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source run.tcl -tclargs ...`
  into `tools/vivado/ooc_hostcpu/runs/<name>/` (gitignored).
- **Test first:** run the flow once on `VexOsd` and check the report parser
  pulls LUT/LUTRAM/FF/RAMB36/RAMB18/DSP of `u_core` and WNS from the
  reports (compare by eye with `util_hier.rpt`).
- **Steps:** run `VexOsd`, `VexOsd_DMT`, `VexOsd_DMJ` at 8.815 ns (three
  runs in parallel is fine, each Vivado ~2-4 GB); write the table into
  `findings/osd-riscv/ooc-2023.2.md` next to the 2026.1 rows of
  tiny-cores.md (IMC + 4 KB I$ + DM: 1742 LUT, +1.104 ns).
- **Commands:** `cd tools/vivado/ooc_hostcpu && for v in VexOsd VexOsd_DMT VexOsd_DMJ; do ./go.sh $v $v 8.815 & done; wait`
- **Pass gate:** `VexOsd` <= 1,450 LUT and WNS >= +1.0 ns; `VexOsd_DMT` and
  `VexOsd_DMJ` <= 1,950 LUT and WNS >= +0.9 ns. If a gate fails, re-run with
  the two catch flags of Task 2 off to show their cost, record both, and stop
  for a decision (plan 2.2: catch flags go first, `mtvec` RW stays).

### Task 4: CPU block `rv_hostcpu.v` and the L1 bench with directed tests

- **Phase / depends on:** plan 1.2 / Tasks 1, 2.
- **Model:** Opus.
- **Files (create):** `rtl/host/rv_hostcpu.v`; `sim/rv_l1/tb_rv_l1.v`,
  `sim/rv_l1/mem_model.v`, `sim/rv_l1/bus_checker.v`, `sim/rv_l1/run.sh`,
  `sim/rv_l1/Makefile`, `sim/rv_l1/.gitignore`, `sim/rv_l1/sw/crt0_l1.S`,
  `sim/rv_l1/sw/l1.ld`, `sim/rv_l1/sw/l1.h`, `sim/rv_l1/tests/lanes.S`,
  `sim/rv_l1/tests/refill.c`, `sim/rv_l1/tests/fencei.S`,
  `sim/rv_l1/README.md`.
- **Interface (exact):**

```verilog
module rv_hostcpu #(
  parameter DEBUG    = 0,  // 0 VexOsd, 1 VexOsd_DMT + rv_bscane2 (Task 14), 2 VexOsd_DMJ
  parameter EXTRA_WS = 0   // bench only: idle cycles before every request
) (
  input  wire        clk,
  input  wire        reset_n,    // async assert, released synchronously inside
  output reg  [31:2] addr,
  output reg  [31:0] q,          // write data, BE lanes when addr[23]=0
  output reg  [3:0]  sel,        // sel[i] = byte A+i
  output reg         wr,
  output reg         req,
  input  wire        ack,
  input  wire [31:0] d,          // read data, BE lanes when addr[23]=0
  input  wire        irq_ext,    // cfide interrupt, level
  input  wire        irq_timer,  // 0 until Phase 8
  input  wire        irq_soft,   // 0
  input  wire        jtag_tck, input wire jtag_tms, input wire jtag_tdi,
  output wire        jtag_tdo    // DEBUG=2 only; 0 otherwise
);
```

  Behaviour: Global Constraints "Bus contract" and "Lane rule"; plan 3.2.
  iBus: on `iBus_cmd_valid && iBus_cmd_ready` capture `{address[31:5],5'b0}`
  (assert `iBus_cmd_payload_size == 3'd5` in simulation), issue 8 reads
  in address order, pulse `iBus_rsp_valid` with the swapped word on each
  `ack`. dBus: `dBus_cmd_ready` only in the idle state; writes complete on
  `ack` (no rsp); reads pulse `dBus_rsp_ready` with the (swapped unless
  `addr[23]`) word; `dBus_rsp_error = 0`. Arbitration in idle only: dBus
  before iBus. `irq_ext` through one register into `externalInterrupt`.
  Reset: 2-FF synchroniser on `reset_n`; core `reset = rst | ndmreset`,
  `debugReset = rst` (DEBUG != 0). DEBUG=1 instantiates `rv_bscane2` (Task
  14; until then `DEBUG=1` is a `$error`/elaboration failure, documented);
  DEBUG=2 connects the `jtag_*` ports. Optional sim-only `ifdef
  RV_HOSTCPU_STATS`: I$ refill counter and dBus counters (`$display` at
  `$finish` via a task the bench calls) -- used by plan 4.5.
- **L1 bench:** `tb_rv_l1.v` instantiates `rv_hostcpu` and `mem_model.v`:
  BE word memory (byte A+0 at bits 31:24, the lane rule's memory side), 1 MB
  (`0x00000000-0x000FFFFF`), loaded by `$readmemh` from `+HEX=<file>` (one
  32-bit BE word per line, file byte i in lane i, i.e. the romgen order);
  latency per region: `addr < 0x2000` ack `1 + ROMWS` cycles after accept
  (`+ROMWS=` default 1), other memory `1 + WS` (`+WS=` default 3), hw
  window 4 cycles; hw window = the sim MMIO of the Global Constraints plus
  a cfide-like INTERRUPT register at `0xFFFFFFA0` (write bit 0 = enable;
  any access clears pending; `IRQ_AT` events set pending if enabled) driving
  `irq_ext`; reads in the hw window return `{16'h0, value16}`; unmapped hw
  reads return 0. `+TIMEOUT=` cycles (default 20 M) prints `=== TIMEOUT`.
  `DONE` prints `=== PASS` (code 0) or `=== FAIL <code>` and `$finish`es.
  `bus_checker.v` asserts the bus contract every cycle (req drop before ack,
  signal change while req, ack without req) and prints
  `=== BUS VIOLATION ...` -> the run fails.
- **Test programs (write first; each ends by writing DONE):**
  - `lanes.S` (at 0x2000, data at 0x4000 preloaded by the hex file with BE
    words `0x11223344`, `0x55667788`): `lbu` of 0x4000..0x4003 = 0x11, 0x22,
    0x33, 0x44; `lhu 0x4000` = 0x2211; `lw 0x4000` = 0x44332211; `sb`/`sh`/
    `sw` at every legal alignment to 0x5000.. then reload and compare; the
    bench also dumps the BE memory words at 0x5000.. after DONE and the run
    script compares them with an expected list (e.g. `sw 0x12345678` at
    0x5000 -> BE word `0x78563412`; `sb 0xAB` at 0x5005 -> byte lane 1 of
    word 0x5004 = bits 23:16); hw window: `sh` of 0x1234 to `0xFFFFFF0C`
    (sim scratch register) and `lhu` back = 0x1234 unswapped.
  - `refill.c`: 24 functions in 6 KB of code called in a pattern that
    misses the 4 KB I$ (direct-mapped conflicts), summing return values;
    expected sum computed at compile time; also run from the ROM region
    (`.text.rom` placed at 0x100).
  - `fencei.S`: copy a 4-instruction routine (`li a0, 1; ret`) to 0x6000,
    execute it, overwrite it with `li a0, 2; ret` through stores, `fence.i`,
    execute -> 2. Build variant `-DNO_FENCEI` must return 1 (stale line) --
    the teeth check (the run script expects FAIL for that variant).
- **Steps:** write tests and `run.sh` first (they fail: no `rv_hostcpu`);
  implement `rv_hostcpu.v` (registered outputs `addr/q/sel/wr/req`); make
  the tests pass for `WS` 0, 3, 8 and `ROMWS` 0, 1 and `EXTRA_WS` 0, 3
  (`run.sh` passes `-P tb_rv_l1.EXTRA_WS=<n>` to iverilog); README with the
  MMIO map and how to add a program.
- **Commands:** `make -C sim/rv_l1 tests && bash sim/rv_l1/run.sh all`
  (run.sh fans the WS/EXTRA_WS matrix out with `xargs -P`).
- **Pass gate:** every program `=== PASS` in the whole matrix; `fencei
  -DNO_FENCEI` `=== FAIL` (teeth); zero `BUS VIOLATION`; `rv_hostcpu.v`
  parses with `iverilog -g2005` (Verilog-2005 subset for Quartus).

### Task 5: L1 firmware-unit programs (`cue_emu`, `cdaudio_emu`, `atapi_emu`)

- **Phase / depends on:** plan 2.2 / Task 4.
- **Model:** Sonnet.
- **Files (create):** `sim/rv_l1/sw/syscalls.c` (newlib-nano: `_write` ->
  UART `0xFFFFFFF0` byte stores, `_sbrk` on a heap after `_end`, `_exit` ->
  DONE, stubs for `_close/_fstat/_isatty/_lseek/_read`), `sim/rv_l1/sw/l1_newlib.ld`
  (text at 0x2000, stack top 0xF0000, heap between), `sim/rv_l1/prog/Makefile`.
  Modify `sim/rv_l1/run.sh` (target `units`).
- **Interface:** `make -C sim/rv_l1/prog FWDIR=../../../fw/ctrl_832` builds
  `atapi_emu.hex`, `cue_emu.hex`, `cdaudio_emu.hex` from
  `$(FWDIR)/test/emu/<name>.c` + `$(FWDIR)/{atapi,cue,cdaudio}.c` (link sets
  as in `fw/ctrl_832/test/emu/Makefile`) with `RV_ARCH -Os -funsigned-char
  --specs=nano.specs -I$(FWDIR)`; `FWDIR` switches to `fw/ctrl_rv` in Phase 3.
  `main` returning 0 -> `_exit(0)`; the bench treats the program's last
  line (`PASS`/`FAIL n`) as the verdict (`run.sh` greps like the emu
  Makefile: no `^FAIL`, a line exactly `PASS`).
- **Test first:** the programs are the tests; first build `cue_emu` and
  confirm a deliberately broken expectation (edit a copy) prints `FAIL`.
- **Steps:** syscalls + linker script; Makefile; run all three at WS=3;
  record cycles per program in `sim/rv_l1/README.md`.
- **Commands:** `make -C sim/rv_l1/prog && bash sim/rv_l1/run.sh units`
- **Pass gate:** three `PASS`, each within the default timeout; the 832
  tree has no modified file (`git status fw/ctrl_832` clean).

### Task 6: Bridge rewrite -- RISC-V generate branch and four-phase hw handshake

- **Phase / depends on:** plan 1.4 / Task 4.
- **Model:** Opus.
- **Files (modify):** `rtl/host/832_bridge.vhd`. (Create)
  `sim/host_bridge/stub/OSDBoot_rv_ROM_stub.vhd` (a 2-word ROM: `j 0` loop)
  for elaboration checks until Task 7 builds real test ROMs.
- **Interface:** Global Constraints "VHDL bridge generics / ports". Both CPUs
  through component declarations (`eightthirtytwo_cpu`, `OSDBoot_832_ROM`,
  `debug_bridge_jtag`, `rv_hostcpu`, `OSDBoot_rv_ROM`) so a compile without
  the other CPU's sources elaborates. `gen832: if not cpu_riscv generate`
  (832 + its ROM + debug bridge as today), `genrv: if cpu_riscv generate`
  (`rv_hostcpu` with `DEBUG => rv_debug`, `EXTRA_WS => rv_extra_ws`,
  `irq_ext => interrupt`, `irq_timer/irq_soft => '0'`, `jtag_*` <->
  `rv_jtag_*`; `OSDBoot_rv_ROM` with `maxAddrBitBRAM => 12`, same port map
  as the 832 ROM). Both branches drive the same `cpu_req/cpu_addr/cpu_q/
  cpu_sel/cpu_wr` and consume `cpu_ack/cpu_d`; `rom_d` from the selected
  ROM. With `cpu_riscv = false`, `rv_jtag_tdo <= '0'`.
- **State machine:** `type bridgestates is (waiting, ram, hw, hw_release,
  rom)`. In `hw`: on `hw_ack='1'` -> `cpu_d <= x"0000" & hw_d`, `wr <= '0'`,
  `hw_req <= '0'`, `cpu_ack <= '1'`, `state <= hw_release; -- 4PHASE`
  (exactly one line in the file carries the marker `-- 4PHASE`, so the L2
  mutant can `sed` it to `state <= waiting;`). In `hw_release`: `if
  hw_ack='0' then state <= waiting`. Everything else as today, including the
  per-cycle `addr<=cpu_addr; q<=cpu_q; sel<=cpu_sel; wr<=cpu_wr` registering
  and the signal names `hw_req`, `wr`.
- **Test first:** run `sim/spi_cdc/host832/run.sh` on the unmodified tree
  and keep its output (baseline); add to `sim/spi_cdc/host832/run.sh` only
  what the component change needs (nothing expected).
- **Steps:** edit; rerun host832 (all 7 default configurations); xvhdl +
  xelab a 20-line `sim/host_bridge/stub/tb_elab_rv.vhd` (bridge with
  `cpu_riscv => true`, stub ROM, `rv_hostcpu.v`, `VexOsd.v`, `hostcache.v`,
  `dpram_inf_generic.v`) to prove the RV branch elaborates; `grep -c '4PHASE'
  rtl/host/832_bridge.vhd` = 1.
- **Commands:**
  `E832=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo/RTL RUNTAG=t6 bash sim/spi_cdc/host832/run.sh`
  and the elaboration commands written into `sim/host_bridge/stub/elab.sh`.
- **Pass gate:** host832: every configuration `=== PASS` (same set as the
  baseline); `elab.sh` exits 0; marker count 1; diff of the 832 path limited
  to the component declarations, `hw_release` and the new generics/ports.

### Task 7: L2 bench `sim/host_bridge/` -- lanes, hw offsets, back-to-back, SPI busy

- **Phase / depends on:** plan 1.5 / Tasks 1, 6.
- **Model:** Opus.
- **Files (create):** `sim/host_bridge/tb_host_bridge.v`,
  `sim/host_bridge/sdram_host_model.v`, `sim/host_bridge/run.sh`,
  `sim/host_bridge/Makefile` (test ROMs), `sim/host_bridge/sw/*.S|*.c`,
  `sim/host_bridge/sw/crt0_rom.S` (reset at 0x0: `sp = 0x2000`, clear
  `.bss`, `call main`, DONE with `main`'s return value),
  `sim/host_bridge/sw/rom.ld` (all sections in 0x0-0x1FFF), `sim/host_bridge/README.md`,
  `sim/host_bridge/.gitignore`.
- **Interfaces:** `tb_host_bridge.v` = `EightThirtyTwo_Bridge
  #(.cpu_riscv(1), .rv_extra_ws(EXTRA_WS))` (bench parameter, set with
  `xelab -generic_top EXTRA_WS=<n>`, default 0) + real
  `cfide` (generics as host832) + real `hostcache.v` (inside the bridge) +
  `sdram_host_model.v`: halfword SDRAM, latency `+SLAT=` (default 8) +
  `+SJIT=`, the 8-halfword burst order of tb_832_dmode, **write lanes per
  the Lane rule** (`sel[0]` -> `hostWR[31:24]` -> upper byte of the lower
  halfword), base 0 (host addresses), preload `+SDRAM_HEX=` (BE 32-bit
  words). Test ROM: `make` builds each test to `OSDBoot_rv_ROM.vhd` in the
  run directory with `fw/romgen/romgen` + `fw/ctrl_boot_832/rom_prologue.vhd`
  / `rom_epilogue.vhd` (read-only; `sed 's/soc_firmware/OSDBoot_rv_ROM/'` as
  the 832 Makefile does). `run.sh` copies RTL into the run directory, applies
  the hostcache `#1` fix of host832/run.sh, compiles once per ROM (xvlog/
  xvhdl/xelab), runs xsim. Bench snoops hw writes at the bridge's
  `addr/q/wr/hw_req`: UART `0xFFFFFFF0` -> character log, DONE `0xFFFFFF04`
  -> verdict. SPI: a byte-capture slave on `sd_cs[1]`/`sd_clk`/`sd_do`
  returning a scripted MISO byte stream.
- **Tests (write first, each a ROM program printing PASS/FAIL):**
  - `t_lanes`: stores of every width/alignment to SDRAM `0x3000..` and to
    the boot BRAM `0x1800..`, read back through the CPU; the bench then
    checks the SDRAM model halfwords (`sw 0x12345678` at 0x3000 -> halfwords
    `0x7856`, `0x3412`; `sb 0xAB` at 0x3003 -> low byte of the second
    halfword) -- BE byte-invariance as the 68k sees it.
  - `t_hwoff`: `sh 1, 0xFFFFFFC0` (PLATFORM) and the matching cfide output
    pin (find the bit in cfide.vhd's platform register; if PLATFORM has no
    visible output, use AUDIO `0xFFFFFFB0` -> `audio_ena`); `lhu 0xFFFFFFD0`
    twice (TIMER advances); SPI: `sb 0x02, 0xFFFFFFE4` -> `sd_cs` pattern,
    `sb 0x5A, 0xFFFFFFE0` -> captured MOSI byte 0x5A, `lbu 0xFFFFFFE0` ->
    the scripted MISO byte.
  - `t_b2b`: 64 back-to-back `sh` to PLATFORM/AUDIO alternating 1/0 in
    straight-line asm (no other instructions between); the bench counts
    output toggles = 64 and the program reads back the last value; same for
    32 back-to-back SPI CS writes (CS pattern sequence logged = written).
  - `t_spibusy`: `SPI_slow()` (`sb 0xEF, 0xFFFFFFE8`), then 8 consecutive
    `sb` to SPI DATA; bench assertion: cfide never accepts a DATA write
    while its `SD_busy` is high (hierarchical reference), and all 8 bytes
    arrive in order.
  - Mutant: `run.sh mutant` seds the `-- 4PHASE` line to `state <=
    waiting;` in the run copy and reruns `t_b2b`.
- **Steps:** model + bench + `t_lanes` first; then the rest; then the
  mutant; README with the plusargs, the lane-rule note and the per-test
  expectations.
- **Commands:** `RUNTAG=t7 bash sim/host_bridge/run.sh all && RUNTAG=t7m bash sim/host_bridge/run.sh mutant`
- **Pass gate:** all four tests `=== PASS` for `SLAT` 2, 8, 20 and `SJIT`
  0, 8; the mutant run of `t_b2b` `=== FAIL` (if it passes, the bench has no
  teeth: find out why -- e.g. the stores are not back-to-back on the bus --
  and fix the test, not the gate).

### Task 8: OOC of the whole `hostcpu` (Vivado 2023.2)

- **Phase / depends on:** plan 1.3 / Tasks 3, 6, 7.
- **Model:** Sonnet.
- **Files (create/modify):** `tools/vivado/ooc_hostcpu/run_bridge.tcl`,
  `tools/vivado/ooc_hostcpu/go_bridge.sh`; append to
  `findings/osd-riscv/ooc-2023.2.md`; update `doc/osd-riscv-plan.md`
  section 4 numbers (one paragraph, measured values replacing estimates).
- **Interfaces:** top = `EightThirtyTwo_Bridge` OOC with generics
  `cpu_riscv`, `rv_debug`; sources: `832_bridge.vhd`, `rv_hostcpu.v`,
  `VexOsd*.v`, `hostcache.v`, `dpram_inf_generic.v`, the `t_lanes`
  `OSDBoot_rv_ROM.vhd` from Task 7 (any 8 KB ROM image will do), and for the
  832 reference row the EightThirtyTwo RTL from `E832` + `OSDBoot_832_ROM.vhd`
  + `debug_bridge_stub.vhd`. Clock `clk` 8.815 ns. All ports unconstrained
  except the clock (OOC); `-flatten_hierarchy rebuilt`.
- **Test first:** run the 832 reference row first and compare with the
  stage figure (hostcpu 912 LUT / 944 FF, plan 1.3); the flow is trusted
  only if it lands within +/-10 %.
- **Steps:** runs `832` (`cpu_riscv=false`), `rv0` (`cpu_riscv=true,
  rv_debug=0`), `rv2` (`rv_debug=2`); `get_cells -hier -filter {NAME =~
  *hw_req_reg*}` and `*wr_reg*` printed in the log; table into the findings
  file; plan section 4 updated.
- **Commands:** `cd tools/vivado/ooc_hostcpu && ./go_bridge.sh 832 && ./go_bridge.sh rv0 & ./go_bridge.sh rv2 & wait`
- **Pass gate:** 832 row within +/-10 % of 912 LUT; `rv0` <= 1,750 LUT,
  WNS >= +0.5 ns; cells `hw_req_reg` and `wr_reg` present in every run.
  A miss: record and stop for a decision (do not tune).

### Task 9: SD card SPI model and FAT16 card image tool

- **Phase / depends on:** plan 2.3 / none (iverilog only).
- **Model:** Sonnet.
- **Files (create):** `sim/common/sd_spi_model.v`,
  `sim/common/tb_sd_spi_model.v`, `sim/common/run_sd_model.sh`,
  `tools/sim/mkcard.sh`, `tools/sim/README.md`.
- **Interfaces:** `module sd_spi_model #(parameter IMG_SECTORS = 65536)
  (input cs_n, input sck, input mosi, output reg miso)`; plusargs
  `+SD_IMG=<raw image>` (loaded with `$fopen`/`$fread` into a byte array at
  time 0, written back with `+SD_SAVE=<file>` at `$finish` via a task the
  bench calls), `+SD_TOKEN_DLY=<bytes>` (0xFF bytes before the data token,
  default 4), `+SD_BUSY=<bytes>` (busy after a write, default 8). SPI mode 0,
  MSB first, commands CMD0, CMD8 (echo 0x1AA), CMD55/ACMD41 (idle for the
  first `+SD_INIT_POLLS=` default 2 polls, then ready), CMD58 (OCR with
  CCS=1, SDHC block addressing), CMD16, CMD17, CMD18 + CMD12, CMD24, CMD25
  (+ stop token), CRC ignored, R1 after 1-8 0xFF bytes (`+SD_NCR=`, default
  1). Logs every command with `+SD_LOG=1`. The command sequence must match
  what `fw/ctrl_boot_832/spi.c` and `fw/ctrl_832/mmc.c` send (read both;
  list the sequence in the README). Verilog-2005, works in iverilog and
  xsim. `mkcard.sh <img> <size_MB> <file>...`: MBR with one FAT16
  partition at LBA 2048 (`sfdisk`), `mkfs.fat -F 16` on the partition via
  an offset loop or `mformat`, `mcopy -i <img>@@<offset>` the files.
- **Test first:** `tb_sd_spi_model.v`: a Verilog SPI master task that sends
  the boot ROM's init sequence, reads LBA 0 (checks 0x55AA at 510/511 and
  the partition start 2048), reads the FAT16 boot sector, then reads a
  4 KB file's sectors with CMD18 and compares with the file bytes (the run
  script makes the image with `mkcard.sh` and passes the file as a hex dump
  for the compare); also CMD24 write + CMD17 read-back.
- **Steps:** mkcard; bench; model; README.
- **Commands:** `bash sim/common/run_sd_model.sh`
- **Pass gate:** `=== PASS` with `+SD_TOKEN_DLY` 0, 4, 200 and `+SD_NCR` 1,
  8; the read-back of the CMD24 write matches.

### Task 10: Boot ROM port `fw/ctrl_boot_rv`

- **Phase / depends on:** plan 2.4 / Tasks 1, 9.
- **Model:** Sonnet.
- **Files (create):** `fw/ctrl_boot_rv/` with copies of
  `fw/ctrl_boot_832/{boot.c,bootdiag.h,bootdiag.s,checksum.c,checksum.h,hexdump.c,hexdump.h,minfat.c,minfat.h,small_printf.h,spi.c,spi.h,swap.c,swap.h,uart.c,uart.h,rom_prologue.vhd,rom_epilogue.vhd}`
  (record the source commit in `fw/ctrl_boot_rv/README.md`), new
  `crt0.S`, `boot.ld`, `Makefile`, `test/minfat_test.c`, `test/Makefile`;
  generated and committed `OSDBoot_rv.bin`, `OSDBoot_rv_ROM.vhd`.
- **Changes vs the 832 copy:** `spi.h` `SPIBASE 0xffffffe0`, `HW_SPI_DATA
  0x00`, `HW_SPI_CS 0x04`, `HW_SPI_SPEED 0x08`, `PLATFORM` at `0xffffffc0`;
  `uart.h` `REG_UART 0x00`; `uart.c` `puts(const char *)` prototype
  consistent with the header; `OSDNAME="RV32OSDABIN"` (file `RV32OSDA.BIN`);
  `swap.h` adds `le16/le32` (identity when `__BYTE_ORDER__ ==
  __ORDER_LITTLE_ENDIAN__`) and `minfat.c` uses them where it used
  `SwapBB/SwapBBBB` on on-disk LE fields (lines ~138, 239, 279-280); the MBR
  signature test keeps both branches; `pe->startlba` (MBR offset 454,
  misaligned for a 32-bit load -- it would trap) is read byte-wise;
  `_boot()` executes `fence.i` before the call through `prg_start`
  (`(void (*)(void))prg_start`). `crt0.S`: at 0x0 `j _start`; at 0x20
  `boot_trap` (save nothing, read `mcause/mepc/mtval`, print `TRAP <mcause>
  <mepc> <mtval>` through `putchar`, `ErrorCode(0xf0f)` loop); `_start`:
  `sp = 0x2000`, `gp`, `mtvec = boot_trap`, clear `.bss`, `call main`.
  `boot.ld`: everything in 0x0-0x1FFF, `.text.start` first, `.data` in place
  (the BRAM is initialised RAM), `ASSERT(_end <= 0x1C00, ...)` (>= 1 KB
  stack). `Makefile`: includes `tools/riscv/toolchain.mk`, `RV_CFLAGS_FW` (no
  `-DSTANDALONE`), `-Dprg_start=0x2000 -DOSDNAME=\"RV32OSDABIN\"`;
  targets `OSDBoot_rv.bin` (objcopy -O binary), `OSDBoot_rv_ROM.vhd` (romgen
  as the 832 Makefile), `size`, `im` (an rv32im build to `build_im/`,
  size printed, not committed), `check` (no A-extension opcodes in the
  disassembly). `bootdiag.h` is the committed 68k byte array (vasm optional:
  rebuild only if `bootdiag.s` is newer and vasm exists).
- **Test first:** `test/minfat_test.c` (host gcc, `-fsanitize=address,undefined`):
  links `minfat.c` + `swap.c` with a mock `sd_read_sector()` reading a card
  image made by `tools/sim/mkcard.sh` (holding `RV32OSDA.BIN` = 3000 random
  bytes and two decoy files), calls `FindDrive()` and `LoadFile(OSDNAME,
  buf)`, compares the bytes; a second image without the file -> `LoadFile`
  returns 0; a superfloppy image (no MBR) also works.
- **Steps:** copy; test; edits; build; check; commit ROM VHDL with sources.
- **Commands:** `make -C fw/ctrl_boot_rv/test && make -C fw/ctrl_boot_rv && make -C fw/ctrl_boot_rv check im size`
- **Pass gate:** host test PASS (three images); `OSDBoot_rv.bin` text +
  data + bss <= 6 KB (`size`), `ASSERT` holds; rv32im build size recorded in
  README; `check` finds no `lr.w/sc.w/amo*`; rebuilding twice gives a
  byte-identical `OSDBoot_rv_ROM.vhd`.

### Task 11: Trap and IRQ entry `fw/ctrl_rv/arch`

- **Phase / depends on:** plan 2.5 / Tasks 4, 5, 7.
- **Model:** Opus.
- **Files (create):** `fw/ctrl_rv/arch/crt0.S`, `fw/ctrl_rv/arch/trap.S`,
  `fw/ctrl_rv/arch/trap.c`, `fw/ctrl_rv/arch/irq.c`,
  `fw/ctrl_rv/arch/irq.h`, `fw/ctrl_rv/arch/csr.h`,
  `fw/ctrl_rv/arch/firmware.ld`, `fw/ctrl_rv/arch/README.md`; tests
  `sim/rv_l1/tests/irq_sig.S`, `sim/rv_l1/tests/irq_c.c`,
  `sim/rv_l1/tests/exc.c`; L2 test `sim/host_bridge/sw/t_irq.c`.
- **Interfaces (plan 6.2):** `crt0.S` `_start` in `.text.start` (linked
  first at 0x2000): `sp = __stack_top` (0x2000), `gp`, clear `.bss`, `mtvec
  = trap_entry`, run `__init_array_start..end`, set `mie.MEIE`, set
  `mstatus.MIE`, `call main`, then loop. `trap.S` `trap_entry` (4-byte
  aligned): `addi sp, sp, -64`; save `ra, t0-t6, a0-a7`; `csrr a0, mcause;
  csrr a1, mepc; csrr a2, mtval; call rv_trap`; restore; `addi sp, sp, 64;
  mret`. `trap.c`: `void rv_trap(uint32_t mcause, uint32_t mepc, uint32_t
  mtval)`: `mcause == 0x8000000B` -> `(*_InterruptVector)()`; else
  `rv_exception(mcause, mepc, mtval)` (weak; default prints `EXC mcause=..
  mepc=.. mtval=..` via a weak `rv_putc` writing `0xFFFFFFF0`, then spins).
  `irq.h`/`irq.c`: `extern void (*volatile _InterruptVector)(void)`,
  `void SetIntHandler(void (*h)(void))` (writes `HW_INTERRUPT = 0`, then the
  pointer), `int GetInterrupts(void)` (32-bit read of `0xFFFFFFA0`),
  `void EnableInterrupts(void)` (write 1), `void DisableInterrupts(void)`
  (write 0), `static inline uint32_t irq_save(void)` (`csrrci t, mstatus,
  8`), `static inline void irq_restore(uint32_t)`; a default handler that
  calls `GetInterrupts()`. `firmware.ld`: `ORIGIN 0x2000`, `.text.start`
  first, `.init_array` kept, `__stack_top = 0x2000`, `ASSERT(_end <
  0x70000)`.
- **Test first:**
  - `irq_sig.S` (L1): fill `x1..x31` (except `sp`) with distinct patterns,
    enable the L1 INTERRUPT register, request 50 `IRQ_AT` events at
    pseudo-random distances while spinning in a loop that checks all
    registers every iteration; the handler (C, via `SetIntHandler`) counts
    and clears; PASS if count = 50 and no register changed.
  - `irq_c.c` (L1): `DisableInterrupts()` masks (event while disabled is
    lost exactly as cfide does: the line is gated by enable at event time),
    `irq_save/restore` nesting, `SetIntHandler` switch while running.
  - `exc.c` (L1): an illegal instruction (`.word 0xffffffff`, a 32-bit encoding; not `.word 0`,
    which is two 16-bit `c.illegal`, nor `unimp`, a CSR access that the
    `small` CSR config does not trap), a misaligned `lw`,
    a misaligned `sh`; a `rv_exception` override records `mcause` (2, 4, 6),
    `mepc`, `mtval`, skips the instruction (`mepc += 4` or 2 for compressed
    -- the test uses 32-bit encodings) and returns; PASS if all three seen.
  - `t_irq.c` (L2, real cfide): enable via `0xFFFFFFA0`, the bench pulses
    `vbl_int` 20 times (one clk_28 cycle each, 2000 clk_114 apart); handler
    counts via `GetInterrupts()`; PASS if 20.
- **Steps:** tests; arch files; L1 builds link the arch files with
  `firmware.ld`; L2 test ROM links the same files but against a ROM layout
  (`sim/host_bridge/sw/rom.ld`), so `crt0.S` must not assume 0x2000 beyond
  the linker symbols.
- **Commands:** `make -C sim/rv_l1 tests && bash sim/rv_l1/run.sh irq &&
  RUNTAG=t11 bash sim/host_bridge/run.sh t_irq`
- **Pass gate:** `irq_sig`, `irq_c`, `exc` PASS at WS 0/3/8; `t_irq` PASS at
  SLAT 8; a mutant `trap.S` that skips restoring `t3` fails `irq_sig`
  (teeth, run once and recorded in the README).

### Task 12: End-to-end boot in L2 (boot ROM loads `RV32OSDA.BIN` from a card image)

- **Phase / depends on:** plan 2.6 / Tasks 7, 9, 10, 11.
- **Model:** Opus.
- **Files (create/modify):** `sim/host_bridge/boot/fwtest.c` (test
  firmware: prints `FW OK`, runs the `t_irq` check with `vbl_int`, prints
  `IRQ <n>`, writes DONE), `sim/host_bridge/boot/Makefile` (builds
  `RV32OSDA.BIN` with `fw/ctrl_rv/arch` + `firmware.ld`, objcopy binary),
  `sim/host_bridge/run.sh` target `boot`; `tb_host_bridge.v` gains the SD
  model on `sd_cs[1]` (`ifdef SDCARD`, so Task 7 tests still run without
  it) and the real ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`.
- **Test first:** the bench's expected UART log
  (`sim/host_bridge/boot/expect.txt`): the boot ROM's lines from
  `Initializing SD card` through `Hunting for partition`, then `FW OK`,
  `IRQ 20`; and the negative case (card without the file): `Can't load
  firmware` and an `ErrorCode` write pattern, no DONE (the run script
  stops it at a cycle limit and checks the log).
- **Steps:** build the card with `tools/sim/mkcard.sh` (8 MB, FAT16,
  `RV32OSDA.BIN` + `832OSDAD.BIN` decoy); run with `SPI_slow` real timing
  (expect ~1-3 M clk_114 cycles for init at the slow SPI clock; measure);
  record the boot cycle count and the I$ refill count (`RV_HOSTCPU_STATS`).
- **Commands:** `make -C fw/ctrl_boot_rv && make -C sim/host_bridge/boot &&
  RUNTAG=t12 bash sim/host_bridge/run.sh boot && RUNTAG=t12n bash sim/host_bridge/run.sh boot_nofile`
- **Pass gate:** log matches `expect.txt` line for line (positive), negative
  case shows the error path; no `TRAP`/`EXC` line; the run uses the committed
  `OSDBoot_rv_ROM.vhd` unmodified.

### Task 13: Dhrystone `fw/dhrystone_rv`

- **Phase / depends on:** plan 2.7 / Tasks 4, 7, 11.
- **Model:** Sonnet.
- **Files (create):** `fw/dhrystone_rv/` with `dhry_1.c`, `dhry_2.c`,
  `dhry.h` copied from `fw/dhrystone_832` (source commit in README),
  `hw.c`/`hw.h` (time + output: `-DL1` -> TIME stamps at `0xFFFFFF00` and
  UART char out, `Number_Of_Runs = 100`, DONE at the end; board build ->
  cfide TIMER `0xFFFFFFD0` and UART `0xFFFFFFF0` (byte writes, no polling:
  see the Global Constraints' UART entry),
  `Number_Of_Runs` from a define, default 200000), `Makefile` (targets
  `l1_O2.hex`, `l1_Os.hex`, `RV32OSDA.BIN` for the board, linked with
  `fw/ctrl_rv/arch` + `firmware.ld`), `README.md`;
  `findings/osd-riscv/dhrystone-rv.md`; `sim/rv_l1/run.sh` target `dhry`;
  `sim/host_bridge/run.sh` target `dhry` (ROM = a 3-instruction stub
  jumping to 0x2000, SDRAM preloaded with `+SDRAM_HEX=`).
- **Test first:** the L1 run must pass Dhrystone's own result checks (the
  program prints them; the run script greps "should be" mismatches as in
  the 832 bench).
- **Steps:** build; L1 `WS=3` for `-O2` and `-Os`; L2 at `SLAT` 8 (real
  bridge + hostcache); write the findings table: cycles per 100 runs, DMIPS/
  MHz = 1e8 / (cycles x 1757), x 832 (bench: 714,342 cycles at WS=3 per
  tiny-cores.md), and the tiny-cores VexRiscv IMC + 4 KB I$ reference
  (101,087 cycles; that bench's bus had no CPU-block registering).
- **Commands:** `make -C fw/dhrystone_rv && bash sim/rv_l1/run.sh dhry &&
  RUNTAG=t13 bash sim/host_bridge/run.sh dhry`
- **Pass gate:** Dhrystone checks pass; L1 `-O2` WS=3 <= 142,868 cycles
  (>= 5.0x the 832's 714,342); L2 number recorded. Above the bound: record
  and report the per-access overhead of `rv_hostcpu` (it is a Phase 7 item,
  not a reason to tune here).

### Task 14: Debug -- DM smoke test (pin TAP) in L1, BSCANE2 wrapper, OpenOCD configs

- **Phase / depends on:** plan 2.8 / Tasks 2, 4. Not blocking Phase 3.
- **Model:** Opus.
- **Files (create/modify):** `rtl/host/xilinx/rv_bscane2.v` (module
  `rv_bscane2 (output tck, output tdi, output sel, output capture, output
  shift, output update, output reset, input tdo)` around `BSCANE2
  #(.JTAG_CHAIN(4))`); `rtl/host/rv_hostcpu.v` (`DEBUG=1` branch wiring per
  the Task 2 README mapping); `sim/rv_l1/jtag_bfm.v`,
  `sim/rv_l1/tests/dm_smoke.v` (or a bench mode `+DM_SMOKE`);
  `tools/openocd/minimig-rv-pins.cfg`, `tools/openocd/minimig-rv-bscan.cfg`,
  `tools/openocd/README.md`.
- **Interfaces:** JTAG BFM tasks `jtag_reset`, `jtag_ir(width 5, value)`,
  `jtag_dr(n, in, out)` at TCK = 50 ns (async to clk). DMI access through
  the DTM's `dmi` register (IR 0x11, 41 bits: addr 7 / data 32 / op 2) and
  `dtmcs` (IR 0x10). OpenOCD configs as plan 3.8 (pins: `jtag newtap riscv
  cpu -irlen 5 -expected-id 0x10002FFF`; bscan: `source [find
  cpld/xilinx-xc7.cfg]`, `riscv use_bscan_tunnel 6 1`), adapter section left
  as an `ADAPTER` include the user picks (ftdi example for a Digilent HS2),
  README states that OpenOCD 0.12.0 here has no driver for the Platform
  Cable USB II (03fd:0008).
- **Test first (L1, `DEBUG=2`, a program spinning in a counter loop):**
  read IDCODE = `0x10002FFF`; `dtmcs` version = 1; write `dmcontrol.dmactive
  = 1`; `haltreq` -> `dmstatus.allhalted = 1`; abstract command read of
  `x10` (access register 0x100A) returns the loop counter's register value
  (bench knows the program); `resumereq` -> `allrunning`; the counter keeps
  incrementing (a DONE after N more iterations).
- **Steps:** BFM + test; `rv_bscane2.v` + `DEBUG=1` wiring; elaborate
  `DEBUG=1` in xsim against `unisim` (`xelab ... -L unisims_ver`) to prove it
  connects (no simulation of the tunnel protocol); re-run Task 8's OOC with
  `rv1` (adds `rv_bscane2.v`) and append the row.
- **Commands:** `bash sim/rv_l1/run.sh dm_smoke && bash sim/host_bridge/stub/elab.sh dmt &&
  (cd tools/vivado/ooc_hostcpu && ./go_bridge.sh rv1)`
- **Pass gate:** `dm_smoke` `=== PASS`; `DEBUG=1` elaborates; `rv1` OOC row
  recorded; `rtl/host/host.qip` does not list `rv_bscane2.v`; hardware test
  stays plan 5.4.

### Task 15: Dependency map of phases 3-9 (ask Paul for the phase-8 order)

- **Phase / depends on:** plan 2.9 / Tasks 1-14 done (or at least 12).
- **Model:** Sonnet (records the answer; the question goes to Paul through
  the orchestrator).
- **Files (modify after Paul answers):** `doc/osd-riscv-plan.md` decision
  12.9 and section 8 Phase 8 order.
- **Dependency map (what each later step needs):**

```
Phase 3  firmware 1:1 (fw/ctrl_rv)
  3.1 copy + Makefile ............ needs T1 toolchain, T11 arch
  3.2 gcc fixes, I/O offsets ..... needs 3.1
  3.3 endianness 5.2 items 1-8 ... needs 3.2; goldens from the 832 build
  3.4 config LE + cfgconv ........ needs 3.2 (independent of 3.3)
  3.5 vbcc workaround removal .... needs 3.3 (diff review)
  3.6 host unit tests ............ can start with 3.2; goldens from the 832 build
  3.7 stack high-water, clang .... needs 3.1
Phase 4  co-simulation
  4.1 L3 bench ................... needs T9 SD model (+CMD18/24/25 under load), T12 boot,
                                   3.x firmware, Amiga-side model, gayle/paula models
  4.2 differential 832 vs RV ..... needs 4.1 + host832 flow + 832 firmware on the card
  4.3 trap log empty ............. needs 4.1
  4.4 speed (SPI loop, ring fill)  needs 4.1   --> decides whether P5 is needed
  4.5 I$ hit rate ................ needs 4.1 + RV_HOSTCPU_STATS (T4) --> 8 KB I$ or not
  4.6 832 Dhrystone on the board . needs nothing (current bitstream)
Phase 5  build + A/B .............. needs 4.x green; 5.2 only if 5.1 misses timing
  5.4 debug bring-up ............. needs 5.1 + T14 + an OpenOCD-supported cable
Phase 6  board parity + stress .... needs 5.3
Phase 7  performance .............. needs 6; 7.2 options need 4.5/7.1 numbers
Phase 8  peripherals (each: L2/L3 bench, build, board, merge)
  8.0 IRQ pending/mask on MEI .... needs 6 (A/B reference stable); prerequisite for
                                   any per-source IRQ (P1, P3 RX, P4, P5 done, P6, P7)
  P2  timer on MTI ............... independent of 8.0 (MTI is its own line)
  P4  I2C INT routing ............ needs 8.0 (one bit), ~free
  P1  request IRQ + OSD ready .... needs 8.0; minimig output ports; closes 7.1 item 2
  P3  UART RX FIFO ............... needs 8.0 for RX IRQ (polling works without)
  P5  SPI FIFO ................... independent of 8.0 (polling) unless "done" IRQ;
                                   only if 4.4/7.1 show the byte loop matters
  P6  sector DMA ................. needs P5's engine (shares the SPI master) + measurements
  P7  CD-DA ring DMA ............. needs the bridge DMA arbiter (plan 3.3.5), hostcache
                                   coherency rule, P2 tick (half flip timing); only if
                                   underruns remain after P1/P5
  8.7 firmware yield points ...... needs only 6 (no hardware)
Phase 9  retire the 832 ........... needs 6 parity + whatever of 8 Paul wants before it
```

- **Questions for Paul (the task's deliverable):** (1) Phase 8 order --
  proposal: 8.0 -> P1 -> P2 + P4 -> P3 -> (P5 if 4.4 says so) -> P6/P7 on
  evidence; alternatives: P2 first (no 8.0 dependency), or P5 first if the
  4.4 ring-fill number is poor. (2) Is any Phase 8 step required before
  Phase 9 retires the 832, or can 9 follow 6/7 directly? (3) Debug cable for
  5.4: buy an FTDI-based cable (Digilent HS2/HS3) for the BSCANE2 tunnel, or
  use four header pins with any OpenOCD adapter?
- **Steps:** present the map and questions; record the answers in plan
  12.9 and section 8; no other edits.
- **Commands:** none (documentation).
- **Pass gate:** Paul's answers recorded verbatim (date) in plan 12.9; plan
  section 8 Phase 8 list reordered to match.
