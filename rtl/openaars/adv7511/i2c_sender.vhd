----------------------------------------------------------------------------------
-- Engineer: <mfield@concepts.co.nz
-- 
-- Description: Send register writes over an I2C-like interface
--
-- Changed to adv7511 init by emu.(AN-1720)
-- 
----------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;

entity i2c_sender is
Port
(
  clk       : in    STD_LOGIC;
  rst       : in    STD_LOGIC;
  resend    : in    STD_LOGIC;
  read_regs : in    STD_LOGIC;
  out_valid : out   STD_LOGIC;
  out_addr  : out   STD_LOGIC_VECTOR(7 downto 0);
  out_value : out   STD_LOGIC_VECTOR(7 downto 0);
  sioc      : inout STD_LOGIC;
  siod      : inout STD_LOGIC
);
end i2c_sender;

architecture behave of work.i2c_sender is
    -- this value gives nearly 200ms cycles before the first register is written
   signal   address           : std_logic_vector(7 downto 0)  := (others => '0');
   signal   reg_value         : std_logic_vector(23 downto 0)  := (others => '0');

   -- Command
   signal cmd_read : std_logic;
   signal cmd_ready : std_logic;
   signal cmd_start : std_logic;
   signal cmd_stop : std_logic;
   signal cmd_valid : std_logic;
   signal cmd_write : std_logic;
   signal cmd_write_multiple : std_logic;

   -- Write data
   signal data_in : std_logic_vector(7 downto 0) := (others => '0');
   signal data_in_valid : std_logic;
   signal data_in_ready : std_logic;
   signal data_in_last : std_logic := '0';

   -- Read data
   signal data_out : std_logic_vector(7 downto 0);
   signal data_out_valid : std_logic;
   signal data_out_ready : std_logic;
   signal data_out_last : std_logic;

   -- Status
   signal r_busy : std_logic;

   -- Tristate
   signal scl_i : std_logic;
   signal scl_o : std_logic;
   signal scl_t : std_logic;
   signal sda_i : std_logic;
   signal sda_o : std_logic;
   signal sda_t : std_logic;

   -- State machine states
   type State_type is (
      -- Write loop
      START,
      FIRST_BYTE,
      SECOND_BYTE,
      STOP,
      WAIT_RETRANS,
      -- Read loop
      START_RD,
      FIRST_BYTE_RD,
      START_2_RD,
      SECOND_BYTE_RD,
      STOP_RD
   );
   signal send_state: State_type := START;

   CONSTANT bit_0             : STD_LOGIC:= '0';

   constant i2c_wr_addr       : std_logic_vector(7 downto 0)  := x"72";

   -- prescale = Fclk / (FI2Cclk * 4)
   constant i2c_prescale : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(200, 16));

   type T_writereg is
   record
     addr, reg, val: std_logic_vector(7 downto 0);
   end record;
   type T_init_sequence is array(0 to 40) of T_writereg;
   constant C_init_sequence: T_init_sequence :=
   (
     ---------------------
     -- ADV7511 Video out
     ---------------------
     -- Power cycle
     (addr => x"72", reg => x"41", val => x"40"), --  7 Power Down
     (addr => x"72", reg => x"41", val => x"10"), --  7 Power Up
     --(addr => x"ff", reg => x"d6", val => x"c0"), --  Force HPD high (Power on)
     -- Setup mandatory registers
     (addr => x"72", reg => x"98", val => x"03"), -- ADI required Write
     (addr => x"72", reg => x"99", val => x"02"), -- ADI required Write
     (addr => x"72", reg => x"9a", val => x"e0"), -- ADI required Write
     (addr => x"72", reg => x"9c", val => x"30"), -- ADI required Write
     (addr => x"72", reg => x"9d", val => x"01"), -- ADI required Write
     (addr => x"72", reg => x"a2", val => x"a4"), -- ADI required Write
     (addr => x"72", reg => x"a3", val => x"a4"), -- ADI required Write
     (addr => x"72", reg => x"e0", val => x"d0"), -- ADI required Write
     (addr => x"72", reg => x"f9", val => x"00"), -- ADI required Write
     (addr => x"72", reg => x"d0", val => x"3e"), -- ADI required Write
     -- Setup video input mode
     (addr => x"72", reg => x"48", val => x"20"), -- DDR alignment [35:24]
     (addr => x"72", reg => x"15", val => x"05"), -- Input 444 (RGB or YCrCb) with Separate Syncs DDR
     (addr => x"72", reg => x"16", val => x"38"), -- 8 bit, style 1, falling edge
     (addr => x"72", reg => x"17", val => x"02"), -- 12 bit, style 1, falling edge
     (addr => x"72", reg => x"18", val => x"00"), -- CSC disabled
     (addr => x"72", reg => x"55", val => x"00"), -- 0 default
     (addr => x"72", reg => x"56", val => x"28"), -- 16:9, active same as aspect ratio
     -- (addr => x"ff", reg => x"48", val => x"28"), -- 11 0 default
     -- Set output mode
     (addr => x"72", reg => x"af", val => x"04"), -- Must be 04
     (addr => x"72", reg => x"40", val => x"80"), -- GC Package Enable
     (addr => x"72", reg => x"4c", val => x"04"), -- 0 default
     -- Tell the display the resolution
     (addr => x"72", reg => x"3c", val => x"04"), -- Nbr of times to search for good phase
     (addr => x"72", reg => x"d1", val => x"ff"), -- Nbr of times to search for good phase
     (addr => x"72", reg => x"de", val => x"9c"), -- ADI required write
     (addr => x"72", reg => x"e4", val => x"9c"), -- ADI required write
     (addr => x"72", reg => x"96", val => x"20"), -- Clear HPD interrupt
     (addr => x"72", reg => x"fa", val => x"00"), -- Nbr of times to search for good phase
     -- Set the video clock delay
     (addr => x"72", reg => x"ba", val => x"60"), -- Configure no clock delay
     ---------------------
     -- MAX9850+ Audio out
     ---------------------
     (addr => x"20", reg => x"02", val => x"59"), -- -29.5 dB (Pg 24 datasheet)
     (addr => x"20", reg => x"03", val => x"40"), -- GPIO high impedance, no zero detect
     (addr => x"20", reg => x"04", val => x"00"), -- disable interrupts
     (addr => x"20", reg => x"05", val => x"FD"), -- Power on, Mclk enable, charge pump enable, headphone out enable, DAC enable
     (addr => x"20", reg => x"06", val => x"00"), -- Transparent internal clock devider
     (addr => x"20", reg => x"07", val => x"40"), -- Use internal oscillator for charge pump
     --(addr => x"20", reg => x"08", val => x"45"), -- Non interger mode 45C5 +- 48Khz 
     --(addr => x"20", reg => x"09", val => x"c5"), -- 
     (addr => x"20", reg => x"08", val => x"00"), -- Non interger mode 45C5 +- 48Khz 
     (addr => x"20", reg => x"09", val => x"00"), -- 
     (addr => x"20", reg => x"0a", val => x"08"), -- Slave mode, 16 bits
     -- Fill the rest of the array with 'FF'
     others => (addr => x"ff", reg => x"ff", val => x"ff")  -- 25 FFFF end of sequence
   );
   
   -- ATTRIBUTE MARK_DEBUG : string;
   -- ATTRIBUTE MARK_DEBUG of send_state: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_read: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_ready: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_start: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_stop: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_valid: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_write: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of cmd_write_multiple: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_in: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_in_valid: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_in_ready: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_in_last: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_out: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_out_valid: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_out_ready: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of data_out_last: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of scl_i: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of scl_o: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of sda_i: SIGNAL IS "TRUE";
   -- ATTRIBUTE MARK_DEBUG of sda_o: SIGNAL IS "TRUE";

