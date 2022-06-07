library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity akiko is
    generic(
        havertg   : boolean := true;
        haveaudio : boolean := true;
        havec2p   : boolean := true
    );
    port(
        clk            : in  std_logic;
        reset_n        : in  std_logic;
        addr           : in  std_logic_vector(10 downto 0);
        req            : in  std_logic;
        wr             : in  std_logic;
        ack            : out std_logic;
        d              : in  std_logic_vector(15 downto 0);
        q              : out std_logic_vector(15 downto 0);
        -- Host interface
        host_req       : out std_logic;
        host_ack       : in  std_logic;
        host_q         : in  std_logic_vector(15 downto 0);
        -- RTG signals
        rtg_addr       : out std_logic_vector(25 downto 4);
        rtg_vbend      : out std_logic_vector(6 downto 0);
        rtg_ext        : out std_logic;
        rtg_pixelclock : out std_logic_vector(3 downto 0);
        rtg_clut       : out std_logic;
        rtg_16bit      : out std_logic;
        rtg_clut_idx   : in  std_logic_vector(7 downto 0);
        rtg_clut_r     : out std_logic_vector(7 downto 0);
        rtg_clut_g     : out std_logic_vector(7 downto 0);
        rtg_clut_b     : out std_logic_vector(7 downto 0);
        -- Audio signals
        audio_buf      : in  std_logic;
        audio_ena      : out std_logic;
        audio_int      : out std_logic
    );
end entity;

architecture rtl of akiko is

    signal id_q   : std_logic_vector(15 downto 0);
    signal id_sel : std_logic;
    signal id_ack : std_logic;
    signal ct_sel : std_logic;
    signal ct_q   : std_logic_vector(15 downto 0);
    signal ct_ack : std_logic;

    signal host_sel   : std_logic;
    signal host_ack_d : std_logic;

    signal rtg_sel    : std_logic;
    signal rtg_ack    : std_logic;
    signal clut_sel   : std_logic;
    signal clut_wr    : std_logic;
    signal clut_idx_w : std_logic_vector(7 downto 0);
    signal clut_high  : std_logic_vector(7 downto 0);
    type clutarray is array (0 to 255) of std_logic_vector(31 downto 0);
    signal clut       : clutarray;
    signal clut_rgb   : std_logic_vector(31 downto 0);

    signal ahi_sel      : std_logic;
    signal ahi_q        : std_logic_vector(15 downto 0);
    signal audio_intena : std_logic;
    signal audio_buf_d  : std_logic;

begin

    -- ID Register

    id_sel <= '1' when addr(7 downto 2) = X"0" & "00" else '0';
    id_q   <= X"C0CA" when addr(1) = '0' else X"CAFE";
    id_ack <= req and id_sel;

    -- Cornerturn for Chunky to Planar

    ct_sel <= '1' when addr(7 downto 2) = X"3" & "10" else '0'; -- Cornerturn at 0xb80038

    c2p : if havec2p generate
        myc2p : entity work.cornerturn
            port map(
                clk     => clk,
                reset_n => reset_n,
                d       => d,
                q       => ct_q,
                wr      => wr,
                req     => req and ct_sel,
                ack     => ct_ack
            );
    end generate;

    noc2p : if havec2p = false generate
        ct_ack <= '0';
    end generate;

    -- Host interface
    -- Defer any requests not handled by the Cornerturn or RTG to the host CPU

    host_sel <= not (rtg_sel or clut_sel or ahi_sel or ct_sel);
    host_req <= req and host_sel;

    -- Audio registers

    ahi_sel <= '1' when addr(10 downto 8) = "010" else '0'; -- Audio registers at 0xb802xx

    process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                audio_intena <= '0';
                audio_int    <= '0';
                audio_ena    <= '0';
            elsif haveaudio then
                -- Trigger an interrupt when the buffer flips
                audio_buf_d <= audio_buf;
                if audio_buf_d /= audio_buf then
                    audio_int <= audio_intena;
                end if;

                if ahi_sel = '1' and req = '1' then
                    if wr = '1' then    -- Write cycle
                        case addr(4 downto 1) is
                            when X"0" =>
                                audio_ena    <= d(0);
                                audio_int    <= '0'; -- Clear interrupt on write
                                audio_intena <= d(1);
                            when others =>
                                null;
                        end case;
                    else                -- Read cycle
                        ahi_q(15 downto 1) <= (others => '0');
                        ahi_q(0)           <= audio_buf;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- RTG registers and CLUT

    rtg_sel    <= '1' when addr(10 downto 8) = "001" else '0'; -- RTG registers at 0xb801xx
    clut_sel   <= '1' when addr(10) = '1' else '0'; -- RTG CLUT at 0xb80400 - 7ff
    clut_idx_w <= addr(9 downto 2);     -- 256 CLUT entries mapped from b80400 - b807ff
    clut_wr    <= wr and addr(1);       -- Write 32-bit clut entry on write to lower word.

    rtg_ack <= req and (rtg_sel or clut_sel);

    rtg_clut_r <= clut_rgb(23 downto 16);
    rtg_clut_g <= clut_rgb(15 downto 8);
    rtg_clut_b <= clut_rgb(7 downto 0);

    process(clk)
    begin
        if rising_edge(clk) then

            clut_rgb <= clut(to_integer(unsigned(rtg_clut_idx)));

            if havertg then

                -- RTG registers.  Will need a secondary framebuffer address to support
                -- screen dragging, but I suspect screen dragging will cause a display "ReThink"
                -- and thus mess with the AGA registers, so will probably need a full CRTC too.
                if req = '1' and wr = '1' then
                    if rtg_sel = '1' then
                        case addr(4 downto 1) is
                            when X"0" => -- High word of framebuffer address
                                rtg_addr(25 downto 16) <= d(9 downto 0);
                            when X"1" => -- Low word of framebuffer address
                                rtg_addr(15 downto 4) <= d(15 downto 4);
                            when X"2" => -- CLUT (15) : Extend (14) : VBEnd(n downto 6) : PixelClock (3 downto 0)
                                rtg_pixelclock <= d(3 downto 0);
                                rtg_vbend      <= d(rtg_vbend'high + 6 downto 6);
                                rtg_clut       <= d(15);
                                rtg_ext        <= d(14);
                            when X"3" => -- PixelFormat - 16bit (0) 
                                rtg_16bit <= d(0);
                            when others =>
                                null;
                        end case;
                    end if;
                    if clut_sel = '1' then
                        if clut_wr = '1' then
                            clut(to_integer(unsigned(clut_idx_w))) <= X"00" & clut_high & d;
                        else
                            clut_high <= d(7 downto 0);
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- CPU read cycles

    q <= ct_q when ct_sel = '1' else
         host_q when host_sel = '1' else
         ahi_q when ahi_sel = '1' else
         id_q when id_sel = '1' else
         X"8320" when rtg_sel = '1'     -- just ID number from RTG registers
         else
         X"ffff";

    process(clk)
    begin
        if rising_edge(clk) then
            if host_ack = '1' then
                host_ack_d <= '1';
            end if;
            if (req and host_sel) = '0' then
                host_ack_d <= '0';
            end if;

            ack <= ct_ack or id_ack or rtg_ack or host_ack_d;

        end if;
    end process;

end architecture;

