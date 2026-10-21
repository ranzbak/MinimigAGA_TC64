------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2008-2011 Tobias Gubener                                   --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU General Public License as published        --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
-- Modifications by Alastair M. Robinson to work with a cheap
-- Ebay Cyclone III board.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.STD_LOGIC_UNSIGNED.all;        -- @suppress "Deprecated package"
use ieee.numeric_std.all;

entity cfide is
    generic(
        spimux     : in boolean;
        havespirtc : in boolean;
        havei2c    : in boolean;
        havevpos   : in boolean
    );
    port(
        sysclk        : in  std_logic;
        n_reset       : in  std_logic;
        addr          : in  std_logic_vector(31 downto 2);
        d             : in  std_logic_vector(15 downto 0);
        q             : out std_logic_vector(15 downto 0);
        req           : in  std_logic;
        wr            : in  std_logic;
        ack           : out std_logic;
        sd_di         : in  std_logic;
        sd_cs         : out std_logic_vector(7 downto 0);
        sd_clk        : out std_logic;
        sd_do         : out std_logic;
        sd_dimm       : in  std_logic;  --for sdcard
        sd_ack        : in  std_logic;  -- indicates that SPI signal has made it to the wire
        debugTxD      : out std_logic;
        debugRxD      : in  std_logic;
        menu_button   : in  std_logic                     := '1';
        -- FPGA die temperature, the XADC's raw 12-bit reading (rtl/soc/fpga_temp.v).
        -- Defaulted, so a build without the XADC needs no change here; such a
        -- build also leaves CORE_CAPS_TEMP clear, and the firmware then does
        -- not read this at all.
        xadc_temp     : in  std_logic_vector(15 downto 0) := (others => '0');
        scandoubler   : out std_logic;
        audio_ena     : out std_logic;
        audio_clear   : out std_logic;
        audio_buf     : in  std_logic;
        audio_amiga   : in  std_logic;
        vbl_int       : in  std_logic;
        interrupt     : out std_logic;
        -- Interrupt controller sources 4..15 (0x3x window, see below); bits 0..3
        -- are vbl_int, the I2C transfer event, amiga_req and i2c_ext_int.
        -- Defaulted: a top that has no such source leaves the port open.
        irq_src       : in  std_logic_vector(15 downto 4) := (others => '0');
        c64_keys      : in  std_logic_vector(63 downto 0) := X"FFFFFFFFFFFFFFFF";
        amiga_key     : out std_logic_vector(7 downto 0);
        amiga_key_stb : out std_logic;
        amiga_addr    : in  std_logic_vector(7 downto 0);
        amiga_d       : in  std_logic_vector(15 downto 0);
        amiga_q       : out std_logic_vector(15 downto 0);
        amiga_req     : in  std_logic;
        amiga_wr      : in  std_logic;
        amiga_ack     : out std_logic;
        rtc_q         : out std_logic_vector(63 downto 0);
        -- I2C interface
        scl_i         : in  std_logic;
        scl_o         : out std_logic;
        scl_t         : out std_logic;
        sda_i         : in  std_logic;
        sda_o         : out std_logic;
        sda_t         : out std_logic;
        i2c_ext_int   : in  std_logic := '0';  -- the ADV7511's INT (status 0x400)
        -- Video scaler coordinates
        pos_data_q    : out std_logic_vector(15 downto 0);
        -- userio_osd's reply sequence (rtl/minimig/userio_osd.v osd_rx_seq):
        -- +1 per OSD byte it has taken; clk_28 domain.  For HOST_REQ (0x0fffffb4),
        -- see the OSD reply-ready handshake below.  Defaulted: a top without
        -- the port reads OSD_RDY 0 after the first OSD byte (until the resync).
        osd_rx_seq    : in  std_logic_vector(1 downto 0) := "00";
        -- 28Mhz signals
        clk_28        : in  std_logic;
        tick_in       : in  std_logic   -- 44.1KHz - makes it easy to keep timer in lockstep with audio.
    );

end cfide;

