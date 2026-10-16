-- xsim test for the boot ROM template (rom_prologue/rom_epilogue): every byte-enable
-- pattern on port A and on port B writes a word inside the firmware image, and both
-- ports read it back.  Failing conditions: any 'X'/'U' on q/q2, a lane merged wrongly,
-- or a write that did not land.  bytesel(0) is the byte at bits 31:24 (lane rule).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rom_tb is
end rom_tb;

architecture sim of rom_tb is
	constant AW : integer := 12;
	signal clk : std_logic := '0';
	signal addr, addr2 : std_logic_vector(AW-2 downto 0) := (others => '0');
	signal q, q2, d, d2 : std_logic_vector(31 downto 0) := (others => '0');
	signal we, we2 : std_logic := '0';
	signal bytesel, bytesel2 : std_logic_vector(3 downto 0) := "1111";
	signal done : boolean := false;
	signal errors : integer := 0;
begin
	clk <= not clk after 5 ns when not done;

	dut : entity work.OSDBoot_rv_ROM
		generic map (maxAddrBitBRAM => AW)
		port map (clk => clk, addr => addr, q => q, d => d, we => we, bytesel => bytesel,
		          addr2 => addr2, q2 => q2, d2 => d2, we2 => we2, bytesel2 => bytesel2);

	stim : process
		type word_array is array (0 to 15) of std_logic_vector(31 downto 0);
		variable old : word_array;
		variable expv, wr : std_logic_vector(31 downto 0);
		variable fails : integer := 0;
		variable a : integer;

		procedure tick is
		begin
			wait until rising_edge(clk);
			wait for 1 ns;
		end procedure;

		procedure check(name : string; got, want : std_logic_vector(31 downto 0)) is
		begin
			if is_x(got) or got /= want then
				report name & ": got " & to_hstring(got) & " want " & to_hstring(want) severity error;
				fails := fails + 1;
			end if;
		end procedure;
	begin
		-- Read the initial words (port A and port B, must be clean).
		for p in 0 to 15 loop
			a := 100 + p;
			addr <= std_logic_vector(to_unsigned(a, AW-1));
			addr2 <= std_logic_vector(to_unsigned(a, AW-1));
			tick; tick;
			check("init A " & integer'image(p), q, q2);
			old(p) := q;
			if is_x(q) then fails := fails + 1; end if;
		end loop;

		-- Port A writes, every bytesel pattern at its own word.
		for p in 0 to 15 loop
			a := 100 + p;
			wr := x"A1B2C3D4";
			expv := old(p);
			for i in 0 to 3 loop
				-- bytesel(i) selects bits (31-8*i) downto (24-8*i)
				if (p / (2 ** i)) mod 2 = 1 then
					expv(31 - 8*i downto 24 - 8*i) := wr(31 - 8*i downto 24 - 8*i);
				end if;
			end loop;
			addr <= std_logic_vector(to_unsigned(a, AW-1));
			d <= wr;
			bytesel <= std_logic_vector(to_unsigned(p, 4));
			we <= '1';
			tick;
			we <= '0';
			tick; tick;
			check("A write pattern " & integer'image(p), q, expv);
			addr2 <= std_logic_vector(to_unsigned(a, AW-1));
			tick; tick;
			check("A write seen on B " & integer'image(p), q2, expv);
			old(p) := expv;
		end loop;

		-- Port B writes over the same words, another value.
		for p in 0 to 15 loop
			a := 100 + p;
			wr := x"0F1E2D3C";
			expv := old(p);
			for i in 0 to 3 loop
				if (p / (2 ** i)) mod 2 = 1 then
					expv(31 - 8*i downto 24 - 8*i) := wr(31 - 8*i downto 24 - 8*i);
				end if;
			end loop;
			addr2 <= std_logic_vector(to_unsigned(a, AW-1));
			d2 <= wr;
			bytesel2 <= std_logic_vector(to_unsigned(p, 4));
			we2 <= '1';
			tick;
			we2 <= '0';
			tick; tick;
			check("B write pattern " & integer'image(p), q2, expv);
			addr <= std_logic_vector(to_unsigned(a, AW-1));
			tick; tick;
			check("B write seen on A " & integer'image(p), q, expv);
		end loop;

		-- A word far from the image (zero fill) is clean too, with we='0' held.
		addr <= std_logic_vector(to_unsigned(2000, AW-1));
		tick; tick;
		check("zero fill", q, x"00000000");

		if fails = 0 then
			report "ROM xsim test: PASS (16 bytesel patterns x 2 ports, no X)" severity note;
		else
			report "ROM xsim test: FAIL (" & integer'image(fails) & ")" severity failure;
		end if;
		done <= true;
		wait;
	end process;
end sim;
