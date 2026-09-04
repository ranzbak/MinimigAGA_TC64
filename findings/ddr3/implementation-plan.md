# DDR3 Zorro-III fast RAM — implementation plan

For an implementer (a fresh Claude session or a person) working from
[design.md](design.md). Do the tasks in order; each ends with a test that must pass
before the next starts. Commit after each task. Nothing here touches `sdram_ctrl.v`,
`amiga_clk*.v` or the existing XDC beyond one comment.

## 0. Environment, quirks, lessons (read first)

* Vivado 2023.2 at `/opt/Xilinx/Vivado/2023.2`. It needs `libtinfo.so.5`; either install
  `libtinfo5` or run with `LD_LIBRARY_PATH=<dir containing a symlink libtinfo.so.5 -> /lib/x86_64-linux-gnu/libtinfo.so.6>`.
  Do **not** pass `-stack 6000` (router segfault).
* Project: `project_1/project_1.xpr`. The runs use constraints fileset **`XC7A100T`**, not
  `constrs_1`; a file added to `constrs_1` is silently ignored. Sources are added with
  `$PPRDIR`-relative paths. Scripts: `tools/vivado/build.tcl`, `program.tcl`.
* Build ≈ 25 min. Known timing state after the constraint rework: everything met except
  `clk_gen_sdram -> clk_114` at −0.349 ns (16 endpoints). That is expected; do not "fix" it here.
* Board reality: boot is a coin flip (SDRAM read path is marginal, plus a sticky failure
  in the SD-card path once a boot has failed). **Test boots by reprogramming the FPGA**,
  never by a soft reset from a VIO, and expect to need several attempts. Screen colours
  before Kickstart are boot-firmware stage markers (white = stuck initialising the SD
  card, red = SD init failed, yellow = no partition, green = firmware load failed,
  black = host CPU never ran). See `findings/constraints/fix-12-*.md` for the full story.
* Simulation: xsim (`xvlog/xelab/xsim`) with unisims for anything with ISERDES/OSERDES/
  IDELAY/PLL; iverilog is fine for pure-RTL benches (see `sim/sdram_timing/run.sh`).
* A safety hook in this environment blocks git history rewriting, file-tree deletion and
  checkout-style reverts regardless of justification. Revert a file with
  `git show HEAD:<file> > <file>`; never amend a commit, make a follow-up commit instead.
* Hardware helpers in `tools/vivado/` (moved out of the session scratchpad; see its README):
  program a bitstream, run a build, step an MMCM/PLL fine phase over a VIO, capture an ILA.

## 1. Vendor the controller (½ day)

Copy from `~/work/fpga/Xilinx/artix7/qmtech_minimig_tests/core_ddr3_controller/core_ddr3_controller`
into `lib/core_ddr3_controller/` **only**: `src_v/ddr3_core.sv`, `src_v/ddr3_dfi_seq.sv`,
`src_v/ddr3_const.svh`, `src_v/phy/xc7/ddr3_dfi_phy.v`, `examples/arty_a7/artix7_pll.v`,
`tb/ddr3_core_xc7/{testbench.v,ddr3.v,2048Mb_ddr3_parameters.vh,makefile,run.tcl}`, and
the LICENSE. Record the upstream commit hash in `lib/core_ddr3_controller/README.md`.

Test: run the vendored testbench under xsim exactly as its makefile does
(`VIVADO_PATH=/opt/Xilinx/Vivado/2023.2 make`); it must complete its read/write checks.
This proves the model, the PHY and the xsim flow before any of our code exists.

## 2. Island: `rtl/ddr3/ddr3_top.v` + BIST (1 day)

* PLLE2_BASE as in `artix7_pll.v` but CLKIN 50 MHz: MULT 24, DIVCLK 1, VCO 1200;
  CLKOUT0 /12 → `clk100`, CLKOUT1 /3 → `clk400`, CLKOUT2 /6 → `clk200`, CLKOUT3 /3 at
  90° → `clk400_90`. BUFG each. Reset synchroniser from PLL `LOCKED` and the external reset.
* `IDELAYCTRL` (REFCLK `clk200`), `ddr3_dfi_phy` (xc7, `REFCLK_FREQUENCY 200`, default
  taps), `ddr3_core` (`DDR_MHZ 100`). Tie `cfg_*` off unless the core needs a strobe at
  init (read `ddr3_core.sv`; the Arty top shows the exact wiring, copy it).
* Native port exposed upward: `req_valid/req_wr[15:0]/req_addr[31:0]/req_wdata[127:0]`,
  `req_accept`, `resp_valid/resp_rdata[127:0]` (map to `inport_*`).
* **BIST** (`rtl/ddr3/ddr3_bist.v`, clk100): start/stop/pattern-select/range inputs, error
  counter, first-error address and data, "done" flag. Patterns: address-as-data, 0x5555/
  0xAAAA, walking ones, LFSR. Inputs and outputs are plain registers so a VIO can drive them.
* Port list of `ddr3_top` includes every DDR3 pin. In `minimig_openaars_top.v` add the
  47 pins as top-level ports (names as in the QMTECH UCF); `ddr3.xdc` per design.md.

