----------------------------------------------------------------------------------
-- Testbench: tb_regfile
-- Verifica:
--   - x0 sempre legge 0
--   - Scrittura su x0 ignorata
--   - Scrittura/lettura su x1..x31 funziona
--   - Le letture rs1/rs2 sono latched (1 ciclo di ritardo dopo cambio addr)
--   - Mux esterno simulato: a_addr passa da rs1 (lettura) a rd (scrittura)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_regfile is
end tb_regfile;

architecture sim of tb_regfile is
    signal clk       : std_logic := '0';
    signal we        : std_logic := '0';
    signal a_addr    : std_logic_vector(4 downto 0) := (others => '0');
    signal rs2_addr  : std_logic_vector(4 downto 0) := (others => '0');
    signal rd_data   : std_logic_vector(31 downto 0) := (others => '0');
    signal rs1_value : std_logic_vector(31 downto 0);
    signal rs2_value : std_logic_vector(31 downto 0);
begin
    uut: entity work.regfile
        port map (
            clk       => clk,
            we        => we,
            a_addr    => a_addr,
            rs2_addr  => rs2_addr,
            rd_data   => rd_data,
            rs1_value => rs1_value,
            rs2_value => rs2_value
        );

    clk <= not clk after 5 ns;  -- 100 MHz

    stim: process
    begin
        wait for 7 ns;  -- offset rispetto al rising edge

        ------------------------------------------------------------------
        -- 1) Scrittura: x5 <= 0xDEADBEEF (simula MEM/WB di un'istruzione)
        ------------------------------------------------------------------
        a_addr  <= "00101";        -- rd = x5
        rd_data <= x"DEADBEEF";
        we      <= '1';
        wait for 10 ns;            -- 1 ciclo di clock → la scrittura avviene
        we      <= '0';

        ------------------------------------------------------------------
        -- 2) Lettura: a_addr <= x5 (rs1), rs2_addr <= 0
        --    rs1_value dovrebbe diventare 0xDEADBEEF dopo 1 ciclo (latch).
        --    rs2_value = 0 (perché x0 è hardwired).
        ------------------------------------------------------------------
        a_addr   <= "00101";       -- rs1 = x5
        rs2_addr <= "00000";       -- rs2 = x0
        wait for 20 ns;            -- 2 cicli (1 per la propagazione qspo, 1 per il latch)
        assert rs1_value = x"DEADBEEF" report "x5 letto male" severity error;
        assert rs2_value = x"00000000" report "x0 dovrebbe essere 0" severity error;

        ------------------------------------------------------------------
        -- 3) Scrittura su x0: deve essere IGNORATA
        ------------------------------------------------------------------
        a_addr  <= "00000";
        rd_data <= x"FFFFFFFF";    -- proviamo a scrivere tutti uni in x0
        we      <= '1';
        wait for 10 ns;
        we      <= '0';

        -- Lettura di x0: deve rimanere 0
        a_addr   <= "00000";
        wait for 20 ns;
        assert rs1_value = x"00000000" report "Scrittura su x0 NON deve avere effetto" severity error;

        ------------------------------------------------------------------
        -- 4) Scriviamo qualcosa in x10, x20, x31
        ------------------------------------------------------------------
        -- x10 <= 0x000000AA
        a_addr <= "01010"; rd_data <= x"000000AA"; we <= '1';
        wait for 10 ns;
        -- x20 <= 0xCAFEBABE
        a_addr <= "10100"; rd_data <= x"CAFEBABE"; we <= '1';
        wait for 10 ns;
        -- x31 <= 0x12345678
        a_addr <= "11111"; rd_data <= x"12345678"; we <= '1';
        wait for 10 ns;
        we <= '0';

        ------------------------------------------------------------------
        -- 5) Lettura simultanea di rs1 (x10) e rs2 (x20)
        --    È il caso tipico DECODE: serve leggere due registri nello stesso ciclo.
        ------------------------------------------------------------------
        a_addr   <= "01010";   -- rs1 = x10
        rs2_addr <= "10100";   -- rs2 = x20
        wait for 20 ns;
        assert rs1_value = x"000000AA" report "rs1=x10: dovrebbe essere 0xAA" severity error;
        assert rs2_value = x"CAFEBABE" report "rs2=x20: dovrebbe essere 0xCAFEBABE" severity error;

        ------------------------------------------------------------------
        -- 6) Cambio rs2 e verifico che cambia (latched, 1 ciclo dopo)
        ------------------------------------------------------------------
        rs2_addr <= "11111";   -- rs2 = x31
        wait for 20 ns;
        assert rs2_value = x"12345678" report "rs2=x31: dovrebbe essere 0x12345678" severity error;

        ------------------------------------------------------------------
        -- 7) Sovrascrittura: x10 <= 0xBEEF0000
        ------------------------------------------------------------------
        a_addr <= "01010"; rd_data <= x"BEEF0000"; we <= '1';
        wait for 10 ns;
        we <= '0';
        a_addr <= "01010";
        wait for 20 ns;
        assert rs1_value = x"BEEF0000" report "x10 sovrascritto: dovrebbe essere 0xBEEF0000" severity error;

        report "tb_regfile: tutti i casi verificati" severity note;
        wait;
    end process;
end sim;
