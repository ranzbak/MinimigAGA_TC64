------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2011 Tobias Gubener                                   --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This is the TOP-Level for TG68KdotC_Kernel to generate 68K Bus signals   --
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
		-- Which CPU core the wrapper instantiates.  "TG68K" is the
		-- TG68KdotC kernel this design has always used; "AP040" is the
		-- AP68040 (lib/AP68040, MC68040 with MMU and FPU), which presents a
		-- TG68K-shaped port set so that everything else in this file --
		-- decode, Zorro III, DDR3, Akiko, the 7 MHz chipset state machine --
		-- is unchanged.  See findings/ap68040/plan-v2-with-ddr3.md stage A.
		cpu_core  : string  := "TG68K";
		-- AP68040 configuration, ignored for the TG68K.  All three on by
		-- default: the full core places and routes at 28,694 LUTs.
		ap040_has_mmu      : integer := 1;
		ap040_has_fpu      : integer := 1;
		ap040_enable_cache : integer := 1;
		-- Posted stores: a store to a cacheable page is acknowledged by the
		-- data cache and drained behind the core's back (AP040 plan X3.3).
		-- 0 is the synchronous-store reference the A/B measurement wants.
		ap040_post_stores  : integer := 1;
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
		-- clocks the AP68040 kernel and NOTHING else; with cpu_core = "TG68K"
		-- this port is unused and the kernel stays on clk exactly as before.
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
		fromram         : in     std_logic_vector(15 downto 0);
		toram           : out    std_logic_vector(15 downto 0);
		ramready        : in     std_logic                     := '0';
		-- DDR3 Zorro-III fast RAM port (used only when haveddr3)
		ddraddr         : out    std_logic_vector(25 downto 1);
		ddrcs           : out    std_logic;
		fromddr         : in     std_logic_vector(15 downto 0) := (others => '0');
		ddr_ready       : in     std_logic                     := '0';
		ddr_ena         : in     std_logic                     := '0';
		cpu             : in     std_logic_vector(1 downto 0);
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
		-- clock domain.  Unused by the TG68K, which has no internal cache.
		snoop_stb       : in     std_logic                     := '0';
		snoop_addr      : in     std_logic_vector(31 downto 0) := (others => '0');
		-- AP68040 fault observation, for an ILA during bring-up.  Zero with the
		-- TG68K.  Sliced out of the core's debug_status/debug_status2 (see
		-- ap040_core.v:6134-6152): everything needed to name an exception --
		-- which vector, at what PC, on which opcode, and the address that
		-- faulted if it was an access error.
		dbg_pc          : out    std_logic_vector(31 downto 0);
		dbg_fault_addr  : out    std_logic_vector(31 downto 0);
		dbg_ir          : out    std_logic_vector(15 downto 0);
		dbg_sr          : out    std_logic_vector(15 downto 0);
		dbg_exc_vec     : out    std_logic_vector(7 downto 0);
		dbg_flags       : out    std_logic_vector(3 downto 0); -- fault, in_exc, halted, busy
		-- Stage D3 snoop instrumentation, read by ila_cpu040's probe8.  The
		-- crossing that carries a chipset DMA write snoop into the kernel is
		-- the one bus -> core path that is a PULSE and not a level (see the
		-- holder in the g_ap040 branch), and nothing until now could say
		-- whether a pulse ever fails to cross.  Two free-running counters
		-- answer it directly: one counts what the bus offered, the other what
		-- the kernel actually saw.  Zero in a TG68K build.
		--   (40:20) snoop_addr(21:1)   (19) unused
		--   (18) cpu_ph2  (17) snp_stb_held  (16) snoop_stb
		--   (15:8) snp_out_cnt (kernel side)  (7:0) snp_in_cnt (bus side)
		dbg_snoop       : out    std_logic_vector(40 downto 0);
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
		ramaddr         : out    std_logic_vector(31 downto 0);
		cpustate        : out    std_logic_vector(6 downto 0);
		nResetOut       : out    std_logic;
		skipFetch       : out    std_logic;
		--    cpuDMA        : buffer  std_logic;
		ramlds          : out    std_logic;
		ramuds          : out    std_logic;
		CACR_out        : out    std_logic_vector(3 downto 0);
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
		host_q          : in     std_logic_vector(15 downto 0) := "----------------"
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
	SIGNAL clkena_f    : std_logic;
	SIGNAL S_state     : std_logic_vector(1 downto 0);
	-- SIGNAL decode           : std_logic;
	SIGNAL wr          : std_logic;
	SIGNAL uds_in      : std_logic;
	SIGNAL lds_in      : std_logic;
	SIGNAL state       : std_logic_vector(1 downto 0);
	signal longword    : std_logic;
	SIGNAL clkena      : std_logic;
	-- The first term of clkena: which clock edge the CPU kernel is allowed to
	-- advance on.  With the TG68K it is clkena_in, the SDRAM controller's
	-- enaWRreg (four of sixteen clk phases).  With the AP68040 the kernel runs
	-- on clk_cpu and this is the clk-domain marker for "the next clk edge is
	-- also a clk_cpu edge", so clkena stays a one-clk-cycle pulse on the exact
	-- edge the kernel advances -- which is what every clk-domain consumer of
	-- clkena in this file (slower, chipset_done, akiko_req, the chipset FSM,
	-- cpustate) was written against.
	SIGNAL cpu_ce_phase : std_logic;
	-- cpu_ph is high in (T+1,T+2) and cpu_ph2 in (T+2,T+3), where the kernel's
	-- clock edges are at T and T+3.  cpu_ph2 is the enable phase; cpu_ph is
	-- declared HERE rather than inside the g_ap040 block because the walker
	-- routers below need it -- see bus_step.  It keeps its initial '0' in a
	-- TG68K build, where the g_ap040 block that drives it is not elaborated.
	SIGNAL cpu_ph       : std_logic := '0';
	SIGNAL cpu_ph2      : std_logic := '0';
	-- '1' when the kernel's bus outputs have settled; see where it is driven.
	SIGNAL cpu_bus_settled : std_logic;
	-- The clkena release term on its own, and the AP68040's registered clkena.
	-- See where they are driven.
	SIGNAL bus_release  : std_logic;
	SIGNAL clkena_r     : std_logic := '0';
	-- '1' in the one clk cycle after a bus router took the bus: the cycle in
	-- which the completion cone is still answering for the PREVIOUS address.
	-- See bus_fresh, where it is driven.
	SIGNAL wk_active_d  : std_logic := '0';
	SIGNAL bus_fresh    : std_logic;
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

	TYPE sync_states IS (sync0, sync1, sync2, sync3, sync4, sync5, sync6, sync7, sync8, sync9);
	SIGNAL sync_state : sync_states;
	SIGNAL datatg68_c : std_logic_vector(15 downto 0);
	SIGNAL datatg68   : std_logic_vector(15 downto 0);
	SIGNAL w_datatg68 : std_logic_vector(15 downto 0);
	SIGNAL ramcs      : std_logic;

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
	signal sel_akiko_d     : std_logic;
	signal sel_audio       : std_logic;
	signal sel_ram_d       : std_logic;
	SIGNAL cpu_int         : std_logic;

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
	SIGNAL sel_ddr_d       : std_logic;
	SIGNAL mem_ready       : std_logic; -- SDRAM or DDR3 access acknowledge

	-- Akiko registers
	signal akiko_d    : std_logic_vector(15 downto 0);
	signal akiko_q    : std_logic_vector(15 downto 0);
	signal akiko_wr   : std_logic;
	signal akiko_req  : std_logic;
	signal akiko_ack  : std_logic;
	signal host_req_r : std_logic;

	SIGNAL NMI_addr            : std_logic_vector(31 downto 0);
	SIGNAL sel_nmi_vector_addr : std_logic;
	SIGNAL sel_nmi_vector      : std_logic;

	signal chipset_cycle : std_logic;

	signal nResetOut_w : std_logic;
	signal VBR_out_w   : std_logic_vector(31 downto 0);

	-- Which core is built.  Both strings are five characters, so this is a
	-- plain constrained comparison.
	CONSTANT use_ap040 : boolean := (cpu_core = "AP040");

	-- The AP68040 is always a 68040: 32-bit address space and AGA longword
	-- chip access, whatever the OSD's CPU setting says.  The TG68K keeps
	-- taking that setting.  Everything downstream reads cpu_i, not cpu.
	SIGNAL cpu_i : std_logic_vector(1 downto 0);

	-- The chipset 32-bit optimisation below is a TG68K contract, not a bus
	-- feature: on a longword-aligned chip/Kick access the wrapper answers ONE
	-- request with TWO words, the second through data_read2, and the kernel is
	-- built to consume both.  The AP68040 is not: ap040_bus16_adapter's stated
	-- contract is one stable request at a time, exactly one completion per
	-- 16-bit sub-cycle, and a long transfer split into two separate word cycles
	-- with an IDLE between them.  Handing it a word it never asked for puts the
	-- two out of step and the next fetch never completes -- on hardware the
	-- 040 wedged on the fetch straight after the first longword-aligned one
	-- ($00F800D4 took the paired path, $00F800D6 then hung forever), which is
	-- what put Kickstart on its yellow screen.
	SIGNAL longword_pair : std_logic;

	--------------------------------------------------------------------------
	-- Stage B: the MMU table walker's path to memory.
	--
	-- A walk happens during address translation, before the core's own bus
	-- request exists, so the wrapper's memory side is idle whenever
	-- walker_req is high and the walker can simply borrow it.  No new port on
	-- sdram_ctrl (its slot arbiter already uses all eight types), no arbiter,
	-- and no ap040_walker_cdc (that module is for hosts whose wrapper is in
	-- another clock domain; everything here is clk_114 with clkena).
	--
	-- The borrowing is done by muxing the handful of signals the whole bus
	-- side of this file derives from -- address, bus state, byte selects,
	-- write data, write strobe -- so a walker cycle is indistinguishable from
	-- a CPU cycle to the decode, to sdram_ctrl, to the DDR3 backend and to the
	-- 7 MHz chipset FSM.  That last one matters: with Turbo chip RAM off, a
	-- descriptor in chip RAM has to go out over the chipset bus, and it does,
	-- without a line of its own.
	--
	-- A descriptor is a longword and this bus is 16 bits, so each walk
	-- transaction is TWO sub-cycles, at A and A+2, with an idle gap between
	-- them -- never the paired-transfer path (longword_pair is 0 for this
	-- core, and for the reason recorded at cpustate below).
	SIGNAL wk_req     : std_logic;                      -- from the core
	SIGNAL wk_we      : std_logic;
	SIGNAL wk_addr    : std_logic_vector(31 downto 0);
	SIGNAL wk_wdat    : std_logic_vector(31 downto 0);
	SIGNAL wk_ack     : std_logic;                      -- to the core, a LEVEL
	SIGNAL wk_data    : std_logic_vector(31 downto 0);
	SIGNAL wk_berr    : std_logic;                      -- also a level
	SIGNAL wk_active  : std_logic;                      -- walker owns the bus
	SIGNAL wk_bstate  : std_logic_vector(1 downto 0);
	SIGNAL wk_busaddr : std_logic_vector(31 downto 0);
	SIGNAL wk_wdat16  : std_logic_vector(15 downto 0);
	TYPE   wk_state_t IS (WK_IDLE, WK_HI, WK_GAP, WK_LO, WK_DONE);
	SIGNAL wk_st      : wk_state_t;
	-- '1' on the clk edges the walker and line-fill routers are allowed to
	-- advance on; see the note above the walker process.  Constant '1' for
	-- the TG68K, where both routers fold away anyway.
	SIGNAL bus_step   : std_logic;

	--------------------------------------------------------------------------
	-- Stage D: the line-fill requester -- the walker router's twin.
	--
	-- On a miss in a window the wrapper serves, the AP68040's data/instruction
	-- cache raises fill_req with the 16-byte line address and waits for the
	-- whole line as ONE 128-bit payload, instead of sending four longwords
	-- (eight 16-bit sub-cycles) down the bus16 adapter.  Each of those eight
	-- sub-cycles costs the core a full clock-enable round trip, and with
	-- clkena_in high on four of sixteen phases (2, 6, 10, 14 --
	-- rtl/sdram/cpu_enable_cadence.v is the single source) that is where a miss spends its
	-- time -- not in the DDR3, which already fetches the whole line on the
	-- first word and serves the other seven from cpu_cache_new's line buffer
	-- (findings/ap68040/plan-v2-with-ddr3.md, "D2, second survey").
	--
	-- So this FSM borrows the bus exactly as the walker does -- same mux, same
	-- decode, same controllers, no new port anywhere -- and streams the eight
	-- words itself at the free clk_114 rate.  The core sees one handshake.
	--
	-- ap040_fill_cdc.v is deliberately NOT instantiated, for the same reason
	-- ap040_walker_cdc is not: it bridges two clock domains and there is only
	-- one here.  Its semantics are kept -- the acknowledge is a LEVEL held
	-- until the core drops its request (the core consumes it under ce, which
	-- this wrapper stops and starts), and the payload is stable while it is.
	SIGNAL fl_req     : std_logic;                      -- from the core, a level
	SIGNAL fl_addr    : std_logic_vector(31 downto 4);  -- the line address
	SIGNAL fl_ack     : std_logic;                      -- to the core, a LEVEL
	-- fl_err is wired but never raised: FL_DEC auto-completes an address that
	-- decodes to nothing instead of faulting it, which is this SoC's policy.
	SIGNAL fl_err     : std_logic;                      -- also a level
	SIGNAL fl_line    : std_logic_vector(127 downto 0); -- the assembled payload
	SIGNAL fl_busy    : std_logic;                      -- a fill is in progress
	SIGNAL fl_active  : std_logic;                      -- the fill owns the bus
	SIGNAL fl_bstate  : std_logic_vector(1 downto 0);
	SIGNAL fl_busaddr : std_logic_vector(31 downto 0);
	SIGNAL fl_word    : std_logic_vector(2 downto 0);   -- which of the eight
	SIGNAL fl_ok      : std_logic;                      -- the line decodes to RAM
	TYPE   fl_state_t IS (FL_IDLE, FL_DEC, FL_SEL, FL_GAP, FL_DONE);
	SIGNAL fl_st      : fl_state_t;

	-- The muxed bus-side signals.  Everything below this point uses these and
	-- not the core's own outputs; with the TG68K, or with the walker idle,
	-- they ARE the core's own outputs.
	SIGNAL bstate     : std_logic_vector(1 downto 0);
	SIGNAL buds       : std_logic;
	SIGNAL blds       : std_logic;
	SIGNAL bwr        : std_logic;
	SIGNAL bwdata     : std_logic_vector(15 downto 0);
	-- '1' on the cycle the current bus access is complete, i.e. the clkena
	-- release term factored out so the walker can use the same completion.
	SIGNAL bus_ready  : std_logic;
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

	COMPONENT ap040_tg68k_compat IS
		GENERIC(
			AP040_HAS_MMU      : integer := 1;
			AP040_HAS_FPU      : integer := 1;
			AP040_ENABLE_CACHE : integer := 1;
			AP040_FAST_SIM     : integer := 0;
			AP040_POST_STORES  : integer := 1;
			AP040_FILL_CHANNEL : integer := 1
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
			debug_status2     : out std_logic_vector(127 downto 0)
		);
	END COMPONENT;

