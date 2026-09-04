# core_ddr3_controller (vendored)

Lightweight DLL-off DDR3 controller by ultra-embedded, vendored into this repo as
the backend for the Zorro-III fast RAM (see `findings/ddr3/design.md`, decision D2).

## Upstream

| | |
|---|---|
| Project | ultraembedded / core_ddr3_controller |
| URL | https://github.com/ultraembedded/core_ddr3_controller |
| Commit | `a03492a6000ca0185c615060b171bda64806a7bb` |
| Commit date | Sun Oct 10 17:09:28 2021 +0100 |
| Commit subject | "ddr3: Get the controller working at 100MHz on XC7 (tested Arty A7). Measured 367MB/s sequential read/write performance (out of 400MB/s interface BW). Add a small simple Vivado testbench." |
| License | Apache-2.0 (see `LICENSE`; upstream ships no LICENSE file, the header is in every source file) |
| Copied from | local working checkout `~/work/fpga/Xilinx/artix7/qmtech_minimig_tests/core_ddr3_controller/core_ddr3_controller` |

**The two controller sources are the local SystemVerilog variants, not the upstream
`.v` files.** In that working checkout `src_v/ddr3_core.v` and `src_v/ddr3_dfi_seq.v`
were deleted and replaced by untracked `ddr3_core.sv` / `ddr3_dfi_seq.sv`. Diffing
those against `git show a03492a:src_v/ddr3_core.v` (and `ddr3_dfi_seq.v`) with
whitespace and comments normalised shows **only cosmetic differences**: reformatting,
`begin`/`end` restructuring, `always @(posedge)` → `always_ff`, `always @*` →
`always_comb`, and the `CMD_*` / `STATE_*` `localparam`s promoted to `typedef enum`
(`cmd_t`, `state_t`). No logic, no port, no parameter changed. The `.sv` variants are
what has been simulated here, so they are what is vendored.

## What was copied, and why

| File | Why |
|---|---|
| `src_v/ddr3_core.sv` | The controller: bank/row state machine, refresh, native 128-bit request port. This is the piece the Zorro-III backend talks to. Also contains `ddr3_fifo`. |
| `src_v/ddr3_dfi_seq.sv` | DDR command sequencer: timing delays (tRCD/tRP/tRFC/tWTR), write-data FIFO, 128-bit ↔ 32-bit DFI gearing. Instantiated by `ddr3_core`. Also contains `ddr3_dfi_fifo`. |
| `src_v/ddr3_const.svh` | Copied for completeness because the plan lists it. **It is dead code** — neither `.sv` file `include`s it; both declare `cmd_t` / `state_t` inline. Do not add it to a build. |
| `src_v/phy/xc7/ddr3_dfi_phy.v` | The Xilinx 7-series DFI PHY: OSERDESE2 command/data output, ISERDESE2 + IDELAYE2 DQS-strobed read capture, its own `IDELAYCTRL`. This is the reason we use this core (D2). |
| `examples/arty_a7/artix7_pll.v` | PLLE2_BASE giving 100 / 400 / 400@90° / 200 MHz from a 1200 MHz VCO. Used by the testbench; the template for the island PLL in task 2 (which will take 50 MHz in and use `CLKFBOUT_MULT(24)`). |
| `tb/ddr3_core_xc7/testbench.v` | The controller's own testbench: 3 × 128-bit write then 3 × 128-bit read-back compare. |
| `tb/ddr3_core_xc7/ddr3.v` | Micron DDR3 Verilog simulation model v1.70 (**not Apache-2.0**, see `LICENSE`). |
| `tb/ddr3_core_xc7/2048Mb_ddr3_parameters.vh` | Part parameters for that model. |
| `tb/ddr3_core_xc7/makefile` | The xsim flow (locally fixed, see below). |
| `tb/ddr3_core_xc7/run.tcl` | xsim command file (`run 10ms; quit`). |
| `tb/ddr3_core_xc7/simulation.vh` | **Not in the plan's copy list, but required**: `testbench.v` line 5 does `` `include "simulation.vh" `` for its `CLOCK_GEN` / `RESET_GEN` / `TB_VCD` macros. Without it the testbench does not compile. |
| `LICENSE` | Written here; upstream has none. Apache-2.0 text plus the Micron-model carve-out. |

