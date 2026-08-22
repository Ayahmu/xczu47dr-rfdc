library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_hmc7044 is
end entity;

architecture sim of tb_hmc7044 is
    constant CLK_PERIOD : time := 10 ns;
    constant SIM_SETTLE_TICKS : positive := 8;

    signal clk : std_logic := '0';
    signal rst_n : std_logic := '0';
    signal cs_n : std_logic;
    signal sclk : std_logic;
    signal sdata : std_logic;
    signal finish : std_logic;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.hmc7044
        generic map (
            PLL2_SETTLE_TICKS => SIM_SETTLE_TICKS
        )
        port map (
            clk => clk,
            rst => rst_n,
            H7044_SLEN => cs_n,
            H7044_SCLK => sclk,
            H7044_SDATA => sdata,
            SET_FINISH => finish,
            USE_EXTERNAL_10MHZ => '1',
            IS_MASTER => '1'
        );

    stimulus : process
    begin
        wait for 100 ns;
        rst_n <= '1';
        wait for 5 ms;
        assert false report "timeout waiting for HMC7044 configuration" severity failure;
    end process;

    spi_monitor : process(sclk, cs_n)
        variable shift_word : std_logic_vector(23 downto 0) := (others => '0');
        variable bit_count : natural range 0 to 24 := 0;
        variable tail_stage : natural range 0 to 7 := 0;
        variable autotune_clear_time : time := 0 ns;
    begin
        if rising_edge(sclk) and cs_n = '0' then
            shift_word := shift_word(22 downto 0) & sdata;
            if bit_count < 24 then
                bit_count := bit_count + 1;
            end if;
        elsif rising_edge(cs_n) then
            if bit_count = 24 then
                case shift_word is
                    when x"015208" =>
                        assert tail_stage = 0
                            report "final output configuration appeared out of order" severity failure;
                        tail_stage := 1;
                    when x"000204" =>
                        assert tail_stage = 2
                            report "PLL2 autotune trigger appeared out of order" severity failure;
                        tail_stage := 3;
                    when x"000200" =>
                        if tail_stage = 1 then
                            tail_stage := 2;
                        elsif tail_stage = 3 then
                            tail_stage := 4;
                            autotune_clear_time := now;
                        end if;
                    when x"000120" =>
                        if tail_stage = 4 then
                            assert now - autotune_clear_time >= SIM_SETTLE_TICKS * 40 ns
                                report "divider restart began before PLL2 settle interval" severity failure;
                            tail_stage := 5;
                        elsif tail_stage = 6 then
                            tail_stage := 7;
                        end if;
                    when x"000122" =>
                        assert tail_stage = 5
                            report "divider restart pulse appeared out of order" severity failure;
                        tail_stage := 6;
                    when others =>
                        null;
                end case;
            end if;
            bit_count := 0;

            if finish = '1' then
                assert tail_stage = 7
                    report "SET_FINISH asserted before autotune and divider restart completed" severity failure;
                report "HMC7044 SPI autotune sequence passed" severity note;
                stop;
            end if;
        end if;
    end process;
end architecture;
