--------------------------------------------------------------------------
-- ap040_ram_seq_tb.vhd - Stage E2 Task 4a.
--
-- Drives rtl/soc/ap040_ram_seq.vhd against a behavioural unit-port memory,
-- for every size at every offset of one 16-byte line, and checks:
--
--   1. NO UNIT CROSSES A LINE.  The memory model itself asserts this, so a
--      split-table mistake fails here instead of becoming 26 silent backdoor
--      mismatches in sim/ddr3_cpu (which is exactly how it failed in Task 3).
--   2. The bytes written are the operand's bytes, in the right places, and
--      NOTHING around them moved -- the whole array is compared to a golden
--      copy after every write.
--   3. Read-back returns the operand, right-aligned by size.
--   4. The unit count per access never exceeds two.
--
-- Run twice: with the placement gate held open, and with it open one cycle
-- in four, which is the shape the D3 phase grid presents.
--------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY ap040_ram_seq_tb IS
	GENERIC (
		gate_div    : integer := 1;      -- 1 = always open, 4 = one cycle in four
		line_mutant : integer := 0       -- 1 = let units cross a line; must fail
	);
END ap040_ram_seq_tb;

ARCHITECTURE tb OF ap040_ram_seq_tb IS

	CONSTANT MEMBYTES : integer := 256;
	CONSTANT LINEBASE : integer := 64;   -- the line under test starts here

	SIGNAL clk    : std_logic := '0';
	SIGNAL reset  : std_logic := '0';
	SIGNAL halt   : boolean   := false;

	SIGNAL req    : std_logic := '0';
	SIGNAL we     : std_logic := '0';
	SIGNAL ir     : std_logic := '0';
	SIGNAL size   : std_logic_vector(1 downto 0) := "00";
	SIGNAL addr   : std_logic_vector(25 downto 0) := (OTHERS => '0');
	SIGNAL wdata  : std_logic_vector(31 downto 0) := (OTHERS => '0');
	SIGNAL ack    : std_logic;
	SIGNAL rdata  : std_logic_vector(31 downto 0);
	SIGNAL gate   : std_logic := '1';

	SIGNAL u_req  : std_logic;
	SIGNAL u_we   : std_logic;
	SIGNAL u_ir   : std_logic;
	SIGNAL u_wadr : std_logic_vector(25 downto 1);
	SIGNAL u_bs   : std_logic_vector(3 downto 0);
	SIGNAL u_wdat : std_logic_vector(31 downto 0);
	SIGNAL u_rdat : std_logic_vector(31 downto 0) := (OTHERS => '0');
	SIGNAL u_ack  : std_logic := '0';

	TYPE mem_t IS ARRAY (0 TO MEMBYTES-1) OF std_logic_vector(7 downto 0);

	-- The background pattern, as the array's initial value.  It must NOT be
	-- driven by the stimulus process: mem is written by the memory model, and
	-- a second driver on a resolved type resolves to 'X' instead of failing.
	FUNCTION init_mem RETURN mem_t IS
		VARIABLE m : mem_t;
	BEGIN
		FOR i IN 0 TO MEMBYTES-1 LOOP
			m(i) := std_logic_vector(to_unsigned((i * 7 + 11) MOD 256, 8));
		END LOOP;
		RETURN m;
	END FUNCTION;

	SIGNAL mem : mem_t := init_mem;

	-- counters owned by the memory model, and by it ALONE: these are
	-- unresolved integers, so a second driver fails elaboration
	SIGNAL units_total : integer := 0;
	SIGNAL units_here  : integer := 0;   -- units in the access under way
	SIGNAL cross_fail  : integer := 0;

