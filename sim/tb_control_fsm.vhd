----------------------------------------------------------------------------------
-- Testbench: tb_control_fsm
-- Verifica:
--   - Reset porta in FETCH
--   - Sequenza FETCH → DECODE → EXECUTE → MEM_WB → FETCH per 2 giri completi
--   - In MEM_WB: pc_load='1', regfile_a_sel='1'
--   - mem_we='1' solo se op_class=Store
--   - rd_write_en='1' per ALU op / Load / Jump; '0' per Store e Branch
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_control_fsm is
end tb_control_fsm;

architecture sim of tb_control_fsm is
    signal clk           : std_logic := '0';
    signal reset         : std_logic := '1';
    signal op_class      : std_logic_vector(4 downto 0) := "00000";
    signal pc_load       : std_logic;
    signal mem_we        : std_logic;
    signal rd_write_en   : std_logic;
    signal regfile_a_sel : std_logic;
    signal state_out     : std_logic_vector(1 downto 0);
begin
    uut: entity work.control_fsm
        port map (
            clk           => clk,
            reset         => reset,
            op_class      => op_class,
            pc_load       => pc_load,
            mem_we        => mem_we,
            rd_write_en   => rd_write_en,
            regfile_a_sel => regfile_a_sel,
            state_out     => state_out
        );

    clk <= not clk after 5 ns;

    stim: process
    begin
        wait for 7 ns;

        ------------------------------------------------------------------
        -- 1) Reset: stato deve essere FETCH (00)
        ------------------------------------------------------------------
        reset <= '1';
        wait for 20 ns;
        assert state_out = "00" report "Dopo reset deve essere FETCH" severity error;
        assert pc_load = '0' report "FETCH: pc_load deve essere 0" severity error;

        ------------------------------------------------------------------
        -- 2) Ciclo completo con un'istruzione ALU op (op_class = "00001" = O)
        -- Sequenza attesa: FETCH → DECODE → EXECUTE → MEM_WB → FETCH
        ------------------------------------------------------------------
        reset    <= '0';
        op_class <= "00001";  -- ALU op (O)

        -- Ora dovrebbe transitare FETCH → DECODE
        wait for 10 ns;
        assert state_out = "01" report "Dovrebbe essere DECODE (01)" severity error;
        assert pc_load = '0' report "DECODE: pc_load deve essere 0" severity error;
        assert regfile_a_sel = '0' report "DECODE: regfile_a_sel deve essere 0 (rs1)" severity error;

        -- DECODE → EXECUTE
        wait for 10 ns;
        assert state_out = "10" report "Dovrebbe essere EXECUTE (10)" severity error;
        assert pc_load = '0' report "EXECUTE: pc_load deve essere 0" severity error;

        -- EXECUTE → MEM_WB
        wait for 10 ns;
        assert state_out = "11" report "Dovrebbe essere MEM_WB (11)" severity error;
        assert pc_load = '1' report "MEM_WB: pc_load deve essere 1" severity error;
        assert regfile_a_sel = '1' report "MEM_WB: regfile_a_sel deve essere 1 (rd)" severity error;
        assert rd_write_en = '1' report "MEM_WB con op_class=O: rd_write_en deve essere 1" severity error;
        assert mem_we = '0' report "MEM_WB con op_class=O: mem_we deve essere 0" severity error;

        -- MEM_WB → FETCH (giro completo)
        wait for 10 ns;
        assert state_out = "00" report "Dovrebbe tornare a FETCH (00)" severity error;
        assert pc_load = '0' report "FETCH: pc_load deve essere 0" severity error;

        ------------------------------------------------------------------
        -- 3) Secondo giro con op_class = Store (S = "00010")
        --    In MEM_WB: mem_we='1', rd_write_en='0'
        ------------------------------------------------------------------
        op_class <= "00010";  -- Store

        wait for 30 ns;  -- 3 cicli: FETCH(corrente) → DECODE → EXECUTE → MEM_WB
        -- Adesso siamo in MEM_WB
        assert state_out = "11" report "Secondo giro: dovrebbe essere MEM_WB" severity error;
        assert mem_we = '1' report "MEM_WB con Store: mem_we deve essere 1" severity error;
        assert rd_write_en = '0' report "MEM_WB con Store: rd_write_en deve essere 0 (Store non scrive in regfile)" severity error;
        assert pc_load = '1' report "MEM_WB: pc_load deve essere 1" severity error;

        wait for 10 ns;  -- → FETCH

        ------------------------------------------------------------------
        -- 4) Terzo giro con op_class = Branch (B = "01000")
        --    In MEM_WB: rd_write_en='0' (Branch non scrive nemmeno lui), mem_we='0'
        ------------------------------------------------------------------
        op_class <= "01000";

        wait for 30 ns;  -- arriviamo in MEM_WB
        assert state_out = "11" severity error;
        assert mem_we = '0' report "MEM_WB con Branch: mem_we deve essere 0" severity error;
        assert rd_write_en = '0' report "MEM_WB con Branch: rd_write_en deve essere 0" severity error;
        assert pc_load = '1' report "MEM_WB: pc_load deve essere 1" severity error;

        wait for 10 ns;  -- → FETCH

        ------------------------------------------------------------------
        -- 5) Quarto giro con op_class = Load (L = "00100")
        --    In MEM_WB: rd_write_en='1' (Load scrive il dato in rd)
        ------------------------------------------------------------------
        op_class <= "00100";

        wait for 30 ns;
        assert state_out = "11" severity error;
        assert mem_we = '0' report "MEM_WB con Load: mem_we deve essere 0" severity error;
        assert rd_write_en = '1' report "MEM_WB con Load: rd_write_en deve essere 1" severity error;

        wait for 10 ns;

        ------------------------------------------------------------------
        -- 6) Quinto giro con op_class = Jump (J = "10000")
        --    In MEM_WB: rd_write_en='1' (JAL salva return address in rd)
        ------------------------------------------------------------------
        op_class <= "10000";

        wait for 30 ns;
        assert state_out = "11" severity error;
        assert rd_write_en = '1' report "MEM_WB con Jump: rd_write_en deve essere 1 (JAL scrive return address)" severity error;
        assert mem_we = '0' severity error;

        wait for 10 ns;

        ------------------------------------------------------------------
        -- 7) Reset durante esecuzione: ritorna a FETCH
        ------------------------------------------------------------------
        op_class <= "00001";
        wait for 20 ns;   -- siamo da qualche parte nel ciclo
        reset <= '1';
        wait for 10 ns;
        assert state_out = "00" report "Reset deve riportare a FETCH" severity error;

        report "tb_control_fsm: tutti i casi verificati" severity note;
        wait;
    end process;
end sim;