Deliberately **not** copied: `ddr3_axi.v`, `ddr3_axi_pmem.v`, `ddr3_axi_retime.v`
(we use the native 128-bit port, decision D4), the ECP5 PHY, the Arty `top.v` /
`arty_revb.xdc` / `reset_gen.v`, and the docs.

## Running the testbench

From `lib/core_ddr3_controller/tb/ddr3_core_xc7`:

```sh
export LD_LIBRARY_PATH=/path/to/dir/containing/libtinfo.so.5   # symlink -> libtinfo.so.6
VIVADO_PATH=/opt/Xilinx/Vivado/2023.2 make
```

`make clean` removes the generated products (`project.prj`, `xsim.dir`, `*.wdb`,
`*.vcd`, `xelab.*`, `xsim.log`, …); it deliberately keeps `xsim_run.log`, the
checked-in reference run. Takes about 1 minute (elaboration ~25 s, simulation ~32 s).

The libtinfo shim is the Vivado-2023.2-on-modern-Ubuntu quirk from
`findings/ddr3/implementation-plan.md` §0:

```sh
mkdir -p /somewhere/shim
ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 /somewhere/shim/libtinfo.so.5
```

### Result

Passes. `xsim_run.log` is the full run. The testbench has no "PASS" banner: it
`$fatal`s on any mismatch (`$fatal(1, "ERROR: Data mismatch!")` at `testbench.v` lines 288, 294 and 300)
and otherwise reaches `$finish` at line 305. The log contains no `$fatal` and ends:

```
testbench.u_ram.cmd_task: at time 41020000.0 ps INFO: Initialization Sequence is complete
...
$finish called at time : 63055 ns : File ".../tb/ddr3_core_xc7/testbench.v" Line 305
INFO: [Common 17-206] Exiting xsim at Fri Sep  4 22:17:25 2026...
```

and the Micron model observed the three write bursts and read the same data back,
e.g. for the 128-bit word `ffeeddccbbaa99887766554433221100` at address 0:

```
testbench.u_ram.data_task: at time 61625000.0 ps INFO: READ @ DQS= bank = 0 row = 0000 col = 00000000 data = 1100
testbench.u_ram.data_task: at time 61630000.0 ps INFO: READ @ DQS= bank = 0 row = 0000 col = 00000001 data = 3322
...
testbench.u_ram.data_task: at time 61660000.0 ps INFO: READ @ DQS= bank = 0 row = 0000 col = 00000007 data = ffee
```

## Flow fixes made to the makefile

The upstream makefile was written for an older Vivado and for the upstream `.v`
sources. Four minimal changes, RTL untouched:

1. **Per-file language in `project.prj`.** The rule emitted `verilog work "<file>"`
   for everything. `ddr3_core.sv` / `ddr3_dfi_seq.sv` are SystemVerilog (typedef
   enums, `always_ff`, `always_comb`) and `xelab` rejects them in Verilog-2001 mode.
   The file list is now split into `SRC_V` (emitted as `verilog work`) and `SRC_SV`
   (emitted as `sv work`), and the two paths point at the `.sv` files.
2. **Fixed the `$(abspath ...)` quoting bug** in that rule — upstream had
   `$(abspath $(_file)\"")`, with the closing paren inside the quoted string.
3. **`xelab` / `xsim` are called as `$(VIVADO_PATH)/bin/xelab`** instead of bare
   names, so the flow works without sourcing `settings64.sh`.
4. **`run.tcl` is now a checked-in file**, so the rule that generated it is gone and
   `clean` no longer deletes it (nor `xsim_run.log`).