architecture rtl of cfide is

    signal shift           : std_logic_vector(9 downto 0);
    -- clkgen and timecnt have no reset: the explicit 0 is the FPGA power-up value
    -- (Xilinx and Intel honour VHDL signal initial values) and lets simulation count
    signal clkgen          : std_logic_vector(9 downto 0) := (others => '0');
    signal shiftout        : std_logic;
    signal txbusy          : std_logic;
    signal uart_ld         : std_logic;
    --signal IO_select : std_logic;
    signal platform_select : std_logic;
    signal timer_select    : std_logic;
    signal SPI_select      : std_logic;
    signal platformdata    : std_logic_vector(15 downto 0); -- X"000" & "0" & spirtcpresent & "1" & menu_button
    signal IOdata          : std_logic_vector(15 downto 0);
    signal I2Cdata         : std_logic_vector(15 downto 0);
    signal IOcpuena        : std_logic;

    type support_states is (idle, io_aktion);
    signal support_state : support_states;
    --signal next_support_state     : support_states;

    signal sd_out      : std_logic_vector(15 downto 0);
    signal sd_in       : std_logic_vector(15 downto 0);
    signal sd_in_shift : std_logic_vector(15 downto 0);
    signal sd_di_in    : std_logic;
    signal shiftcnt    : std_logic_vector(13 downto 0);
    signal sck         : std_logic;
    -- The SPI clock as it leaves cfide: the same value as sck, in a register of
    -- its own.  sck is read by the shift logic below as DATA; the pin is the
    -- clock of every SPI slave in the Minimig (paula_floppy, userio_osd_spi).
    -- With one register doing both, a clock defined on that register's output
    -- (fpga/openaars/.../sd_card.xdc) also became the launch clock of this
    -- process's own sck -> sck/shiftcnt/sd_out/sd_in_shift paths, and those
    -- single-cycle sysclk paths went untimed with the SPI clock's crossings.
    -- Keep the two apart; the attributes stop synthesis from merging them
    -- back (dont_touch for Vivado, preserve for Quartus; each ignores the other).
    signal sck_pin     : std_logic;
    attribute dont_touch : string;
    attribute dont_touch of sck_pin : signal is "true";
    attribute preserve : boolean;
    attribute preserve of sck_pin : signal is true;
    signal scs         : std_logic_vector(7 downto 0);
    --signal dscs       : std_logic;
    signal SD_busy     : std_logic;
    signal spi_div     : std_logic_vector(8 downto 0);
    signal spi_speed   : std_logic_vector(7 downto 0);
    signal spi_wait    : std_logic;
    signal spi_wait_d  : std_logic;

    signal timecnt : std_logic_vector(23 downto 0) := (others => '0'); -- no reset, see clkgen

    signal rs232_select : std_logic;
    --signal rs232data : std_logic_vector(15 downto 0);

    signal audio_q      : std_logic_vector(15 downto 0);
    signal audio_select : std_logic;

    signal interrupt_select : std_logic;
    signal interrupt_ena    : std_logic;
    signal keyboard_select  : std_logic;
    signal keyboard_q       : std_logic_vector(15 downto 0);
    signal amigatohost      : std_logic_vector(15 downto 0);
    signal amiga_select     : std_logic;
    signal amiga_req_d      : std_logic;

    signal rtc_select      : std_logic;
    signal i2c_select      : std_logic;
    signal videoscl_select : std_logic;
    signal i2c_int         : std_logic;
    signal xadc_select     : std_logic;
    signal irqctl_select   : std_logic;
    signal spirtcpresent   : std_logic;

    signal reset : std_logic;

    -- OSD reply-ready handshake (HOST_REQ, 0x0fffffb4), see below
    signal osd_tx_seq  : std_logic_vector(1 downto 0) := "00";  -- no reset
    signal osd_idle    : std_logic_vector(6 downto 0) := (others => '0');
    signal osd_rdy     : std_logic;
    signal host_req_q  : std_logic;
    signal spi_dat_go  : std_logic;

    -- Interrupt controller (0x3x window)
    signal int_legacy  : std_logic;                      -- the 0xa0 flag
    signal int_legacy_nx : std_logic;                    -- ... its next state
    signal irq_in      : std_logic_vector(15 downto 0);  -- the sources
    signal irq_sync1   : std_logic_vector(15 downto 0);
    signal irq_sync2   : std_logic_vector(15 downto 0);  -- synchronised = IRQ_RAW
    signal irq_prev    : std_logic_vector(15 downto 0);  -- irq_sync2 one cycle ago
    signal irq_edge    : std_logic_vector(15 downto 0);
    signal irq_pend    : std_logic_vector(15 downto 0);  -- EDGE-mode event latch
    signal irq_eff     : std_logic_vector(15 downto 0);  -- PENDING as the CPU sees it
    signal irq_ret     : std_logic_vector(15 downto 0);  -- PENDING and MASK
    signal irq_clr     : std_logic_vector(15 downto 0);
    signal irq_mask    : std_logic_vector(15 downto 0);
    signal irq_mode    : std_logic_vector(15 downto 0);  -- 1 = LEVEL, 0 = EDGE
    signal irq_q       : std_logic_vector(15 downto 0);
    signal irq_seen    : std_logic;                      -- req one clk_28 cycle ago
    signal irq_acc     : std_logic;                      -- first cycle of a 0x3x access
    signal irq_rd      : std_logic;                      -- ... and it reads IRQ_PENDING
    -- next-state values of the registers (loaded at the next clk_28 edge)
    signal irq_pend_nx : std_logic_vector(15 downto 0);
    signal irq_mask_nx : std_logic_vector(15 downto 0);
    signal irq_mode_nx : std_logic_vector(15 downto 0);
    signal irq_eff_nx  : std_logic_vector(15 downto 0);  -- irq_eff after that edge
    signal int_nx      : std_logic;
    signal int_out     : std_logic;                      -- the interrupt output register

    -- PENDING as the CPU sees it: per bit the level (MODE 1, LEVEL) or the
    -- EDGE latch (MODE 0).  One function for the current and the next state.
    function irq_mux(lvl, pend, mode : std_logic_vector) return std_logic_vector is
    begin
        return (lvl and mode) or (pend and not mode); -- IRQ MODE MUX
    end function;