BEGIN

	clk <= NOT clk AFTER 5 ns WHEN NOT halt ELSE '0';

	dut : ENTITY work.ap040_ram_seq
		GENERIC MAP ( line_mutant => line_mutant )
		PORT MAP (
			clk => clk, reset => reset,
			req => req, we => we, ir => ir, size => size,
			addr => addr, wdata => wdata, ack => ack, rdata => rdata,
			gate => gate,
			u_req => u_req, u_we => u_we, u_ir => u_ir,
			u_wadr => u_wadr, u_bs => u_bs, u_wdat => u_wdat,
			u_rdat => u_rdat, u_ack => u_ack
		);

	--------------------------------------------------------------------------
	-- The placement gate.  gate_div = 1 leaves it open; 4 opens it one cycle
	-- in four, the way the SDRAM round opens phase 2/6/10/14.
	--------------------------------------------------------------------------
	gate_gen : PROCESS(clk)
		VARIABLE g : integer RANGE 0 TO 15 := 0;
	BEGIN
		IF rising_edge(clk) THEN
			IF gate_div <= 1 THEN
				gate <= '1';
			ELSE
				IF g = 0 THEN gate <= '1'; ELSE gate <= '0'; END IF;
				IF g = gate_div-1 THEN g := 0; ELSE g := g + 1; END IF;
			END IF;
		END IF;
	END PROCESS;

	--------------------------------------------------------------------------
	-- Behavioural unit-port memory.  Level acknowledge, three cycles of
	-- latency, released when the request drops -- the same handshake shape
	-- cpu_cache_new and ddr3_fastram present.
	--------------------------------------------------------------------------
	memmodel : PROCESS(clk)
		VARIABLE lat  : integer RANGE 0 TO 7 := 0;
		VARIABLE base : integer;
	BEGIN
		IF rising_edge(clk) THEN
			-- a new access starts the count; the stimulus reads it back
			-- before it releases req
			IF req = '0' THEN
				units_here <= 0;
			END IF;

			IF u_req = '0' THEN
				u_ack <= '0';
				lat   := 0;
			ELSIF u_ack = '0' THEN
				IF lat < 3 THEN
					lat := lat + 1;
				ELSE
					base := to_integer(unsigned(u_wadr)) * 2;

					-- INVARIANT 1: a unit may name two words only when they
					-- lie in the same 16-byte line, i.e. never at word 7.
					IF (u_bs(1) = '1' OR u_bs(0) = '1')
					   AND u_wadr(3 downto 1) = "111" THEN
						REPORT "FAIL line crossing: unit at word " &
						       integer'image(to_integer(unsigned(u_wadr))) &
						       " bs=" & integer'image(to_integer(unsigned(u_bs)))
						       SEVERITY ERROR;
						cross_fail <= cross_fail + 1;
					END IF;

					IF u_we = '1' THEN
						IF u_bs(3) = '1' THEN mem(base)   <= u_wdat(31 downto 24); END IF;
						IF u_bs(2) = '1' THEN mem(base+1) <= u_wdat(23 downto 16); END IF;
						IF u_bs(1) = '1' THEN mem(base+2) <= u_wdat(15 downto 8);  END IF;
						IF u_bs(0) = '1' THEN mem(base+3) <= u_wdat(7 downto 0);   END IF;
					END IF;

					u_rdat <= mem(base) & mem(base+1) & mem(base+2) & mem(base+3);
					u_ack  <= '1';
					units_total <= units_total + 1;
					units_here  <= units_here + 1;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	--------------------------------------------------------------------------
	-- Stimulus
	--------------------------------------------------------------------------
	stim : PROCESS
		VARIABLE gold     : mem_t := (OTHERS => x"00");
		VARIABLE fails    : integer := 0;
		VARIABLE checks   : integer := 0;
		VARIABLE nbytes   : integer;
		VARIABLE operand  : std_logic_vector(31 downto 0);
		VARIABLE expect   : std_logic_vector(31 downto 0);
		VARIABLE baseaddr : integer;
		VARIABLE nu       : integer := 0;   -- units the last access took
		VARIABLE units_max: integer := 0;

		PROCEDURE step IS
		BEGIN
			WAIT UNTIL rising_edge(clk);
		END PROCEDURE;

		-- one access through the sequencer; returns when it has acknowledged
		PROCEDURE do_access(sz : std_logic_vector(1 downto 0);
		                    a  : integer;
		                    wr : std_logic;
		                    d  : std_logic_vector(31 downto 0);
		                    n  : OUT integer) IS
		BEGIN
			step;
			size  <= sz;
			addr  <= std_logic_vector(to_unsigned(a, 26));
			wdata <= d;
			we    <= wr;
			req   <= '1';
			LOOP
				step;
				EXIT WHEN ack = '1';
			END LOOP;
			n := units_here;        -- read it while req is still high
			req <= '0';
			step;
		END PROCEDURE;

	BEGIN
		reset <= '0';
		FOR i IN 0 TO 3 LOOP step; END LOOP;
		reset <= '1';
		step;

		-- the golden copy starts as the array's initial value
		FOR i IN 0 TO MEMBYTES-1 LOOP
			gold(i) := std_logic_vector(to_unsigned((i * 7 + 11) MOD 256, 8));
		END LOOP;
		step;

		FOR szi IN 0 TO 2 LOOP
			CASE szi IS
				WHEN 0      => nbytes := 1;
				WHEN 1      => nbytes := 2;
				WHEN OTHERS => nbytes := 4;
			END CASE;

			FOR off IN 0 TO 15 LOOP
				baseaddr := LINEBASE + off;

				-- a pattern unique to (size, offset, byte position)
				operand := (OTHERS => '0');
				FOR n IN 0 TO nbytes-1 LOOP
					operand(31-8*n downto 24-8*n) :=
						std_logic_vector(to_unsigned(
							(szi*64 + off*4 + n + 1) MOD 256, 8));
				END LOOP;

				-- right-align it the way the core presents write data
				CASE szi IS
					WHEN 0      => expect := x"000000" & operand(31 downto 24);
					WHEN 1      => expect := x"0000" & operand(31 downto 16);
					WHEN OTHERS => expect := operand;
				END CASE;

				-- WRITE, then update the golden copy
				do_access(std_logic_vector(to_unsigned(szi, 2)), baseaddr, '1', expect, nu);
				FOR n IN 0 TO nbytes-1 LOOP
					gold(baseaddr + n) := operand(31-8*n downto 24-8*n);
				END LOOP;

				IF nu > units_max THEN units_max := nu; END IF;
				IF nu > 2 THEN
					REPORT "FAIL unit count: size " & integer'image(szi) &
					       " offset " & integer'image(off) & " took " &
					       integer'image(nu) & " units"
					       SEVERITY ERROR;
					fails := fails + 1;
				END IF;
				checks := checks + 1;

				-- INVARIANT 2: the whole memory matches the golden copy, so
				-- any byte written outside the operand is caught
				FOR i IN 0 TO MEMBYTES-1 LOOP
					IF mem(i) /= gold(i) THEN
						REPORT "FAIL stray write: size " & integer'image(szi) &
						       " offset " & integer'image(off) & " byte " &
						       integer'image(i) SEVERITY ERROR;
						fails := fails + 1;
						EXIT;
					END IF;
				END LOOP;
				checks := checks + 1;

				-- INVARIANT 3: read it back
				do_access(std_logic_vector(to_unsigned(szi, 2)), baseaddr, '0', (OTHERS => '0'), nu);
				IF rdata /= expect THEN
					REPORT "FAIL readback: size " & integer'image(szi) &
					       " offset " & integer'image(off) SEVERITY ERROR;
					fails := fails + 1;
				END IF;
				checks := checks + 1;
			END LOOP;
		END LOOP;

		REPORT "=== ram_seq sweep: " & integer'image(checks) & " checked, " &
		       integer'image(fails) & " failed, " &
		       integer'image(cross_fail) & " line crossings, " &
		       integer'image(units_total) & " units, max " &
		       integer'image(units_max) & " per access"
		       SEVERITY NOTE;

		IF fails = 0 AND cross_fail = 0 THEN
			REPORT "=== ram_seq PASS" SEVERITY NOTE;
		ELSE
			REPORT "=== ram_seq FAIL" SEVERITY ERROR;
		END IF;

		halt <= true;
		WAIT;
	END PROCESS;

END tb;
