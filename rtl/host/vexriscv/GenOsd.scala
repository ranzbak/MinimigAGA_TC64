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
//
// Source of truth for rtl/host/vexriscv/VexOsd*.v: edit this file, run
// rtl/host/vexriscv/regen.sh, commit this file and the Verilog together.
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
  // privateNamespace: submodules become <Top>_InstructionCache etc., so the
  // three files can share one source list (otherwise InstructionCache,
  // DebugModule, BufferCC... are defined in each file).
  for (d <- Seq(0, 1, 2))
    SpinalConfig(targetDirectory = "gen_osd", privateNamespace = true)
      .generateVerilog(cpu(d))
}