begin

   my_i2c_master: entity i2c_master port map (
       clk => clk,
       rst => rst,

        -- Host interface
       --cmd_address => std_logic_vector(i2c_wr_addr(7 downto 1)),
       cmd_address => reg_value(23 downto 17),
       cmd_start => cmd_start,
       cmd_read => cmd_read,
       cmd_write => cmd_write,
       cmd_write_multiple => cmd_write_multiple,
       cmd_stop => cmd_stop,
       cmd_valid => cmd_valid,
       cmd_ready => cmd_ready,

       data_in => data_in,
       data_in_valid => data_in_valid,
       data_in_ready => data_in_ready,
       data_in_last => data_in_last,

       data_out => data_out,
       data_out_valid => data_out_valid,
       data_out_ready => data_out_ready,
       data_out_last => data_out_last,

       -- I2C interface
       scl_i => scl_i,
       scl_o => scl_o,
       scl_t => scl_t,
       sda_i => sda_i,
       sda_o => sda_o,
       sda_t => sda_t,

        -- Status
       busy => r_busy,
       bus_control => open,
       bus_active => open,
       missed_ack => open,

       -- Configuration
       prescale => i2c_prescale,
       stop_on_idle => bit_0
   );

   -- I2C output
   scl_i <= sioc;
   sioc <= scl_o when (scl_t = '0') else 'Z';
   sda_i <= siod;
   siod <= sda_o when (sda_t = '0') else 'Z';

   registers: process(clk)
   begin
      if rising_edge(clk) then
        reg_value <= C_init_sequence(to_integer(unsigned(address))).addr
                   & C_init_sequence(to_integer(unsigned(address))).reg
                   & C_init_sequence(to_integer(unsigned(address))).val;
      end if;
   end process;


   -- Transmit registers state machine
   statemachine: process(clk)
   begin
      if rising_edge(Clk) then
         if (rst = '1') then
            send_state <= START;
         else 
            case send_state is
               -- WRITE SEQUENCE
               -- Send start and address
               when START =>

                  -- ffff is end of initialization sequence
                  if(reg_value = X"ffffff") then
                     send_state <= WAIT_RETRANS;
                  else
                     cmd_valid <= '1';
                     -- cmd_write <= '1';
                     cmd_write_multiple <= '1';
                     data_in_last <= '0';
                     data_in_valid <= '1';
                     data_in <= reg_value(15 downto 8);
                     if (data_in_ready = '1' ) then
                        send_state <= FIRST_BYTE;
                     end if;
                  end if;
               -- Send first data byte (register)
               when FIRST_BYTE =>
                  data_in <= reg_value(7 downto 0);
                  data_in_valid <= '1';
                  cmd_valid <= '1';
                  data_in_last <= '1';
                  cmd_stop <= '1';
                  if (data_in_ready = '1') then
                     cmd_valid <= '0';
                     send_state <= SECOND_BYTE;
                  end if;

               -- Send second data byte (content)
               when SECOND_BYTE =>
                  cmd_valid <= '1';
                  data_in_valid <= '1';
                  cmd_write_multiple <= '0';
                  cmd_stop <= '1';
                  if (cmd_ready = '1') then
                     cmd_valid <= '0';
                     send_state <= STOP;
                  end if;

               -- Send stop
               when STOP =>
                  data_in_valid <= '0';
                  data_in_last <= '0';
                  cmd_stop <= '0';
                  address <= std_logic_vector(unsigned(address) + 1);
                  send_state <= START;   

               -- wait for retransfer signal
               when WAIT_RETRANS =>
                  cmd_valid <= '0';
                  cmd_write <= '0';
                  cmd_write_multiple <= '0';
                  cmd_stop  <= '0';
                  address <= (others => '0');
                  if (resend = '1') then
                     send_state <= START;
                  end if;
                  if (read_regs = '1') then
                     send_state <= START_RD;
                  end if;

               -- READ SEQUENCE

               -- Send START and write register address
               when START_RD =>
               -- ffff is end of initialization sequence
                  if(address = X"ff") then
                     send_state <= WAIT_RETRANS;
                  else
                     cmd_valid <= '1';
                     cmd_write <= '1';
                     data_in_valid <= '1';
                     data_in <= address;
                     if (data_in_ready = '1' ) then
                        cmd_valid <= '0';
                        send_state <= FIRST_BYTE_RD;
                     end if;
                  end if;
               -- Send start and write register address again
               when FIRST_BYTE_RD =>
                  data_in_valid <= '1';
                  cmd_start <= '1';
                  cmd_write <= '1';
                  data_in <= address;
                  cmd_valid <= '1';
                  if (data_in_ready = '1') then
                     cmd_valid <= '0';
                     send_state <= START_2_RD;
                  end if;
               -- Read byte 
               when START_2_RD =>
                  cmd_valid <= '1';
                  cmd_read <= '1';
                  data_out_ready <= '1';
                  cmd_start <= '0';
                  cmd_write <= '0';
                  if (data_out_valid = '1') then
                     data_out_ready <= '0';
                     cmd_valid <= '0';
                     send_state <= SECOND_BYTE_RD;
                     -- Valid output
                     out_valid <= '1';
                     out_addr <= address;
                     out_value <= data_out;
                  end if;
               -- Send Stop
               when SECOND_BYTE_RD =>
                  cmd_valid <= '1';
                  cmd_stop <= '1';
                  cmd_read <= '0';
                  cmd_write <= '0';
                  cmd_start <= '0';
                  data_in <= (others => '0');
                  data_in_valid <= '0';
                  if (cmd_ready = '1') then
                     cmd_valid <= '0';
                     send_state <= STOP_RD;
                  end if;
               -- Return to begin of loop
               when STOP_RD =>
                  cmd_read <= '0';
                  cmd_stop <= '0';
                  data_out_ready <= '0';
                  address <= std_logic_vector(unsigned(address) + 1);
                  send_state <= START_RD;
               when others =>
                  send_state <= WAIT_RETRANS;
            end case;
         end if;
      end if;
   end process;

end behave;
