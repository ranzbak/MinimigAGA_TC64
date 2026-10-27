-- cfide's Video Pos registers (findings/osd-redesign Phase 4): a host write
-- to 0x0fffff50 sets pos_data_q (the PAL/NTSC picture), to 0x0fffff54
-- pos_rtg_q (the RTG screen); any other 0x0fffff5x address still sets
-- pos_data_q, as every one of them did before.  pos_rtg_q is 0 (centred)
-- from power-up.  Written the way the OSD CPU's store reaches cfide: addr
-- and d held, req and wr high for a few clk_28 cycles.  GHDL (run.sh).
library ieee;
use ieee.std_logic_1164.all;

entity cfide_tb is
end cfide_tb;

architecture sim of cfide_tb is
    signal clk      : std_logic := '0';
    signal addr     : std_logic_vector(31 downto 2) := (others => '0');
    signal d        : std_logic_vector(15 downto 0) := (others => '0');
    signal req, wr  : std_logic := '0';
    signal pos_data, pos_rtg : std_logic_vector(15 downto 0);
    signal done     : boolean := false;
begin
    clk <= not clk after 17.6 ns when not done;

    dut : entity work.cfide
        generic map(spimux => false, havespirtc => false, havei2c => false, havevpos => true)
        port map(
            sysclk => clk, n_reset => '1', addr => addr, d => d, q => open,
            req => req, wr => wr, ack => open,
            sd_di => '1', sd_cs => open, sd_clk => open, sd_do => open,
            sd_dimm => '1', sd_ack => '1',
            debugTxD => open, debugRxD => '1',
            scandoubler => open, audio_ena => open, audio_clear => open,
            audio_buf => '0', audio_amiga => '0', vbl_int => '0', interrupt => open,
            amiga_key => open, amiga_key_stb => open,
            amiga_addr => (others => '0'), amiga_d => (others => '0'), amiga_q => open,
            amiga_req => '0', amiga_wr => '0', amiga_ack => open, rtc_q => open,
            scl_i => '1', scl_o => open, scl_t => open, sda_i => '1', sda_o => open, sda_t => open,
            pos_data_q => pos_data, pos_rtg_q => pos_rtg,
            ext_wstb => open, ext_rstb => open, ext_addr => open, ext_d => open,
            clk_28 => clk, tick_in => '0');

    process
        variable errors : integer := 0;
        procedure wr16(a : std_logic_vector(31 downto 0); v : std_logic_vector(15 downto 0)) is
        begin
            wait until rising_edge(clk);
            addr <= a(31 downto 2);
            d <= v;
            req <= '1';
            wr <= '1';
            for i in 1 to 4 loop
                wait until rising_edge(clk);
            end loop;
            req <= '0';
            wr <= '0';
            addr <= (others => '0');
            for i in 1 to 4 loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
        procedure check(what : string; got, want : std_logic_vector(15 downto 0)) is
        begin
            if got /= want then
                report "FAIL: " & what & " = " & to_hstring(got) & ", expected " & to_hstring(want) severity note;
                errors := errors + 1;
            else
                report "  ok: " & what & " = " & to_hstring(got) severity note;
            end if;
        end procedure;
    begin
        for i in 1 to 4 loop
            wait until rising_edge(clk);
        end loop;
        check("(e) pos_rtg_q at power-up (centred)", pos_rtg, x"0000");
        wr16(x"FFFFFF50", x"04F8");
        check("(f) 0x50 -> pos_data_q", pos_data, x"04F8");
        check("(f) 0x50 leaves pos_rtg_q", pos_rtg, x"0000");
        wr16(x"FFFFFF54", x"FA10");
        check("(g) 0x54 -> pos_rtg_q", pos_rtg, x"FA10");
        check("(g) 0x54 leaves pos_data_q", pos_data, x"04F8");
        wr16(x"FFFFFF58", x"1234");
        check("(h) 0x58 -> pos_data_q (as before)", pos_data, x"1234");
        check("(h) 0x58 leaves pos_rtg_q", pos_rtg, x"FA10");
        wr16(x"FFFFFF60", x"5555");
        check("(i) 0x60 (I2C) leaves pos_data_q", pos_data, x"1234");
        check("(i) 0x60 leaves pos_rtg_q", pos_rtg, x"FA10");
        if errors = 0 then
            report "=== PASS" severity note;
        else
            report "=== FAIL (" & integer'image(errors) & ")" severity note;
        end if;
        done <= true;
        wait;
    end process;
end sim;
