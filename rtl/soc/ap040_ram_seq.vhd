--------------------------------------------------------------------------
-- ap040_ram_seq.vhd - Stage E2 Task 4.
--
-- One AP68040 memory access in, a sequence of UNIT PORT accesses out.
--
-- The unit port contract (E2 decision D3): one request is at most two
-- CONSECUTIVE words inside ONE 16-byte line, with a byte select per byte.
--   u_wadr  word address of word A
--   u_bs    {A hi, A lo, A+2 hi, A+2 lo}, active high
--   u_wdat  {word A, word A+2};  u_rdat the same, valid with u_ack
-- "hi" is the even byte address (big endian), matching the nuds/nlds lanes
-- the 16-bit adapter this replaces drove.
--
-- Rather than encode D3's hand-written split table, this walks the operand's
-- byte range and takes, each step, as many bytes as fit in BOTH the current
-- two-word window AND the current 16-byte line.  "No unit crosses a line" is
-- then a property of the arithmetic instead of a table entry that can be
-- mistyped -- and it comes out cheaper than the table: a longword at an odd
-- offset needs TWO units (offset 1 -> bytes 1..3 as bs=0111, then byte 4),
-- not the table's byte+word+byte.  The worst case anywhere is two units.
--
-- Data alignment follows the core, not the bus: wdata and rdata are
-- RIGHT-aligned by size (byte in [7:0], word in [15:0], long in [31:0]),
-- while operand bytes travel MSB first, exactly as ap040_bus16_adapter.v
-- shifted them.
--
-- ack is a LEVEL, held until req drops -- not a pulse.  This block runs on
-- the memory clock and the master that reads ack runs on clk_38, so the D4
-- crossing contract applies; a held level is stable across the whole capture
-- window and needs no edge shaping.
--------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY ap040_ram_seq IS
	GENERIC (
		-- Test hook, 0 in every build.  1 drops the 16-byte line limit, so
		-- units are allowed to cross a line: sim/ram_seq's mutant mode sets
		-- it and MUST fail.  A sweep that reports no failures either way is
		-- a sweep with no teeth.
		line_mutant : integer := 0
	);
	PORT (
		clk      : IN  std_logic;                        -- memory clock
		reset    : IN  std_logic;                        -- active low
		-- the access, held stable while req is high
		req      : IN  std_logic;
		we       : IN  std_logic;
		ir       : IN  std_logic;
		size     : IN  std_logic_vector(1 downto 0);     -- 0 B, 1 W, 2 L
		addr     : IN  std_logic_vector(25 downto 0);    -- MAPPED byte address
		wdata    : IN  std_logic_vector(31 downto 0);    -- right-aligned
		ack      : OUT std_logic;                        -- level, until req drops
		rdata    : OUT std_logic_vector(31 downto 0);    -- right-aligned
		-- D3 placement gate: a unit may only be LAUNCHED while this is high,
		-- so every unit of a split access lands on the grid, not just the first
		gate     : IN  std_logic;
		-- the unit port
		u_req    : OUT std_logic;
		u_we     : OUT std_logic;
		u_ir     : OUT std_logic;
		u_wadr   : OUT std_logic_vector(25 downto 1);
		u_bs     : OUT std_logic_vector(3 downto 0);
		u_wdat   : OUT std_logic_vector(31 downto 0);
		u_rdat   : IN  std_logic_vector(31 downto 0);
		u_ack    : IN  std_logic
	);
END ap040_ram_seq;

ARCHITECTURE rtl OF ap040_ram_seq IS

	TYPE state_t IS (RS_IDLE, RS_LAUNCH, RS_WAIT, RS_GAP, RS_DONE);
	SIGNAL st     : state_t;

	SIGNAL cur    : unsigned(25 downto 0);      -- byte address of the next byte
	SIGNAL left   : unsigned(2 downto 0);       -- operand bytes still to move
	SIGNAL pos    : unsigned(2 downto 0);       -- operand bytes already moved
	SIGNAL wsh    : std_logic_vector(31 downto 0);  -- write operand, left-aligned
	SIGNAL rbuf   : std_logic_vector(31 downto 0);  -- read operand, left-aligned
	SIGNAL sz_r   : std_logic_vector(1 downto 0);
	SIGNAL done_r : std_logic;
	SIGNAL armed  : std_logic;                  -- this unit's fields are out

	SIGNAL u_req_r  : std_logic;
	SIGNAL u_we_r   : std_logic;
	SIGNAL u_ir_r   : std_logic;
	SIGNAL u_wadr_r : std_logic_vector(25 downto 1);
	SIGNAL u_bs_r   : std_logic_vector(3 downto 0);
	SIGNAL u_wdat_r : std_logic_vector(31 downto 0);

	-- shape of the unit that starts at cur
	SIGNAL p0     : integer RANGE 0 TO 1;       -- first byte's slot in the window
	SIGNAL ncov   : integer RANGE 1 TO 4;       -- bytes this unit carries

	-- operand length in bytes
	FUNCTION size_bytes(s : std_logic_vector(1 downto 0)) RETURN unsigned IS
	BEGIN
		CASE s IS
			WHEN "00"   => RETURN to_unsigned(1, 3);
			WHEN "01"   => RETURN to_unsigned(2, 3);
			WHEN OTHERS => RETURN to_unsigned(4, 3);
		END CASE;
	END FUNCTION;

	-- the write operand, left-aligned, so byte n of the operand is always
	-- wsh(31-8n downto 24-8n) whatever its size
	FUNCTION left_align(d : std_logic_vector(31 downto 0);
	                    s : std_logic_vector(1 downto 0)) RETURN std_logic_vector IS
	BEGIN
		CASE s IS
			WHEN "00"   => RETURN d(7 downto 0) & x"000000";
			WHEN "01"   => RETURN d(15 downto 0) & x"0000";
			WHEN OTHERS => RETURN d;
		END CASE;
	END FUNCTION;