Test: bench `sim/ddr3/ddr3_top_tb.sv` (xsim): island + Micron model; run BIST over a small
range for each pattern; zero errors; PLL lock and core init complete within the model's
timing. Then **hardware stage A**: build with a VIO connected to the BIST (create the
`vio` IP from the build script the way `tools/vivado/build.tcl` adds `cpu.xdc`), program,
run each pattern over the full 256 MB, zero errors; repeat after 30 minutes. Sweep the DQS
tap (core `cfg` register `DDR_PHY_CFG_DLY_DQS_INC`) to find the passing window; set
`DQS_TAP_DELAY_INIT` to its centre. Record all numbers in `findings/ddr3/bringup.md`.

## 3. Cache backend + CDC: `rtl/ddr3/ddr3_fastram.v`, `rtl/ddr3/ddr3_cdc.v` (1–2 days)

* `ddr3_cdc.v`: toggle-handshake request/response as described in design.md. Buses are
  registered on the source side and held until the ack toggle returns. Two-flop
  synchronisers on the toggles with `ASYNC_REG`. Header comment states the invariant
  (buses only change while `req==ack`).
* `ddr3_fastram.v`: `cpu_cache_new` instance copied from `sdram_ctrl.v` lines
  ~270–300 (same parameters, `snoop_act` 0, `cache_inhibit` 0, `cacheline_clr` passed
  through). Backend FSM: IDLE → (read) REQ → WAIT → DELIVER 8 words in wrapped order →
  IDLE; (write) build 16 byte enables from `sdr_dqm_w`/`sdr_adr[3:1]`, REQ → WAIT →
  ack → IDLE. Exactly one request in flight.
* CPU port identical to `sdram_ctrl`'s: `cpuAddr[25:1]`, `cpustate[6:0]` (use bit 2 as
  chip select exactly like `cpuCSn`), `cpuU/cpuL`, `cpuWR[15:0]`, `cpuRD[15:0]`,
  `cpuena`. Add `ddr_ready` (init done) so the wrapper can hold the CPU until then.

Test: bench `sim/ddr3/ddr3_fastram_tb.sv` (xsim): fastram + island + model, driven by the
`cpu_read`/write tasks from `sim/sdram_timing/sdram_timing_tb.v`. Cases listed in design.md
"Verification 2". Also a CDC stress: random gaps between requests (0–40 clocks).

## 4. Wrapper hookup: `TG68K.vhd`, `minimig_virtual_top.v` (1 day)

* `TG68K.vhd`: generic `haveddr3 : boolean := true`. `sel_ddr <= sel_z3ram OR sel_z3ram2`
  when haveddr3, else '0'; remove those two from `sel_ram` when haveddr3; `sel_z3ram3`
  forced '0' when haveddr3. New outputs `ddrcs` (built like `ramcs` from a registered
  `sel_ddr_d`, including `slower(0)`), `ddraddr(27 downto 0) <= cpuaddr(27 downto 0)`.
  New inputs `fromddr(15 downto 0)`, `ddr_ready`. `datatg68` picks `fromddr` when
  `sel_ddr_d='1'`. `clkena` term: `ramready='1' OR ddr_ready='1'`; check the exact
  gating at line ~457 so a DDR access cannot be released by an SDRAM ack and vice versa
  (they are mutually exclusive by address, but be explicit: AND each ready with its select).
* Chip-select timing: the SDRAM controller requires `cpuAddr` one cycle before `cpuCSn`
  (`cpuAddr_r`); `ddr3_fastram` must register the address the same way. Copy that.
* `minimig_virtual_top.v`: instantiate `ddr3_fastram`, wire the cpu port and the pins;
  `.reset_in(sdctl_rst)`, `.cache_rst(tg68_rst)`, same as the SDRAM.
* `minimig_openaars_top.v`: pins through; `ddr3.xdc` in fileset `XC7A100T` (build script
  adds it, as it does `cpu.xdc`).

Test: full build; timing as in design.md; hardware **stage B**: reprogram, boot to
Workbench, `avail` shows the Z3 board, RAM test on the Z3 range (SysTest or AmigaTestKit),
copy a 20 MB file to RAM: and compare, repeat warm. Then the same with `haveddr3=false`
to prove the fallback still builds and boots.

## 5. Documentation and hand-back (½ day)

`findings/ddr3/bringup.md` with the delay window, BIST results, utilisation and timing
numbers; update `findings/README.md`; note stage C prerequisites (autoconfig size code,
OSD menu, cache tag width) with file pointers: `rtl/minimig/minimig_autoconfig.v` (Z3
`ramsize` at the 0x44 handler), `fw/ctrl_832` memory menu, `rtl/sdram/cpu_cache_new.v`
tag width.

## Acceptance for the whole plan

* Workbench boots with fast RAM on DDR3 and passes a RAM test cold and warm.
* SDRAM controller, Minimig clock module and existing constraints unchanged (diff shows
  only the one comment in `clocks.xdc`).
* Full build timing unchanged for every pre-existing path group.
* `haveddr3=false` reproduces today's core.
