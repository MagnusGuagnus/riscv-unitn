----------------------------------------------------------------------------------
-- Testbench: tb_comparator
-- Verifica i 4 confronti (EQ, NEQ, LT, GE) con valori positivi, negativi, e
-- controlla che cond_opcode "fuori spec" produca sempre branch_cond = '0'.
-- Tiene conto del latch: branch_cond cambia 1 ciclo di clock dopo che cambiano
-- gli ingressi.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_comparator is
end tb_comparator;

architecture sim of tb_comparator is
    signal clk         : std_logic := '0';
    signal rs1_value   : std_logic_vector(31 downto 0) := (others => '0');
    signal rs2_value   : std_logic_vector(31 downto 0) := (others => '0');
    signal cond_opcode : std_logic_vector(2 downto 0)  := "000";
    signal branch_cond : std_logic;
begin
    uut: entity work.comparator
        port map (
            clk         => clk,
            rs1_value   => rs1_value,
            rs2_value   => rs2_value,
            cond_opcode => cond_opcode,
            branch_cond => branch_cond
        );

    -- Clock 100 MHz (period 10 ns)
    clk <= not clk after 5 ns;

    stim: process
    begin
        wait for 7 ns;  -- offset rispetto al rising edge

        ------------------------------------------------------------------
        -- EQ
        ------------------------------------------------------------------
        cond_opcode <= "000";
        rs1_value <= x"00000005"; rs2_value <= x"00000005";
        wait for 10 ns;
        assert branch_cond = '1' report "EQ 5==5: dovrebbe essere taken" severity error;

        rs1_value <= x"00000005"; rs2_value <= x"00000006";
        wait for 10 ns;
        assert branch_cond = '0' report "EQ 5==6: dovrebbe essere NOT taken" severity error;

        ------------------------------------------------------------------
        -- NEQ
        ------------------------------------------------------------------
        cond_opcode <= "001";
        rs1_value <= x"00000005"; rs2_value <= x"00000006";
        wait for 10 ns;
        assert branch_cond = '1' report "NEQ 5!=6: dovrebbe essere taken" severity error;

        rs1_value <= x"00000005"; rs2_value <= x"00000005";
        wait for 10 ns;
        assert branch_cond = '0' report "NEQ 5!=5: dovrebbe essere NOT taken" severity error;

        ------------------------------------------------------------------
        -- LT (signed)
        ------------------------------------------------------------------
        cond_opcode <= "100";

        -- 3 < 7 → taken
        rs1_value <= x"00000003"; rs2_value <= x"00000007";
        wait for 10 ns;
        assert branch_cond = '1' report "LT 3<7: dovrebbe essere taken" severity error;

        -- 7 < 3 → not taken
        rs1_value <= x"00000007"; rs2_value <= x"00000003";
        wait for 10 ns;
        assert branch_cond = '0' report "LT 7<3: dovrebbe essere NOT taken" severity error;

        -- -1 < 1 (signed!) → taken (perché -1 è negativo)
        rs1_value <= x"FFFFFFFF"; rs2_value <= x"00000001";
        wait for 10 ns;
        assert branch_cond = '1' report "LT -1<1 signed: dovrebbe essere taken" severity error;

        -- 1 < -1 → not taken
        rs1_value <= x"00000001"; rs2_value <= x"FFFFFFFF";
        wait for 10 ns;
        assert branch_cond = '0' report "LT 1<(-1) signed: dovrebbe essere NOT taken" severity error;

        ------------------------------------------------------------------
        -- GE (signed)
        ------------------------------------------------------------------
        cond_opcode <= "101";

        -- 7 >= 3 → taken
        rs1_value <= x"00000007"; rs2_value <= x"00000003";
        wait for 10 ns;
        assert branch_cond = '1' report "GE 7>=3: dovrebbe essere taken" severity error;

        -- 3 >= 3 → taken (uguaglianza inclusa)
        rs1_value <= x"00000003"; rs2_value <= x"00000003";
        wait for 10 ns;
        assert branch_cond = '1' report "GE 3>=3: dovrebbe essere taken (=)" severity error;

        -- 3 >= 7 → not taken
        rs1_value <= x"00000003"; rs2_value <= x"00000007";
        wait for 10 ns;
        assert branch_cond = '0' report "GE 3>=7: dovrebbe essere NOT taken" severity error;

        -- -1 >= 1 (signed) → not taken
        rs1_value <= x"FFFFFFFF"; rs2_value <= x"00000001";
        wait for 10 ns;
        assert branch_cond = '0' report "GE -1>=1 signed: dovrebbe essere NOT taken" severity error;

        ------------------------------------------------------------------
        -- cond_opcode fuori spec (010, 011, 110, 111) → sempre '0'
        ------------------------------------------------------------------
        rs1_value <= x"00000005"; rs2_value <= x"00000005";  -- uguali
        cond_opcode <= "010";  -- fuori spec
        wait for 10 ns;
        assert branch_cond = '0' report "cond_opcode 010 fuori spec: dovrebbe essere 0" severity error;

        cond_opcode <= "111";  -- fuori spec (sarebbe BGEU in RV32I, ma noi non lo facciamo)
        wait for 10 ns;
        assert branch_cond = '0' report "cond_opcode 111 fuori spec: dovrebbe essere 0" severity error;

        report "tb_comparator: tutti i casi verificati" severity note;
        wait;
    end process;
end sim;
