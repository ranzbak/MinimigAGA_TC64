// The cycle-accounting probe (AP68040-pipelined tb/perf/perf_probe.vh) on
// sim/ddr3_cpu: a second top, elaborated next to ddr3_cpu_tb.  The window is
// the program's phase 2 (siloop_ddr3.asm).
module perf_probe_ddr3;
`define PP_W   ddr3_cpu_tb.tg68k.g_ap040.g_pipe.ap040
`define PP_EN  (ddr3_cpu_tb.phase_seen == 32'd2)
`define PP_TAG "ddr3_cpu"
`include "perf_probe.vh"
endmodule
