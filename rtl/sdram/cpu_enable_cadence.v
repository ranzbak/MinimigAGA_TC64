`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////
//
// cpu_enable_cadence.v -- THE enable cadence of the sixteen-phase SDRAM round.
//
// One sixteen-phase round of sdram_ctrl's sdram_state is one 7.09 MHz period.
// Three clock enables are derived from it:
//
//   ena_cpu  -> sdram_ctrl's enaWRreg -> minimig's tg68_ena28 -> the wrapper's
//               clkena_in, i.e. the CPU's clock enable and nothing else's.
//   ena7rd   -> ena7RDreg, the 7 MHz chipset read strobe.
//   ena7wr   -> ena7WRreg, the 7 MHz chipset write strobe.
//
// This module is purely combinational and produces the NEXT value of each
// enable from the CURRENT phase, because that is how sdram_ctrl has always
// registered them (`case(sdram_state) ph2: enaWRreg <= 1'b1;` makes enaWRreg
// high during ph3).  Consumers register the outputs themselves; nothing here
// has state, so it costs no flops and cannot drift out of step with the phase
// counter it is given.
//
// ---------------------------------------------------------------------------
// WHY THIS IS A MODULE AND NOT A CASE STATEMENT
// ---------------------------------------------------------------------------
//
// sim/ddr3_cpu does not compile sdram_ctrl -- it drives the wrapper from a
// phase counter of its own -- so for as long as the cadence lived in two
// places it could, and did, differ between them.  On 2026-09-08 the plan's D1
// moved enaWRreg to five phases in sdram_ctrl.v; the bench went on pulsing
// four, and three green runs said nothing at all about the change they were
// meant to test.  The cadence now has exactly one source: this file.  Both the
// controller and the bench instantiate it, so a phase list edited here is
// necessarily what both of them see.
//
// ---------------------------------------------------------------------------
// THE PHASE LIST
// ---------------------------------------------------------------------------
//
// FOUR CPU enables at ph2/6/10/14, spacing 4-4-4-4.  This is the cadence the
// machine boots with.  ena7RDreg at ph6 and ena7WRreg at ph14 are the 7 MHz
// chipset timing and are not up for negotiation; note that at four phases
// ena_cpu happens to coincide with both of them.
//
// The five-phase variant (findings/ap68040/performance.md option 1a) is
// ph2/5/8/11/14, spacing 3-3-3-3-4: the core advances at an average 35.4 MHz
// instead of 28.4, and the multicycle exceptions in cpu.xdc become
// -start 3 / -hold 2, the MINIMUM spacing being what a constraint has to
// cover.  It also breaks the coincidence with ena7RDreg -- five gaps of at
// least 3 summing to 16 are four 3s and one 4, and no partial sum of those
// reaches the 8 phases between 6 and 14 -- which is why TG68K.vhd latches the
// chipset release (chipset_done) instead of relying on it.  That variant did
// not boot; see the plan's stage D.
//
// Changing the list is a hardware-visible change to the CPU's clock enable.
// Anything that depends on the SPACING -- the multicycle exceptions in
// fpga/openaars/aars_v5.0/xc7a100t/cpu.xdc, and TG68K.vhd's `slower` shift
// register, which holds the memory chip selects off for a fixed number of
// clocks after every enable -- has to be re-checked with it.
//
//////////////////////////////////////////////////////////////////////////////

module cpu_enable_cadence (
    input  wire [ 4-1:0] phase,       // sdram_state, 0..15
    output wire          ena_cpu,     // next enaWRreg
    output wire          ena7rd,      // next ena7RDreg
    output wire          ena7wr       // next ena7WRreg
);

// The CPU enable phases, in one place.  Four today.
assign ena_cpu = (phase == 4'd2)  ||
                 (phase == 4'd6)  ||
                 (phase == 4'd10) ||
                 (phase == 4'd14);

// The 7 MHz chipset strobes.  Fixed by the chipset, not by the CPU cadence.
assign ena7rd  = (phase == 4'd6);
assign ena7wr  = (phase == 4'd14);

endmodule
