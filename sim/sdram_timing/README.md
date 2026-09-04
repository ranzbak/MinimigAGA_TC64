# SDRAM read-path timing simulation

Answers one question: **on which `clk_114` edge does SDRAM read data land in
`sdata_reg`, and with how much margin, at each process corner?**

Uses the Alliance `AS4C16M16SA` vendor model (`lib/models/AS4C16M16SA.v`, real
tAC/tOH, CL3, BL8) driven by the unmodified `rtl/sdram/sdram_ctrl.v`, with the
FPGA and board delays from the Vivado routed report
(`findings/constraints/vivado-reports/32_sdram_in_AFTER.rpt`) modelled as
explicit transport delays in the testbench.

```
./run.sh slow sg7     # Vivado max delays, -7 grade part (tAC 5.4 ns)  <- worst case
./run.sh slow sg6     # Vivado max delays, -6 grade part (tAC 5.0 ns)
./run.sh fast sg7     # estimated fast corner
./run.sh fast sg6
```

Needs Icarus Verilog (`iverilog`, `vvp`). Output goes to `build/<corner>_<grade>.log`.

Each run writes eight words, reads them back as one burst, and for every
`clk_114` edge of the read round prints the value present at `sdata_reg/D`,
its setup and hold margin, and the same for two alternative sample points: a
capture clock at +3.5 ns (the fix proposed in
`findings/constraints/sdram-read-path.md`) and the falling edge (+4.4 ns).

Results and interpretation: `findings/constraints/sdram-sim-results.md`.

Delay model (all relative to the internal `clk_114` edge that clocks the DUT):

| | slow | fast | source |
|---|---|---|---|
| `dr_clk` at SDRAM pin | +1.505 ns | +0.025 ns | −2.975 phase + 9.68 clock-out − 5.2 insertion |
| DUT register → pin | 0.84 ns (+1 ns RTL `#1`) | 0.20 ns (+1) | 1.84 / 1.2 clk-to-Q + OBUF |
| pin → `sdata_reg/D` | 3.03 ns | 1.90 ns | IBUF + route |

The model's default `` `define sg6 `` was wrapped in `` `ifndef sg5/sg7 `` so
that `-Dsg7` does not also enable the sg6 data-out block (see the comment in
the model header).
