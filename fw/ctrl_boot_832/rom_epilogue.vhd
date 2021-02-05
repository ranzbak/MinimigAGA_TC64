  others => ( x"00000000")
);

-- Xilinx Vivado attributes
attribute ram_style: string;
attribute ram_style of ram: signal is "block";

signal wea : std_logic_vector(NB_COL - 1 downto 0);
signal web : std_logic_vector(NB_COL - 1 downto 0);

begin
    
    -- Generate write enable signals
    -- The Block ram generator doesn't like it when the compare is done in the if statement it self.
    
    
    wea <= bytesel(0) & bytesel(1) & bytesel(2) & bytesel(3) when we = '1' else (others => '0');
    web <= bytesel2(0) & bytesel2(1) & bytesel2(2) & bytesel2(3) when we2 = '1' else (others => '0');

    ------- Port A -------
    process(clk)
    begin
        if rising_edge(clk) then
            q <= ram(to_integer(unsigned(addr)));
            for i in 0 to NB_COL - 1 loop
                if (wea(i) = '1') then
                    ram(to_integer(unsigned(addr)))((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH) <= d((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH);
                end if;
            end loop;
        end if;
    end process;

    ------- Port B -------
    process(clk)
    begin
        if rising_edge(clk) then
            q2 <= ram(to_integer(unsigned(addr2)));
            for i in 0 to NB_COL - 1 loop
                if (web(i) = '1') then
                    ram(to_integer(unsigned(addr2)))((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH) <= d2((i + 1) * COL_WIDTH - 1 downto i * COL_WIDTH);
                end if;
            end loop;
        end if;
    end process;

end arch;
