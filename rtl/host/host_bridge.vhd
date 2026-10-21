-- Bridge between the OSD host CPU (rv_hostcpu.v, the VexRiscv RV32IMC) and
-- its memories: the boot BRAM, the SDRAM through hostcache, and the cfide
-- registers on the 16-bit host bus.  The CPU block presents the req/ack bus
-- (cpu_*): addr, q, sel and wr stable until ack, one transaction at a time.
--
-- hw accesses use a four-phase handshake: cfide's ack is a clk_28 register,
-- it stays high up to four clk_114 cycles after hw_req drops.  hw_release
-- waits for it to fall, so the next hw request never sees the old ack.

library ieee;
use ieee.std_logic_1164.all;
-- use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity host_bridge is
   generic (
      rv_debug : natural := 0;         -- 0 none, 1 BSCANE2 tunnel (Artix only), 2 pin TAP
      rv_extra_ws : natural := 0       -- bench only: idle cycles before every RV request
   );
   port(
      clk             : in std_logic;
      nReset            : in std_logic;         --low active
      addr              : out std_logic_vector(31 downto 2);
      q                 : out std_logic_vector(31 downto 0);
      sel               : out std_logic_vector(3 downto 0);
      wr                : out std_logic;

      ram_req           : out std_logic;
      ram_ack           : in std_logic;
      ram_d             : in std_logic_vector(15 downto 0);

      hw_req            : out std_logic;
      hw_ack            : in std_logic;
      hw_d              : in std_logic_vector(15 downto 0);
      interrupt         : in std_logic;

      -- RISC-V debug TAP (rv_debug = 2); rv_jtag_tdo = '0' otherwise
      rv_jtag_tck       : in std_logic := '0';
      rv_jtag_tms       : in std_logic := '0';
      rv_jtag_tdi       : in std_logic := '0';
      rv_jtag_tdo       : out std_logic
   );
end host_bridge;

architecture rtl of host_bridge is

   type bridgestates is (waiting,ram,hw,hw_release,rom);
   signal state : bridgestates;

   signal cpu_req : std_logic;
   signal cpu_ack : std_logic;
   signal cpu_d   : std_logic_vector(31 downto 0);
   signal cpu_q   : std_logic_vector(31 downto 0);
   signal cpu_addr   : std_logic_vector(31 downto 2);
   signal cpu_wr  : std_logic;
   signal cpu_sel : std_logic_vector(3 downto 0);

   signal cache_req : std_logic;
   signal cache_ack : std_logic;
   signal cache_q : std_logic_vector(31 downto 0);

   signal rom_d : std_logic_vector(31 downto 0);
   signal rom_wr : std_logic;
   signal rom_select : std_logic;
   signal hw_select : std_logic;

   -- attribute MARK_DEBUG : string;
   -- attribute MARK_DEBUG of cpu_addr : signal is "TRUE";
   -- attribute MARK_DEBUG of cpu_q : signal is "TRUE";
   -- attribute MARK_DEBUG of cpu_sel : signal is "TRUE";
   -- attribute MARK_DEBUG of cpu_req : signal is "TRUE";
   -- attribute MARK_DEBUG of rom_select : signal is "TRUE";
   -- attribute MARK_DEBUG of hw_select : signal is "TRUE";
   -- attribute MARK_DEBUG of hw_ack : signal is "TRUE";
   -- attribute MARK_DEBUG of ram_ack : signal is "TRUE";

   component hostcache
      port
      (
         sysclk : in std_logic;
         reset_n : in std_logic;
         a : in std_logic_vector(24 downto 2);
         q : out std_logic_vector(31 downto 0);
         req : in std_logic;
         wr : in std_logic;
         ack : out std_logic;
         sdram_d : in std_logic_vector(15 downto 0);
         sdram_req : out std_logic;
         sdram_ack : in std_logic
      );
   end component;

   component OSDBoot_rv_ROM
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
   end component;

   component rv_hostcpu
      generic (
         DEBUG : integer := 0;
         EXTRA_WS : integer := 0
      );
      port (
         clk : in std_logic;
         reset_n : in std_logic;
         addr : out std_logic_vector(31 downto 2);
         q : out std_logic_vector(31 downto 0);
         sel : out std_logic_vector(3 downto 0);
         wr : out std_logic;
         req : out std_logic;
         ack : in std_logic;
         d : in std_logic_vector(31 downto 0);
         irq_ext : in std_logic;
         irq_timer : in std_logic;
         irq_soft : in std_logic;
         jtag_tck : in std_logic;
         jtag_tms : in std_logic;
         jtag_tdi : in std_logic;
         jtag_tdo : out std_logic
      );
   end component;

