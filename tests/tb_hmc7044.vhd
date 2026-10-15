library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
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
    signal sdata_oe : std_logic;
    signal sdata_line : std_logic;
    signal sdata_in : std_logic;
    signal slave_drive : std_logic := 'Z';
    signal rb_index : std_logic_vector(5 downto 0) := (others => '0');
    signal rb_word : std_logic_vector(31 downto 0);
    signal rb_sweeps : std_logic_vector(15 downto 0);
    signal config_done_seen : boolean := false;

    -- What the HMC7044 model returns for a register address.
    function model_value(addr : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(addr, 8) xor x"A5");
    end function;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.hmc7044
        generic map (
            PLL2_SETTLE_TICKS => SIM_SETTLE_TICKS,
            RB_PHASE_TICKS => 2,
            RB_GAP_TICKS => 3
        )
        port map (
            clk => clk,
            rst => rst_n,
            H7044_SLEN => cs_n,
            H7044_SCLK => sclk,
            H7044_SDATA => sdata,
            H7044_SDATA_OE => sdata_oe,
            H7044_SDATA_IN => sdata_in,
            SET_FINISH => finish,
            RB_WORD_INDEX => rb_index,
            RB_WORD => rb_word,
            RB_SWEEPS => rb_sweeps
        );

    -- Open-drain SDATA: FPGA push-pull while it owns the line, the HMC7044
    -- model pulls low during read data, a pad pull-up otherwise.
    sdata_line <= sdata when sdata_oe = '1' else 'Z';
    sdata_line <= slave_drive;
    sdata_line <= 'H';
    sdata_in <= to_x01(sdata_line);

    hmc_read_model : process(sclk, cs_n)
        variable header : std_logic_vector(15 downto 0) := (others => '0');
        variable rising_count : natural := 0;
        variable value : std_logic_vector(7 downto 0);
    begin
        if cs_n = '1' then
            rising_count := 0;
            slave_drive <= 'Z';
        elsif rising_edge(sclk) then
            if rising_count < 16 then
                header := header(14 downto 0) & sdata_line;
            end if;
            rising_count := rising_count + 1;
        elsif falling_edge(sclk) and rising_count >= 16 and rising_count < 24
              and to_x01(header(15)) = '1' then
            assert sdata_oe = '0' or rising_count > 16
                report "FPGA still drives SDATA in the read data phase" severity failure;
            value := model_value(to_integer(unsigned(header(7 downto 0))));
            if value(23 - rising_count) = '0' then
                slave_drive <= '0';
            else
                slave_drive <= 'Z';
            end if;
        end if;
    end process;


    stimulus : process
    begin
        wait for 100 ns;
        rst_n <= '1';
        wait until config_done_seen for 5 ms;
        assert config_done_seen report "timeout waiting for HMC7044 configuration" severity failure;
        wait until unsigned(rb_sweeps) >= 1 for 10 ms;
        assert unsigned(rb_sweeps) >= 1 report "timeout waiting for a readback sweep" severity failure;
        for i in 0 to 39 loop
            rb_index <= std_logic_vector(to_unsigned(i, 6));
            wait for 1 ns;
            for b in 0 to 3 loop
                assert rb_word(8 * b + 7 downto 8 * b) = model_value(4 * i + b)
                    report "readback register " & integer'image(4 * i + b) & " wrong" severity failure;
            end loop;
        end loop;
        rb_index <= std_logic_vector(to_unsigned(40, 6));
        wait for 1 ns;
        assert rb_word = x"00000000" report "register beyond 0x9F was read back" severity failure;
        report "HMC7044 register readback passed" severity note;
        stop;
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
                if not config_done_seen then
                    report "HMC7044 SPI autotune sequence passed" severity note;
                end if;
                config_done_seen <= true;
            end if;
        end if;
    end process;
end architecture;
