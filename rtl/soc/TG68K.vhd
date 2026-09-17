------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2011 Tobias Gubener                                   --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This is the TOP-Level for the CPU kernel to generate 68K Bus signals     --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU General Public License as published        --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;        -- @suppress "Deprecated package"

entity TG68K is
	generic(
		havertg   : boolean := true;
		haveaudio : boolean := true;
		havec2p   : boolean := true;
		-- Zorro-III fast RAM lives on the DDR3 island instead of the SDRAM.
		-- See findings/ddr3/design.md, decisions D1/D6, and
		-- findings/ddr3/z3ram3-on-ddr3-plan.md (which supersedes D8).
		haveddr3  : boolean := true;
		-- The CPU is the AP68040 (lib/AP68040, MC68040 with MMU and FPU).  It
		-- presents a TG68K-shaped port set, so everything else in this file --
		-- decode, Zorro III, DDR3, Akiko, the 7 MHz chipset state machine --
		-- was unchanged by it.  The TG68KdotC kernel was removed in Stage E4a
		-- (tag d3_stable still has it).  findings/ap68040/plan-v2-with-ddr3.md.
		-- AP68040 configuration.  All three on by
		-- default: the full core places and routes at 28,694 LUTs.
		ap040_has_mmu      : integer := 1;
		ap040_has_fpu      : integer := 1;
		ap040_enable_cache : integer := 1;
		-- Posted stores: a store to a cacheable page is acknowledged by the
		-- data cache and drained behind the core's back (AP040 plan X3.3).
		-- 0 is the synchronous-store reference the A/B measurement wants.
		ap040_post_stores  : integer := 1;
		-- clk / clk_cpu, the AP68040 island's clock ratio.  3 is stage D3 as
		-- shipped (37.8125 MHz); 4 runs the same architecture at the pre-D3 CPU
		-- rate.  THE PHASE MARKER BELOW DEPENDS ON THIS AND IS NOT RATIO-AGNOSTIC
		-- -- getting that wrong produces a core that never executes an
		-- instruction, because clkena lands one clk cycle before the kernel's
		-- edge instead of on it.  Must match amiga_clk's CPU_CLK_DIVIDE / 10.
		cpu_clk_ratio      : integer := 3;
		-- Size of the third ZIII board, log2 of its byte size: 24 = 16 MB,
		-- 25 = 32 MB, 26 = 64 MB.  It is the DDR3 board when haveddr3, and the
		-- board is size-aligned, so this also says how many address bits are
		-- compared against the base the OS assigned and how many are offset
		-- into the board.  Must agree with the size the autoconfig ROM
		-- advertises (rtl/minimig/minimig_autoconfig_rom.v).
		z3ram3_size_log2 : integer := 24
	);
	port(
		clk             : in     std_logic;
		-- The CPU island's own clock, 37.8125 MHz, a phase-aligned 1:3 sibling
		-- of clk on the same MMCM (rtl/clock/amiga_clk_xilinx.v CLKOUT3).  It
		-- clocks the AP68040 kernel and NOTHING else.
		-- See findings/ap68040/plan-v2-with-ddr3.md, stage D3.
		clk_cpu         : in     std_logic                     := '0';
		reset           : in     std_logic;
		clkena_in       : in     std_logic                     := '1';
		IPL             : in     std_logic_vector(2 downto 0)  := "111";
		dtack           : in     std_logic;
		vpa             : in     std_logic                     := '1';
		ein             : in     std_logic                     := '1';
		addr            : out    std_logic_vector(31 downto 0);
		data_read       : in     std_logic_vector(15 downto 0);
		data_read2      : in     std_logic_vector(15 downto 0);
		data_write      : out    std_logic_vector(15 downto 0);
		data_write2     : out    std_logic_vector(15 downto 0);
		as              : out    std_logic;
		uds             : out    std_logic;
		lds             : out    std_logic;
		uds2            : out    std_logic;
		lds2            : out    std_logic;
		rw              : out    std_logic;
		vma             : buffer std_logic                     := '1';
		wrd             : out    std_logic;
		ena7RDreg       : in     std_logic                     := '1';
		ena7WRreg       : in     std_logic                     := '1';
		-- THE UNIT PORT (Stage E2).  One request is at most two consecutive
		-- words inside one 16-byte line, with a byte select per byte;
		-- ap040_ram_seq splits anything that does not fit.
		--   *_req   level, fields stable while it is high
		--   *_wadr  word address of word A (already mapped for the controller)
		--   *_bs    {A hi, A lo, A+2 hi, A+2 lo}, active high
		--   *_wdat  {word A, word A+2};  *_rdat the same, valid with *_ack
		--   *_ack   level, only ever high while *_req is
		ram_req         : out    std_logic;
		ram_we          : out    std_logic;
		ram_ir          : out    std_logic;
		ram_wadr        : out    std_logic_vector(25 downto 1);
		ram_bs          : out    std_logic_vector(3 downto 0);
		ram_wdat        : out    std_logic_vector(31 downto 0);
		ram_rdat        : in     std_logic_vector(31 downto 0) := (others => '0');
		ram_ack         : in     std_logic                     := '0';
		-- '1' when the fields on the port now would be answered from the
		-- controller's line buffer: such a unit needs no SDRAM slot, so
		-- ap040_ram_seq launches it without waiting for the placement gate.
		ram_hit         : in     std_logic                     := '0';
		-- DDR3 Zorro-III fast RAM, the same port (used only when haveddr3)
		ddr_req         : out    std_logic;
		ddr_we          : out    std_logic;
		ddr_ir          : out    std_logic;
		ddr_wadr        : out    std_logic_vector(25 downto 1);
		ddr_bs          : out    std_logic_vector(3 downto 0);
		ddr_wdat        : out    std_logic_vector(31 downto 0);
		ddr_rdat        : in     std_logic_vector(31 downto 0) := (others => '0');
		ddr_ack         : in     std_logic                     := '0';
		ddr_hit         : in     std_logic                     := '0';
		-- the DDR3 island's init-done flag: before it an access is held
		ddr_ready       : in     std_logic                     := '0';
		ziiram_active   : in     std_logic;
		ziiiram_active  : in     std_logic;
		ziiiram2_active : in     std_logic;
		ziiiram3_active : in     std_logic;
		-- A31-A24 of the base the OS assigned to the third ZIII RAM board,
		-- latched by rtl/minimig/minimig_autoconfig.v.  Valid once
		-- ziiiram3_active is set; the decode below follows it rather than
		-- assuming an address.
		z3ram3_base     : in     std_logic_vector(7 downto 0)  := (others => '0');
		-- Chipset DMA write snoop, for the AP68040's data cache: sdram_ctrl
		-- already produces these for cpu_cache_new, and they are in this
		-- clock domain.
		snoop_stb       : in     std_logic                     := '0';
		snoop_addr      : in     std_logic_vector(31 downto 0) := (others => '0');
		-- AP68040 fault observation, for an ILA during bring-up.  Sliced out of
		-- the core's debug_status/debug_status2 (see
		-- ap040_core.v:6134-6152): everything needed to name an exception --
		-- which vector, at what PC, on which opcode, and the address that
		-- faulted if it was an access error.
		dbg_pc          : out    std_logic_vector(31 downto 0);
		dbg_fault_addr  : out    std_logic_vector(31 downto 0);
		dbg_ir          : out    std_logic_vector(15 downto 0);
		dbg_sr          : out    std_logic_vector(15 downto 0);
		dbg_exc_vec     : out    std_logic_vector(7 downto 0);
		dbg_flags       : out    std_logic_vector(3 downto 0); -- fault, in_exc, halted, busy
		-- Chip-RAM acknowledge phase histogram, ila_cpu040 probe8.  384 bits:
		--   (127:0)   8 bins x 16: clk cycles from a chip-RAM acknowledge to the
		--             kernel's release (clkena_r), bin 7 = 7 or more
		--   (383:128) 16 bins x 16: SDRAM round phase the acknowledge landed on
		-- Snapshot of one 2**22-cycle window (~37 ms), refreshed every window, so a
		-- single ILA sample reads a complete histogram.
		dbg_phist       : out    std_logic_vector(383 downto 0);
		-- Stage E0 RTG diagnosis: {akiko_req, akiko_wr, state, cpuaddr(11:0),
		-- akiko_d} for ila_cpu040 probe9. Observation only.
		dbg_rtg         : out    std_logic_vector(31 downto 0);
		eth_en          : in     std_logic                     := '0'; -- @suppress "Unused port: eth_en is not used in work.TG68K(logic)"
		sel_eth         : buffer std_logic;
		frometh         : in     std_logic_vector(15 downto 0);
		ethready        : in     std_logic; -- @suppress "Unused port: ethready is not used in work.TG68K(logic)"
		slow_config     : in     std_logic_vector(1 downto 0);
		aga             : in     std_logic;
		turbochipram    : in     std_logic;
		turbokick       : in     std_logic;
		cache_inhibit   : out    std_logic;
		cacheline_clr   : out    std_logic;
		--    ovr           : in      std_logic;
		nResetOut       : out    std_logic;
		skipFetch       : out    std_logic;
		CACR_out       : out    std_logic_vector(3 downto 0);
		VBR_out         : out    std_logic_vector(31 downto 0);
		-- RTG interface
		rtg_addr        : out    std_logic_vector(25 downto 4);
		rtg_vbend       : out    std_logic_vector(6 downto 0);
		rtg_ext         : out    std_logic;
		rtg_pixelclock  : out    std_logic_vector(3 downto 0);
		rtg_clut        : out    std_logic;
		rtg_16bit       : out    std_logic;
		rtg_clut_idx    : in     std_logic_vector(7 downto 0)  := X"00";
		rtg_clut_r      : out    std_logic_vector(7 downto 0);
		rtg_clut_g      : out    std_logic_vector(7 downto 0);
		rtg_clut_b      : out    std_logic_vector(7 downto 0);
		-- Audio interface
		audio_buf       : in     std_logic;
		audio_ena       : out    std_logic;
		audio_int       : out    std_logic;
		-- Host interface
		host_req        : out    std_logic;
		host_ack        : in     std_logic                     := '0';
		host_q          : in     std_logic_vector(15 downto 0) := "----------------";
		-- The Akiko register cycle the host is asked to serve.  Before Stage
		-- E2 the host read these off the RAM port (ramaddr(8:1), toram and
		-- cpustate(0)), which Akiko traffic no longer shares.
		host_addr       : out    std_logic_vector(8 downto 1);
		host_d          : out    std_logic_vector(15 downto 0);
		host_wr         : out    std_logic
	);
end TG68K;

