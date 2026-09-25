# Pipelined AP68040 parity tests

Companion to `../assessment.md`. Everything here was
written and RUN on 2026-09-21 against

- pipelined: `nonarkitten/AP68040` branch `pipelined` @ `71caa48` (milestone 17)
- reference: `apolkosnik/AP68040` `main` @ `8f72275`

with iverilog 12/13 (`-g2012`), vvp, vasmm68k_mot and python3.

```
AP040_PIPE=/path/to/AP68040-pipelined AP040_REF=/path/to/AP68040 sh run_all.sh
```

`AP040_REF` may also point at `lib/AP68040` (the local e2-fixes derivative);
the runner adds `ap040_fill_cdc.v` when it exists. `WORK=` relocates the
build directory (default `./build`).

## What is here

| file | kind | status when run |
|---|---|---|
| `tb_ap040_pipe_trace.v` | retire-trace dumper for the pipelined core: `+prog=<hex> +trace=<out> [+cycles=N] [+halt_pc=H]`, one line per retired instruction with PC/SR/D0-D7/A0-A7 | works |
| `tb_ap040_ref_trace.v` | same dumper for the reference core (flat 16-bit memory, no wait states), one line per instruction decode; A1-A6/D3-D7 printed as `xxxxxxxx` because `ap040_regfile` only exposes D0-D2/A0/A7 | works |
| `compare_trace.py` | compares the two traces: PC sequence, per-register value ORDER (timing independent) and final state; `--from-pc` starts past a known reset difference; `--mode lagged` for per-instruction snapshots | works |
| `asm/diff_smoke.s` | first differential program, restricted to the milestone-17 subset (MOVEQ, ADD.L Dn,Dn, Bcc, DBcc, Scc Dn, BSR/RTS, TRAP/RTE, MOVEC) | **parity** from PC $402 on; **diverges from reset** (ISP not loaded from vector 0) |
| `tb_ap040_pipe_red_movew.v` | MOVE.W (A0),D0 sizing/merge/CCR | red: opcode takes vector 4 |
| `tb_ap040_pipe_red_rte_fmt2.v` | RTE of a format $2 frame pops 12 bytes; unknown format -> vector 14 | red: pops 8 |
| `tb_ap040_pipe_red_vbr.v` | vector fetch at VBR+vector*4 | red: VBR ignored |
| `tb_ap040_pipe_red_aline_fline.v` | $Axxx -> vector 10, $Fxxx -> vector 11 | red: both take vector 4 |
| `run_all.sh` | runs all of the above; red legs are reported as `red (expected)` / `GREEN`, the differential leg must pass | exit 0 on 2026-09-21 |

The red benches are written in the pipelined branch's own idiom (program
poked into `dut.u_l1.mem[]` at PC_RESET-relative word indices, registers
poked one edge after reset release, `ALL TESTS PASSED` sentinel) so they can
be dropped into `tb/run_pipe_tests.sh` unchanged once the feature lands.

## What is only specified

The full parity suite (per feature group, per instruction, with the
cputest corpus as the terminal oracle) is specified in section 5 of the
assessment. It is not written; the trace harness above is the mechanism it
runs on, and needs one RTL change on the reference side (a 16-register debug
tap on `ap040_regfile`) to compare all registers instead of six.