BEGIN

	cpu_i <= "11" WHEN use_ap040 ELSE cpu;
	longword_pair <= '0' WHEN use_ap040 ELSE longword;

	nResetOut <= nResetOut_w;
	VBR_out   <= VBR_out_w;

	sel_eth <= '0';

	-- NMI
	PROCESS(reset, clk)
	BEGIN
		IF reset = '0' THEN
			NMI_addr            <= X"0000007c";
			sel_nmi_vector_addr <= '0';
		ELSIF rising_edge(clk) THEN
			NMI_addr            <= VBR_out_w + X"0000007c";
			sel_nmi_vector_addr <= '0';
			IF (cpuaddr(31 downto 2) = NMI_addr(31 downto 2)) THEN
				sel_nmi_vector_addr <= '1';
			END IF;
		END IF;
	END PROCESS;

	-- NOT during a walk, and not during a line fill: a descriptor -- or a word
	-- of a cache line -- that happens to live at the NMI vector address is
	-- memory, and must be read from memory, not answered from the vector shim.
	sel_nmi_vector <= '1' WHEN sel_nmi_vector_addr = '1' AND bstate = "10"
	                          AND wk_active = '0' AND fl_active = '0' ELSE '0';

	--------------------------------------------------------------------------
	-- The bus-side mux.  wk_active and fl_active are constant '0' unless the
	-- AP68040 is built (with its MMU, and with the fill channel enabled), so
	-- for the TG68K this is wiring, not logic.  The two are mutually exclusive
	-- by construction -- see the two FSMs' start conditions -- so their order
	-- here only decides what a broken build would do, not what a working one
	-- does; the walker is first because it is the older master.
	--------------------------------------------------------------------------
	bstate  <= wk_bstate  WHEN wk_active = '1' ELSE
	           fl_bstate  WHEN fl_active = '1' ELSE state;
	buds    <= '0'        WHEN wk_active = '1' OR fl_active = '1' ELSE uds_in;
	blds    <= '0'        WHEN wk_active = '1' OR fl_active = '1' ELSE lds_in;
	-- descriptors are aligned longwords and a line word is a whole word, so
	-- both borrowers take both byte lanes; wr is active low and a fill reads
	bwr     <= NOT wk_we  WHEN wk_active = '1' ELSE
	           '1'        WHEN fl_active = '1' ELSE wr;
	bwdata  <= wk_wdat16  WHEN wk_active = '1' ELSE w_datatg68;

	toram   <= bwdata;
	wrd     <= bwr;
	cpu_int <= '1' WHEN bstate = "01" else '0';
	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			z2ram_ena  <= ziiram_active;
			z3ram_ena  <= ziiiram_active;
			z3ram2_ena <= ziiiram2_active;
			z3ram3_ena <= ziiiram3_active;

			sel_akiko_d     <= sel_akiko;
			sel_undecoded_d <= sel_undecoded;
		END IF;
	END PROCESS;

	datatg68 <= fromddr WHEN cpu_int = '0' AND sel_ddr_d = '1' AND sel_nmi_vector = '0' ELSE
	            fromram WHEN cpu_int = '0' AND sel_ram_d = '1' AND sel_nmi_vector = '0' ELSE datatg68_c;

	-- Register incoming data
	process(clk)
	begin
		if rising_edge(clk) then
			if sel_undecoded = '1' then
				datatg68_c <= X"FFFF";
			elsif sel_akiko_d = '1' then
				datatg68_c <= akiko_q;
			elsif sel_eth = '1' then
				datatg68_c <= frometh;
			else
				datatg68_c <= r_data;
			end if;
		end if;
	end process;

	sel_akiko     <= '1' when cpuaddr(31 downto 16) = X"00B8" else '0';
	sel_32        <= '1' when cpu_i(1) = '1' and cpuaddr(31 downto 24) /= X"00" and cpuaddr(31 downto 24) /= X"ff" else '0'; -- Decode 32-bit space, but exclude interrupt vectors
	--  sel_z3ram       <= '1' WHEN (cpuaddr(31 downto 24)=z3ram_base) else '0'; -- AND z3ram_ena='1' ELSE '0';
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
	-- space (cpuaddr(31 downto 24) = 0x00) and the interrupt vectors (0xff),
	-- where a Zorro-III board can never live.  Without it a base register that
	-- reads back as 0 -- an unconnected wire, a board the OS has not placed
	-- yet, a bug upstream -- makes this board answer for chip RAM, the CIAs and
	-- the custom registers the moment it is enabled, and the machine dies with
	-- a black screen before it can say why.  It cost a bring-up cycle on
	-- 2026-09-06 (z3ram3_base left undriven in minimig_virtual_top.v).
	sel_z3ram3    <= '1' WHEN sel_32 = '1'
	                          AND cpuaddr(31 downto z3ram3_size_log2) = z3ram3_base(7 downto z3ram3_size_log2 - 24)
	                          AND z3ram3_ena = '1' ELSE '0';
	-- First block of ZIII RAM - 0x40000000 - 0x40ffffff
	-- Second block of ZIII RAM - 32 meg from 0x42000000 - 0x43ffffff
	-- Both still assume where the OS puts them, which holds because they are
	-- configured first and land on the bottom of the ZIII free space.  Board 3
	-- wins if the OS ever does place it inside one of these ranges, so that an
	-- address can never select two backends at once.
	sel_z3ram     <= '1' WHEN (cpuaddr(31 downto 30) = "01") and cpuaddr(26 downto 24) = "000" AND z3ram_ena = '1' AND sel_z3ram3 = '0' ELSE '0';
	sel_z3ram2    <= '1' WHEN (cpuaddr(31 downto 30) = "01") and cpuaddr(25) = '1' AND z3ram2_ena = '1' AND sel_z3ram3 = '0' ELSE '0';
	sel_z2ram     <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND ((cpuaddr(23 downto 21) = "001") OR (cpuaddr(23 downto 21) = "010") OR (cpuaddr(23 downto 21) = "011") OR (cpuaddr(23 downto 21) = "100")) AND z2ram_ena = '1' ELSE '0';
	--sel_eth         <= '1' WHEN (cpuaddr(31 downto 24) = eth_base) AND eth_cfgd='1' ELSE '0';
	sel_chip      <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND (cpuaddr(23 downto 21) = "000") ELSE '0'; --$000000 - $1FFFFF
	sel_chipram   <= '1' WHEN sel_chip = '1' AND turbochip_d = '1' ELSE '0';
	sel_kick      <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND ((cpuaddr(23 downto 19) = "11111") OR (cpuaddr(23 downto 19) = "11100")) AND bstate /= "11" ELSE '0'; -- $F8xxxx, $E0xxxx, read only
	sel_kickram   <= '1' WHEN sel_kick = '1' AND turbokick_d = '1' ELSE '0';
	sel_slow      <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND ((cpuaddr(23 downto 20) = X"C" AND ((cpuaddr(19) = '0' AND slow_config /= "00") OR (cpuaddr(19) = '1' AND slow_config(1) = '1'))) OR (cpuaddr(23 downto 19) = X"D" & '0' AND slow_config = "11")) ELSE '0'; -- $C00000 - $D7FFFF
	sel_slowram   <= '1' WHEN sel_slow = '1' AND turboslow_d = '1' ELSE '0';
	-- sel_cart        <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND (cpuaddr(23 downto 20)="1010") ELSE '0'; -- $A00000 - $A7FFFF (actually matches up to $AFFFFF)
	sel_audio     <= '1' WHEN (cpuaddr(31 downto 24) = X"00") AND (cpuaddr(23 downto 18) = "111011") ELSE '0'; -- $EC0000 - $EFFFFF
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

	-- Stage D.  '1' where a RAM controller actually answers: the DDR3 board,
	-- or one of the ZII/ZIII boards on the SDRAM.  The core cannot tell board
	-- 1 from board 3 -- its cache_z3_* windows say "Zorro III RAM", not which
	-- memory backs it -- so the wrapper decodes every fill address with the
	-- SAME logic the CPU's own address takes.
	--
	-- It is NARROWER than those windows, and deliberately so.  cache_z3_base0
	-- is addr(31:27) and cache_z3_base1 addr(31:28)
	-- (ap040_tg68k_compat.v:397-401), i.e. a 128 MB and a 256 MB window
	-- around boards that are 16 or 32 MB -- so a cacheable read of a hole
	-- inside one, past the end of the DDR3 board or where board 1 would be if
	-- it were fitted, is perfectly reachable and the core WILL raise fill_req
	-- for it.  The router answers those out of fl_ok = '0' with a line of
	-- $FFFF words, not with a bus error: this SoC auto-completes an address
	-- that decodes to nothing (sel_undecoded, and the note beside the core's
	-- berr input), so the eight adapter reads this replaces returned exactly
	-- that.  Widening fl_ok is not the alternative -- it would hand the fill
	-- to a controller that cannot decode the address.
	fl_ok <= '1' WHEN (sel_ddr = '1' OR sel_z2ram = '1' OR sel_z3ram_sdram = '1') ELSE '0';

	cache_inhibit <= '1' WHEN sel_kickram = '1' ELSE '0';

	ramcs <= NOT (NOT cpu_int AND sel_ram_d AND NOT sel_nmi_vector) OR slower(0);
	-- Same shape as ramcs, slower(0) throttle included, so the DDR3 backend sees
	-- exactly the chip-select timing sdram_ctrl sees (address one cycle early).
	ddrcs <= NOT (NOT cpu_int AND sel_ddr_d AND NOT sel_nmi_vector) OR slower(0);
	-- The DDR3 address is the offset inside board 3, which the OS may have put
	-- anywhere, so the base bits are dropped and what is left is zero-extended
	-- to the 25-bit word address the backend takes (design.md D6, amended by
	-- findings/ddr3/z3ram3-on-ddr3-plan.md: identity only when the board covers
	-- the whole 64 MB).  One assignment, so ddraddr has one driver.
	ddraddr <= ddr_zero_hi & cpuaddr(z3ram3_size_log2 - 1 downto 1);

	-- cpustate(6) is the RAM port's 32-bit-write flag, and it is the same
	-- paired-transfer protocol the AGA chipset path uses, so it takes the same
	-- gate.  sdram_ctrl derives cpuLongword from it and cpu_cache_new answers
	-- a set bit by acknowledging the high word at once and moving to
	-- CPU_SM_WAIT_LOWORD, where it expects the low word as a continuation of
	-- THE SAME request.  The TG68K supplies exactly that.  The AP68040 does
	-- not: its bus16 adapter issues two fully independent word cycles, so the
	-- controller banks a half-written longword and the two sides desync --
	-- the $F800D6 hang again, on the port that fix did not reach.
	--
	-- Found on hardware: Kickstart 46.143 spun in AllocMem because
	-- SysBase->MemList (ExecBase+$142) read back zero.  ExecBase lives in
	-- slow/fast RAM, which leaves on this port, so Exec's list relocation
	-- stored its pointers through the broken 32-bit write while the chipset
	-- bus -- already fixed -- carried the instruction fetches and the stack
	-- correctly.  sim/ddr3_cpu cannot see it: its RAM model uses only
	-- cpustate[2:0] and ignores this bit.
	cpustate <= longword_pair & clkena & slower(1 downto 0) & ramcs & bstate(1 downto 0);
	ramlds   <= blds;
	ramuds   <= buds;

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

	ramaddr(31 downto 26) <= "000000";
	ramaddr(25)           <= sel_z3ram2; -- Second block of 32 meg
	ramaddr(24)           <= (cpuaddr(24) and sel_z3ram2) or sel_z3ram; -- Remap the first block of Zorro III RAM to 0x1000000
	ramaddr(23)           <= (cpuaddr(23) xor (cpuaddr(22) or cpuaddr(21))) and not sel_z3ram3;
	ramaddr(22)           <= cpuaddr(21) when sel_z3ram3 = '1' else cpuaddr(22);
	ramaddr(21)           <= cpuaddr(21) xor sel_z3ram3;
	ramaddr(20 downto 0)  <= cpuaddr(20 downto 0);

	-- 32bit address space for 68020, limit address space to 24bit for 68000/68010.
	-- A walk drives a physical address straight in: translation is what the
	-- walk is for, and the 040 is 32-bit anyway.
	cpuaddr <= wk_busaddr WHEN wk_active = '1' ELSE
	           fl_busaddr WHEN fl_active = '1' ELSE
	           addrtg68   WHEN cpu_i(1) = '1' ELSE X"00" & addrtg68(23 downto 0);

	--------------------------------------------------------------------------
	-- The CPU kernel.  Exactly one branch is elaborated; everything else in
	-- this file is common to both cores.
	--------------------------------------------------------------------------
	g_tg68k : IF NOT use_ap040 GENERATE
		-- The kernel below is clocked by clk and enabled by clkena_in, exactly
		-- as it always has been, so clk_cpu is not read anywhere in this
		-- branch and the TG68K build is unchanged by stage D3.
		cpu_ph2 <= '0';

		-- No table walker: the TG68K has no MMU.  wk_active follows and is a
		-- constant '0', so the whole router folds away.  Same for the line
		-- fill: the TG68K has no internal cache to fill, so fl_busy and
		-- fl_active are constant '0' and that router folds away too.
		wk_req  <= '0';
		wk_we   <= '0';
		wk_addr <= (others => '0');
		wk_wdat <= (others => '0');
		fl_req  <= '0';
		fl_addr <= (others => '0');

		pf68K_Kernel_inst : entity work.TG68KdotC_Kernel
			GENERIC MAP(                    -- @suppress "Generic map uses default values. Missing optional actuals: BarrelShifter"
				SR_Read        => 2,        -- 0=>user,   1=>privileged,    2=>switchable with CPU(0)
				VBR_Stackframe => 2,        -- 0=>no,     1=>yes/extended,  2=>switchable with CPU(0)
				extAddr_Mode   => 2,        -- 0=>no,     1=>yes,           2=>switchable with CPU(1)
				MUL_Mode       => 2,        -- 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,
				DIV_Mode       => 2,        -- 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,
				BitField       => 2,        -- 0=>no,     1=>yes,           2=>switchable with CPU(1)
				MUL_Hardware   => 1         -- 0=>no,     1=>yes
			)
			PORT MAP(                       -- @suppress "The order of the associations is different from the declaration order"
				clk            => clk,      -- : in std_logicvec

				nReset         => reset,    -- : in std_logic:='1';      --low active
				clkena_in      => clkena,   -- : in std_logic:='1';
				data_in        => datatg68, -- : in std_logic_vector(15 downto 0);
				IPL            => cpuIPL,   -- : in std_logic_vector(2 downto 0):="111";
				IPL_autovector => '1',      -- : in std_logic:='0';
				CPU            => cpu,
				regin_out      => open,     -- : out std_logic_vector(31 downto 0);
				addr_out       => addrtg68, -- : buffer std_logic_vector(31 downto 0);
				data_write     => w_datatg68, -- : out std_logic_vector(15 downto 0);
				busstate       => state,    -- : buffer std_logic_vector(1 downto 0);
				longword       => longword,
				nWr            => wr,       -- : out std_logic;
				nUDS           => uds_in,
				nLDS           => lds_in,   -- : out std_logic;
				nResetOut      => nResetOut_w,
				skipFetch      => skipFetch, -- : out std_logic
				CACR_out       => CACR_out,
				VBR_out        => VBR_out_w,
				berr           => open,
				FC             => open,
				clr_berr       => open
			);
		-- The TG68K has no cache-maintenance sideband, and no fault view.
		ap040_maint    <= '0';
		dbg_pc         <= (others => '0');
		dbg_fault_addr <= (others => '0');
		dbg_ir         <= (others => '0');
		dbg_sr         <= (others => '0');
		dbg_exc_vec    <= (others => '0');
		dbg_flags      <= (others => '0');
		dbg_snoop      <= (others => '0');
	END GENERATE;

	g_ap040 : IF use_ap040 GENERATE
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
		-- cpu_ph is declared in the architecture region, next to cpu_ph2: the
		-- bus routers are outside this generate and read it (bus_step).

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

		-- The instrumentation behind dbg_snoop.  snp_in_cnt counts on clk
		-- every snoop the bus offers; snp_out_cnt counts on clk_cpu every
		-- snoop the KERNEL sees -- literally the value ap040_cache's
		-- ce-independent s_stb port samples, counted in the port's own clock
		-- domain.  Free-running and never cleared, so the two track within
		-- one and diverge FOR GOOD the first time a pulse fails to cross: a
		-- lost snoop is then a subtraction on one ILA sample rather than a
		-- waveform to be argued about.  snp_out_cnt is resynchronised into
		-- clk before it is probed; it is a multi-bit crossing, but it changes
		-- at most once per SDRAM round and is read as a level, so a sample
		-- taken across an increment is at worst off by one.
		SIGNAL snp_in_cnt    : std_logic_vector(7 downto 0) := (others => '0');
		SIGNAL snp_out_cnt   : std_logic_vector(7 downto 0) := (others => '0');
		SIGNAL snp_out_s1    : std_logic_vector(7 downto 0) := (others => '0');
		SIGNAL snp_out_s2    : std_logic_vector(7 downto 0) := (others => '0');
	BEGIN
		PROCESS(clk_cpu)
		BEGIN
			IF rising_edge(clk_cpu) THEN
				cpu_tgl <= NOT cpu_tgl;
			END IF;
		END PROCESS;

		PROCESS(clk)
		BEGIN
			IF rising_edge(clk) THEN
				cpu_tgl_d <= cpu_tgl;
				cpu_ph    <= cpu_tgl XOR cpu_tgl_d;
				cpu_ph2   <= cpu_ph;
			END IF;
		END PROCESS;

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

		-- The two snoop counters; see their signals.
		PROCESS(clk)
		BEGIN
			IF rising_edge(clk) THEN
				IF snoop_stb = '1' THEN
					snp_in_cnt <= snp_in_cnt + 1;
				END IF;
				snp_out_s1 <= snp_out_cnt;
				snp_out_s2 <= snp_out_s1;
			END IF;
		END PROCESS;

		PROCESS(clk_cpu)
		BEGIN
			IF rising_edge(clk_cpu) THEN
				IF snp_stb_held = '1' THEN
					snp_out_cnt <= snp_out_cnt + 1;
				END IF;
			END IF;
		END PROCESS;

		dbg_snoop <= snoop_addr(21 DOWNTO 1) & '0' & cpu_ph2 & snp_stb_held &
		             snoop_stb & snp_out_s2 & snp_in_cnt;

		ap040 : COMPONENT ap040_tg68k_compat
			GENERIC MAP(
				AP040_HAS_MMU      => ap040_has_mmu,
				AP040_HAS_FPU      => ap040_has_fpu,
				AP040_ENABLE_CACHE => ap040_enable_cache,
				AP040_FAST_SIM     => 0,
				AP040_POST_STORES  => ap040_post_stores,
				-- The line-fill channel, routed by the fill router below.
				AP040_FILL_CHANNEL => 1
			)
			PORT MAP(
				-- The CPU island's own 37.8125 MHz clock.  Everything else in
				-- this file -- the decode, both bus routers, slower, the
				-- chipset state machine, Akiko, the registers facing
				-- sdram_ctrl and ddr3_fastram -- stays on clk, because that
				-- is the clock the controllers are on.
				clk            => clk_cpu,
				nreset         => reset,
				clkena_in      => clkena,
				data_in        => datatg68,
				ipl            => cpuIPL,
				ipl_autovector => '1',
				-- The SoC never raises a bus error: undecoded 32-bit space is
				-- auto-completed with $FFFF by sel_undecoded, exactly as it is
				-- for the TG68K.  The core has its own stall watchdog.
				berr           => '0',

				addr_out       => addrtg68,
				data_write     => w_datatg68,
				busstate       => state,
				longword       => longword,
				nwr            => wr,
				nuds           => uds_in,
				nlds           => lds_in,
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
				-- board decodes; fl_ok above says how the fill router answers
				-- one.
				cache_allow_all  => '0',
				cache_snoop_stb  => snp_stb_held,
				cache_snoop_addr => snp_addr_held,
				cache_z2_ena     => z2ram_ena,
				cache_z3_base0   => "01000",
				cache_z3_ena0    => z3ram_ena,
				cache_z3_base1   => z3ram3_base(7 downto 4),
				cache_z3_ena1    => z3ram3_ena,

				-- Stage B: the table walker rides this wrapper's own memory
				-- path, two 16-bit sub-cycles per descriptor.  See the router
				-- below; ap040_walker_cdc is deliberately NOT used (one clock
				-- domain here).
				walker_req     => wk_req,
				walker_we      => wk_we,
				walker_addr    => wk_addr,
				walker_wdat    => wk_wdat,
				walker_ack     => wk_ack,
				walker_data    => wk_data,
				walker_berr    => wk_berr,

				-- Stage D: the line-fill channel, served by the fill router
				-- below out of this wrapper's own memory path -- the walker's
				-- twin, and ap040_fill_cdc is left out for the same reason
				-- ap040_walker_cdc is (one clock domain here).
				--
				-- Zorro lines only.  A chip-RAM line stays on the adapter:
				-- with Turbo chip RAM off it is a 7 MHz chipset cycle, where
				-- eight words would hold the bus for a millisecond and lock
				-- out the chipset's own DMA; with it on, chip RAM is the one
				-- window the chipset also writes, and the fill would have to
				-- be ordered against the snoop that this wrapper delivers on
				-- the free clock.  There is nothing to win there and a
				-- coherency rule to break, so the enable stays low.
				fill_ena_zorro => '1',
				fill_ena_chip  => '0',
				fill_req       => fl_req,
				fill_addr      => fl_addr,
				fill_data      => fl_line,
				fill_ack       => fl_ack,
				fill_err       => fl_err,

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
				debug_status2     => ap040_dbg2
			);

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
			ELSIF bstate = "01" THEN    -- No mem access, so safe to switch chipram access mode
				turbochip_d   <= turbochipram;
				turbokick_d   <= turbokick;
				turboslow_d   <= turbochipram OR aga;
				cacheline_clr <= (turbochipram XOR turbochip_d);
			END IF;
			sel_ram_d <= sel_ram;
			sel_ddr_d <= sel_ddr;
			wk_active_d <= wk_active;
		END IF;
	END PROCESS;

	host_req <= host_req_r;
	myakiko : entity work.akiko
		GENERIC MAP(
			havertg   => havertg,
			haveaudio => haveaudio,
			havec2p   => havec2p
		)
		PORT MAP(                       -- @suppress "The order of the associations is different from the declaration order"
			clk            => clk,
			reset_n        => reset,
			addr           => cpuaddr(10 downto 0),
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

	akiko_d <= bwdata;
	process(clk)
	begin
		if rising_edge(clk) then
			if sel_akiko = '0' then
				akiko_req <= '0';
				akiko_wr  <= '0';
			end if;
			if sel_akiko = '1' and bstate(1) = '1' and slower(2) = '0' then
				akiko_req <= not clkena;
				if bstate(0) = '1' then -- write cycle
					akiko_wr <= '1';
				end if;
			end if;
		end if;
	end process;

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

	-- Each memory's acknowledge is qualified with its own select, so an SDRAM ack
	-- can never release a DDR3 access nor the other way round.  ddr_ready is the
	-- island's init/reset-done flag: before it a DDR3 access is simply held (the
	-- CPU stalls), never released with rubbish and never faulted.
	mem_ready <= ((ramready AND sel_ram_d) OR (ddr_ena AND sel_ddr_d AND ddr_ready)) WHEN haveddr3 ELSE ramready;

	-- The clkena release term, factored out under its own name so the walker
	-- FSM can wait on exactly the condition that releases the CPU -- memory,
	-- chipset bus, undecoded auto-complete or Akiko, whichever answers.
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
	chipset_ready <= '1' WHEN ((ena7RDreg = '1' AND clkena_e = '1') OR (ena7WRreg = '1' AND clkena_f = '1')) ELSE '0';

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

	bus_ready <= '1' WHEN (chipset_ready = '1' OR chipset_done = '1' OR mem_ready = '1' OR sel_undecoded_d = '1' OR akiko_ack = '1') ELSE
	'0';

	-- Which clock edge the kernel may advance on; see the signal declaration.
	cpu_ce_phase <= cpu_ph2 WHEN use_ap040 ELSE clkena_in;

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
	--
	-- A no-op for the TG68K, and constant-folded away in that build: its
	-- enable is enaWRreg on phases 2/6/10/14 and ena7WRreg is phase 14, so
	-- `slower` has always been "0000" by the time the machine looks (reloaded
	-- on the phase-10 enable, three shifts, then the phase-14 edge).
	cpu_bus_settled <= NOT slower(1) WHEN use_ap040 ELSE '1';

	-- This net is the clock enable of 7,391 kernel flops and is the plan's
	-- number-one timing risk ("Timing" item 1).  It carries exactly two terms
	-- for that reason, and it used to carry four more: wk_ack, wk_berr,
	-- fl_ack and fl_err, added as deadlock guards for the two bus borrowers.
	-- They were REDUNDANT, and they cost real time -- the ship build of the
	-- fill router had seven new failing clk_114 endpoints, every one of them
	-- starting at fl_active_reg and ending on a kernel clock-enable pin
	-- (build/stage_ap040_x3fill2/violators.rpt; the plan's D1 note had
	-- already priced the wk_ack term at 0.243 ns on the FPU multiplier's
	-- enable and named it as the first thing to remove).
	--
	-- What makes them redundant is an invariant of the two routers, not an
	-- accident:
	--
	--   In every cycle in which the walker or the line fill holds its
	--   acknowledge or its bus error, it has ALREADY released the bus and
	--   the core's own bus side is idle -- so bstate is "01" and the first
	--   term below enables the core anyway.
	--
	-- Each half of that is by construction.  RELEASED: every state that
	-- raises wk_ack/wk_berr (WK_IDLE's misaligned arm, WK_HI, WK_LO) or
	-- fl_ack (FL_DEC's auto-complete arm, FL_SEL's last word) clears its own
	-- *_active in the SAME assignment, and WK_DONE/FL_DONE hold it clear; the
	-- two routers cannot overlap, so with both *_active low bstate IS the
	-- core's busstate.  IDLE: the core is waiting for that answer and has
	-- nothing outstanding through the bus16 adapter -- the MMU is mid-walk,
	-- or the cache is parked in C_FILLC -- and the one case that could have
	-- broken it, a posted store draining through the adapter underneath a
	-- table walk, is closed inside the core by ap040_mmu's walk_hold, which
	-- is ap040_cache's post_busy (ap040_mmu.v:53 and :478,
	-- ap040_cache.v:362).
	--
	-- sim/ddr3_cpu asserts the invariant directly, so it is checked and not
	-- merely argued: an acknowledge held while cpustate(1 downto 0) is not
	-- the idle state is a FAIL, and so is an acknowledge that drops without
	-- the CPU having been enabled at least once while it was up.
	--
	-- STAGE D3.  The first term is no longer a duty cycle.  With the AP68040
	-- the kernel runs on clk_cpu, 37.8125 MHz, and cpu_ph2 marks the clk edge
	-- that IS a clk_cpu edge -- so clkena is high on one clk edge in three and
	-- the kernel advances on EVERY one of its own clocks except while a bus
	-- request is outstanding.  That is upstream's shape
	-- ("~cpu_req | bus_complete | bus_berr", rtl/cpu_wrapper.v:285 in the
	-- MiSTer tree): a bus handshake, not a divider.  Measured value of the
	-- change: SysInfo's speed test runs entirely out of the internal caches
	-- and sat at exactly the 25.0 % four-phase enable ceiling with 0 % memory
	-- stalls, so this is 37.8125 / 28.359375 = 1.33x on CPU-bound code and
	-- nothing at all on chipset-bound code.
	--
	-- With the TG68K, cpu_ce_phase is clkena_in -- enaWRreg, four of sixteen
	-- clk phases -- and both this expression and the kernel's clock are
	-- exactly what they were.
	-- STAGE D3-STABLE.  bus_ready is masked in the one cycle after the walker
	-- takes the bus.  See bus_fresh below, and the D3-FIX note under it for
	-- why that cycle is the only one that needs it.
	bus_release <= '1' WHEN (bstate = "01" OR (bus_ready = '1' AND bus_fresh = '0')) ELSE '0';

	-- STAGE D3-FIX.  THE AP68040's clkena IS A REGISTER, DECIDED ONE clk EDGE
	-- EARLY.  Same waveform, one clk cycle older content, and one flop instead
	-- of a die-crossing combinational cone in front of 7,391 clock-enable pins.
	--
	-- What forced this.  bus_release's cone runs out of this wrapper, across
	-- the die into a memory controller, through its cache-hit logic and back:
	--
	--   cpuaddr -> the decode -> sdram_ctrl / ddr3_fastram -> cpu_cache_new's
	--   cpu_cacheline_valid -> cpu_ack -> cpuena / ddr_ena -> mem_ready ->
	--   bus_ready -> clkena
	--
	-- and combinationally on into the kernel from there.  Left whole, that is
	-- ONE clk period, 8.815 ns, for the whole round trip plus four levels of
	-- MMU logic on the far side; measured 8.24 ns in build/stage_ap040_d3 and
	-- 8.28 ns after the bus routers were fixed, i.e. 0.3 ns of margin on the
	-- net that decides whether the core advances at all.  Cutting it at
	-- clkena leaves 3.5 ns of controller round trip on one side of the flop
	-- and 4.5 ns of kernel logic on the other, each against 8.815 ns.
	--
	-- WHY THE WAVEFORM IS UNCHANGED.  cpu_ph is high in (T+1,T+2), so this
	-- register goes high at edge T+2, is high through (T+2,T+3), and goes low
	-- at edge T+3 -- exactly where cpu_ph2 AND bus_release put it before.
	-- Every clk-domain consumer of clkena (slower's reload, chipset_done's
	-- clear, akiko_req, the two routers' captures, the chipset FSM's
	-- end-of-cycle test, cpustate(5)) samples it at edge T+3 and sees the same
	-- one-cycle pulse it always saw.
	--
	-- WHY THE CONTENT IS THE SAME FOR bstate, AND ONLY ONE CYCLE OLD FOR
	-- bus_ready.
	--
	--   * `state`, the kernel's own bus state, changes only on clk_cpu edges,
	--     so it is the same during (T+1,T+2) as during (T+2,T+3).
	--   * `wk_active`/`wk_bstate`/`fl_active`/`fl_bstate`, the borrowers' half
	--     of the bstate mux, cannot change at edge T+2 at all: bus_step skips
	--     that edge.  That is the same invariant the cpu.xdc exception rests
	--     on, used a second time.
	--     So `bstate = "01"` is EXACTLY equal in the two cycles: the idle
	--     release, which is what CPU-bound code lives on, is unaffected and
	--     costs nothing.  The 1.26x measured on hardware is not touched.
	--   * `bus_ready` is a genuine one-clk-cycle delay.  Its slow terms are
	--     levels held until the core consumes them -- cpu_cache_ack (cleared
	--     only when the select drops, cpu_cache_new.v:537), chipset_done and
	--     akiko_ack (cleared only by clkena) -- and its one pulse,
	--     chipset_ready, is latched by chipset_done the next cycle.  None of
	--     those can be missed; one that lands in (T+1,T+2) instead of
	--     (T+2,T+3) releases the core at T+6 rather than T+3.
	--
	--     ITS FAST TERMS ARE NOT LEVELS, AND THIS IS WHERE ac9b725 HUNG THE
	--     MACHINE (findings/ap68040/sdd-d3/task-d3stable-report.md).
	--     cpu_cache_new answers a read that hits its line buffer WITHOUT
	--     waiting for the select: cpu_cacheline_match is registered from the
	--     LIVE address every clock (:257) and cpu_ack is combinational from it
	--     while the machine is idle and the bus state is a read (:258-260).
	--     sel_undecoded_d is the same shape, a registered decode of the live
	--     address.  So the value of bus_ready in cycle (T+1,T+2) is an answer
	--     about the address that was on cpuaddr in cycle (T,T+1) -- and that
	--     is only the right question if the address has not moved since.
	--
	--     For the kernel's own accesses it has not: the kernel changed its
	--     address at T, and the T+1 captures see it (cpu.xdc now times those
	--     captures single-cycle, by name, because they ARE one cycle).  For
	--     the walker it HAS: a request the kernel raises at T is seen by the
	--     router at T+1, which is when wk_busaddr goes onto the bus -- so the
	--     T+1 captures still hold the kernel's idle address, which is the last
	--     address the bus16 adapter completed.  After any SDRAM read that is
	--     a line-buffer hit, and with bstate = wk_bstate = "10" supplying the
	--     read qualifier, cpu_cacheline_valid is up in (T+1,T+2) for an access
	--     nobody issued, clkena_r fires at T+2, and WK_HI at T+3 takes
	--     datatg68 -- the buffered word at the DESCRIPTOR's offset in the
	--     PREVIOUS access's line -- as the high word of the descriptor.  Every
	--     walk that follows a fast-RAM read gets a garbage upper half, which
	--     is a fault as soon as the 68040.library turns translation on, and
	--     the fault handler's own walk gets the same treatment: the E flags
	--     the ILA showed.  sim/ddr3_cpu could not see it because its SDRAM
	--     model acknowledged only after the select; it models the line buffer
	--     now, and --mmu at ac9b725 fails on it.
	--
	--     bus_fresh, below, is the mask: bus_ready is ignored in exactly that
	--     one cycle, and the walker's completion is taken at T+5/T+6 from
	--     captures made with its own address on the bus.  The fill router
	--     needs nothing: it takes the bus with fl_bstate = "01", so the T+2
	--     decision is the idle term, and it samples mem_ready itself only
	--     from T+4 on.  The second half of a walk (WK_GAP -> WK_LO) puts its
	--     bus state up at least two cycles after its address, so it needs
	--     nothing either.
	--
	-- COST: one clk cycle of acknowledge latency, which the 1:3 quantisation
	-- turns into one clk_cpu cycle (26.45 ns) for one memory access in three
	-- and nothing for the other two -- 8.8 ns on average per access that
	-- actually goes to memory, and zero for a core running out of its own
	-- caches.  Measured in sim/ddr3_cpu; see
	-- findings/ap68040/sdd-d3/task-d3fix-report.md.
	--
	-- mem_ready is registered here and NOT where the two bus routers read it:
	-- FL_SEL/FL_GAP and WK_GAP keep the live copy, so a line fill's eight
	-- words still stream at the clk rate.
	--
	-- bus_fresh: '1' in the single clk cycle after the walker took the bus,
	-- (S,S+1) where S is the edge wk_active rose.  A walker start is at S = T+1
	-- (the kernel raised wk_req at T) or, when a line fill had the bus, at
	-- S = T (fl_busy dropped at T-2, WK_IDLE saw it at T).  Only the first
	-- lands on the decision at T+2 with the address one cycle old, and it is
	-- the only case that does: wk_bstate goes non-idle for the second
	-- sub-cycle two or more cycles after wk_busaddr moved (WK_GAP waits for
	-- the previous acknowledge to clear), and the kernel's own accesses put
	-- address and bus state up together at T.  Constant '0' for the TG68K,
	-- where wk_active is constant '0' too, so bus_release folds back to
	-- exactly what it was.
	bus_fresh <= '0' WHEN NOT use_ap040 ELSE (wk_active AND NOT wk_active_d);

	PROCESS(clk)
	BEGIN
		IF rising_edge(clk) THEN
			clkena_r <= cpu_ph AND bus_release;
		END IF;
	END PROCESS;

	-- The TG68K keeps the combinational expression exactly as it was
	-- (cpu_ce_phase is clkena_in there, and cpu_ph is a constant '0', so
	-- clkena_r folds away with the rest of the AP68040 plumbing).
	clkena <= clkena_r WHEN use_ap040 ELSE (cpu_ce_phase AND bus_release);

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

	--------------------------------------------------------------------------
	-- The walker router.
	--
	-- One descriptor = two 16-bit sub-cycles at A and A+2, high word first,
	-- with an idle gap between them so the chip select drops and the
	-- controller's acknowledge -- a level -- clears before the second is
	-- issued.  Completion is clkena, which is the exact instant the core
	-- itself samples read data, so the capture cannot be a cycle early or
	-- late.  The bus is released BEFORE the acknowledge goes out, so the core
	-- is guaranteed an enable to consume it with (see clkena above).
	--
	-- Errors, following walker_mem_bad in the MiSTer reference: a misaligned
	-- descriptor address, or one that decodes as nothing, raises walker_berr
	-- rather than hanging.  The MMU turns that into an unsuccessful table
	-- search -- a Guru -- instead of the silent halt a missing acknowledge
	-- produces (which is stage A's behaviour, with the port tied off).
	--
	-- STAGE D3-FIX.  WHY BOTH BUS ROUTERS SKIP ONE clk EDGE IN THREE.
	--
	-- wk_active/wk_busaddr and fl_active/fl_busaddr select the bus-side address
	-- mux above, and that mux is the head of the longest combinational chain in
	-- the design:
	--
	--   cpuaddr -> sel_kickram -> cache_inhibit -> sdram_ctrl -> cpu_cache_new's
	--   cpu_cacheline_valid -> cpu_ack -> cpuena -> ramready -> mem_ready ->
	--   bus_ready -> clkena -> the kernel
	--
	-- (and the same round trip again through ddr3_fastram's own cpu_cache_new).
	-- Out of the wrapper, across the die into a memory controller, through its
	-- cache-hit logic and all the way back into the CPU island.  Driven from the
	-- kernel's own addrtg68 that chain is clk_cpu -> clk_cpu and has 26.45 ns;
	-- driven from these registers it is clk -> clk_cpu and has ONE clk period,
	-- 8.815 ns.  It measured 8.24 ns in build/stage_ap040_d3 and 8.81 ns in
	-- build/stage_ap040_d3_ila -- and in those bitstreams wk_active, wk_busaddr
	-- and fl_busaddr were, in that order, the startpoint of EVERY clk -> clk_cpu
	-- path with less than 0.3 ns of slack.  This is what the intermittent
	-- AN_MemCorrupt Guru was standing on.
	--
	-- Before stage D3 the walker half was covered by a multicycle (cpu.xdc's
	-- $cpu_ce_aligned, -setup -start 2, 17.63 ns) and D3 deleted it -- correctly:
	-- the exception's premise was "every transition of wk_active is triggered by
	-- a ce-aligned event", and with the kernel on its own clock that is false.
	-- It is false in five specific places across the two routers, all of them
	-- waits on something the memory side produces:
	--
	--   * WK_IDLE -> WK_HI is gated on fl_busy, which the line-fill router drops
	--     on whatever edge its eighth word lands on;
	--   * the sel_undecoded abort in WK_HI and WK_LO fires on the first edge in
	--     the state, one edge after the state was entered;
	--   * WK_GAP -> WK_LO is gated on bus_ready falling;
	--   * FL_SEL -> FL_GAP is gated on mem_ready rising, and FL_GAP -> FL_SEL on
	--     it falling -- twice per word, eight words per line.
	--
	-- Each of those can land on the clk edge IMMEDIATELY BEFORE a clk_cpu edge,
	-- and that -- not the average case -- is what makes the honest requirement
	-- one clk period.
	--
	-- So make the premise true by construction instead of asserting it away.
	-- bus_step is NOT cpu_ph, and cpu_ph is the phase marker's middle register,
	-- high in (T+1,T+2) when the kernel's edges are at T and T+3 -- so an edge
	-- that samples cpu_ph = '1' IS edge T+2, the one clk edge before the kernel
	-- samples, and gating both routers on bus_step skips exactly that edge and
	-- no other: T, T+1, T+3 and T+4 all run.  Every register in both routers
	-- therefore holds its value across the pair of clk cycles (T+1,T+2) and
	-- (T+2,T+3), which is precisely and only the premise -setup -start 2 needs.
	-- cpu.xdc states the exception against this paragraph; IF THIS GATE IS EVER
	-- REMOVED, THAT EXCEPTION MUST GO WITH IT.
	--
	-- Two is the maximum and three would be false: both routers still run at
	-- edge T+1, so a value launched at T can be gone by T+1.
	--
	-- NO EVENT CAN BE LOST BY SKIPPING AN EDGE, and that is what makes the gate
	-- safe rather than merely slower.  Every condition either router waits on is
	-- a LEVEL held until it is consumed -- fl_busy, wk_req, fl_req, bus_ready,
	-- mem_ready, sel_undecoded, wk_st -- with exactly one exception, clkena,
	-- which is a pulse and is high in (T+2,T+3): it is therefore only ever
	-- sampled at edge T+3, where cpu_ph is '0' and the routers run.
	--
	-- What the gate costs is one clk cycle on those five transitions, one time
	-- in three.  For the walker that is about 1.7 clk cycles, 15 ns, per
	-- descriptor, on a path only taken on an ATC miss.  For the line fill it is
	-- about 6.7 clk cycles, 59 ns, per 16-byte line.  Measured in sim/ddr3_cpu;
	-- see findings/ap68040/sdd-d3/task-d3fix-report.md.
	--
	-- A no-op for the TG68K: use_ap040 is false, bus_step is a constant '1', and
	-- wk_req/fl_req are tied low so both routers fold away as they always did.
	--------------------------------------------------------------------------
	bus_step <= '1' WHEN NOT use_ap040 ELSE NOT cpu_ph;

	PROCESS(clk, reset)
	BEGIN
		IF reset = '0' THEN
			wk_st      <= WK_IDLE;
			wk_active  <= '0';
			wk_bstate  <= "01";
			wk_busaddr <= (others => '0');
			wk_wdat16  <= (others => '0');
			wk_data    <= (others => '0');
			wk_ack     <= '0';
			wk_berr    <= '0';
		ELSIF rising_edge(clk) THEN
			-- One clk edge in three is skipped; see the note above.
			IF bus_step = '1' THEN
				CASE wk_st IS
					WHEN WK_IDLE =>
						wk_ack    <= '0';
						wk_berr   <= '0';
						wk_active <= '0';
						wk_bstate <= "01";
						-- Order, never interleave, with the line fill (stage D).
						-- The two share every bus-side signal, so one waits while
						-- the other owns them.  The walker has priority: the fill
						-- FSM refuses to start while wk_req is high, so a request
						-- arriving in the same cycle can only be taken here.
						IF wk_req = '1' AND fl_busy = '0' THEN
							IF wk_addr(1 downto 0) /= "00" THEN
								-- a descriptor is a longword; this table is corrupt
								wk_berr <= '1';
								wk_st   <= WK_DONE;
							ELSE
								wk_busaddr <= wk_addr;
								wk_wdat16  <= wk_wdat(31 downto 16);
								IF wk_we = '1' THEN wk_bstate <= "11"; ELSE wk_bstate <= "10"; END IF;
								wk_active  <= '1';
								wk_st      <= WK_HI;
							END IF;
						END IF;

					WHEN WK_HI =>
						-- sel_undecoded, not sel_undecoded_d: the registered copy
						-- still holds the PREVIOUS access's decode on the first
						-- cycle of ours, and the core's last address is often in
						-- undecoded space.  The combinational one is already ours.
						IF sel_undecoded = '1' THEN
							-- nothing lives at this physical address
							wk_active <= '0';
							wk_bstate <= "01";
							wk_berr   <= '1';
							wk_st     <= WK_DONE;
						ELSIF clkena = '1' THEN
							wk_data(31 downto 16) <= datatg68;
							wk_busaddr            <= wk_addr(31 downto 2) & "10";
							wk_wdat16             <= wk_wdat(15 downto 0);
							wk_bstate             <= "01";
							wk_st                 <= WK_GAP;
						END IF;

					WHEN WK_GAP =>
						-- Hold the bus, idle, until the acknowledge that released
						-- the first sub-cycle has cleared.  Without this the
						-- second sub-cycle can complete on the first one's stale
						-- level and read the same word twice.
						IF bus_ready = '0' THEN
							IF wk_we = '1' THEN wk_bstate <= "11"; ELSE wk_bstate <= "10"; END IF;
							wk_st     <= WK_LO;
						END IF;

					WHEN WK_LO =>
						IF sel_undecoded = '1' THEN
							wk_active <= '0';
							wk_bstate <= "01";
							wk_berr   <= '1';
							wk_st     <= WK_DONE;
						ELSIF clkena = '1' THEN
							wk_data(15 downto 0) <= datatg68;
							wk_active            <= '0';
							wk_bstate            <= "01";
							wk_ack               <= '1';
							wk_st                <= WK_DONE;
						END IF;

					WHEN WK_DONE =>
						-- ap040_mmu drops walker_req when it has taken the answer
						-- (walk_ack is qualified with w_active && w_issued), and
						-- inserts a request-low cycle before the next descriptor,
						-- so this is the whole handshake.
						IF wk_req = '0' THEN
							wk_ack  <= '0';
							wk_berr <= '0';
							wk_st   <= WK_IDLE;
						END IF;
				END CASE;
			END IF;
		END IF;
	END PROCESS;

	--------------------------------------------------------------------------
	-- The line-fill router (stage D).
	--
	-- Eight word reads at the line address, offset 0 first, streamed at the
	-- free clk_114 rate, then one acknowledge to the core.  The controllers
	-- see ordinary CPU data reads: the first one misses and fetches the whole
	-- 16-byte line into cpu_cache_new's line buffer, the other seven are hits
	-- out of that buffer, which is why this costs one memory round trip and
	-- not eight.
	--
	-- Per word: put the address out with the select IDLE, wait a cycle, open
	-- the select, take the answer, close the select, wait for the level to
	-- clear.  The wait is the walker's WK_GAP and is there for the same
	-- reason -- cpu_cache_new clears its acknowledge only when the select
	-- goes away, so without it the next word completes on the previous one's
	-- stale level and the line is filled with one word eight times.  The
	-- idle cycle before the select is the port contract both controllers
	-- state in their headers: "cpuAddr must be stable ONE CYCLE BEFORE
	-- cpustate[2] goes low", because each registers cpuAddr into cpuAddr_r
	-- and it is cpuAddr_r that addresses the memory on a miss.
	--
	-- Word order.  fill_data carries the longword at line offset 0 in
	-- [127:96] and the one at offset 12 in [31:0] (ap040_cache.v:93-99), so
	-- the 16-bit word at line offset 2k lands in bits [127-16k : 112-16k]:
	-- shifting each word in from the right as it arrives, offset 0 first,
	-- puts every one of them where the cache expects it.  That is bit for bit
	-- what ap040_fill_cdc.v does with the controller's four longword beats
	-- ("m_line <= {m_line[95:0], m_dat}"), which is the check on this.
	--
	-- An address that decodes to NOTHING is auto-completed, not faulted.  The
	-- core's cacheable Zorro windows are far wider than the boards inside
	-- them (see fl_ok), so a cacheable read of a hole in one is ordinary
	-- traffic; and this SoC's policy for an address that decodes to nothing
	-- is to complete it with $FFFF -- sel_undecoded does exactly that for the
	-- CPU, and the note beside the core's berr input says the SoC never
	-- raises a bus error at all.  So FL_DEC answers a line of all ones and
	-- acknowledges, bit for bit what the eight adapter reads it replaces
	-- returned.
	--
	-- fill_err stays wired for the case that cannot happen.  Measured what
	-- the alternative costs: with fill_err raised there instead, the cache
	-- took C_FERR and the machine did not merely Guru, it STOPPED -- the
	-- bench's 68k program timed out at phase 7 with no fault reported
	-- (sim/ddr3_cpu, 2026-09-09).  err_hold waits for the core to withdraw a
	-- request the core has no reason to withdraw.
	--------------------------------------------------------------------------
	PROCESS(clk, reset)
	BEGIN
		IF reset = '0' THEN
			fl_st      <= FL_IDLE;
			fl_busy    <= '0';
			fl_active  <= '0';
			fl_bstate  <= "01";
			fl_busaddr <= (others => '0');
			fl_word    <= "000";
			fl_line    <= (others => '0');
			fl_ack     <= '0';
			fl_err     <= '0';
		ELSIF rising_edge(clk) THEN
			-- One clk edge in three is skipped, exactly as the walker above:
			-- fl_busaddr and fl_active head the same combinational chain, and
			-- every condition below is a level, so nothing can be missed.
			IF bus_step = '1' THEN
				CASE fl_st IS
					WHEN FL_IDLE =>
						fl_ack    <= '0';
						fl_err    <= '0';
						fl_active <= '0';
						fl_bstate <= "01";
						-- The walker gets the bus first (see WK_IDLE), and the
						-- core's own bus side must be idle -- it is, because the
						-- cache is sitting in C_FILLC waiting for this answer and
						-- has nothing outstanding through the adapter.  Checking
						-- it anyway costs one gate and turns a future violation
						-- into a stall the bench can see instead of a lost access.
						IF fl_req = '1' AND wk_req = '0' AND wk_st = WK_IDLE
						   AND state = "01" THEN
							fl_busy    <= '1';
							fl_word    <= "000";
							fl_busaddr <= fl_addr & "0000";
							fl_active  <= '1';   -- take the bus, select still idle
							fl_st      <= FL_DEC;
						END IF;

					WHEN FL_DEC =>
						-- The address has been on cpuaddr for a whole cycle, so
						-- the combinational decode below is ours and the
						-- controllers' cpuAddr_r has caught it.  (sel_* and not
						-- their registered copies, for the reason WK_HI records:
						-- the registered ones still hold the previous access.)
						IF fl_ok = '0' THEN
							-- Nothing decodes here: auto-complete the whole line
							-- with $FFFF words and acknowledge, exactly as the
							-- eight adapter reads would have (see above).  No bus
							-- transfer is needed, so it is released at once.
							fl_active <= '0';
							fl_bstate <= "01";
							fl_line   <= (others => '1');
							fl_ack    <= '1';
							fl_st     <= FL_DONE;
						ELSE
							fl_bstate <= "10";   -- a data read; the select opens
							fl_st     <= FL_SEL;
						END IF;

					WHEN FL_SEL =>
						IF mem_ready = '1' THEN
							-- offset 0 first, shifted in from the right
							fl_line   <= fl_line(111 downto 0) & datatg68;
							fl_bstate <= "01";   -- close the select
							IF fl_word = "111" THEN
								fl_active <= '0';
								fl_ack    <= '1';
								fl_st     <= FL_DONE;
							ELSE
								fl_word    <= fl_word + 1;
								fl_busaddr <= fl_busaddr(31 downto 4) & (fl_word + 1) & '0';
								fl_st      <= FL_GAP;
							END IF;
						END IF;

					WHEN FL_GAP =>
						-- The next word's address is already out (set above), so
						-- this wait doubles as its setup cycle.
						IF mem_ready = '0' THEN
							fl_bstate <= "10";
							fl_st     <= FL_SEL;
						END IF;

					WHEN FL_DONE =>
						-- ap040_cache drops fill_req in the cycle it takes the
						-- line (C_FILLC, under ce), so the level is held until
						-- then and fl_line is not touched meanwhile.
						IF fl_req = '0' THEN
							fl_ack  <= '0';
							fl_err  <= '0';
							fl_busy <= '0';
							fl_st   <= FL_IDLE;
						END IF;
				END CASE;
			END IF;
		END IF;
	END PROCESS;

	-- A DDR3 (Zorro III) access is a memory cycle released by the DDR3 acknowledge, never a 7 MHz chipset cycle.
	-- (sel_ram no longer covers the Z3 selects when haveddr3; without this term every DDR3 access was released
	-- on the chipset strobes with whatever fromddr held at that moment.)
	chipset_cycle <= '1' when ((sel_ram = '0' AND sel_ddr = '0') OR sel_nmi_vector = '1') AND sel_akiko = '0' and sel_undecoded = '0' else
	'0';

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
			clkena_f <= '0';
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
			-- edge the CPU is released, bus_ready stays high and the next
			-- cpu_ph2 fires this test again.  The point is that the release
			-- is no longer built on it.)  It changes nothing for the TG68K:
			-- between the two firings the only readers of clkena_e are
			-- `ena7RDreg AND clkena_e` (ena7RDreg is low there) and
			-- `S_state = "01"` (S_state is "00" there).
			IF (chipset_ready = '1' OR chipset_done = '1') AND clkena = '1' THEN
				S_state <= "00";
			END IF;

			IF S_state = "01" AND clkena_e = '1' THEN
				uds2        <= buds;
				lds2        <= blds;
				data_write2 <= bwdata;
			END IF;

			IF ena7WRreg = '1' THEN
				CASE S_state IS
					WHEN "00" =>
						-- cpu_bus_settled: with the AP68040 the signals
						-- latched below come off a 37.8125 MHz island, so wait
						-- until they have settled; see where it is driven.
						IF cpu_int = '0' AND chipset_cycle = '1' AND cpu_bus_settled = '1' THEN
							uds        <= buds;
							lds        <= blds;
							uds2       <= '1';
							lds2       <= '1';
							as         <= '0';
							rw         <= bwr;
							data_write <= bwdata;
							addr       <= cpuaddr;
							IF aga = '1' AND cpu_i(1) = '1' AND longword_pair = '1' AND bstate = "11" AND cpuaddr(1 downto 0) = "00" AND sel_chip = '1' THEN
								-- 32 bit write
								clkena_e <= '1';
							END IF;
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
						IF clkena_f = '1' THEN
							clkena_f <= '0';
							r_data   <= data_read2;
						END IF;
					WHEN OTHERS => null;
				END CASE;
			ELSIF ena7RDreg = '1' THEN
				clkena_f <= '0';
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
						IF aga = '1' AND cpu_i(1) = '1' AND longword_pair = '1' AND bstate(0) = '0' AND cpuaddr(1 downto 0) = "00" AND (sel_chip = '1' OR sel_kick = '1') THEN
							-- 32 bit read
							clkena_f <= '1';
						END IF;
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
