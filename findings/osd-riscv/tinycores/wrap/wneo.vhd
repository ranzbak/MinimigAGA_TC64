-- Registered-I/O OOC wrapper for NEORV32 (neorv32_top, minimal: XBUS only, no IMEM/DMEM/peripherals)
library ieee; use ieee.std_logic_1164.all;
library neorv32; use neorv32.neorv32_package.all;
entity wtop is generic (C : boolean := true; OCD : boolean := false; FASTSHIFT : boolean := false; IC : boolean := false; ICB : natural := 16; BS : natural := 64);
port(
  clk : in std_ulogic; rstn : in std_ulogic; tck, tdi, tms : in std_ulogic; tdo : out std_ulogic;
  mei_i, mti_i : in std_ulogic; dat_i : in std_ulogic_vector(31 downto 0); ack_i, err_i : in std_ulogic;
  adr : out std_ulogic_vector(31 downto 0); dat : out std_ulogic_vector(31 downto 0);
  we, stb, cyc : out std_ulogic; sel : out std_ulogic_vector(3 downto 0));
end entity;
architecture rtl of wtop is
  signal rn, mei, mti, ack, err : std_ulogic; signal di : std_ulogic_vector(31 downto 0);
  signal a_w, d_w : std_ulogic_vector(31 downto 0); signal we_w, stb_w, cyc_w : std_ulogic; signal sel_w : std_ulogic_vector(3 downto 0);
begin
  process(clk) begin if rising_edge(clk) then
    rn <= rstn; mei <= mei_i; mti <= mti_i; di <= dat_i; ack <= ack_i; err <= err_i;
    adr <= a_w; dat <= d_w; we <= we_w; stb <= stb_w; cyc <= cyc_w; sel <= sel_w;
  end if; end process;
  u_core : entity neorv32.neorv32_top
    generic map (CLOCK_FREQUENCY => 113_440_000, BOOT_MODE_SELECT => 1, BOOT_ADDR_CUSTOM => x"00000000",
      OCD_EN => OCD, RISCV_ISA_C => C, RISCV_ISA_M => true, RISCV_ISA_Zicntr => false,
      CPU_FAST_MUL_EN => true, CPU_FAST_SHIFT_EN => FASTSHIFT,
      ICACHE_EN => IC, ICACHE_NUM_BLOCKS => ICB, CACHE_BLOCK_SIZE => BS, CACHE_BURSTS_EN => false,
      XBUS_EN => true, XBUS_TIMEOUT => 0, XBUS_REGSTAGE_EN => false)
    port map (clk_i => clk, rstn_i => rn, jtag_tck_i => tck, jtag_tdi_i => tdi, jtag_tdo_o => tdo, jtag_tms_i => tms,
      xbus_adr_o => a_w, xbus_dat_o => d_w, xbus_cti_o => open, xbus_tag_o => open, xbus_we_o => we_w,
      xbus_sel_o => sel_w, xbus_stb_o => stb_w, xbus_cyc_o => cyc_w, xbus_dat_i => di, xbus_ack_i => ack, xbus_err_i => err,
      irq_mei_i => mei, irq_mti_i => mti, irq_msi_i => '0');
end architecture;
