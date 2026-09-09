# Task 1: bump lib/AP68040 to the apol/ap040x3 core, fill channel NOT routed

Plan: findings/ap68040/plan-v2-with-ddr3.md, section "Stage D — REVISED 2026-09-08 evening", revised order item 1:

> Bump lib/AP68040 to the x3 core. Contained: new files, new ports on the compat top, their own suite (tb/run_tests.sh) as the gate. Leave the wrapper NOT routing fill_req, so everything falls back to the adapter path and the only behavioural difference is the cache fix -- which alone may beat D2.

## Where the x3 core is
NOT in the AP68040 upstream repo. It is the directory `rtl/ap040/` on branch `apol/ap040x3` (commit 8665741) of the local clone `~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer`. Read files with `git -C <clone> show apol/ap040x3:rtl/ap040/<file>`. Its design notes are `AP040_IMPLEMENTATION_PLAN.md` on that branch, sections X3.2 (store-hit update), X3.3 (POST_STORES), X3.4 (FILL_CHANNEL).

Against our submodule `lib/AP68040` at 0e76761 (`rtl/`): identical -- ap040_alu, bus16_adapter, bus_timeout, defs.svh, fpu, muldiv, regfile, walker_cdc. Changed -- ap040_cache.v (~407 lines), ap040_core.v (~82), ap040_mmu.v (~40), ap040_tg68k_compat.v (~76). New -- ap040_fill_cdc.v. x3's compat top adds parameters AP040_POST_STORES=1, AP040_FILL_CHANNEL=1 and ports fill_ena_zorro, fill_ena_chip (in), fill_req, fill_addr[31:4] (out), fill_data[127:0], fill_ack, fill_err (in). Note x3 has no rtl/primitives directory in that listing: find what x3's cache/core instantiate for RAM and confirm our override rtl/cpu040/dpram.v still replaces exactly the primitive they use.

## Steps
1. In `lib/AP68040`: create local branch `x3-overlay` from 0e76761; copy the four changed files and the new file from apol/ap040x3 into `rtl/`; commit with a message naming the source commit (Minimig-AGA_MiSTer apol/ap040x3 8665741, rtl/ap040). Do not touch anything else in the submodule. (The branch is local-only; that is known and accepted.)
2. Bump the submodule pointer in the superproject.
3. `rtl/soc/TG68K.vhd`, AP040 generate branch only: extend the `ap040_tg68k_compat` component declaration and instantiation with the new generics and ports. Tie `fill_ena_zorro`, `fill_ena_chip`, `fill_ack`, `fill_err` to '0', `fill_data` to zeros, leave `fill_req`/`fill_addr` open. Read x3's ap040_cache.v to confirm that with both fill_ena low a miss falls back to the adapter (m_req) path even with AP040_FILL_CHANNEL=1; if it does not, pass AP040_FILL_CHANNEL => 0 instead and say so. Expose AP040_POST_STORES as a top-level generic alongside AP040_HAS_FPU/HAS_MMU/ENABLE_CACHE, default 1.
4. Add `ap040_fill_cdc` to every AP040 source list: `tools/vivado/build.tcl` (foreach list ~line 82) and `sim/ddr3_cpu/run.sh` (~line 199). grep the repo for `ap040_walker_cdc` to find any other list.
5. Constraints: `fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc` filters the kernel set by instance path. Confirm the compat top instance name is unchanged. Read the x3 compat top for `always` blocks NOT qualified by `ce`/clkena (free-running, like the stall watchdog) and list any new ones -- they need the same exclusion treatment; add the exclusion if one is new, and report it either way.
6. Gates, in this order, one at a time:
   - `tools/test_ap040.sh` -- the core's own suite against the overlay with rtl/cpu040/dpram.v: all tests must pass (11 at 0e76761; report the count).
   - BEFORE running sim/ddr3_cpu, copy the existing `sim/ddr3_cpu/xsim_run_pass_ap040.log` and `xsim_run_mmu_ap040.log` (if present) aside in the workspace dir so phase timestamps can be compared.
   - `cd sim/ddr3_cpu && ./run.sh --ap040`, then `./run.sh --ap040 --chipbus`, then `./run.sh --mmu`, then `./run.sh --lwmutant` (MUST fail), then `./run.sh --mmumutant` (MUST fail), then plain `./run.sh` (TG68K control, must PASS). Each run takes 15-20 minutes. Never edit run.sh while one is in flight.
   - Record, per PASS run, the phase timestamps vs the saved logs. The x3 cache fix should move them; if nothing moved, say so -- it means the change is not reaching the bench.
7. Add a row to the plan's "Numbers to fill in" table with the phase-6 time, x3 vs 0e76761, and a one-paragraph log entry under "Log" dated 2026-09-08 saying what was overlaid and from where.
8. Commit in the superproject: submodule pointer, TG68K.vhd, build.tcl, run.sh, plan doc. Do NOT stage fw/ctrl_832/version.h, sim/hostcpu-i2c-bridge/*.wcfg, tools/vivado/ila_fastram_check.py or any untracked scratch file.

## Exit criterion
Core suite all pass with the override; all five sim/ddr3_cpu AP040 variants behave as required (3 PASS, 2 mutants FAIL); TG68K control PASS; source lists updated; committed. No bitstream in this task.