Nothing in `src_v/` or in the testbench was modified.

## Notes for the integration work (tasks 2–4)

Read these before writing `rtl/ddr3/ddr3_top.v`.

* **Native port handshake** (`ddr3_core.sv` lines ~144–478, and the upstream note in
  the working checkout's `tb/ddr3_core_xc7/interface.md`):
  `inport_accept_o` and `inport_ack_o` are two separate one-cycle pulses.
  `inport_accept_o = (state_q == STATE_READ || STATE_WRITE) && cmd_accept_w` — it
  fires when the RD/WR command actually goes onto the DDR bus. The requester must
  hold `inport_addr_i`, `inport_rd_i` / `inport_wr_i[15:0]`, `inport_write_data_i`
  and `inport_req_id_i` stable until `accept`, then drop `rd`/`wr` the same cycle.
  `inport_ack_o` comes later and means "response valid": for a **read** it is
  `rddata_valid` from the sequencer, with `inport_read_data_o` valid that cycle
  only; for a **write** it is `write_ack_q`, a register set exactly **one clock after
  the write command was accepted** — a write ack does *not* mean the data has landed
  in the DRAM, only that the command was issued.
* **Ordering.** One in-order state machine; `inport_resp_id_o` comes from a depth-8
  in-order FIFO (`ddr3_fifo`) pushed on accept and popped on ack, so responses come
  back in request order. Up to 8 requests may be outstanding (`id_fifo_space_w`
  gates new requests). Our cache backend issues one at a time, so `req_id` can be
  tied to 0 and `resp_id` left unconnected.
* **Write byte enables.** `inport_wr_i` is 16 *active-high* byte-enable bits over the
  128-bit word; the core inverts them into the DFI mask (`.wrdata_mask_i(~ram_wr_w)`).
  A request is a write when `inport_wr_i != 0` and a read when `inport_rd_i` is set:
  do not assert both.
* **Address mapping.** RBC by default (`DDR_BRC_MODE=0`): column =
  `addr[DDR_COL_W:2]`, bank = `addr[DDR_COL_W+3:DDR_COL_W+1]`, row =
  `addr[DDR_ROW_W+DDR_COL_W+3:DDR_COL_W+4]`. `addr[3:0]` is ignored (BL8 = 16 bytes),
  so the backend must present a 16-byte-aligned address.
* **`cfg_*` on the core is NOT the PHY delay control.** `cfg_enable_i` must be tied
  **1** for normal operation (with it low the core parks in `STATE_IDLE` and drops all
  open-row state). `cfg_stb_i` + `cfg_data_i` are a raw-command injection port, only
  sampled in `STATE_IDLE` **while `cfg_enable_i` is 0**, and the data is
  `{cke, addr[14:0], bank[2:0], command[3:0]}`; `cfg_stall_o` is the back-pressure.
  Mode registers are hard-coded inside the core (`MR0=15'h0120` CL6/BL8,
  `MR1=15'h0001` DLL **disabled**, `MR2=15'h0008` CWL6, `MR3=0`) and are loaded by the
  `STATE_INIT` sequence off `refresh_timer_q`, so **no external strobe is needed at
  init**: tie `cfg_enable_i=1'b1`, `cfg_stb_i=1'b0`, `cfg_data_i=32'b0` exactly as
  `examples/arty_a7/top.v` and the testbench do. Init completes ~41 µs after reset
  ("Initialization Sequence is complete" in the log); the core exposes no `init_done`
  — derive it from `state_q != STATE_INIT` or from a counter.
* **The PHY has its own separate `cfg_valid_i` / `cfg_i[31:0]`** (`ddr3_dfi_phy.v`
  lines 47–48, 88–94). That is where the DQS/DQ tap sweep of plan §2 lives:
  `RDSEL` 3:0, `RDLAT` 10:8, `DLY_DQS_RST` 17:16, `DLY_DQS_INC` 19:18, `DLY_DQ_RST`
  21:20, `DLY_DQ_INC` 23:22. RST/INC are 2-bit, one bit per DQS byte lane, taken on
  the rising edge of `cfg_valid_i`; `RST` reloads the IDELAYE2 to
  `DQS_TAP_DELAY_INIT` / `DQ_TAP_DELAY_INIT`, `INC` bumps it one tap.
  **The vendored testbench leaves both unconnected** (they float to `z`, which the
  `if` statements read as false so the reset values hold). Tie them to `1'b0`/`32'b0`
  explicitly in our top, or wire them to the VIO for the sweep.
* **Latency parameters.** `TPHY_RDLAT` on the PHY is the number of `clk_i` cycles
  from `dfi_rddata_en_i` to `dfi_rddata_valid_o` (it is just the load index into an
  8-deep shift register, overridable at runtime by `cfg_i[10:8]`). It must match the
  real ISERDES capture latency: 5 for the Arty/xc7 build at 100 MHz. It is
  **independent of** the core's `DDR_READ_LATENCY` (= CL, 4 here → `tPHY_RDLAT=3`
  inside `ddr3_dfi_seq`, which is when the sequencer starts pulsing `dfi_rddata_en`)
  and `DDR_WRITE_LATENCY` (= CWL, 4 → `tPHY_WRLAT=3`). Copy the tb/Arty triple
  verbatim for task 2: PHY `DQS_TAP_DELAY_INIT(27)`, `DQ_TAP_DELAY_INIT(0)`,
  `TPHY_RDLAT(5)`; core `DDR_WRITE_LATENCY(4)`, `DDR_READ_LATENCY(4)`, `DDR_MHZ(100)`.
