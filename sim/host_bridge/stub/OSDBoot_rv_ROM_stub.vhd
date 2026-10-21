-- Stub OSDBoot_rv_ROM for elaboration checks (Task 7 builds the real ROMs).
-- Same generics and ports as fw/ctrl_boot/OSDBoot_rv_ROM.vhd.  Two words, big-endian lanes
-- (byte A+0 in bits 31:24, rv_hostcpu swaps them for the core):
--   0x00: j 0    (jal x0,0   = 0x0000006f)
--   0x04: j 0    (jal x0,-4  = 0xffdff06f)
-- Everything else reads 0; writes are ignored.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity OSDBoot_rv_ROM is
generic (
	maxAddrBitBRAM : integer := 15;
	COL_WIDTH : integer := 8;
	NB_COL : integer := 4
);
port (
	clk : in std_logic;
	reset_n : in std_logic := '1';
	addr : in std_logic_vector(maxAddrBitBRAM-2 downto 0);
	q : out std_logic_vector(31 downto 0);
	d : in std_logic_vector(31 downto 0) := X"00000000";
	we : in std_logic := '0';
	bytesel : in std_logic_vector(3 downto 0) := "1111";
	addr2 : in std_logic_vector(maxAddrBitBRAM-2 downto 0) := (others=>'0');
	q2 : out std_logic_vector(31 downto 0);
	d2 : in std_logic_vector(31 downto 0) := X"00000000";
	we2 : in std_logic := '0';
	bytesel2 : in std_logic_vector(3 downto 0) := "1111"
);
end OSDBoot_rv_ROM;

architecture stub of OSDBoot_rv_ROM is
	function word(a : std_logic_vector) return std_logic_vector is
	begin
		case to_integer(unsigned(a)) is
			when 0 => return X"6f000000";
			when 1 => return X"6ff0dfff";
			when others => return X"00000000";
		end case;
	end function;
begin
	process(clk)
	begin
		if rising_edge(clk) then
			q <= word(addr);
			q2 <= word(addr2);
		end if;
	end process;
end architecture;
