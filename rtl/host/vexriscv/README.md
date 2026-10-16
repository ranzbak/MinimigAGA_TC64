# VexRiscv OSD host CPU (generated)

The Minimig OSD host CPU is a VexRiscv RV32IMC with a 4 KB direct-mapped
instruction cache, an uncached data bus and standard M-mode traps. It is
generated from `GenOsd.scala` by SpinalHDL. The generated Verilog is committed,
so building the FPGA needs no Java, Scala or sbt. You only need them to
change the CPU configuration.

| File | What it is |
|---|---|
| `GenOsd.scala` | Source of truth: the plugin list for all three variants |
| `regen.sh` | Clones VexRiscv at the pin, runs the generator, copies the Verilog, runs the gate checks (`--check` runs only the checks) |
| `VERSION` | Pin (commit, SpinalHDL, Scala, sbt, JDK) and the sha256 of each generated file |
| `VexOsd.v` | Generated core, no debug (`rv_debug = 0`) |
| `VexOsd_DMT.v` | Generated core + RISC-V Debug Module, DTM tunnelled through an external Xilinx `BSCANE2` (`rv_debug = 1`) |
| `VexOsd_DMJ.v` | Generated core + RISC-V Debug Module with its own JTAG TAP on four pins (`rv_debug = 2`) |

The generated files are plain Verilog-2001 with no vendor primitives (the
`--check` gate greps for them), so they build on Vivado and Quartus. They carry
synthesis attributes only: `keep`/`syn_keep` on two execute-stage operands
(all variants); in the debug variants also `async_reg` and
`altera_attribute = "-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW"` on the
clock-crossing synchronisers, `keep_hierarchy` on the `BufferCC` instances and
`ram_style = "distributed"` on a 2-word memory. Each tool ignores the
attributes of the other vendor. All submodules are prefixed with the top
name (`VexOsd_InstructionCache`, `VexOsd_DMT_DebugModule`, ...; SpinalHDL
`privateNamespace`), so all three files can be in one source list.

## Rule

**Edit `GenOsd.scala`, run `regen.sh`, commit `GenOsd.scala`, the three
`VexOsd*.v` and `VERSION` together.** Never edit the `.v` files by hand:
`regen.sh --check` compares their sha256 with `VERSION` and fails.

## Configuration

`GenOsd.scala`, VexRiscv plugins:

* `IBusCachedPlugin`: reset vector `0x00000000`, no branch prediction, RVC
  (`compressedGen`, `injectorStage`), 4096 B, 32 B lines, 1 way,
  `twoCycleCache`.
* `DBusSimplePlugin`: misaligned load/store trap on, no access-fault trap.
* `CsrPlugin`: `CsrPluginConfig.small(0x20)` (boot `mtvec` = `0x20`) with
  `mtvec` read/write; `withPrivilegedDebug` in the debug variants.
* `DecoderSimplePlugin`: illegal-instruction trap on.
* `RegFilePlugin` SYNC, `IntAluPlugin`, `SrcPlugin`, `LightShifterPlugin`,
  `HazardSimplePlugin` (full bypass), `MulPlugin`,
  `MulDivIterativePlugin` (divide only, 1 bit/cycle), `BranchPlugin` (late).
* Debug variants: `EmbeddedRiscvJtag`,
  `DebugTransportModuleParameter(addressWidth = 7, version = 1, idle = 7)`,
  debug clock domain = `clk` with its own reset `debugReset`.
  `VexOsd_DMT`: `withTunneling = true, withTap = false`, JTAG clock domain
  `jtag_tck`. `VexOsd_DMJ`: `withTunneling = false, withTap = true`.

The generator warns "configuration is set without software ebreak
instruction support"; that is expected (no `ebreak` exception without a
debugger; JTAG `ebreak` works).

## Ports

All variants: `clk`; `reset` is active high, asynchronous assert. The
interrupt inputs are level sensitive (`mip.MEIP/MTIP/MSIP`). Order as in the
generated module header.

### `VexOsd`

```
input         timerInterrupt
input         externalInterrupt
input         softwareInterrupt
output        iBus_cmd_valid
input         iBus_cmd_ready
output [31:0] iBus_cmd_payload_address
output [2:0]  iBus_cmd_payload_size
input         iBus_rsp_valid
input  [31:0] iBus_rsp_payload_data
input         iBus_rsp_payload_error
output        dBus_cmd_valid
input         dBus_cmd_ready
output        dBus_cmd_payload_wr
output [3:0]  dBus_cmd_payload_mask
output [31:0] dBus_cmd_payload_address
output [31:0] dBus_cmd_payload_data
output [1:0]  dBus_cmd_payload_size
input         dBus_rsp_ready
input         dBus_rsp_error
input  [31:0] dBus_rsp_data
input         clk
input         reset
```

