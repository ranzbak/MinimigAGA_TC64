-- 832_bridge.vhd instantiates debug_bridge_jtag only when debug=true; the
-- analyser still wants the entity.  A stub with its ports.
library ieee;
use ieee.std_logic_1164.all;
entity debug_bridge_jtag is
port (
    clk : in std_logic;
    reset_n : in std_logic;
    d : in std_logic_vector(31 downto 0);
    q : out std_logic_vector(31 downto 0);
    req : in std_logic;
    wr : in std_logic;
    ack : buffer std_logic
);
end entity;
architecture stub of debug_bridge_jtag is
begin
    q <= (others => '0'); ack <= '0';
end architecture;
