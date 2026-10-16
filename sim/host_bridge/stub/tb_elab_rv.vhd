-- Elaboration check: EightThirtyTwo_Bridge with cpu_riscv => true, built
-- without any EightThirtyTwo source (elab.sh).  RV_DEBUG via -generic_top.
library ieee;
use ieee.std_logic_1164.all;
entity tb_elab_rv is
	generic (RV_DEBUG : natural := 0);
end entity;
architecture tb of tb_elab_rv is
	signal clk, nreset, ram_req, ram_ack, hw_req, hw_ack, wr, tdo : std_logic := '0';
	signal ram_d, hw_d : std_logic_vector(15 downto 0) := (others => '0');
begin
	clk <= not clk after 4.4077 ns;
	nreset <= '1' after 100 ns;
	dut : entity work.EightThirtyTwo_Bridge
		generic map (cpu_riscv => true, rv_debug => RV_DEBUG)
		port map (clk => clk, nReset => nreset, addr => open, q => open, sel => open, wr => wr,
			ram_req => ram_req, ram_ack => ram_ack, ram_d => ram_d,
			hw_req => hw_req, hw_ack => hw_ack, hw_d => hw_d, interrupt => '0', rv_jtag_tdo => tdo);
end architecture;