-- attribute MARK_DEBUG : string;
-- attribute MARK_DEBUG of pos_data_q : signal is "TRUE";
-- attribute MARK_DEBUG of d : signal is "TRUE";
-- attribute MARK_DEBUG of req : signal is "TRUE";
-- attribute MARK_DEBUG of videoscl_select : signal is "TRUE";
-- attribute MARK_DEBUG of wr : signal is "TRUE";
-- attribute MARK_DEBUG of addr : signal is "TRUE";

begin

    reset <= not n_reset;

    -- Peripheral registers are only 16-bits wide.

    q(15 downto 0) <= IOdata when rs232_select = '1' or SPI_select = '1' else
    I2Cdata when i2c_select = '1' else
    timecnt(23 downto 8) when timer_select = '1' else
    X"000" & "000" & host_req_q when audio_select = '1' and addr(3 downto 2) = "01" else
    audio_q when audio_select = '1' else
    keyboard_q when keyboard_select = '1' else
    amigatohost when amiga_select = '1' else
    irq_q when irqctl_select = '1' else
    xadc_temp when xadc_select = '1' else
    platformdata;

    spirtcpresent <= '1' when havespirtc = true else '0';

    platformdata <= X"000" & "0" & spirtcpresent & "1" & menu_button; -- Reconfig not currently supported, 32 meg of RAM, menu button.
    IOdata       <= sd_in;

    process(clk_28)
    begin
        if rising_edge(clk_28) then
            ack <= '0';
            if req = '1' then
                if rs232_select = '1' or SPI_select = '1' then
                    ack <= IOcpuena;
                else
                    --          if timer_select='1' or platform_select='1' or audio_select='1' then
                    ack <= '1';
                end if;
            end if;
        end if;
    end process;

    sd_in(15 downto 8) <= (others => '0');
    sd_in(7 downto 0)  <= sd_in_shift(7 downto 0);

    audio_q <= X"000" & "00" & audio_amiga & audio_buf;

    SPI_select       <= '1' when addr(23) = '1' and addr(7 downto 4) = X"E" ELSE '0';
    rs232_select     <= '1' when addr(23) = '1' and addr(7 downto 4) = X"F" ELSE '0';
    timer_select     <= '1' when addr(23) = '1' and addr(7 downto 4) = X"D" ELSE '0';
    platform_select  <= '1' when addr(23) = '1' and addr(7 downto 4) = X"C" ELSE '0';
    audio_select     <= '1' when addr(23) = '1' and addr(7 downto 4) = X"B" else '0';
    interrupt_select <= '1' when addr(23) = '1' and addr(7 downto 4) = X"A" else '0';
    keyboard_select  <= '1' when addr(23) = '1' and addr(7 downto 4) = X"9" else '0';
    amiga_select     <= '1' when addr(23) = '1' and addr(7 downto 4) = X"8" else '0';
    rtc_select       <= '1' when addr(23) = '1' and addr(7 downto 4) = X"7" else '0';
    i2c_select       <= '1' when addr(23) = '1' and addr(7 downto 4) = X"6" else '0';
    videoscl_select  <= '1' when addr(23) = '1' and addr(7 downto 4) = X"5" else '0';
    -- FPGA die temperature at 0fffff40.
    xadc_select      <= '1' when addr(23) = '1' and addr(7 downto 4) = X"4" else '0';
    -- Interrupt controller at 0fffff30
    irqctl_select    <= '1' when addr(23) = '1' and addr(7 downto 4) = X"3" else '0';

    -- RTC handling at 0fffff70

    process(clk_28, n_reset)
    begin
        if n_reset = '0' then
            rtc_q <= (others => '0');
        elsif rising_edge(clk_28) then
            if rtc_select = '1' and req = '1' and wr = '1' then
                case addr(3 downto 2) is
                    when "00" =>
                        rtc_q(63 downto 48) <= d;
                    when "01" =>
                        rtc_q(47 downto 32) <= d;
                    when "10" =>
                        rtc_q(31 downto 16) <= d;
                    when "11" =>
                        rtc_q(15 downto 0) <= d;
                    when others =>
                        rtc_q <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    -- Amiga interface at 0fffff80

    process(clk_28)
    begin
        if rising_edge(clk_28) then

            amiga_ack <= '0';

            if amiga_select = '1' and req = '1' then

                if wr = '1' then
                    amiga_q   <= d(15 downto 0);
                    amiga_ack <= '1';
                end if;

                if addr(2) = '1' then
                    amigatohost <= amiga_d;
                else
                    amigatohost <= amiga_req & amiga_wr & "000000" & amiga_addr;
                end if;

            end if;
        end if;
    end process;

    -- C64 Keyboard handling at 0fffff90

    process(clk_28)
    begin
        if rising_edge(clk_28) then
            amiga_key_stb <= '0';
            if keyboard_select = '1' and req = '1' then
                if wr = '1' then
                    amiga_key     <= d(7 downto 0);
                    amiga_key_stb <= '1';
                end if;
                case addr(3 downto 2) is
                    when "00" =>
                        keyboard_q <= c64_keys(63 downto 48);
                    when "01" =>
                        keyboard_q <= c64_keys(47 downto 32);
                    when "10" =>
                        keyboard_q <= c64_keys(31 downto 16);
                    when "11" =>
                        keyboard_q <= c64_keys(15 downto 0);
                    when others =>
                        keyboard_q <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    -- Interrupt handling at 0fffffa0 (legacy)
    -- Any access to this range will clear the interrupt flag; a source event
    -- sets it to interrupt_ena.  The access wins over an event in its cycle.
    -- int_legacy_nx is the flag's next state, also used for the interrupt
    -- output register (see the controller below).

    int_legacy_nx <= '0' when interrupt_select = '1' and req = '1' else
                     interrupt_ena when vbl_int = '1' or i2c_int = '1' or (amiga_req = '1' and amiga_req_d = '0') else
                     int_legacy;

    process(clk_28, n_reset)
    begin
        if n_reset = '0' then
            int_legacy    <= '0';
            interrupt_ena <= '0';
        elsif rising_edge(clk_28) then
            amiga_req_d <= amiga_req;
            int_legacy  <= int_legacy_nx;
            if interrupt_select = '1' and req = '1' then
                if wr = '1' then
                    interrupt_ena <= d(0);
                end if;
            end if;
        end if;
    end process;

    -- Interrupt controller at 0fffff30, 16-bit registers, addr(3 downto 2):
    --   00 IRQ_PENDING  R: PENDING and MASK; clears exactly the EDGE-mode bits
    --                      it returns, once per access.  W: no effect.
    --   01 IRQ_MASK     R/W, reset 0
    --   10 IRQ_RAW      R: the synchronised source levels, no side effect.
    --                   W: no effect.
    --   11 IRQ_MODE     R/W, reset 0; per bit 0 = EDGE, 1 = LEVEL
    -- Sources:
    --   0  vbl_int      vertical blank (pulse)
    --   1  i2c_int      the I2C master's transfer event (i2c_master_mmio
    --                   r_interrupt): set by its transfer events, cleared only
    --                   by a read of the legacy 0fffffa0 window
    --                   (i2c_master_mmio.sv: interrupt_select and not wr)
    --   2  amiga_req    Akiko request (pulse per request)
    --   3  i2c_ext_int  the ADV7511's INT pin (I2C status bit 0x400 shows it
    --                   too).  Active high as the part is set up: no polarity
    --                   register is written (fw/ctrl/adv7511.c), clearing
    --                   its interrupt flags takes the pin low (ADV7511
    --                   Programming Guide, CEC and interrupt sections), and
    --                   i2c_master_mmio and the firmware use it active
    --                   high.  So no inversion here.  Meant for LEVEL mode.
    --   4..15 irq_src   spare (IDE, floppy, ...)
    -- Every bit is the same logic: a 2-FF synchroniser into clk_28, then
    --   EDGE  (MODE bit 0): a rising edge of the synchronised level sets the
    --         bit; an IRQ_PENDING read that returns it clears it.  An edge in
    --         the cycle of that clear wins: the bit stays set.  An event of a
    --         masked bit stays pending until it is unmasked and read.
    --   LEVEL (MODE bit 1): the bit is the synchronised level itself; a read
    --         returns it and does not clear it, it drops with the source.
    -- Switching the mode: the EDGE latch is held clear while the bit is in
    -- LEVEL mode.  So EDGE -> LEVEL discards an unread event (the bit then
    -- follows the line), and LEVEL -> EDGE starts the bit clear: it needs a new
    -- rising edge, i.e. the line must drop and rise again.  An edge set in the
    -- clk_28 cycle of the MODE write that switches to EDGE is discarded too.
    -- interrupt = the legacy flag OR (PENDING and MASK) /= 0, in every clk_28
    -- cycle.  It is a register of its own (int_out), loaded from the
    -- next-state values of the flag, PENDING, MASK and MODE: the same value
    -- in the same cycle as that OR of the registers, with no logic between
    -- the register and the CPU.  MASK
    -- and MODE reset to 0, so firmware that never writes MASK
    -- sees the legacy flag cycle for cycle.
    -- Once per access: irq_seen = req one cycle ago, so irq_acc is the first
    -- clk_28 cycle of an access; the read value is latched into irq_q and the
    -- returned bits are cleared there and at no later cycle of the access.
    -- The guard is defensive: with the current bridge every hw access is seen
    -- by exactly one clk_28 edge (the bridge drops req in the clk_114 cycle
    -- after ack, and hw_release waits for ack to fall), so a multi-edge access
    -- never happens and the guard is untested.
    -- Firmware rule: put level sources (bit 3 ADV7511 INT, IDE requests; bit 1
    -- the I2C transfer flag, whose handler must read 0fffffa0 to clear it)
    -- in LEVEL mode: the interrupt stays asserted until the device is
    -- serviced, so no IRQ_RAW re-check is needed.  Pulse sources (vblank,
    -- Akiko) stay EDGE.  A LEVEL source the handler cannot service in
    -- interrupt context can be masked off until it is serviced.  The 2-FF
    -- synchroniser delays a LEVEL bit's fall by up to 3 clk_28 cycles after
    -- the device drops its line: a handler that returns at once may be
    -- called one extra time and must tolerate that.  A debugger reading
    -- IRQ_PENDING consumes pending EDGE bits.

    no_i2c : if not havei2c generate
        i2c_int <= '0';
    end generate;

    irq_in   <= irq_src & i2c_ext_int & amiga_req & i2c_int & vbl_int;
    irq_edge <= irq_sync2 and not irq_prev;
    irq_eff  <= irq_mux(irq_sync2, irq_pend, irq_mode);
    irq_ret  <= irq_eff and irq_mask;
    irq_acc  <= '1' when irqctl_select = '1' and req = '1' and irq_seen = '0' else '0';
    irq_rd   <= '1' when irq_acc = '1' and wr = '0' and addr(3 downto 2) = "00" else '0';
    irq_clr  <= (irq_ret and not irq_mode) when irq_rd = '1' else (others => '0');

    -- next state
    irq_pend_nx <= ((irq_pend and not irq_clr) or irq_edge) and not irq_mode; -- IRQ SET WINS
    irq_mask_nx <= d when irq_acc = '1' and wr = '1' and addr(3 downto 2) = "01" else irq_mask;
    irq_mode_nx <= d when irq_acc = '1' and wr = '1' and addr(3 downto 2) = "11" else irq_mode;
    irq_eff_nx  <= irq_mux(irq_sync1, irq_pend_nx, irq_mode_nx);
    int_nx      <= '1' when int_legacy_nx = '1' or (irq_eff_nx and irq_mask_nx) /= X"0000" else '0';

    process(clk_28, n_reset)
    begin
        if n_reset = '0' then
            irq_sync1 <= (others => '0');
            irq_sync2 <= (others => '0');
            irq_prev  <= (others => '0');
            irq_pend  <= (others => '0');
            irq_mask  <= (others => '0');
            irq_mode  <= (others => '0');
            irq_q     <= (others => '0');
            irq_seen  <= '0';
            int_out   <= '0';
        elsif rising_edge(clk_28) then
            irq_sync1 <= irq_in;
            irq_sync2 <= irq_sync1;
            irq_prev  <= irq_sync2;
            irq_seen  <= req;
            irq_pend  <= irq_pend_nx;
            irq_mask  <= irq_mask_nx;
            irq_mode  <= irq_mode_nx;
            int_out   <= int_nx;
            if irq_acc = '1' then
                case addr(3 downto 2) is
                    when "00" =>
                        irq_q <= irq_ret;
                    when "01" =>
                        irq_q <= irq_mask;
                    when "10" =>
                        irq_q <= irq_sync2;
                    when others =>
                        irq_q <= irq_mode;
                end case;
            end if;
        end if;
    end process;

    interrupt <= int_out;

    ---------------------------------
    -- Platform specific registers --
    ---------------------------------

    process(clk_28)
    begin
        if rising_edge(clk_28) then
            if req = '1' and wr = '1' then

                if platform_select = '1' then -- Write to platform registers
                    scandoubler <= d(0);
                end if;

                if audio_select = '1' then
                    audio_clear <= d(1);
                    audio_ena   <= d(0);
                end if;

            end if;
        end if;
    end process;

    -----------------------------------------------------------------
    -- Support States
    -----------------------------------------------------------------
    process(sysclk)
    begin
        IF rising_edge(sysclk) THEN
            --      support_state <= idle;
            IOcpuena <= '0';
            CASE support_state IS
                WHEN idle =>
                    uart_ld <= '0';
                    IF rs232_select = '1' AND req = '1' and wr = '1' THEN
                        IF txbusy = '0' THEN
                            uart_ld       <= '1';
                            support_state <= io_aktion;
                            IOcpuena      <= '1';
                        END IF;
                    ELSIF SPI_select = '1' and req = '1' THEN
                        IF SD_busy = '0' THEN
                            support_state <= io_aktion;
                            IOcpuena      <= '1';
                        END IF;
                    END IF;

                WHEN io_aktion =>
                    if shift(9) = '1' then
                        uart_ld <= '0';
                    end if;
                    if req = '0' then
                        support_state <= idle;
                    else
                        IOcpuena <= '1';
                    end if;

                WHEN OTHERS =>
                    support_state <= idle;
            END CASE;
        END IF;
    end process;

    -----------------------------------------------------------------
    -- SPI-Interface
    -----------------------------------------------------------------
    sd_cs   <= NOT scs;
    sd_clk  <= NOT sck_pin;
    sd_do   <= sd_out(15);
    SD_busy <= shiftcnt(13);

    PROCESS(sysclk, n_reset, scs, sd_di, sd_dimm)
    BEGIN
        IF scs(1) = '0' and scs(7) = '0' THEN
            sd_di_in <= sd_di;
        ELSE
            sd_di_in <= sd_dimm;
        END IF;
        IF n_reset = '0' THEN
            shiftcnt  <= (OTHERS => '0');
            spi_div   <= (OTHERS => '0');
            scs       <= (OTHERS => '0');
            sck       <= '0';
            sck_pin   <= '0';
            spi_speed <= "00000000";
            -- dscs      <= '0';
            spi_wait  <= '0';
        ELSIF rising_edge(sysclk) THEN

            spi_wait_d <= spi_wait;

            if spi_wait_d = '1' and sd_ack = '1' then -- Unpause SPI as soon as the IO controller has written to the MUX
                spi_wait <= '0';
            end if;

            IF SPI_select = '1' AND req = '1' and wr = '1' AND SD_busy = '0' THEN --SD write
                case addr(3 downto 2) is
                    when "10" =>        -- 8
                        spi_speed <= d(7 downto 0);
                    when "01" =>        -- 4
                        scs(0) <= not d(0);
                        IF d(7) = '1' THEN
                            scs(7) <= not d(0);
                        END IF;
                        IF d(6) = '1' THEN
                            scs(6) <= not d(0);
                        END IF;
                        IF d(5) = '1' THEN
                            scs(5) <= not d(0);
                        END IF;
                        IF d(4) = '1' THEN
                            scs(4) <= not d(0);
                        END IF;
                        IF d(3) = '1' THEN
                            scs(3) <= not d(0);
                        END IF;
                        IF d(2) = '1' THEN
                            scs(2) <= not d(0);
                        END IF;
                        IF d(1) = '1' THEN
                            scs(1) <= not d(0);
                        END IF;
                    when "00" =>        -- 0
                        --                      ELSE                            --DA4000
                        if scs(1) = '1' THEN -- Wait for io component to propagate signals.
                            spi_wait <= '1'; -- Only wait if SPI needs to go through the MUX
                            if spimux = true then
                                spi_div(8 downto 1) <= spi_speed + 4;
                            else
                                spi_div(8 downto 1) <= spi_speed;
                            end if;
                        else
                            spi_div(8 downto 1) <= spi_speed;
                        end if;
                        IF scs(6) = '1' THEN -- SPI direkt Mode
                            shiftcnt <= "10111111111111";
                            sd_out   <= X"FFFF";
                        ELSE
                            shiftcnt            <= "10000000000111";
                            sd_out(15 downto 8) <= d(7 downto 0);
                        END IF;
                        sck <= '1';
                        sck_pin <= '1';
                    when others =>
                        null;
                end case;
            ELSE
                IF spi_div = "0000000000" THEN
                    if scs(1) = '1' THEN -- Wait for io component to propagate signals.
                        spi_wait <= '1'; -- Only wait if SPI needs to go through the MUX
                        if spimux = true then
                            spi_div(8 downto 1) <= spi_speed + 4;
                        else
                            spi_div(8 downto 1) <= spi_speed;
                        end if;
                    else
                        spi_div(8 downto 1) <= spi_speed;
                    end if;
                    IF SD_busy = '1' THEN
                        IF sck = '0' THEN
                            IF shiftcnt(12 downto 0) /= "0000000000000" THEN
                                sck <= '1';
                                sck_pin <= '1';
                            END IF;
                            shiftcnt <= shiftcnt - 1;
                            sd_out   <= sd_out(14 downto 0) & '1';
                        ELSE
                            sck         <= '0';
                            sck_pin     <= '0';
                            sd_in_shift <= sd_in_shift(14 downto 0) & sd_di_in;
                        END IF;
                    END IF;
                ELSif spi_wait = '0' then
                    spi_div <= spi_div - 1;
                END IF;
            END IF;

        END IF;
    END PROCESS;

    -----------------------------------------------------------------
    -- OSD reply-ready handshake: HOST_REQ at 0fffffb4 (the audio window,
    -- addr(3 downto 2) = "01"), read only:
    --   bit 0      OSD_RDY: userio_osd has taken every byte cfide started
    --              with the OSD selected, so the next byte's reply is loaded
    --              from the right data (a reply byte may start now)
    --   bits 15..1 0 (reserved)
    -- The rest of the window reads audio_q and is written as before.
    -- osd_tx_seq (sysclk): +1 when a DATA write starts a byte while the OSD
    -- is selected (scs(5) = '1', i.e. sd_cs(5) low).  osd_rx_seq (clk_28,
    -- userio_osd): +1 when it has taken a byte, up to ~40 clk_114 after the
    -- byte's last sck edge.  OSD_RDY = the two agree (2 bits: 1, 2 and 3
    -- bytes outstanding all read 0; across a frame boundary there can be 2).
    -- Resync: once the OSD has been deselected for 64 sysclk cycles (longer
    -- than that window, so every byte has been taken), osd_tx_seq follows
    -- osd_rx_seq; this heals a byte userio_osd never took, and sets the
    -- start value (no reset needed: scs is 0 in reset, so it resyncs then).
    -- Clock domains: the read value is a clk_28 register loaded at EVERY
    -- clk_28 edge (no enable: req and addr are sysclk registers, and a load
    -- enable from them could miss the edge whose ack the bridge takes and
    -- return the previous poll's value), so the value read is the one loaded
    -- at the edge that raised ack, and osd_rx_seq is compared in its own
    -- domain; osd_tx_seq last changed at the DATA write of an earlier access
    -- (>= 4 sysclk cycles before that edge), and the resync copies
    -- osd_rx_seq only while it is static.  findings/osd-riscv/phase4.md,
    -- "Handshake design".
    -----------------------------------------------------------------
    spi_dat_go <= '1' when SPI_select = '1' and req = '1' and wr = '1' and SD_busy = '0'
                           and addr(3 downto 2) = "00" else '0';   -- the byte starts (above)

    process(sysclk)
    begin
        if rising_edge(sysclk) then
            if scs(5) = '1' then
                osd_idle <= (others => '0');
                if spi_dat_go = '1' then
                    osd_tx_seq <= osd_tx_seq + 1;
                end if;
            elsif osd_idle(6) = '0' then
                osd_idle <= osd_idle + 1;
            else
                osd_tx_seq <= osd_rx_seq;   -- OSD RESYNC
            end if;
        end if;
    end process;

    osd_rdy <= '1' when osd_tx_seq = osd_rx_seq else '0'; -- OSD RDY

    process(clk_28)
    begin
        if rising_edge(clk_28) then
            host_req_q <= osd_rdy;   -- every edge: see "Clock domains" above
        end if;
    end process;

    -----------------------------------------------------------------
    -- Simple UART only TxD
    -----------------------------------------------------------------
    debugTxD <= not shiftout;
    process(n_reset, clk_28, shift)
    begin
        if shift = "0000000000" then
            txbusy <= '0';
        else
            txbusy <= '1';
        end if;

        if n_reset = '0' then
            shiftout <= '0';
            shift    <= "0000000000";
        elsif rising_edge(clk_28) then
            if uart_ld = '1' then
                shift <= '1' & d(7 downto 0) & '0'; --STOP,MSB...LSB, START
            end if;
            if clkgen /= 0 then
                clkgen <= clkgen - 1;
            else
                --          clkgen <= "1111011001";--985;       --113.5MHz/115200
                clkgen   <= "0011110110"; --246;        --28.36MHz/115200
                shiftout <= not shift(0) and txbusy;
                shift    <= '0' & shift(9 downto 1);
            end if;
        end if;
    end process;

    -----------------------------------------------------------------
    -- I2C bridge
    -----------------------------------------------------------------
    i2c_master : if (havei2c) generate

        -- I2C master
        --   my_i2c_master: entity work.i2c_master port map (
        my_i2c_mmio : entity work.i2c_master_mmio
            port map(
                clk              => clk_28,
                rst              => reset,
                d                => d,
                q                => I2Cdata,
                interrupt        => i2c_int,
                -- MMIO interface
                addr             => addr,
                i2c_select       => i2c_select,
                interrupt_select => interrupt_select,
                req              => req,
                wr               => wr,
                -- I2C interface
                scl_i            => scl_i,
                scl_o            => scl_o,
                scl_t            => scl_t,
                sda_i            => sda_i,
                sda_o            => sda_o,
                sda_t            => sda_t,
                ext_int          => i2c_ext_int
            );

    end generate;

    vpos_interface : if (havevpos) generate

        process(clk_28)
        begin
            if rising_edge(clk_28) then
                if videoscl_select = '1' and wr = '1' then
                    pos_data_q <= d(15 downto 0);
                end if;
            end if;
        end process;

    end generate;

    -----------------------------------------------------------------
    -- timer
    -----------------------------------------------------------------
    process(clk_28)
    begin
        if rising_edge(clk_28) then
            if tick_in = '1' then
                timecnt <= timecnt + 1;
            end if;
        end if;
    end process;

end;

