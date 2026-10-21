-- Registered-I/O OOC wrapper for the EightThirtyTwo CPU, config as in rtl/host/832_bridge.vhd
library ieee; use ieee.std_logic_1164.all;
entity wtop is port(
  clk : in std_logic; reset_n : in std_logic; interrupt : in std_logic;
  d : in std_logic_vector(31 downto 0); ack : in std_logic;
  addr : out std_logic_vector(31 downto 2); q : out std_logic_vector(31 downto 0);
  wr : out std_logic; req : out std_logic; bytesel : out std_logic_vector(3 downto 0));
end entity;
architecture rtl of wtop is
  signal rn, irq, ack_r : std_logic; signal d_r : std_logic_vector(31 downto 0);
  signal a_w : std_logic_vector(31 downto 2); signal q_w : std_logic_vector(31 downto 0);
  signal wr_w, req_w : std_logic; signal bs_w : std_logic_vector(3 downto 0);
begin
  process(clk) begin if rising_edge(clk) then
    rn <= reset_n; irq <= interrupt; d_r <= d; ack_r <= ack;
    addr <= a_w; q <= q_w; wr <= wr_w; req <= req_w; bytesel <= bs_w;
  end if; end process;
  u_core : entity work.eightthirtytwo_cpu
    generic map (littleendian => false, interrupts => true, dualthread => false,
                 forwarding => false, prefetch => false, debug => false)
    port map (clk => clk, reset_n => rn, interrupt => irq, addr => a_w, d => d_r, q => q_w,
              wr => wr_w, req => req_w, ack => ack_r, bytesel => bs_w,
              debug_d => (others => '0'), debug_q => open, debug_req => open, debug_wr => open, debug_ack => '0');
end architecture;