ARCHITECTURE logic OF TG68K IS

	SIGNAL addrtg68    : std_logic_vector(31 downto 0);
	SIGNAL cpuaddr     : std_logic_vector(31 downto 0);
	SIGNAL r_data      : std_logic_vector(15 downto 0);
	SIGNAL cpuIPL      : std_logic_vector(2 downto 0);
	-- SIGNAL vpad             : std_logic;
	SIGNAL waitm       : std_logic;
	SIGNAL clkena_e    : std_logic;
	SIGNAL S_state     : std_logic_vector(1 downto 0);
	-- SIGNAL decode           : std_logic;
	SIGNAL wr          : std_logic;
	SIGNAL uds_in      : std_logic;
	SIGNAL lds_in      : std_logic;
	SIGNAL state       : std_logic_vector(1 downto 0);
	SIGNAL clkena      : std_logic;
	-- The first term of clkena: which clock edge the CPU kernel is allowed to
	-- advance on.  The AP68040 kernel runs
	-- on clk_cpu and this is the clk-domain marker for "the next clk edge is
	-- also a clk_cpu edge", so clkena stays a one-clk-cycle pulse on the exact
	-- edge the kernel advances -- which is what every clk-domain consumer of
	-- clkena in this file (slower, chipset_done, the chipset FSM) was written
	-- against.
	SIGNAL cpu_ce_phase : std_logic;
	-- cpu_ph is high in (T+N-2,T+N-1) and cpu_ph2 in (T+N-1,T+N), where the
	-- kernel's clock edges are at T and T+N and N is cpu_clk_ratio -- see the
	-- marker in the g_ap040 branch, which is NOT ratio-agnostic.
	-- cpu_ph2 is the enable phase; cpu_ph is
	-- declared HERE rather than inside the g_ap040 block because the
	-- completion process below needs it.
	SIGNAL cpu_ph       : std_logic := '0';
	SIGNAL cpu_ph2      : std_logic := '0';
	-- '1' when the kernel's bus outputs have settled; see where it is driven.
	SIGNAL cpu_bus_settled : std_logic;
	-- The clkena release term on its own, and the AP68040's registered clkena.
	-- See where they are driven.
	SIGNAL bus_release  : std_logic;
	SIGNAL clkena_r     : std_logic := '0';
	-- SIGNAL vmaena           : std_logic;
	SIGNAL eind        : std_logic;
	SIGNAL eindd       : std_logic;
	SIGNAL sel_ram     : std_logic;
	SIGNAL sel_chip    : std_logic;
	SIGNAL sel_chipram : std_logic;
	-- SIGNAL turbochip_ena    : std_logic := '0';
	SIGNAL turbochip_d : std_logic := '0';
	SIGNAL turbokick_d : std_logic := '0';
	SIGNAL turboslow_d : std_logic := '0';
	SIGNAL slower      : std_logic_vector(3 downto 0);
	-- The acknowledge-phase histogram behind dbg_phist.  Stage D3 corrupts at
	-- clock ratios coprime with the 16-phase SDRAM round (3, 5) and is clean at
	-- ratio 4; two changes that made chip-RAM accesses wait longer made it worse.
	-- So what is measured is WHEN a chip-RAM access completes against the round,
	-- and how long the kernel then takes to see it -- built at ratio 3 and 4 and
	-- compared.  Taps are registered, so nothing here loads the critical ram_ack
	-- net more than one flop.
	TYPE ph_hist16_t IS ARRAY (0 TO 15) OF std_logic_vector(15 DOWNTO 0);
	TYPE ph_hist8_t  IS ARRAY (0 TO 7)  OF std_logic_vector(15 DOWNTO 0);
	SIGNAL ph16        : std_logic_vector(3 DOWNTO 0)  := (others => '0');
	SIGNAL ph_ack_r    : std_logic := '0';
	SIGNAL ph_ack_d    : std_logic := '0';
	SIGNAL ph_chip_r   : std_logic := '0';
	SIGNAL ph_pend     : std_logic := '0';
	SIGNAL ph_dly      : std_logic_vector(2 DOWNTO 0)  := (others => '0');
	SIGNAL ph_win      : std_logic_vector(21 DOWNTO 0) := (others => '0');
	SIGNAL ph_cnt_ph   : ph_hist16_t := (others => (others => '0'));
	SIGNAL ph_cnt_dly  : ph_hist8_t  := (others => (others => '0'));
	SIGNAL ph_snap_ph  : ph_hist16_t := (others => (others => '0'));
	SIGNAL ph_snap_dly : ph_hist8_t  := (others => (others => '0'));
	-- PHASE ALIGNMENT OF BUS-CYCLE STARTS (stage D3, 2026-09-11).
	--
	-- The SDRAM round is sixteen clk phases and enaWRreg marks four of them.
	-- Before stage D3 the kernel advanced ONLY on those, so a CPU bus cycle
	-- could only ever start on four fixed phases of the round.  On its own
	-- clock the kernel advances whenever the bus is free, and 16 has no common
	-- factor with 3, so a bus cycle can start on ANY of the sixteen -- including
	-- phases no CPU access had ever landed on in this design.
	--
	-- Measured, three points, on hardware with Turbo chip RAM on:
	--   ratio 3 (coprime with 16, all phases)   corrupts
	--   ratio 4 (divides 16, four fixed phases) CLEAN
	--   ratio 5 (coprime with 16, all phases)   corrupts, and worse
	-- Ratio 5 is SLOWER than ratio 4, so this cannot be a rate-dependent race:
	-- what ratio 4 has and the others lack is a fixed phase relationship.
	-- cpu.xdc already records the same hazard for the 7 MHz chipset machine
	-- ("16 and 3 are coprime, so without a guard it could latch the kernel's
	-- outputs one clk cycle after they moved") and guards that ONE consumer
	-- with cpu_bus_settled; it evidently reaches further than that.
	--
	-- So a unit is launched only on the first enaWRreg phase after `slower`
	-- has drained, which puts every bus-cycle start back on a fixed four-phase
	-- grid.  The kernel keeps its own clock and its full rate: this costs at
	-- most four clk cycles on an access that actually goes to memory, and
	-- NOTHING on a cache hit, which is where the stage D3 speedup comes from.
	--
	-- Stage E2: this is a one-cycle PULSE, not the level cpu_phase_ok was.
	-- The level stayed open until the next clkena, which was harmless while
	-- every 16-bit sub-cycle came with its own clkena; ap040_ram_seq launches
	-- the second unit of a split access with no clkena in between, and a
	-- level would put that unit off the grid.
	SIGNAL unit_gate      : std_logic;
	-- clkena_in delayed 1..3 clk cycles; the gate opens on ena_sr(2).
	SIGNAL ena_sr         : std_logic_vector(2 downto 0) := (others => '0');

	TYPE sync_states IS (sync0, sync1, sync2, sync3, sync4, sync5, sync6, sync7, sync8, sync9);
	SIGNAL sync_state : sync_states;
	SIGNAL datatg68_c : std_logic_vector(15 downto 0);
	-- THE READ-DATA CAPTURE (Stage E2, RTG investigation 2026-09-16).
	-- datatg68_c changes on clk edges, while the
	-- adapter samples it on a clk_cpu edge: the one clk_114 -> clk_38 signal
	-- that is neither held across the capture window nor shaped to the
	-- destination edge (plan-v2, D4).  clkena_r is decided at T+N-2 and the
	-- kernel advances at T+N, so capturing on that same edge hands the core a
	-- value and an enable from ONE instant.  One register on a path with two
	-- clk cycles of slack.
	--
	-- Re-added after E2 Task 1 removed it as dead: it WAS dead where it sat
	-- (the compat top's data_in, which ap040_tg68k_compat.v ties off with
	-- `wire unused_d = |data_in` when AP040_BUS16 = 0).  The live read path is
	-- the adapter this wrapper now instantiates itself.  Since Task 4b-2 it
	-- carries only the adapter's traffic (chipset, NMI vector, undecoded);
	-- RAM and Akiko reads are captured the same way in x_rdata_r.
	SIGNAL datatg68_r : std_logic_vector(15 downto 0) := (others => '0');
	SIGNAL w_datatg68 : std_logic_vector(15 downto 0);

	SIGNAL z2ram_ena       : std_logic;
	SIGNAL z3ram_ena       : std_logic;
	SIGNAL z3ram2_ena      : std_logic;
	SIGNAL z3ram3_ena      : std_logic;
	-- SIGNAL eth_base         : std_logic_vector(7 downto 0);
	-- SIGNAL eth_cfgd         : std_logic;
	SIGNAL sel_z2ram       : std_logic;
	SIGNAL sel_z3ram       : std_logic;
	SIGNAL sel_z3ram2      : std_logic;
	SIGNAL sel_z3ram3      : std_logic;
	SIGNAL sel_kick        : std_logic;
	SIGNAL sel_kickram     : std_logic;
	--SIGNAL sel_eth          : std_logic;
	SIGNAL sel_slow        : std_logic;
	SIGNAL sel_slowram     : std_logic;
	-- SIGNAL sel_cart         : std_logic;
	SIGNAL sel_32          : std_logic;
	signal sel_undecoded   : std_logic;
	signal sel_undecoded_d : std_logic;
	signal sel_akiko       : std_logic;
	signal sel_audio       : std_logic;

	-- DDR3 fast RAM
	SIGNAL have_ddr        : std_logic; -- '1' when the haveddr3 generic is true
	SIGNAL sel_z3ram_sdram : std_logic; -- ZIII boards that still live on the SDRAM
	-- Zero fill above the third board's offset, so that the DDR3 word address
	-- is one concurrent assignment (two assignments to slices of ddraddr would
	-- be two drivers).  A null range when z3ram3_size_log2 = 26, where the
	-- board covers the whole 64 MB the backend can address and the map is the
	-- identity again; concatenating a null vector is legal and drops out.
	CONSTANT ddr_zero_hi   : std_logic_vector(25 downto z3ram3_size_log2) := (others => '0');
	SIGNAL sel_ddr         : std_logic;

	-- Akiko registers
	signal akiko_addr : std_logic_vector(10 downto 0);
	signal akiko_d    : std_logic_vector(15 downto 0);
	signal akiko_q    : std_logic_vector(15 downto 0);
	signal akiko_wr   : std_logic;
	signal akiko_req  : std_logic;
	signal akiko_ack  : std_logic;
	signal host_req_r : std_logic;

	SIGNAL NMI_addr            : std_logic_vector(31 downto 0);
	SIGNAL sel_nmi_vector      : std_logic;

	signal chipset_cycle : std_logic;

	signal nResetOut_w : std_logic;
	signal VBR_out_w   : std_logic_vector(31 downto 0);



	--------------------------------------------------------------------------
	-- THE MASTER CHANNEL (Stage E2 Task 4, decision D4).
	--
	-- Everything that masters the bus sits on clk_38 behind ONE mux: the
	-- core's m_* and the MMU table walker.  The walker is a ce-gated clk_38
	-- master that asks for one longword per descriptor; a walk happens during
	-- address translation, before the core's own request exists, so m_req is
	-- idle whenever the walker owns the mux (asserted in sim/ddr3_cpu).
	--
	-- One router decodes x_addr once per access and sends it to one of three
	-- places: RAM (ap040_ram_seq, one per controller), Akiko (its own
	-- sequencer, decision D3b), or the 16-bit adapter, which is left with the
	-- chipset bus, the NMI vector and undecoded space.  Completion returns to
	-- the master as ONE clkena-shaped pulse with the data captured on that
	-- same edge (x_ack_r / x_rdata_r) -- or, for the adapter's traffic, as the
	-- adapter's own mem_ack.
	SIGNAL wk_req     : std_logic;                      -- from the core
	SIGNAL wk_we      : std_logic;
	SIGNAL wk_addr    : std_logic_vector(31 downto 0);
	SIGNAL wk_wdat    : std_logic_vector(31 downto 0);
	SIGNAL wk_ack     : std_logic;                      -- to the core, a LEVEL
	SIGNAL wk_data    : std_logic_vector(31 downto 0);
	SIGNAL wk_berr    : std_logic;                      -- also a level
	SIGNAL wk_go      : std_logic;                      -- walker owns the mux
	TYPE   wk_state_t IS (WK_IDLE, WK_BUSY, WK_DONE);
	SIGNAL wk_st      : wk_state_t;

	SIGNAL x_req      : std_logic;
	SIGNAL x_we       : std_logic;
	SIGNAL x_instr    : std_logic;
	SIGNAL x_size     : std_logic_vector(1 downto 0);
	SIGNAL x_addr     : std_logic_vector(31 downto 0);
	SIGNAL x_wdata    : std_logic_vector(31 downto 0);
	SIGNAL x_ack      : std_logic;                      -- clkena-shaped
	SIGNAL x_rdata    : std_logic_vector(31 downto 0);
	-- the router's three destinations; x_sdram and x_ddr are both RAM
	SIGNAL x_sdram    : std_logic;
	SIGNAL x_ddr      : std_logic;
	SIGNAL x_akiko    : std_logic;
	SIGNAL x_a16      : std_logic;
	-- x_req as the clk_114 sequencers may see it; see where it is driven
	SIGNAL x_fresh    : std_logic := '0';
	SIGNAL q_req      : std_logic;
	SIGNAL q_sdram    : std_logic;                      -- q_req, per destination
	SIGNAL q_ddr      : std_logic;
	SIGNAL a16_req    : std_logic;
	-- the completion, category 2: a pulse on the kernel's edge, data with it
	SIGNAL x_done     : std_logic;
	SIGNAL x_ack_r    : std_logic := '0';
	SIGNAL x_rdata_r  : std_logic_vector(31 downto 0) := (others => '0');

	-- the adapter's side of the core handshake
	SIGNAL a16_ack    : std_logic;
	SIGNAL a16_rdata  : std_logic_vector(31 downto 0);

	-- ap040_ram_seq, SDRAM (rs_) and DDR3 (rd_)
	SIGNAL ramaddr    : std_logic_vector(25 downto 0);  -- mapped SDRAM address
	SIGNAL ddraddr    : std_logic_vector(25 downto 0);  -- offset in board 3
	SIGNAL rs_ack     : std_logic;
	SIGNAL rs_rdata   : std_logic_vector(31 downto 0);
	SIGNAL rd_ack     : std_logic;
	SIGNAL rd_rdata   : std_logic_vector(31 downto 0);

	-- The Akiko sequencer (decision D3b): the adapter's split, one Akiko
	-- register cycle per 16-bit sub-cycle, with akiko_req low between them.
	TYPE   ak_state_t IS (AK_IDLE, AK_SETUP, AK_CYC, AK_GAP);
	SIGNAL ak_st      : ak_state_t;
	SIGNAL ak_left    : std_logic_vector(2 downto 0);   -- bytes still to move
	SIGNAL ak_wsh     : std_logic_vector(31 downto 0);  -- left-aligned
	SIGNAL ak_rsh     : std_logic_vector(31 downto 0);  -- bytes shifted in
	SIGNAL ak_done    : std_logic;

	-- The 16-bit adapter's bus side, which now carries only chipset traffic.
	-- '1' on the cycle the adapter's current sub-cycle is complete.
	SIGNAL bus_ready16 : std_logic;
	-- The 7 MHz chipset bus answers on a single-cycle pulse; these hold that
	-- answer until the CPU's next clock enable.  See where they are driven.
	SIGNAL chipset_ready : std_logic;
	SIGNAL chipset_done  : std_logic;

	-- AP68040 cache maintenance (CINV / CPUSH), mapped onto the external
	-- cache's clear bit below.
	SIGNAL ap040_maint : std_logic;
	SIGNAL ap040_dbg1  : std_logic_vector(255 downto 0);
	SIGNAL ap040_dbg2  : std_logic_vector(127 downto 0);
	SIGNAL ap040_fault : std_logic;
	SIGNAL ap040_halt  : std_logic;
	SIGNAL ap040_busy  : std_logic;
	-- The core's 32-bit master channel (Stage E2).  Task 1 feeds it straight
	-- into the 16-bit adapter, which now lives in this file.
	SIGNAL m_req       : std_logic;
	SIGNAL m_write     : std_logic;
	SIGNAL m_instr     : std_logic;
	SIGNAL m_size      : std_logic_vector(1 downto 0);
	SIGNAL m_addr      : std_logic_vector(31 downto 0);
	SIGNAL m_wdata     : std_logic_vector(31 downto 0);
	SIGNAL m_fc        : std_logic_vector(2 downto 0);
	SIGNAL m_ack       : std_logic;
	SIGNAL m_rdata     : std_logic_vector(31 downto 0);

	COMPONENT ap040_tg68k_compat IS
		GENERIC(
			AP040_HAS_MMU      : integer := 1;
			AP040_HAS_FPU      : integer := 1;
			AP040_ENABLE_CACHE : integer := 1;
			AP040_FAST_SIM     : integer := 0;
			AP040_POST_STORES  : integer := 1;
			AP040_FILL_CHANNEL : integer := 1;
			AP040_BUS16        : integer := 1
		);
		PORT(
			clk               : in  std_logic;
			nreset            : in  std_logic;
			clkena_in         : in  std_logic;
			cache_allow_all   : in  std_logic;
			cache_snoop_stb   : in  std_logic;
			cache_snoop_addr  : in  std_logic_vector(31 downto 0);
			cache_z2_ena      : in  std_logic;
			cache_z3_base0    : in  std_logic_vector(4 downto 0);
			cache_z3_ena0     : in  std_logic;
			cache_z3_base1    : in  std_logic_vector(3 downto 0);
			cache_z3_ena1     : in  std_logic;
			data_in           : in  std_logic_vector(15 downto 0);
			ipl               : in  std_logic_vector(2 downto 0);
			ipl_autovector    : in  std_logic;
			berr              : in  std_logic;
			addr_out          : out std_logic_vector(31 downto 0);
			data_write        : out std_logic_vector(15 downto 0);
			nwr               : out std_logic;
			nuds              : out std_logic;
			nlds              : out std_logic;
			busstate          : out std_logic_vector(1 downto 0);
			longword          : out std_logic;
			nresetout         : out std_logic;
			fc                : out std_logic_vector(2 downto 0);
			nmi_ack_toggle    : out std_logic;
			fill_ena_zorro    : in  std_logic;
			fill_ena_chip     : in  std_logic;
			fill_req          : out std_logic;
			fill_addr         : out std_logic_vector(31 downto 4);
			fill_data         : in  std_logic_vector(127 downto 0);
			fill_ack          : in  std_logic;
			fill_err          : in  std_logic;
			cache_maint_req   : out std_logic;
			cache_maint_ic    : out std_logic;
			cache_maint_dc    : out std_logic;
			mmu_addr_log      : out std_logic_vector(31 downto 0);
			mmu_addr_phys     : out std_logic_vector(31 downto 0);
			mmu_cache_inhibit : out std_logic;
			walker_req        : out std_logic;
			walker_we         : out std_logic;
			walker_addr       : out std_logic_vector(31 downto 0);
			walker_wdat       : out std_logic_vector(31 downto 0);
			walker_ack        : in  std_logic;
			walker_data       : in  std_logic_vector(31 downto 0);
			walker_berr       : in  std_logic;
			cache_req         : out std_logic;
			cache_addr        : out std_logic_vector(31 downto 0);
			cache_data        : in  std_logic_vector(15 downto 0);
			cache_ack         : in  std_logic;
			cache_burst       : out std_logic;
			cache_burst_len   : out std_logic_vector(2 downto 0);
			cache_ramaddr     : out std_logic_vector(28 downto 1);
			cacr_out          : out std_logic_vector(31 downto 0);
			vbr_out           : out std_logic_vector(31 downto 0);
			debug_busy        : out std_logic;
			debug_fault       : out std_logic;
			debug_halted      : out std_logic;
			debug_status      : out std_logic_vector(255 downto 0);
			debug_status2     : out std_logic_vector(127 downto 0);
			m_req             : out std_logic;
			m_write           : out std_logic;
			m_instr           : out std_logic;
			m_size            : out std_logic_vector(1 downto 0);
			m_addr            : out std_logic_vector(31 downto 0);
			m_wdata           : out std_logic_vector(31 downto 0);
			m_fc              : out std_logic_vector(2 downto 0);
			m_ack             : in  std_logic;
			m_rdata           : in  std_logic_vector(31 downto 0)
		);
	END COMPONENT;

	COMPONENT ap040_bus16_adapter IS
		PORT(
			clk        : in  std_logic;
			nreset     : in  std_logic;
			clkena_in  : in  std_logic;
			mem_req    : in  std_logic;
			mem_berr   : in  std_logic;
			mem_write  : in  std_logic;
			mem_instr  : in  std_logic;
			mem_size   : in  std_logic_vector(1 downto 0);
			mem_addr   : in  std_logic_vector(31 downto 0);
			mem_wdata  : in  std_logic_vector(31 downto 0);
			mem_fc     : in  std_logic_vector(2 downto 0);
			mem_ack    : out std_logic;
			mem_rdata  : out std_logic_vector(31 downto 0);
			data_in    : in  std_logic_vector(15 downto 0);
			addr_out   : out std_logic_vector(31 downto 0);
			data_write : out std_logic_vector(15 downto 0);
			nwr        : out std_logic;
			nuds       : out std_logic;
			nlds       : out std_logic;
			busstate   : out std_logic_vector(1 downto 0);
			longword   : out std_logic;
			fc         : out std_logic_vector(2 downto 0)
		);
	END COMPONENT;

BEGIN


	nResetOut <= nResetOut_w;
	VBR_out   <= VBR_out_w;

	sel_eth <= '0';

	-- NMI
	PROCESS(reset, clk)
	BEGIN
		IF reset = '0' THEN
			NMI_addr            <= X"0000007c";
		ELSIF rising_edge(clk) THEN
			NMI_addr            <= VBR_out_w + X"0000007c";
		END IF;
	END PROCESS;

	-- A DATA READ of the vector longword -- not a fetch, not a store, and not
	-- a walk: a descriptor that happens to live at the NMI vector address is
	-- memory, and must be read from memory, not answered from the vector shim.
	--
	-- Stage E2: on the master channel.  This was `bstate = "10"`, the
	-- adapter's bus state, which a RAM access no longer reaches; and the
	-- compare is combinational, because a registered copy of it is one clk
	-- cycle behind x_addr on the first edge the router's decision is taken.
	sel_nmi_vector <= '1' WHEN x_addr(31 downto 2) = NMI_addr(31 downto 2)
	                          AND x_instr = '0' AND x_we = '0'
	                          AND wk_go = '0' ELSE '0';

	wrd     <= wr;
	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			z2ram_ena  <= ziiram_active;
			z3ram_ena  <= ziiiram_active;
			z3ram2_ena <= ziiiram2_active;
			z3ram3_ena <= ziiiram3_active;

			sel_undecoded_d <= sel_undecoded;
		END IF;
	END PROCESS;

	-- Register incoming data
	process(clk)
	begin
		if rising_edge(clk) then
			if sel_undecoded = '1' then
				datatg68_c <= X"FFFF";
			elsif sel_eth = '1' then
				datatg68_c <= frometh;
			else
				datatg68_c <= r_data;
			end if;
		end if;
	end process;

	sel_akiko     <= '1' when x_addr(31 downto 16) = X"00B8" else '0';
	sel_32        <= '1' when x_addr(31 downto 24) /= X"00" and x_addr(31 downto 24) /= X"ff" else '0'; -- Decode 32-bit space, but exclude interrupt vectors
	--  sel_z3ram       <= '1' WHEN (x_addr(31 downto 24)=z3ram_base) else '0'; -- AND z3ram_ena='1' ELSE '0';
	-- Third block of ZIII RAM.  Decoded against the base the OS actually
	-- assigned (latched in minimig_autoconfig.v), not against a guess: the OS
	-- allocates ZIII bases from its own free list and puts this board wherever
	-- it likes -- $08000000 for the small SDRAM board, elsewhere for the 16 MB
	-- DDR3 one -- and the old hard-wired $41000000/$44000000 decode is exactly
	-- why the board had to be disabled before.  The board is size-aligned, so
	-- the bits above its size are the base and the rest are the offset.
	--
	-- z3ram3_base is A31-A24, so the compare has 16 MB granularity.  That is
	-- exact for the 16 MB DDR3 board.  For the 4 MB leftover SDRAM board
	-- (haveddr3 = false) it claims the rest of the 16 MB the board sits in,
	-- which is harmless only because every ZIII base the OS hands out is 16 MB
	-- aligned and nothing else is placed inside that window -- checked, not
	-- assumed, by sim/autoconfig.  Making it exact means latching A23-A16 from
	-- the register-48 write too; see the plan's "Later" list.
	-- sel_32 first, and not merely as an optimisation: it excludes the 24-bit
	-- space (x_addr(31 downto 24) = 0x00) and the interrupt vectors (0xff),
	-- where a Zorro-III board can never live.  Without it a base register that
	-- reads back as 0 -- an unconnected wire, a board the OS has not placed
	-- yet, a bug upstream -- makes this board answer for chip RAM, the CIAs and
	-- the custom registers the moment it is enabled, and the machine dies with
	-- a black screen before it can say why.  It cost a bring-up cycle on
	-- 2026-09-06 (z3ram3_base left undriven in minimig_virtual_top.v).
	sel_z3ram3    <= '1' WHEN sel_32 = '1'
	                          AND x_addr(31 downto z3ram3_size_log2) = z3ram3_base(7 downto z3ram3_size_log2 - 24)
	                          AND z3ram3_ena = '1' ELSE '0';
	-- First block of ZIII RAM - 0x40000000 - 0x40ffffff
	-- Second block of ZIII RAM - 32 meg from 0x42000000 - 0x43ffffff
	-- Both still assume where the OS puts them, which holds because they are
	-- configured first and land on the bottom of the ZIII free space.  Board 3
	-- wins if the OS ever does place it inside one of these ranges, so that an
	-- address can never select two backends at once.
	sel_z3ram     <= '1' WHEN (x_addr(31 downto 30) = "01") and x_addr(26 downto 24) = "000" AND z3ram_ena = '1' AND sel_z3ram3 = '0' ELSE '0';
	sel_z3ram2    <= '1' WHEN (x_addr(31 downto 30) = "01") and x_addr(25) = '1' AND z3ram2_ena = '1' AND sel_z3ram3 = '0' ELSE '0';
	sel_z2ram     <= '1' WHEN (x_addr(31 downto 24) = X"00") AND ((x_addr(23 downto 21) = "001") OR (x_addr(23 downto 21) = "010") OR (x_addr(23 downto 21) = "011") OR (x_addr(23 downto 21) = "100")) AND z2ram_ena = '1' ELSE '0';
	--sel_eth         <= '1' WHEN (x_addr(31 downto 24) = eth_base) AND eth_cfgd='1' ELSE '0';
	sel_chip      <= '1' WHEN (x_addr(31 downto 24) = X"00") AND (x_addr(23 downto 21) = "000") ELSE '0'; --$000000 - $1FFFFF
	sel_chipram   <= '1' WHEN sel_chip = '1' AND turbochip_d = '1' ELSE '0';
	sel_kick      <= '1' WHEN (x_addr(31 downto 24) = X"00") AND ((x_addr(23 downto 19) = "11111") OR (x_addr(23 downto 19) = "11100")) AND x_we = '0' ELSE '0'; -- $F8xxxx, $E0xxxx, read only
	sel_kickram   <= '1' WHEN sel_kick = '1' AND turbokick_d = '1' ELSE '0';
	sel_slow      <= '1' WHEN (x_addr(31 downto 24) = X"00") AND ((x_addr(23 downto 20) = X"C" AND ((x_addr(19) = '0' AND slow_config /= "00") OR (x_addr(19) = '1' AND slow_config(1) = '1'))) OR (x_addr(23 downto 19) = X"D" & '0' AND slow_config = "11")) ELSE '0'; -- $C00000 - $D7FFFF
	sel_slowram   <= '1' WHEN sel_slow = '1' AND turboslow_d = '1' ELSE '0';
	-- sel_cart        <= '1' WHEN (x_addr(31 downto 24) = X"00") AND (x_addr(23 downto 20)="1010") ELSE '0'; -- $A00000 - $A7FFFF (actually matches up to $AFFFFF)
	sel_audio     <= '1' WHEN (x_addr(31 downto 24) = X"00") AND (x_addr(23 downto 18) = "111011") ELSE '0'; -- $EC0000 - $EFFFFF
	sel_undecoded <= '1' WHEN sel_32 = '1' and sel_z3ram = '0' and sel_z3ram2 = '0' and sel_z3ram3 = '0' else '0';
	-- '1' when the DDR3 fast RAM is present.  Everything DDR3-specific is gated
	-- with this, so haveddr3 = false reproduces today's core exactly.
	have_ddr        <= '1' WHEN haveddr3 ELSE '0';
	-- The DDR3 is an extra board, not a different backing for the boards the
	-- SDRAM already serves: boards 1 and 2 stay on the SDRAM whether or not the
	-- DDR3 is fitted, and board 3 is the DDR3 board when it is (falling back to
	-- the leftover SDRAM board when it is not).  See
	-- findings/ddr3/z3ram3-on-ddr3-plan.md.
	sel_ddr         <= sel_z3ram3 AND have_ddr;
	sel_z3ram_sdram <= sel_z3ram OR sel_z3ram2 OR (sel_z3ram3 AND NOT have_ddr);
	sel_ram       <= '1' WHEN (sel_z2ram = '1' OR sel_z3ram_sdram = '1' OR sel_chipram = '1' OR sel_slowram = '1' OR sel_kickram = '1' OR sel_audio = '1') ELSE
	'0';


	cache_inhibit <= '1' WHEN sel_kickram = '1' ELSE '0';

	--------------------------------------------------------------------------
	-- THE ROUTER (Stage E2 Task 4).  Every sel_* above is decoded from the
	-- MASTER address x_addr, once per access -- not from the adapter's
	-- advancing address, which a RAM access never reaches.  Every window
	-- boundary is at bit 18 or above and an access spans at most four bytes,
	-- so an access that decoded differently at its first and last byte would
	-- need a window to be narrowed first.
	--
	-- Precedence: the NMI vector shim beats RAM and Akiko; everything that is
	-- not RAM or Akiko goes to the adapter.
	--------------------------------------------------------------------------
	x_sdram <= sel_ram   AND NOT sel_nmi_vector;
	x_ddr   <= sel_ddr   AND NOT sel_nmi_vector;
	x_akiko <= sel_akiko AND NOT sel_nmi_vector;
	x_a16   <= NOT (x_sdram OR x_ddr OR x_akiko);

	-- x_req AS THE clk_114 SEQUENCERS SEE IT.  x_* is clk_38 and changes only
	-- on a kernel edge K, the edge clkena_r was high into; cpu.xdc gives a
	-- path from the island two clk cycles, so the first clk edge that may
	-- look at a new x_* is K+2.  q_req is therefore masked on the two edges
	-- before that: K itself (clkena_r high) and K+1 (x_fresh high).
	--
	-- The mask on K is also what ends each sequencer's completion level.
	-- Both hold their done flag until they see the request low, and the
	-- core does not always give them that: ap040_cache keeps m_req high
	-- straight from one line-fill beat into the next, changing only the
	-- address.  With the mask, every access the core consumes is followed by
	-- at least one clk edge on which q_req is low.
	--
	-- Neither mask can land inside an access: clkena_r is only high on a
	-- completion, or while no request is outstanding.
	q_req   <= x_req AND NOT clkena_r AND NOT x_fresh;
	q_sdram <= q_req AND x_sdram;
	q_ddr   <= q_req AND x_ddr;

	ram_seq_sdram : entity work.ap040_ram_seq
		PORT MAP(
			clk    => clk,
			reset  => reset,
			req    => q_sdram,
			we     => x_we,
			ir     => x_instr,
			size   => x_size,
			addr   => ramaddr,
			wdata  => x_wdata,
			ack    => rs_ack,
			rdata  => rs_rdata,
			gate   => unit_gate,
			hit    => ram_hit,
			u_req  => ram_req,
			u_we   => ram_we,
			u_ir   => ram_ir,
			u_wadr => ram_wadr,
			u_bs   => ram_bs,
			u_wdat => ram_wdat,
			u_rdat => ram_rdat,
			u_ack  => ram_ack
		);

	-- DDR3: same sequencer, same gate.  ddr_ready is the island's init/reset-
	-- done flag: before it an access is simply held (the CPU stalls), never
	-- released with rubbish and never faulted.
	-- The DDR3 address is the offset inside board 3, which the OS may have put
	-- anywhere, so the base bits are dropped and what is left is zero-extended
	-- (design.md D6, amended by findings/ddr3/z3ram3-on-ddr3-plan.md: identity
	-- only when the board covers the whole 64 MB).  One assignment, so
	-- ddraddr has one driver.
	ddraddr <= ddr_zero_hi & x_addr(z3ram3_size_log2 - 1 downto 0);

	g_ddr_seq : IF haveddr3 GENERATE
		SIGNAL ddr_ack_q : std_logic;
	BEGIN
		ddr_ack_q <= ddr_ack AND ddr_ready;

		ram_seq_ddr : entity work.ap040_ram_seq
			PORT MAP(
				clk    => clk,
				reset  => reset,
				req    => q_ddr,
				we     => x_we,
				ir     => x_instr,
				size   => x_size,
				addr   => ddraddr,
				wdata  => x_wdata,
				ack    => rd_ack,
				rdata  => rd_rdata,
				gate   => unit_gate,
				hit    => ddr_hit,
				u_req  => ddr_req,
				u_we   => ddr_we,
				u_ir   => ddr_ir,
				u_wadr => ddr_wadr,
				u_bs   => ddr_bs,
				u_wdat => ddr_wdat,
				u_rdat => ddr_rdat,
				u_ack  => ddr_ack_q
			);
	END GENERATE;

	g_no_ddr_seq : IF NOT haveddr3 GENERATE
		ddr_req  <= '0';
		ddr_we   <= '0';
		ddr_ir   <= '0';
		ddr_wadr <= (OTHERS => '0');
		ddr_bs   <= (OTHERS => '0');
		ddr_wdat <= (OTHERS => '0');
		rd_ack   <= '0';
		rd_rdata <= (OTHERS => '0');
	END GENERATE;

	--------------------------------------------------------------------------
	-- The Akiko sequencer (decision D3b).  Akiko's registers are 16 bits, so
	-- an access is split EXACTLY as ap040_bus16_adapter.v splits it -- a byte
	-- is one cycle on its word, an even word one cycle, an even longword two
	-- (A, A+2), anything odd byte-first -- and akiko_addr is the advancing
	-- byte address the adapter's addr_out was.  Two rules come from akiko.vhd:
	--
	--   * its ack is REGISTERED from req, so it is still high on the edge
	--     after req drops;
	--   * cornerturn acknowledges the RISING edge of req.
	--
	-- So req goes low for two clk cycles (AK_GAP, AK_SETUP) between register
	-- cycles, and AK_CYC waits for the ack its own req produced.
	--
	-- A fetch from Akiko space is served as a read.  (Before E2 it raised no
	-- akiko_req at all and hung the CPU.)
	--------------------------------------------------------------------------
	PROCESS(clk, reset)
		VARIABLE odd_v  : boolean;
		VARIABLE two_v  : boolean;
	BEGIN
		IF reset = '0' THEN
			ak_st      <= AK_IDLE;
			ak_left    <= (OTHERS => '0');
			ak_wsh     <= (OTHERS => '0');
			ak_rsh     <= (OTHERS => '0');
			ak_done    <= '0';
			akiko_addr <= (OTHERS => '0');
			akiko_d    <= (OTHERS => '0');
			akiko_req  <= '0';
			akiko_wr   <= '0';
		ELSIF rising_edge(clk) THEN
			-- the completion level lasts exactly as long as the request does
			IF (q_req AND x_akiko) = '0' THEN
				ak_done <= '0';
			END IF;

			odd_v := akiko_addr(0) = '1';
			two_v := NOT odd_v AND ak_left(2 DOWNTO 1) /= "00";

			CASE ak_st IS
				WHEN AK_IDLE =>
					akiko_req <= '0';
					akiko_wr  <= '0';
					IF (q_req AND x_akiko) = '1' AND ak_done = '0' THEN
						akiko_addr <= x_addr(10 DOWNTO 0);
						ak_rsh     <= (OTHERS => '0');
						CASE x_size IS
							WHEN "00" =>
								ak_left <= "001";
								ak_wsh  <= x_wdata(7 DOWNTO 0) & X"000000";
							WHEN "01" =>
								ak_left <= "010";
								ak_wsh  <= x_wdata(15 DOWNTO 0) & X"0000";
							WHEN OTHERS =>
								ak_left <= "100";
								ak_wsh  <= x_wdata;
						END CASE;
						akiko_wr <= x_we;
						ak_st    <= AK_SETUP;
					END IF;

				WHEN AK_SETUP =>
					IF two_v THEN
						akiko_d <= ak_wsh(31 DOWNTO 16);
					ELSE
						akiko_d <= ak_wsh(31 DOWNTO 24) & ak_wsh(31 DOWNTO 24);
					END IF;
					akiko_req <= '1';
					ak_st     <= AK_CYC;

				WHEN AK_CYC =>
					IF akiko_ack = '1' THEN
						-- big endian, as the adapter's rshift
						IF odd_v THEN
							ak_rsh <= ak_rsh(23 DOWNTO 0) & akiko_q(7 DOWNTO 0);
						ELSIF two_v THEN
							ak_rsh <= ak_rsh(15 DOWNTO 0) & akiko_q;
						ELSE
							ak_rsh <= ak_rsh(23 DOWNTO 0) & akiko_q(15 DOWNTO 8);
						END IF;
						IF two_v THEN
							akiko_addr <= akiko_addr + 2;
							ak_left    <= ak_left - 2;
							ak_wsh     <= ak_wsh(15 DOWNTO 0) & X"0000";
						ELSE
							akiko_addr <= akiko_addr + 1;
							ak_left    <= ak_left - 1;
							ak_wsh     <= ak_wsh(23 DOWNTO 0) & X"00";
						END IF;
						akiko_req <= '0';
						ak_st     <= AK_GAP;
					END IF;

				WHEN AK_GAP =>
					IF ak_left = "000" THEN
						akiko_wr <= '0';
						ak_done  <= '1';
						ak_st    <= AK_IDLE;
					ELSE
						ak_st    <= AK_SETUP;
					END IF;
			END CASE;
		END IF;
	END PROCESS;

	x_done <= rs_ack OR rd_ack OR ak_done;

	-- This is the mapping to the SDRAM
	-- map $00-$1F to $00-$1F (chipram), $A0-$FF to $20-$7F. All non-fastram goes into the first
	-- 8M block (i.e. SDRAM bank 0). This map should be the same as in minimig_sram_bridge.v
	-- 8M Zorro II RAM $20-9F goes to $80-$FF (SDRAM bank 1)

	-- Boolean logic can handle this mapping.  Furthermore, applying the same
	-- mapping to the other three banks is harmless, so there's no point expending logic
	-- to make it specific to the first bank.

	-- ABCD  B|C  A^(B|C)
	--
	-- 0000  0    0       0 -> 0
	--
	-- 0010  1    1       2 -> A
	-- 0100  1    1       4 -> C
	-- 0110  1    1       6 -> E
	-- 1000  0    1       8 -> 8
	--
	-- 1010  1    0       A -> 2
	-- 1100  1    0       C -> 4
	-- 1110  1    0       E -> 6

	-- On 64-meg platforms we need an extra 32 meg merged into the memory map.
	-- If we configure that range second, it should end up in 42000000 - 43ffffff
	-- so the extra 2 or 4 meg will end up at either 41000000 or 4400000, depending
	-- on whether the extra 32 meg is configured.

	-- addr(25) will be high only when the second 32-meg block is active (64-mb mode)
	-- addr(24) will be high for the 16-meg block or the second half of the 32-meg block

	-- The extra ZIII mapping maps 41000000 -> 2000000, (or 44000000 -> 2000000)
	-- bits 23 downto 20 are mapped like so:
	-- 0000->0010 (1st 2 meg), 0010->0100 (2nd 2 meg),
	-- 0100->0010 (3rd 2 meg, aliases 1st), 0110->0100 (4th 2 meg, aliases 2nd),
	-- addr(23) <= addr(23) and not sel_ziii_3;
	-- addr(22) <= (addr(22) and not sel_ziii_3) or (addr(21) and sel_ziii_3);
	-- addr(21) <= addr(21) xor sel_ziii_3;

	ramaddr(25)           <= sel_z3ram2; -- Second block of 32 meg
	ramaddr(24)           <= (x_addr(24) and sel_z3ram2) or sel_z3ram; -- Remap the first block of Zorro III RAM to 0x1000000
	ramaddr(23)           <= (x_addr(23) xor (x_addr(22) or x_addr(21))) and not sel_z3ram3;
	ramaddr(22)           <= x_addr(21) when sel_z3ram3 = '1' else x_addr(22);
	ramaddr(21)           <= x_addr(21) xor sel_z3ram3;
	ramaddr(20 downto 0)  <= x_addr(20 downto 0);

	-- The adapter's ADVANCING address (A, then A+2 within one access): what
	-- the 7 MHz chipset machine latches, and what dbg_rtg shows.
	cpuaddr <= addrtg68;

	--------------------------------------------------------------------------
	-- The CPU kernel: the AP68040.
	--------------------------------------------------------------------------

	-- Always elaborated since Stage E4a removed the TG68K branch.  It stays a
	-- generate on purpose: Vivado names an if-generate instance
	-- "<label>.<instance>", and fpga/openaars/.../cpu.xdc, the ILA scripts and
	-- sim/ddr3_cpu all name the kernel as tg68k/g_ap040.ap040.  Unwrapping it
	-- would rename that path, and the -quiet timing rules would drop silently.
	g_ap040 : IF true GENERATE
		-- The 1:3 phase marker.  clk_cpu is clk divided by three off the same
		-- MMCM with no phase shift, so every clk_cpu rising edge lands on a
		-- clk one; what the clk side needs to know is WHICH of its three
		-- edges that is, and it cannot count them on its own because nothing
		-- aligns its counter to the MMCM's divider.
		--
		-- So the kernel's clock supplies the alignment: cpu_tgl flips on every
		-- clk_cpu edge, the clk domain samples it (getting the pre-edge value
		-- on the coincident edge, which is the ordinary hold check every other
		-- signal leaving this island already has), and the difference is a
		-- one-clk-cycle pulse in the cycle AFTER the clk_cpu edge.  Two more
		-- registers move it to the cycle BEFORE the next one:
		--
		--   clk_cpu edge at T (= clk edge T), edges T+1, T+2, next at T+3
		--   cpu_tgl   flips at T
		--   cpu_tgl_d flips at T+1        -> cpu_tgl XOR cpu_tgl_d high in (T,T+1)
		--   cpu_ph                        high in (T+1,T+2)
		--   cpu_ph2                       high in (T+2,T+3)
		--
		-- so a clk register sampling at edge T+3 -- the next clk_cpu edge --
		-- sees cpu_ph2 = '1', and cpu_ph2 is '0' on the other two edges.  That
		-- makes clkena below a pulse on exactly the clk edges the kernel
		-- advances on, which is the shape enaWRreg used to give it.
		--
		-- Free-running by design, like the core's stall watchdog: a wedge
		-- anywhere else must not be able to stop the phase marker, and the
		-- three registers power up at '0' together so the chain is in step
		-- from configuration.
		SIGNAL cpu_tgl   : std_logic := '0';
		SIGNAL cpu_tgl_d : std_logic := '0';
		-- ph_sr(k) is high in (T+1+k, T+2+k); cpu_ph wants (T+N-2, T+N-1), so
		-- it is ph_sr(N-3).  Four stages covers ratios 3 to 6.
		SIGNAL ph_sr     : std_logic_vector(3 downto 0) := (others => '0');
		-- cpu_ph is declared in the architecture region, next to cpu_ph2: the
		-- completion process is outside this generate and reads it.

		-- STAGE D3, THE OTHER HALF OF THE CROSSING.  The chipset DMA write
		-- snoop is the one bus -> core signal that is NOT a level the core
		-- can wait for, and moving the kernel to clk_cpu breaks it outright.
		--
		-- sdram_ctrl makes snoop_act exactly one clk cycle wide -- cleared
		-- unconditionally every sysclk (sdram_ctrl.v:492), set at ph2 (:633)
		-- -- and registers it out still one cycle wide (:190-196).  Only one
		-- clk cycle in three precedes a clk_cpu edge, so a raw pulse reaches
		-- the cache only when it happens to land in that one: TWO SNOOPS IN
		-- THREE VANISH.
		--
		-- The consumer states what it needs, and states what happened last
		-- time it did not get it (ap040_cache.v:111-116): "s_stb is a single
		-- CLOCK pulse in THIS clock domain, ce-independent, with s_addr held
		-- alongside it.  (A ce-gated snoop port was the 5.1 loss: chipset
		-- writes landing while clkena is frozen simply vanished.)"  Losing
		-- them through the clock instead of through the enable is the same
		-- bug with the same signature: stale data-cache lines after blitter
		-- or trackdisk DMA into chip RAM, intermittent, data-dependent and
		-- never a hang.  Chip RAM IS cached on the D side -- the
		-- $000000-$1fffff window at ap040_tg68k_compat.v:396 -- and with
		-- Turbo chip RAM on the 040 caches it in earnest.
		--
		-- So the pulse and its address are latched here and the latch is
		-- cleared on cpu_ph2, the clk cycle the kernel takes it: the kernel
		-- then sees a level that is high at EXACTLY ONE clk_cpu edge and low
		-- at the next, which is the single pulse in its own clock domain the
		-- contract asks for.
		--
		-- Cleared on cpu_ph2 and NOT on clkena, although clkena is the
		-- "held until consumed" shape everything else on this crossing uses.
		-- clkena stops for the whole of a bus access -- a chipset cycle is
		-- some eighty clk cycles -- and a second snoop arriving inside that
		-- window would be merged into the first and lost.  On cpu_ph2 the
		-- latch is never held for more than three clk cycles, and a chip
		-- slot-1 write happens at most once per sixteen-cycle SDRAM round,
		-- so two snoops can never merge.  The set wins over the clear, so a
		-- snoop arriving on the clearing edge is delivered one clk_cpu
		-- period later rather than dropped.
		SIGNAL snp_stb_held  : std_logic := '0';
		SIGNAL snp_addr_held : std_logic_vector(31 downto 0) := (others => '0');
	BEGIN
		PROCESS(clk_cpu)
		BEGIN
			IF rising_edge(clk_cpu) THEN
				cpu_tgl <= NOT cpu_tgl;
			END IF;
		END PROCESS;

		-- THE MARKER TRACKS THE CLOCK RATIO.  What clkena needs is a pulse in
		-- the clk cycle IMMEDIATELY BEFORE a clk_cpu edge, because clkena_r
		-- registers cpu_ph and the kernel samples the result on its own next
		-- edge.  With edges at T and T+N that cycle is (T+N-2, T+N-1), and
		-- the XOR of the toggle and its delayed copy marks (T+1, T+2).  Those
		-- coincide only at N = 3, so the shift register below supplies one
		-- more stage per ratio step.  cpu_clk_ratio is a generic, so the index
		-- is a constant and the selection synthesises to a wire, not a mux.
		--
		-- This is the bug that made the first divide-by-4 bitstream show a
		-- black screen: the marker was asserted to be ratio-agnostic, the
		-- enable landed one cycle early, and the core never advanced at all.
		PROCESS(clk)
		BEGIN
			IF rising_edge(clk) THEN
				cpu_tgl_d <= cpu_tgl;
				ph_sr     <= ph_sr(2 DOWNTO 0) & (cpu_tgl XOR cpu_tgl_d);
				cpu_ph2   <= cpu_ph;
			END IF;
		END PROCESS;

		cpu_ph <= ph_sr(cpu_clk_ratio - 3);

		-- The snoop holder; see the note beside its signals.
		PROCESS(clk)
		BEGIN
			IF rising_edge(clk) THEN
				IF snoop_stb = '1' THEN
					snp_stb_held  <= '1';
					snp_addr_held <= snoop_addr;
				ELSIF cpu_ph2 = '1' THEN
					snp_stb_held  <= '0';
				END IF;
			END IF;
		END PROCESS;

		ap040 : COMPONENT ap040_tg68k_compat
			GENERIC MAP(
				AP040_HAS_MMU      => ap040_has_mmu,
				AP040_HAS_FPU      => ap040_has_fpu,
				AP040_ENABLE_CACHE => ap040_enable_cache,
				AP040_FAST_SIM     => 0,
				AP040_POST_STORES  => ap040_post_stores,
				-- The line-fill channel is off (E2 D4/D5): a line fills over m_*.
				AP040_FILL_CHANNEL => 0,
				-- The 16-bit adapter is instantiated below, in this file.
				AP040_BUS16        => 0
			)
			PORT MAP(
				-- The CPU island's own 37.8125 MHz clock.  So are the master
				-- mux, the walker and the 16-bit adapter.  The router's
				-- sequencers, slower, the chipset state machine, Akiko and the
				-- registers facing sdram_ctrl and ddr3_fastram stay on clk,
				-- because that is the clock the controllers are on.
				clk            => clk_cpu,
				nreset         => reset,
				clkena_in      => clkena,
				-- unused with AP040_BUS16 => 0: the adapter below has data_in
				data_in        => (others => '0'),
				ipl            => cpuIPL,
				ipl_autovector => '1',
				-- The SoC never raises a bus error: undecoded 32-bit space is
				-- auto-completed with $FFFF by sel_undecoded.  The core has its
				-- own stall watchdog.
				berr           => '0',

				addr_out       => OPEN,
				data_write     => OPEN,
				busstate       => OPEN,
				longword       => OPEN,
				nwr            => OPEN,
				nuds           => OPEN,
				nlds           => OPEN,
				nresetout      => nResetOut_w,
				fc             => open,
				nmi_ack_toggle => open,
				vbr_out        => VBR_out_w,

				-- Cacheable windows for the 040's internal caches.  Chip RAM
				-- is covered by cache_z2_ena and the core's own hard-wired
				-- $200000-$9FFFFF window; the Zorro III windows follow the
				-- autoconfig state this wrapper already tracks.  Board 0 is
				-- addr(31:27), so 01000 is $40000000-$47FFFFFF -- 128 MB
				-- around the 16 MB SDRAM board; board 1 is addr(31:28), a
				-- 256 MB window following the base the OS gave the DDR3 board
				-- wherever it put it.  Both are much wider than the board
				-- inside them, so a cacheable read can land in a hole no
				-- board decodes, which the router sends to the adapter as
				-- undecoded space.
				cache_allow_all  => '0',
				cache_snoop_stb  => snp_stb_held,
				cache_snoop_addr => snp_addr_held,
				cache_z2_ena     => z2ram_ena,
				cache_z3_base0   => "01000",
				cache_z3_ena0    => z3ram_ena,
				cache_z3_base1   => z3ram3_base(7 downto 4),
				cache_z3_ena1    => z3ram3_ena,

				-- Stage B: the table walker rides this wrapper's own memory
				-- path, one longword per descriptor through the master mux.
				-- ap040_walker_cdc is deliberately NOT used: the walker FSM
				-- below is on the core's own clock and enable.
				walker_req     => wk_req,
				walker_we      => wk_we,
				walker_addr    => wk_addr,
				walker_wdat    => wk_wdat,
				walker_ack     => wk_ack,
				walker_data    => wk_data,
				walker_berr    => wk_berr,

				-- Stage D's line-fill channel is OFF (E2 decision D4).  The
				-- router that served it borrowed the bus on clk_114 and was one
				-- of the three masters D4 collapses; with the unit port a line
				-- fill has no 16-bit sub-cycles to stream, so the channel is
				-- retired rather than converted.  AP040_FILL_CHANNEL => 0 below
				-- stubs it inside the compat top as well.
				fill_ena_zorro => '0',
				fill_ena_chip  => '0',
				fill_req       => open,
				fill_addr      => open,
				fill_data      => (others => '0'),
				fill_ack       => '0',
				fill_err       => '0',

				-- The older 16-byte burst port, stubbed to zero inside the
				-- compat top and superseded by the fill channel above.
				cache_req      => open,
				cache_addr     => open,
				cache_data     => (others => '0'),
				cache_ack      => '0',
				cache_burst    => open,
				cache_burst_len=> open,
				cache_ramaddr  => open,

				cache_maint_req => ap040_maint,
				cache_maint_ic  => open,
				cache_maint_dc  => open,

				mmu_addr_log      => open,
				mmu_addr_phys     => open,
				mmu_cache_inhibit => open,
				cacr_out          => open,
				debug_busy        => ap040_busy,
				debug_fault       => ap040_fault,
				debug_halted      => ap040_halt,
				debug_status      => ap040_dbg1,
				debug_status2     => ap040_dbg2,

				m_req             => m_req,
				m_write           => m_write,
				m_instr           => m_instr,
				m_size            => m_size,
				m_addr            => m_addr,
				m_wdata           => m_wdata,
				m_fc              => m_fc,
				m_ack             => m_ack,
				m_rdata           => m_rdata
			);

		-- The master mux.  The walker owns it from the ce edge it raises wk_go
		-- to the ce edge it takes its answer; m_req is idle for all of that.
		x_req   <= '1'     WHEN wk_go = '1' ELSE m_req;
		x_we    <= wk_we   WHEN wk_go = '1' ELSE m_write;
		x_instr <= '0'     WHEN wk_go = '1' ELSE m_instr;
		x_size  <= "10"    WHEN wk_go = '1' ELSE m_size;    -- AP040_SZ_L
		x_addr  <= wk_addr WHEN wk_go = '1' ELSE m_addr;
		x_wdata <= wk_wdat WHEN wk_go = '1' ELSE m_wdata;

		-- The answer, from whichever side served it, to whichever master
		-- asked.  a16_ack is the adapter's own registered pulse, x_ack_r the
		-- router's; they can never both be high, since an access goes to one
		-- side only.
		a16_req <= x_req AND x_a16;

		x_ack   <= a16_ack OR x_ack_r;
		x_rdata <= a16_rdata WHEN a16_ack = '1' ELSE x_rdata_r;
		m_ack   <= x_ack AND NOT wk_go;
		m_rdata <= x_rdata;

		-- The 16-bit adapter, moved out of the compat top (Stage E2 Task 1).
		-- Since Task 4b-2 it gets only what the router does not send to RAM
		-- or Akiko: the chipset bus, the NMI vector and undecoded space.
		bus16 : COMPONENT ap040_bus16_adapter
			PORT MAP(
				clk        => clk_cpu,
				nreset     => reset,
				clkena_in  => clkena,
				mem_req    => a16_req,
				mem_berr   => '0',
				mem_write  => x_we,
				mem_instr  => x_instr,
				mem_size   => x_size,
				mem_addr   => x_addr,
				mem_wdata  => x_wdata,
				mem_fc     => m_fc,
				mem_ack    => a16_ack,
				mem_rdata  => a16_rdata,
				data_in    => datatg68_r,
				addr_out   => addrtg68,
				data_write => w_datatg68,
				nwr        => wr,
				nuds       => uds_in,
				nlds       => lds_in,
				busstate   => state,
				longword   => OPEN,
				fc         => OPEN
			);

		--------------------------------------------------------------------------
		-- The walker (Stage E2, decision D4): a clk_38 master on the core's own
		-- enable, one longword request per descriptor through the master mux.
		--
		-- Errors, following walker_mem_bad in the MiSTer reference: a
		-- misaligned descriptor address, or one that decodes as nothing, raises
		-- walker_berr rather than hanging.  The MMU turns that into an
		-- unsuccessful table search -- a Guru -- instead of a silent halt.  An
		-- undecoded descriptor still runs its access (the adapter auto-completes
		-- it); sel_undecoded_d has been stable for the whole of it by then.
		--------------------------------------------------------------------------
		PROCESS(clk_cpu, reset)
		BEGIN
			IF reset = '0' THEN
				wk_st   <= WK_IDLE;
				wk_go   <= '0';
				wk_ack  <= '0';
				wk_berr <= '0';
				wk_data <= (OTHERS => '0');
			ELSIF rising_edge(clk_cpu) THEN
				IF clkena = '1' THEN
					CASE wk_st IS
						WHEN WK_IDLE =>
							IF wk_req = '1' THEN
								IF wk_addr(1 DOWNTO 0) /= "00" THEN
									-- a descriptor is a longword; this table is corrupt
									wk_berr <= '1';
									wk_st   <= WK_DONE;
								ELSE
									wk_go   <= '1';
									wk_st   <= WK_BUSY;
								END IF;
							END IF;

						WHEN WK_BUSY =>
							IF x_ack = '1' THEN
								wk_go   <= '0';
								wk_data <= x_rdata;
								IF sel_undecoded_d = '1' THEN
									wk_berr <= '1';   -- nothing lives here
								ELSE
									wk_ack  <= '1';
								END IF;
								wk_st   <= WK_DONE;
							END IF;

						WHEN WK_DONE =>
							-- ap040_mmu drops walker_req when it has taken the
							-- answer and inserts a request-low cycle before the
							-- next descriptor, so this is the whole handshake.
							IF wk_req = '0' THEN
								wk_ack  <= '0';
								wk_berr <= '0';
								wk_st   <= WK_IDLE;
							END IF;
					END CASE;
				END IF;
			END IF;
		END PROCESS;

		-- ap040_core.v:6141  debug_status  = {magic, .., state, a0, d2, d1, d0, a7, ir, sr, pc}
		-- ap040_core.v:6134  debug_status2 = {aer_fa, usp, isp, 16'd0, exc_vec, 5'd0, in_exc, fault, 1'b0}
		dbg_pc         <= ap040_dbg1(31 downto 0);
		dbg_sr         <= ap040_dbg1(47 downto 32);
		dbg_ir         <= ap040_dbg1(63 downto 48);
		dbg_fault_addr <= ap040_dbg2(127 downto 96);
		dbg_exc_vec    <= ap040_dbg2(15 downto 8);
		dbg_flags      <= ap040_fault & ap040_dbg2(2) & ap040_halt & ap040_busy;

		-- The AP68040 has no skipFetch (a TG68K debug output, unconnected at
		-- the top level anyway).
		skipFetch <= '0';

		-- CACR_out feeds cpu_cache_ctrl on both external caches (sdram_ctrl
		-- and ddr3_fastram), whose nibble means {clear, -, freeze, enable}.
		-- The 040's CACR is a different register entirely -- data enable is
		-- bit 31, instruction enable bit 15 -- so it is mapped here rather
		-- than passed through.
		--
		-- Enable is held high.  The external cache is write-through and
		-- physically tagged, sdram_ctrl snoops every chipset write into it,
		-- and nothing but the CPU writes the DDR3, so it stays coherent
		-- whatever the 040 does with its own caches.  Clear follows
		-- CINV/CPUSH as belt and braces: by that reasoning an external flush
		-- is never actually required, and the edge detector only samples
		-- while the chip select is low, so a missed pulse costs nothing
		-- either.  Stage A5 checks the mapping against the real registers.
		CACR_out <= ap040_maint & "001";
	END GENERATE;

	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF (reset = '0' OR nResetOut_w = '0') THEN
				turbochip_d   <= '0';
				turbokick_d   <= '0';
				turboslow_d   <= '0';
				cacheline_clr <= '0';
			ELSIF q_req = '0' AND clkena_r = '0' AND x_fresh = '0' AND state = "01" THEN    -- No mem access, so safe to switch chipram access mode
				-- (the master's request, not just the adapter's bus state: a
				-- RAM access never reaches the adapter, and these switch the
				-- router's decode.  Not on the two edges after a kernel edge,
				-- where x_req and state are not settled; see q_req.)
				turbochip_d   <= turbochipram;
				turbokick_d   <= turbokick;
				turboslow_d   <= turbochipram OR aga;
				cacheline_clr <= (turbochipram XOR turbochip_d);
			END IF;
		END IF;
	END PROCESS;

	host_req  <= host_req_r;
	host_addr <= akiko_addr(8 downto 1);
	host_d    <= akiko_d;
	host_wr   <= akiko_wr;
	myakiko : entity work.akiko
		GENERIC MAP(
			havertg   => havertg,
			haveaudio => haveaudio,
			havec2p   => havec2p
		)
		PORT MAP(                       -- @suppress "The order of the associations is different from the declaration order"
			clk            => clk,
			reset_n        => reset,
			addr           => akiko_addr,
			d              => akiko_d,
			q              => akiko_q,
			wr             => akiko_wr,
			req            => akiko_req,
			ack            => akiko_ack,
			host_req       => host_req_r,
			host_ack       => host_ack,
			host_q         => host_q,
			rtg_addr       => rtg_addr,
			rtg_vbend      => rtg_vbend,
			rtg_ext        => rtg_ext,
			rtg_pixelclock => rtg_pixelclock,
			rtg_16bit      => rtg_16bit,
			rtg_clut       => rtg_clut,
			rtg_clut_idx   => rtg_clut_idx,
			rtg_clut_r     => rtg_clut_r,
			rtg_clut_g     => rtg_clut_g,
			rtg_clut_b     => rtg_clut_b,
			audio_buf      => audio_buf,
			audio_ena      => audio_ena,
			audio_int      => audio_int
		);

	dbg_rtg <= akiko_req & akiko_wr & state & cpuaddr(11 downto 0) & akiko_d;

	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF ena7WRreg = '1' THEN
				eind  <= ein;
				eindd <= eind;
				CASE sync_state IS
					WHEN sync0 => sync_state <= sync1;
					WHEN sync1 => sync_state <= sync2;
					WHEN sync2 => sync_state <= sync3;
					WHEN sync3 => sync_state <= sync4;
						vma        <= vpa;
					WHEN sync4 => sync_state <= sync5;
					WHEN sync5 => sync_state <= sync6;
					WHEN sync6 => sync_state <= sync7;
					WHEN sync7 => sync_state <= sync8;
					WHEN sync8 => sync_state <= sync9;
					WHEN OTHERS => sync_state <= sync0;
						vma        <= '1';
				END CASE;
				IF eind = '1' AND eindd = '0' THEN
					sync_state <= sync7;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	-- The adapter's completion, bus_ready16: chipset bus or undecoded
	-- auto-complete, whichever answers.
	--
	-- The chipset half of it is LATCHED (chipset_done) rather than taken
	-- straight from ena7RDreg/ena7WRreg.  Those are single-cycle pulses on
	-- phases 6 and 14 of the SDRAM round, and the raw term only ever released
	-- the CPU because clkena_in happened to pulse on those same phases.  With
	-- the enable at five phases instead of four (3-3-3-3-4, performance.md
	-- option 1a) that coincidence is gone -- and it cannot be restored, since
	-- no partial sum of those gaps spans the eight phases from 6 to 14.  So
	-- the pulse is caught here and held until the CPU's next enable, at most
	-- three cycles later, which is invisible next to a 140 ns chipset cycle.
	chipset_ready <= '1' WHEN (ena7RDreg = '1' AND clkena_e = '1') ELSE '0';

	PROCESS(clk, reset)
	BEGIN
		IF reset = '0' THEN
			chipset_done <= '0';
		ELSIF rising_edge(clk) THEN
			IF chipset_ready = '1' THEN
				chipset_done <= '1';
			ELSIF clkena = '1' THEN
				chipset_done <= '0';
			END IF;
		END IF;
	END PROCESS;

	bus_ready16 <= '1' WHEN (chipset_ready = '1' OR chipset_done = '1' OR sel_undecoded_d = '1') ELSE
	'0';

	-- Which clock edge the kernel may advance on; see the signal declaration.
	cpu_ce_phase <= cpu_ph2;

	-- STAGE D3.  '1' once the kernel's bus outputs have settled, which is what
	-- the 7 MHz chipset state machine below waits for before it samples them.
	--
	-- `slower` reloads "0111" on clkena -- a one-cycle pulse on exactly the clk
	-- edge the kernel advances on -- and shifts down otherwise, so slower(1)
	-- first reads '0' on the third clk cycle after that edge.  The machine can
	-- therefore start no earlier than the edge after that, and the address,
	-- byte selects, write data and bus state it latches there were settled two
	-- clk cycles after the kernel advanced.  That is exactly the budget
	-- cpu.xdc gives a path out of the CPU island (-setup -end 2 on
	-- clk_38 -> clk_114), and it is the same number the memory side has always
	-- had from the same `slower`.
	--
	-- Without it the machine could sample those signals ONE clk cycle after
	-- they moved: ena7WRreg lands on phase 14 of a sixteen-phase round and the
	-- kernel now advances every three cycles, and 16 and 3 are coprime, so
	-- every relative phase occurs.
	cpu_bus_settled <= NOT slower(1);

	-- This net is the clock enable of 7,391 kernel flops and is the plan's
	-- number-one timing risk ("Timing" item 1), which is why it is a register
	-- (clkena_r below) and why its inputs are all levels.
	--
	-- STAGE D3.  The kernel runs on clk_cpu, 37.8125 MHz, and cpu_ph2 marks
	-- the clk edge that IS a clk_cpu edge -- so clkena is high on one clk edge
	-- in three and the kernel advances on EVERY one of its own clocks except
	-- while a bus request is outstanding.  That is upstream's shape
	-- ("~cpu_req | bus_complete | bus_berr", rtl/cpu_wrapper.v:285 in the
	-- MiSTer tree): a bus handshake, not a divider.
	--
	-- STAGE E2.  The request is the master channel's, x_req, and what
	-- completes it depends on where the router sent it:
	--
	--   * RAM or Akiko: the sequencer's done level (x_done).  It is set only
	--     once the sequencer has run THIS access, and cleared on the edge
	--     after the kernel consumed it (see q_req), three edges before this
	--     is next decided -- so it can never release a newer access.
	--   * the adapter: its own idle state (it needs an enable to take the
	--     request, and one between sub-cycles) or bus_ready16.  Its terms are
	--     levels held until clkena consumes them -- chipset_done, and
	--     sel_undecoded_d, registered from an x_addr the core has held since
	--     it raised the request, three or more edges before the adapter
	--     starts.
	--
	-- The D3-FIX hazard (a line-buffer answer about the PREVIOUS address,
	-- which bus_fresh masked for the clk_114 walker) cannot occur: the
	-- walker is on clk_38 and the controllers no longer answer before the
	-- select.
	bus_release <= '1' WHEN x_req = '0' OR x_done = '1' OR
	                        (x_a16 = '1' AND (state = "01" OR bus_ready16 = '1')) ELSE '0';

	-- STAGE D3-FIX.  THE AP68040's clkena IS A REGISTER, DECIDED ONE clk EDGE
	-- EARLY: cpu_ph is high in (T+1,T+2), so clkena_r is high through
	-- (T+2,T+3) and the kernel advances at T+3.  Every clk-domain consumer of
	-- clkena (slower's reload, chipset_done's clear, the chipset FSM's
	-- end-of-cycle test) samples it at T+3.
	--
	-- THE COMPLETION, CATEGORY 2 (Stage E2).  For an access the router sent
	-- to RAM or Akiko, x_ack_r is set on the same edge as clkena_r and the
	-- read data is captured with it: a pulse shaped to the kernel's edge,
	-- and a value that does not move across it.  This is the registered read
	-- data the AP68040 never had before E2 (e2 plan, finding 4).  datatg68_r
	-- does the same for the adapter.
	--
	-- x_fresh is clkena_r one clk cycle later; see q_req.
	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			clkena_r <= cpu_ph AND bus_release;
			x_fresh  <= clkena_r;
			x_ack_r  <= '0';
			IF (cpu_ph AND bus_release) = '1' THEN
				-- capture the read data with the grant; see datatg68_r
				datatg68_r <= datatg68_c;
				IF x_req = '1' AND x_done = '1' THEN
					x_ack_r <= '1';
					IF rs_ack = '1' THEN
						x_rdata_r <= rs_rdata;
					ELSIF rd_ack = '1' THEN
						x_rdata_r <= rd_rdata;
					ELSE
						x_rdata_r <= ak_rsh;
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	clkena <= clkena_r;

	-- The phase gate; see unit_gate's declaration.  Open for one clk cycle on
	-- an enaWRreg phase once `slower` has drained, so every unit ap040_ram_seq
	-- launches starts on a fixed four phases of the sixteen-phase round
	-- however the island clock is divided.  slower(0) keeps the earliest
	-- launch where the level gate (cpu_phase_ok, before E2) put it: four clk
	-- edges after the kernel edge that issued the access.
	--
	-- The gate opens three clk cycles after enaWRreg -- one before the next,
	-- since enaWRreg repeats every four -- which lands chip-RAM acknowledges on
	-- SDRAM round phases 2/6/10/14.  Opening on enaWRreg itself (the gate as
	-- first built) moved them to 3/7/11/15: Way Too Rude corrupted at ratio 3
	-- and boot crashed at ratio 4 with Chip turbo (hardware 2026-09-14, tag
	-- d3_stable; findings/ap68040/sdd-d3/d3-snoop-coherency.md).  Why that
	-- placement corrupts is not explained; sim/ddr3_cpu's placement monitor
	-- and its --gatemutant leg (which reverts this to clkena_in) guard it.
	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			ena_sr <= ena_sr(1 DOWNTO 0) & clkena_in;
		END IF;
	END PROCESS;

	unit_gate <= ena_sr(2) AND NOT slower(0);

	-- The acknowledge-phase histogram; see ph_hist16_t.
	PROCESS(clk)
		VARIABLE v_ph  : integer RANGE 0 TO 15;
		VARIABLE v_dly : integer RANGE 0 TO 7;
	BEGIN
		IF rising_edge(clk) THEN
			-- position in the 16-phase round, re-synchronised on ena7WRreg
			IF ena7WRreg = '1' THEN
				ph16 <= (others => '0');
			ELSE
				ph16 <= ph16 + 1;
			END IF;
			ph_ack_r  <= ram_ack;
			ph_ack_d  <= ph_ack_r;
			ph_chip_r <= sel_chipram;

			ph_win <= ph_win + 1;
			IF ph_win = "1111111111111111111111" THEN
				ph_snap_ph  <= ph_cnt_ph;
				ph_snap_dly <= ph_cnt_dly;
				ph_cnt_ph   <= (others => (others => '0'));
				ph_cnt_dly  <= (others => (others => '0'));
				ph_pend     <= '0';
			ELSE
				-- a chip-RAM acknowledge rising: bin its round phase, start timing
				IF ph_ack_r = '1' AND ph_ack_d = '0' AND ph_chip_r = '1' THEN
					v_ph := conv_integer(ph16);
					ph_cnt_ph(v_ph) <= ph_cnt_ph(v_ph) + 1;
					ph_pend <= '1';
					ph_dly  <= (others => '0');
				ELSIF ph_pend = '1' THEN
					IF clkena_r = '1' THEN
						v_dly := conv_integer(ph_dly);
						ph_cnt_dly(v_dly) <= ph_cnt_dly(v_dly) + 1;
						ph_pend <= '0';
					ELSIF ph_dly /= "111" THEN
						ph_dly <= ph_dly + 1;
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	g_phist_ph : FOR i IN 0 TO 15 GENERATE
		dbg_phist(128 + 16*i + 15 DOWNTO 128 + 16*i) <= ph_snap_ph(i);
	END GENERATE;
	g_phist_dly : FOR i IN 0 TO 7 GENERATE
		dbg_phist(16*i + 15 DOWNTO 16*i) <= ph_snap_dly(i);
	END GENERATE;

	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena = '1' THEN
				slower <= "0111";       -- rokk
			ELSE
				slower(3 downto 0) <= '0' & slower(3 downto 1); -- enaWRreg&slower(3 downto 1);
			END IF;
		END IF;
	END PROCESS;

	-- What the adapter carries that is a real 7 MHz chipset cycle: everything
	-- the router gave it except undecoded space, which bus_ready16
	-- auto-completes.
	chipset_cycle <= x_a16 AND NOT sel_undecoded;

	PROCESS(clk, reset)
	BEGIN
		IF reset = '0' THEN
			S_state  <= "00";
			as       <= '1';
			rw       <= '1';
			uds      <= '1';
			lds      <= '1';
			uds2     <= '1';
			lds2     <= '1';
			clkena_e <= '0';
		ELSIF rising_edge(clk) THEN
			-- End the chipset cycle when the CPU has actually taken its
			-- answer.  This used to live inside the ena7RDreg branch, where it
			-- worked only because clkena could only ever be high on the same
			-- phase; with the enable at five phases that is no longer true, so
			-- the test belongs out here.  It also means the release now lands
			-- on the next enable (2-3 cycles) instead of waiting a full 7 MHz
			-- round, which is a small speed-up in its own right.
			--
			-- The matching clkena_e <= '0' is at the BOTTOM of this process,
			-- not here, and that is deliberate (stage D3).  The ena7RDreg
			-- branch below re-asserts clkena_e in state "11" and would
			-- override a clear written here.  It used to, on every chipset
			-- read: with enaWRreg on phases 2/6/10/14 and ena7RDreg on 6, the
			-- release and that branch always fell on the same edge, and what
			-- actually cleared clkena_e was this same test firing a SECOND
			-- time on the next enable, chipset_done still being up.
			--
			-- Putting the clear last makes it clear OUTRIGHT, so the release
			-- no longer depends on that second firing happening.  (It does
			-- still happen: chipset_ready wins the priority in the
			-- chipset_done process above, so chipset_done is set on the very
			-- edge the CPU is released, bus_ready16 stays high and the next
			-- cpu_ph2 fires this test again.  The point is that the release
			-- is no longer built on it.)  Between the two firings the only readers
			-- of clkena_e are
			-- `ena7RDreg AND clkena_e` (ena7RDreg is low there) and
			-- `S_state = "01"` (S_state is "00" there).
			IF (chipset_ready = '1' OR chipset_done = '1') AND clkena = '1' THEN
				S_state <= "00";
			END IF;

			IF S_state = "01" AND clkena_e = '1' THEN
				uds2        <= uds_in;
				lds2        <= lds_in;
				data_write2 <= w_datatg68;
			END IF;

			IF ena7WRreg = '1' THEN
				CASE S_state IS
					WHEN "00" =>
						-- cpu_bus_settled: with the AP68040 the signals
						-- latched below come off a 37.8125 MHz island, so wait
						-- until they have settled; see where it is driven.
						IF state /= "01" AND chipset_cycle = '1' AND cpu_bus_settled = '1' THEN
							uds        <= uds_in;
							lds        <= lds_in;
							uds2       <= '1';
							lds2       <= '1';
							as         <= '0';
							rw         <= wr;
							data_write <= w_datatg68;
							addr       <= cpuaddr;
							S_state <= "01";
						END IF;
					WHEN "01" =>
						clkena_e <= '0';
						S_state  <= "10";
					WHEN "10" =>
						IF waitm = '0' OR (vma = '0' AND sync_state = sync9) THEN
							S_state <= "11";
						END IF;
					WHEN "11" =>
					WHEN OTHERS => null;
				END CASE;
			ELSIF ena7RDreg = '1' THEN
				CASE S_state IS
					WHEN "00" =>
						cpuIPL <= IPL;
					WHEN "01" =>
					WHEN "10" =>
						cpuIPL <= IPL;
						waitm  <= dtack;
					WHEN "11" =>
						as   <= '1';
						rw   <= '1';
						uds  <= '1';
						lds  <= '1';
						uds2 <= '1';
						lds2 <= '1';
						IF clkena_e = '0' THEN
							r_data <= data_read;
						END IF;

						clkena_e <= '1';
					WHEN OTHERS => null;
				END CASE;
			END IF;

			-- Last, so that it wins over the ena7RDreg "11" branch above; see
			-- the note at the top of this process.
			IF (chipset_ready = '1' OR chipset_done = '1') AND clkena = '1' THEN
				clkena_e <= '0';
			END IF;
		END IF;
	END PROCESS;

END;