BEGIN

	--------------------------------------------------------------------------
	-- Shape of the unit starting at cur.  The two-word window holds the four
	-- bytes (cur AND NOT 1) .. (cur AND NOT 1)+3, so a byte at an odd address
	-- starts in slot 1 and only three of the four slots are reachable.  The
	-- line limit is what keeps a unit inside one 16-byte line.
	--------------------------------------------------------------------------
	p0 <= 1 WHEN cur(0) = '1' ELSE 0;

	PROCESS(cur, left, p0)
		VARIABLE lim_win  : integer RANGE 3 TO 4;   -- slots left in the window
		VARIABLE lim_line : integer RANGE 1 TO 16;  -- bytes left in the line
		VARIABLE n        : integer RANGE 1 TO 4;
	BEGIN
		lim_win  := 4 - p0;
		lim_line := 16 - to_integer(cur(3 downto 0));
		n := to_integer(left);
		IF n < 1 THEN n := 1; END IF;
		IF n > lim_win  THEN n := lim_win;  END IF;
		IF line_mutant = 0 AND n > lim_line THEN n := lim_line; END IF;
		ncov <= n;
	END PROCESS;

	PROCESS(clk, reset)
		VARIABLE bs_v   : std_logic_vector(3 downto 0);
		VARIABLE wd_v   : std_logic_vector(31 downto 0);
		VARIABLE k      : integer RANGE 0 TO 7;
		-- the first unit's shape, straight from the inputs: RS_IDLE presents it
		-- in the same edge that latches the access, so the setup cycle IS the
		-- latch cycle (Stage E2 Task 5a, -1 clk per access)
		VARIABLE a_v    : unsigned(25 downto 0);
		VARIABLE w_v    : std_logic_vector(31 downto 0);
		VARIABLE p0_v   : integer RANGE 0 TO 1;
		VARIABLE n_v    : integer RANGE 1 TO 4;
		VARIABLE lw_v   : integer RANGE 3 TO 4;
		VARIABLE ll_v   : integer RANGE 1 TO 16;
		VARIABLE lf_v   : integer RANGE 1 TO 4;
	BEGIN
		IF reset = '0' THEN
			st       <= RS_IDLE;
			cur      <= (OTHERS => '0');
			left     <= (OTHERS => '0');
			pos      <= (OTHERS => '0');
			wsh      <= (OTHERS => '0');
			rbuf     <= (OTHERS => '0');
			sz_r     <= (OTHERS => '0');
			done_r   <= '0';
			armed    <= '0';
			u_req_r  <= '0';
			u_we_r   <= '0';
			u_ir_r   <= '0';
			u_wadr_r <= (OTHERS => '0');
			u_bs_r   <= (OTHERS => '0');
			u_wdat_r <= (OTHERS => '0');
		ELSIF rising_edge(clk) THEN
			-- the completion level lasts exactly as long as the request does
			IF req = '0' THEN
				done_r <= '0';
			END IF;

			CASE st IS

				WHEN RS_IDLE =>
					u_req_r <= '0';
					IF req = '1' AND done_r = '0' THEN
						a_v    := unsigned(addr);
						w_v    := left_align(wdata, size);
						cur    <= a_v;
						left   <= size_bytes(size);
						pos    <= (OTHERS => '0');
						wsh    <= w_v;
						rbuf   <= (OTHERS => '0');
						sz_r   <= size;
						u_we_r <= we;
						u_ir_r <= ir;
						-- the first unit's fields, so RS_LAUNCH only waits for
						-- the gate.  Same arithmetic as the ncov process, on
						-- the inputs instead of the registered copies.
						IF a_v(0) = '1' THEN p0_v := 1; ELSE p0_v := 0; END IF;
						lw_v := 4 - p0_v;
						ll_v := 16 - to_integer(a_v(3 downto 0));
						lf_v := to_integer(size_bytes(size));
						n_v  := lf_v;
						IF n_v > lw_v THEN n_v := lw_v; END IF;
						IF line_mutant = 0 AND n_v > ll_v THEN n_v := ll_v; END IF;
						bs_v := (OTHERS => '0');
						wd_v := (OTHERS => '0');
						FOR p IN 0 TO 3 LOOP
							IF p >= p0_v AND p < p0_v + n_v THEN
								k := p - p0_v;
								bs_v(3 - p) := '1';
								wd_v(31 - 8*p downto 24 - 8*p) :=
									w_v(31 - 8*k downto 24 - 8*k);
							END IF;
						END LOOP;
						u_wadr_r <= std_logic_vector(a_v(25 downto 1));
						u_bs_r   <= bs_v;
						u_wdat_r <= wd_v;
						armed  <= '1';
						st     <= RS_LAUNCH;
					END IF;

				WHEN RS_LAUNCH =>
					-- The unit's fields go out on the first edge here and the
					-- request only on a later one, when the placement gate is
					-- open: cpu_cache_new registers the live address and acts
					-- in the request's first cycle, so it needs the fields a
					-- cycle early, as the old port had the address a cycle
					-- before the select.  Every unit is gated, not just the
					-- first.
					bs_v := (OTHERS => '0');
					wd_v := (OTHERS => '0');
					FOR p IN 0 TO 3 LOOP
						IF p >= p0 AND p < p0 + ncov THEN
							k := to_integer(pos) + (p - p0);
							bs_v(3 - p) := '1';
							wd_v(31 - 8*p downto 24 - 8*p) :=
								wsh(31 - 8*k downto 24 - 8*k);
						END IF;
					END LOOP;
					u_wadr_r <= std_logic_vector(cur(25 downto 1));
					u_bs_r   <= bs_v;
					u_wdat_r <= wd_v;
					armed    <= '1';
					IF gate = '1' AND armed = '1' THEN
						u_req_r  <= '1';
						st       <= RS_WAIT;
					END IF;

				WHEN RS_WAIT =>
					IF u_ack = '1' THEN
						-- take this unit's bytes, MSB first, into the
						-- left-aligned read buffer
						FOR p IN 0 TO 3 LOOP
							IF p >= p0 AND p < p0 + ncov THEN
								k := to_integer(pos) + (p - p0);
								rbuf(31 - 8*k downto 24 - 8*k) <=
									u_rdat(31 - 8*p downto 24 - 8*p);
							END IF;
						END LOOP;
						cur     <= cur + to_unsigned(ncov, 26);
						left    <= left - to_unsigned(ncov, 3);
						pos     <= pos + to_unsigned(ncov, 3);
						u_req_r <= '0';
						armed   <= '0';
						-- The LAST unit finishes here, on the acknowledge edge:
						-- RS_GAP only exists to drop the request before the
						-- NEXT unit, and RS_DONE only to raise done_r, which
						-- this edge can do (Stage E2 Task 5a, -2 clk per
						-- access; with the 1:3 quantisation that is often a
						-- whole clk_38 period).
						IF left = to_unsigned(ncov, 3) THEN
							done_r <= '1';
							st     <= RS_IDLE;
						ELSE
							st     <= RS_GAP;
						END IF;
					END IF;

				WHEN RS_GAP =>
					-- One cycle with the request low, between the units of a
					-- split access.  Both RAM controllers hold their
					-- acknowledge until the request drops, so a new address
					-- presented on the ack edge would be lost.  (The last unit
					-- does not come through here; see RS_WAIT.)
					st <= RS_LAUNCH;

				WHEN RS_DONE =>
					-- unreachable since Task 5a; kept so the state encoding and
					-- the bench's state names do not change
					done_r <= '1';
					st     <= RS_IDLE;

			END CASE;
		END IF;
	END PROCESS;

	u_req  <= u_req_r;
	u_we   <= u_we_r;
	u_ir   <= u_ir_r;
	u_wadr <= u_wadr_r;
	u_bs   <= u_bs_r;
	u_wdat <= u_wdat_r;

	ack   <= done_r;

	-- right-align the read operand again for the core
	rdata <= x"000000" & rbuf(31 downto 24) WHEN sz_r = "00" ELSE
	         x"0000"   & rbuf(31 downto 16) WHEN sz_r = "01" ELSE
	         rbuf;

END rtl;