### `VexOsd_DMT` (BSCANE2 tunnel)

```
input         timerInterrupt
input         externalInterrupt
input         softwareInterrupt
input         jtagInstruction_tdi
input         jtagInstruction_enable
input         jtagInstruction_capture
input         jtagInstruction_shift
input         jtagInstruction_update
input         jtagInstruction_reset
output        jtagInstruction_tdo
output        ndmreset
output        iBus_cmd_valid
input         iBus_cmd_ready
output [31:0] iBus_cmd_payload_address
output [2:0]  iBus_cmd_payload_size
input         iBus_rsp_valid
input  [31:0] iBus_rsp_payload_data
input         iBus_rsp_payload_error
output        dBus_cmd_valid
input         dBus_cmd_ready
output        dBus_cmd_payload_wr
output [3:0]  dBus_cmd_payload_mask
output [31:0] dBus_cmd_payload_address
output [31:0] dBus_cmd_payload_data
output [1:0]  dBus_cmd_payload_size
input         dBus_rsp_ready
input         dBus_rsp_error
input  [31:0] dBus_rsp_data
input         reset
output        stoptime
input         clk
input         debugReset
input         jtag_tck
```

### `VexOsd_DMJ` (TAP on pins)

```
input         timerInterrupt
input         externalInterrupt
input         softwareInterrupt
input         jtag_tms
input         jtag_tdi
output        jtag_tdo
input         jtag_tck
output        ndmreset
output        iBus_cmd_valid
input         iBus_cmd_ready
output [31:0] iBus_cmd_payload_address
output [2:0]  iBus_cmd_payload_size
input         iBus_rsp_valid
input  [31:0] iBus_rsp_payload_data
input         iBus_rsp_payload_error
output        dBus_cmd_valid
input         dBus_cmd_ready
output        dBus_cmd_payload_wr
output [3:0]  dBus_cmd_payload_mask
output [31:0] dBus_cmd_payload_address
output [31:0] dBus_cmd_payload_data
output [1:0]  dBus_cmd_payload_size
input         dBus_rsp_ready
input         dBus_rsp_error
input  [31:0] dBus_rsp_data
input         reset
output        stoptime
input         clk
input         debugReset
```

### Bus and debug notes

* **iBus (cached):** one command per 32-byte line miss,
  `iBus_cmd_payload_address` is line aligned and `iBus_cmd_payload_size` = 5
  (2^5 bytes); the memory answers with 8 `iBus_rsp_valid` beats of one 32-bit
  word each, ascending addresses. There is no response back-pressure.
* **dBus (simple):** `dBus_cmd_valid`/`ready` handshake; `mask` is the byte
  enable of the 32-bit word (bit i = `data[8i+7:8i]` = byte at word address
  + i, little endian),
  `size` is log2 of the access size. A read completes with one
  `dBus_rsp_ready` pulse carrying `dBus_rsp_data`; a write has no response.
* Tie `iBus_rsp_payload_error` and `dBus_rsp_error` low (no access-fault
  traps are generated).
* Reference: `findings/osd-riscv/tinycores/perf/tb/tb_vexc.v`.
* **Debug:** `debugReset` (active high, async, `clk` domain) resets the Debug
  Module; keep it separate from `reset`, so a CPU reset does not drop the
  debugger. `ndmreset` is the debugger's request to reset the system: OR it
  into the CPU (and SoC) reset. `stoptime` is high while the hart is halted
  and the debugger has set `dcsr.stoptime` (for a timer that should stop in
  debug mode); it may be left open.
  In `VexOsd_DMT` the DTM logic runs on `jtag_tck` (rising edge); clock
  domain crossing to `clk` is inside the core.

### BSCANE2 to `jtagInstruction` (Task 14, `rtl/host/xilinx/rv_bscane2.v`)

`BSCANE2 #(.JTAG_CHAIN(4))` (USER4, as the VexRiscv README requires;
`DISABLE_JTAG = "FALSE"`), connected to `VexOsd_DMT` as SpinalHDL
`spinal.lib.blackbox.xilinx.s7.BSCANE2.toJtagTapInstructionCtrl` does
(checked against SpinalHDL v1.13.0 `lib/.../blackbox/xilinx/s7/Config.scala`):

| `VexOsd_DMT` port | BSCANE2 pin |
|---|---|
| `jtagInstruction_tdi` | `TDI` |
| `jtagInstruction_enable` | `SEL` |
| `jtagInstruction_capture` | `CAPTURE` |
| `jtagInstruction_shift` | `SHIFT` |
| `jtagInstruction_update` | `UPDATE` |
| `jtagInstruction_reset` | `RESET` |
| `jtagInstruction_tdo` | drives `TDO` |
| `jtag_tck` | `TCK` (VexRiscv README: `jtagCd = ClockDomain(clock = xilJtag.TCK)`) |

