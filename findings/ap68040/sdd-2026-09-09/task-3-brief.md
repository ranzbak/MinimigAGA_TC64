# Task 3: route the line-fill channel -- a miss in a Zorro window is one line transfer, not eight selects

Plan: findings/ap68040/plan-v2-with-ddr3.md, "Stage D — REVISED", revised order item 2, and the two D2 surveys under the original Stage D table ("D2, second survey" first). Read those, then the coherency note (findings/ddr3/design.md) before touching the read path.

## What exists after Task 1
The x3 compat top (lib/AP68040/rtl/ap040_tg68k_compat.v) has the channel: `fill_ena_zorro`, `fill_ena_chip` (in), `fill_req`, `fill_addr[31:4]` (out), `fill_data[127:0]`, `fill_ack`, `fill_err` (in). TG68K.vhd ties the inputs off. Read ap040_cache.v's C_FILLC/C_FILLW states for the exact handshake: is fill_ack a level held until fill_req drops (the walker rule -- the core consumes under ce) or a pulse? Must fill_data stay stable until fill_req drops? What does fill_err do (C_FERR: abandon like m_err -- i.e. a bus error, NOT a fallback to the adapter)? State these in your report before designing.

Reference integration (the author's own): ~/work/fpga/Xilinx/artix7/minimig/Minimig-AGA_MiSTer, branch apol/ap040x3 -- `rtl/cpu_wrapper.v` lines ~518-539 (fill address bank map, fill_mem_bad), `Minimig.sv` lines ~337-385 (fill CDC + a bus_timeout watchdog on the fill), `rtl/ddram_ctrl.v` fill port (~84-98, ~346, ~470-523: four longword beats, ack with the last). Their design notes: AP040_IMPLEMENTATION_PLAN.md section X3.4 on that branch. Use `git -C <clone> show apol/ap040x3:<path>`.

## Design constraints (rulings already made)
1. **No CDC.** Core and controllers are all clk_114 here; ap040_fill_cdc is for a two-clock host. Do not instantiate it (same ruling as ap040_walker_cdc). Keep its semantics: ack level-held until the request drops, payload stable until observed.
2. **The wrapper serves the line, the ports stay as they are.** The second survey is the design: cpu_cache_new already fetches the whole 16-byte line on the first miss and serves the other seven words as hits; the DDR3 side needs no widening and ddr3_fastram's CPU port is untouched. A fill FSM in TG68K.vhd (the walker requester's twin, next to it) takes fill_req, decodes fill_addr with the SAME decode the CPU address uses (sel_ddr for board 3, sel_ram for boards 1/2 -- the core cannot tell board 1 from board 3 by window, so the wrapper decodes every Zorro fill), then streams the eight words through the existing port with the chip select held and the word address advancing on each cpuena, assembles 128 bits in cpu_cache_new's word order (see the ddr3_fastram.v header: word k at bits [16k+15:16k], k = byte offset/2), and answers fill_ack. `fill_ena_zorro` = '1', `fill_ena_chip` = '0' (chip lines stay on the adapter: the 7 MHz chipset bus, coherency with chipset DMA, nothing to gain).
3. **Honour the port contract**: address stable one cycle before the select goes low; whatever the controllers require while it is low (read both headers). If Task 4 has landed, its bench assertion is the check; if not, write the same assertion as part of this task.
4. **Order, never interleave, with the walker**: fill FSM waits while wk_active; walker waits while the fill owns the bus. Assert in the bench that they never overlap.
5. **clkena stays alive** while the fill owns the bus (the same term the walker has), and the bench's stall watchdog must see progress.
6. **Decode misses**: a fill address that decodes to nothing (sel_undecoded) or is not a Zorro window -> fill_err, exactly as walker_berr. Never hang.
7. cpustate(6) stays 0, longword_pair stays 0 -- word reads.
8. cpu.xdc: the fill FSM's address register drives the cpuaddr mux like the walker's does; name it so the existing `addr*` filter in cpu.xdc catches it (or extend the filter) and say which in the report. Any free-running register you add must be excluded from the kernel set -- there should be none in the wrapper.

## Bench
sim/ddr3_cpu: the DDR3 chain is real RTL; the SDRAM side is a model in ddr3_cpu_tb.sv (~line 471-600) -- check it can serve back-to-back word reads with the select held, and fix the model if it cannot. Add: a counter of channel fills vs adapter fills printed in the summary (expected: every Zorro-window instruction/data miss is a channel fill once caches are on; report the numbers); the walker/fill mutual-exclusion assertion; a mutant switch (e.g. `--fillmutant`: the FSM assembles the words in the wrong order, or acks one word early) that MUST fail on the summary line. Runs, one at a time: `./run.sh --ap040`, `--ap040 --chipbus`, `--mmu`, `--lwmutant` (fail), `--mmumutant` (fail), `--fillmutant` (fail), plain `./run.sh`. Record the phase timestamps against the Task 1 logs in the workspace dir: a fill that costs one handshake instead of eight must move phase times measurably; if nothing moves, the channel is not being used -- find out why before reporting.

## Deliverables
TG68K.vhd (fill FSM + mux + fill_ena wiring), any tb changes, run.sh flag, plan doc: a Numbers row (phase-6 time before/after, fill counts) and a Log paragraph. Commit; leave Paul's pre-existing edits and untracked scratch unstaged. No bitstream in this task (Task 5).

## Exit criterion
All seven runs behave as required; fill counts show the channel in use; phase times moved; committed.

## Addendum (controller, 00:40)
- project_1/project_1.xpr does not contain ap040_fill_cdc.v and tools/vivado/build_ap040.tcl adds no sources; tools/vivado/build.tcl's add_src path does. If your design instantiates nothing from ap040_fill_cdc.v (it should not: no CDC here), nothing to do; if it does, add the file to the project the way build.tcl does and prove it from the build log.
- The bench pulses FIVE enable phases while hardware pulses FOUR (see Task 4 brief). If Task 4 has not landed when you start, run your legs as the bench is; note it in the report.
- Boot verification on hardware is the controller's; a "booted" ILA signature detector exists in this directory (sigcmp.py, ref_booted_* captures) from the debug round -- read its header if you need to know what booted looks like.