* **Do not add a second `IDELAYCTRL`.** `ddr3_dfi_phy.v` line 1423 already
  instantiates one on `clk_ref_i`. The island only has to supply the 200 MHz
  reference and set `REFCLK_FREQUENCY(200)`.
* **The PHY hard-codes `IOSTANDARD("SSTL135")` / `DIFF_SSTL135`** in its 19
  OBUF/OBUFDS/IOBUFDS instances. design.md wants SSTL15 for bank 16 (VCCO = 1.5 V).
  An `IOSTANDARD` set in an XDC overrides the instance parameter, so `ddr3.xdc` can
  fix this without touching the RTL — but check the post-implementation report to be
  sure the XDC won, and expect a DRC/warning about the mismatch.
* **`artix7_pll.v` puts no BUFG on its outputs** (the four `clkoutN_o` are the raw
  PLLE2 outputs) and hard-ties `RST(1'b0)` with `LOCKED()` unconnected. Task 2 needs
  its own copy with BUFGs and a `LOCKED`-based reset synchroniser, as plan §2 says.
* **Measured throughput in this run**, with the testbench's strict one-request-at-a-
  time discipline (issue → wait accept → wait ack → issue next): successive `Read`
  commands appear at the DRAM 170 ns apart (61580 / 61750 / 61920 ns), i.e. ~17 clocks
  at 100 MHz for a 16-byte round trip ≈ 94 MB/s. Writes, which ack one cycle after
  acceptance, pipeline back to back at 40 ns (61350 / 61390 ns). The upstream
  367 MB/s number requires many outstanding requests via the AXI port. This matches
  the "≈250 ns unloaded line fill" estimate in design.md once the CDC is added, and
  it is the number to beat if the cache backend is ever allowed >1 request in flight.
* **Caveat on what this testbench proves.** The Micron model prints
  `WARNING: Load Mode 1 DLL off mode is not fully modeled` — the model accepts
  MR1 with the DLL disabled but does not simulate DLL-off timing behaviour. The
  simulation therefore proves the toolchain, the PHY gearing, the command sequencing
  and the data path; it does **not** prove that DLL-off works on the real part. That
  remains hardware stage A (design.md, "Risks").
