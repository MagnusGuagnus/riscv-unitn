----------------------------------------------------------------------------------
-- Testbench: tb_pc_unit
-- Verifica:
--   - Reset sincrono porta pc a 0
--   - Senza load_en il PC non cambia
--   - Con load_en il PC carica pc_in al rising_edge
--   - next_pc è sempre pc + 4 (combinatorio)
--   - pc_word è pc[11:2]
--   - Caricamento di un branch target di esempio
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pc_unit is
end tb_pc_unit;

architecture sim of tb_pc_unit is
    signal clk     : std_logic := '0';
    signal reset   : std_logic := '1';
    signal load_en : std_logic := '0';
    signal pc_in   : std_logic_vector(11 downto 0) := (others => '0');
    signal pc      : std_logic_vector(11 downto 0);
    signal next_pc : std_logic_vector(11 downto 0);
    signal pc_word : std_logic_vector(9 downto 0);
begin
    uut: entity work.pc_unit
        port map (
            clk     => clk,
            reset   => reset,
            load_en => load_en,
            pc_in   => pc_in,
            pc      => pc,
            next_pc => next_pc,
            pc_word => pc_word
        );

    clk <= not clk after 5 ns;

    stim: process
    begin
        ------------------------------------------------------------------
        -- 1) Reset: pc deve essere 0
        ------------------------------------------------------------------
        reset <= '1'; load_en <= '0';
        wait for 20 ns;
        assert pc = x"000" report "Dopo reset, pc dovrebbe essere 0" severity error;
        assert next_pc = x"004" report "Dopo reset, next_pc dovrebbe essere 4" severity error;
        assert pc_word = "0000000000" report "Dopo reset, pc_word dovrebbe essere 0" severity error;

        ------------------------------------------------------------------
        -- 2) Senza load_en, pc non cambia anche se pc_in cambia
        ------------------------------------------------------------------
        reset <= '0';
        pc_in <= x"100";   -- cambio l'input ma load_en resta 0
        wait for 20 ns;
        assert pc = x"000" report "Senza load_en pc non doveva cambiare" severity error;

        ------------------------------------------------------------------
        -- 3) Con load_en, pc carica pc_in al prossimo rising_edge
        ------------------------------------------------------------------
        pc_in <= x"008";   -- carico l'indirizzo dell'istruzione 2 (8 byte = 2 word)
        load_en <= '1';
        wait for 10 ns;    -- 1 ciclo
        load_en <= '0';
        wait for 1 ns;     -- piccolo settling
        assert pc = x"008" report "Dopo load_en, pc dovrebbe essere 0x008" severity error;
        assert next_pc = x"00C" report "next_pc dovrebbe essere 0x00C (8+4)" severity error;
        assert pc_word = "0000000010" report "pc_word dovrebbe essere 2 (= 8/4)" severity error;

        ------------------------------------------------------------------
        -- 4) Avanzamento sequenziale: simulo che la FSM faccia load_en=1
        --    in fase FETCH, con pc_in = next_pc.
        --    In 4 colpi pc dovrebbe passare 8 → 12 → 16 → 20 → 24
        ------------------------------------------------------------------
        for i in 0 to 3 loop
            pc_in <= next_pc;   -- pc_in segue next_pc come farebbe il mux finale
            load_en <= '1';
            wait for 10 ns;
            load_en <= '0';
            wait for 1 ns;
        end loop;
        -- partito da pc=8, 4 incrementi di +4 → pc = 24
        assert pc = x"018" report "Dopo 4 incrementi pc dovrebbe essere 0x018 (24)" severity error;

        ------------------------------------------------------------------
        -- 5) Salto a un branch target (es. pc = 0x100)
        ------------------------------------------------------------------
        pc_in <= x"100";
        load_en <= '1';
        wait for 10 ns;
        load_en <= '0';
        wait for 1 ns;
        assert pc = x"100" report "Branch target: pc dovrebbe essere 0x100" severity error;
        assert next_pc = x"104" report "next_pc dopo branch dovrebbe essere 0x104" severity error;

        ------------------------------------------------------------------
        -- 6) Reset di nuovo durante l'esecuzione
        ------------------------------------------------------------------
        reset <= '1';
        wait for 10 ns;
        assert pc = x"000" report "Reset durante esecuzione dovrebbe azzerare pc" severity error;

        report "tb_pc_unit: tutti i casi verificati" severity note;
        wait;
    end process;
end sim;