begin

   myrv : component rv_hostcpu
      generic map (
         DEBUG => rv_debug,
         EXTRA_WS => rv_extra_ws
      )
      port map (
         clk => clk,
         reset_n => nReset,
         addr => cpu_addr,
         q => cpu_q,
         sel => cpu_sel,
         wr => cpu_wr,
         req => cpu_req,
         ack => cpu_ack,
         d => cpu_d,
         irq_ext => interrupt,
         irq_timer => '0',
         irq_soft => '0',
         jtag_tck => rv_jtag_tck,
         jtag_tms => rv_jtag_tms,
         jtag_tdi => rv_jtag_tdi,
         jtag_tdo => rv_jtag_tdo
      );

   bootrom: component OSDBoot_rv_ROM
      generic map
      (
         maxAddrBitBRAM => 12
      )
      PORT MAP
      (
         addr => cpu_addr(12 downto 2),
         clk   => clk,
         d  => cpu_q,
         we => rom_wr,
         bytesel => cpu_sel,
         q     => rom_d,
         q2    => open
      );


   rom_select <= '1' when cpu_addr(23 downto 13)=X"00"&"000" ELSE '0';

   hw_select <= cpu_addr(23);

   process(clk,nReset)
   begin

      if nReset='0' then
         state<=waiting;
         hw_req<='0';
         wr<='0';
      elsif rising_edge(clk) then

         cpu_ack<='0';
         rom_wr<='0';

         addr<=cpu_addr;
         q<=cpu_q;
         sel<=cpu_sel;
         wr<=cpu_wr;

         case state is
            when waiting =>
               if cpu_ack='0' and cpu_req='1' then
                  if rom_select='1' then
                     rom_wr<=cpu_wr;
                     state<=rom;
                  elsif hw_select='1' then
                     hw_req<='1';
                     state<=hw;
                  else
                     cache_req<='1';
                     state<=ram;
                  end if;
               end if;

            when rom =>
               cpu_d<=rom_d;
               wr<='0';
               rom_wr<='0';
               cpu_ack<='1';
               state<=waiting;

            when ram =>
               if cache_ack='1' then
                  cache_req<='0';
                  cpu_d<=cache_q;
                  wr<='0';
                  cpu_ack<='1';
                  state<=waiting;
               end if;

            when hw =>
               if hw_ack='1' then
                  cpu_d(31 downto 16)<=(others=>'0');
                  cpu_d(15 downto 0)<=hw_d;
                  wr<='0';
                  hw_req<='0';
                  cpu_ack<='1';
                  state <= hw_release; -- 4PHASE
               end if;

            when hw_release =>
               -- cfide's ack (clk_28) lags hw_req; a new hw request may only
               -- start once it has fallen.
               if hw_ack='0' then
                  state<=waiting;
               end if;

         end case;
      end if;
   end process;

   hostcache_inst : component hostcache
      port map
      (
         sysclk => clk,
         reset_n => nReset,
         a => cpu_addr(24 downto 2),
         q => cache_q,
         req => cache_req,
         wr => cpu_wr,
         ack => cache_ack,
         sdram_d => ram_d,
         sdram_req => ram_req,
         sdram_ack => ram_ack
      );

end architecture;
