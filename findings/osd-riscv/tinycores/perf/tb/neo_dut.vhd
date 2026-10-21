library ieee; use ieee.std_logic_1164.all;
library neorv32; use neorv32.neorv32_package.all;
entity neo_dut is generic (C : integer := 1; IC : integer := 0; ICB : integer := 16; BS : integer := 64);
port (clk, rstn : in std_ulogic; adr, dat_o : out std_ulogic_vector(31 downto 0); we, stb, cyc : out std_ulogic;
      sel : out std_ulogic_vector(3 downto 0); dat_i : in std_ulogic_vector(31 downto 0); ack : in std_ulogic);
end entity;
architecture rtl of neo_dut is begin
  u : entity neorv32.neorv32_top
    generic map (CLOCK_FREQUENCY => 113_440_000, BOOT_MODE_SELECT => 1, BOOT_ADDR_CUSTOM => x"00000000",
      RISCV_ISA_C => (C = 1), RISCV_ISA_M => true, CPU_FAST_MUL_EN => true, ICACHE_EN => (IC = 1), ICACHE_NUM_BLOCKS => ICB, CACHE_BLOCK_SIZE => BS, CACHE_BURSTS_EN => false, XBUS_EN => true, XBUS_TIMEOUT => 0)
    port map (clk_i => clk, rstn_i => rstn, xbus_adr_o => adr, xbus_dat_o => dat_o, xbus_we_o => we, xbus_sel_o => sel,
      xbus_stb_o => stb, xbus_cyc_o => cyc, xbus_dat_i => dat_i, xbus_ack_i => ack, xbus_err_i => '0');
end architecture;