## Regenerating on a fresh machine

Prerequisites (Ubuntu 24.04; any Linux with the same tools works):

1. **JDK 17.** The default JDK 23 does **not** work: sbt 1.6.0 (the version
   VexRiscv pins in `project/build.properties`) fails with "bad constant pool
   index". JDK 17 is used only through `-java-home`, so it need not be the
   system default.

   ```sh
   sudo apt install openjdk-17-jdk-headless
   ls /usr/lib/jvm/java-17-openjdk-amd64/bin/java      # the path regen.sh uses
   ```

   Elsewhere, set `JAVA17=/path/to/jdk17` when running `regen.sh`.

2. **sbt** (any recent launcher; it downloads sbt 1.6.0 itself). Tested with
   the 1.10.1 launcher. Either the official apt repository:

   ```sh
   echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" | sudo tee /etc/apt/sources.list.d/sbt.list
   curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | sudo gpg --no-default-keyring --keyring gnupg-ring:/etc/apt/trusted.gpg.d/scalasbt-release.gpg --import
   sudo chmod 644 /etc/apt/trusted.gpg.d/scalasbt-release.gpg
   sudo apt update && sudo apt install sbt
   ```

   or, without root, the release tarball:

   ```sh
   mkdir -p ~/opt && curl -L https://github.com/sbt/sbt/releases/download/v1.10.1/sbt-1.10.1.tgz | tar -xz -C ~/opt
   export PATH=$HOME/opt/sbt/bin:$PATH
   ```

3. **git**, **iverilog** (for `--check`; tested with Icarus 12, set
   `IVERILOG=` for another binary) and network access to GitHub and Maven
   Central.

4. **Disk:** about 1.3 GB for the sbt/coursier caches (`~/.sbt` ~0.55 GB,
   `~/.cache/coursier` ~0.75 GB) and 60 MB for the VexRiscv clone plus its
   build output. Nothing is written inside this repository except the
   outputs.

Run, from the repository root:

```sh
bash rtl/host/vexriscv/regen.sh            # clone/checkout pin, generate, copy, check
bash rtl/host/vexriscv/regen.sh --check    # gate checks on the committed files only
git diff --stat rtl/host/vexriscv/         # review what changed
```

`regen.sh` clones `https://github.com/SpinalHDL/VexRiscv` into
`$VEX_SRC` (default `~/opt/vexriscv-src`) if it is missing, fetches only if
the pinned commit is absent, checks out the pin detached, and refuses to run
if that clone has local changes other than its own `GenOsd.scala` copy and
`gen_osd/` output. It copies `GenOsd.scala` into
`src/main/scala/vexriscv/demo/`, runs
`sbt -java-home $JAVA17 -batch "runMain vexriscv.demo.GenOsd"`, copies
`gen_osd/VexOsd*.v` here, writes their sha256 into `VERSION` and runs the
checks. The first run takes a few minutes (downloads, compiling ~100 Scala
files, ~1 min); later runs take 15-60 s. Generation is deterministic: two runs
give byte-identical files, header included (the header holds the SpinalHDL
version and the VexRiscv commit, no date).

`--check` passes only if:

1. each of the three files exists, is `module <name>` and parses with
   `iverilog -g2012`;
2. outside `(* ... *)` attributes, none contains `BSCANE2`, `BUFG*`,
   `RAMB*`, `DSP48*`, `IBUF*`, `OBUF*`, `altsyncram` or `altera_*`; any
   `$readmem` file it names exists here (today none does);
3. `VexOsd` has no `jtag*`, `debugReset` or `ndmreset` port; `VexOsd_DMT` has
   the seven `jtagInstruction_*` ports, `jtag_tck`, `debugReset`, `ndmreset`
   and no `jtag_tms/tdi/tdo`; `VexOsd_DMJ` has `jtag_tck/tms/tdi/tdo`,
   `debugReset`, `ndmreset` and no `jtagInstruction_*`;
4. all three have `clk`, `reset`, the three interrupt inputs and every
   `iBus_*` / `dBus_*` port listed above;
5. every module in `X.v` is `X` or `X_*`, and the three files compile together
   in one `iverilog` run;
6. `VERSION` names the pin of `regen.sh` and the sha256 of each file.

To move to another VexRiscv commit: change `PIN` in `regen.sh` and the
`vexriscv_*`, `spinalhdl`, `scala`, `sbt_project` lines in `VERSION` (from the
new `build.sbt` / `project/build.properties`), run `regen.sh`, re-run the
OOC and simulation gates of the host CPU, and commit everything together.
