----------------------------------------------------------------------------------
-- Module Name: control_fsm - Behavioral
-- Description: FSM di controllo a 4 stati per la CPU multi-cycle del prof.
--   Stati: FETCH → DECODE → EXECUTE → MEM_WB → FETCH → ...
--   Transizioni lineari, nessuna ramificazione.
--
--   Output Moore (dipendono solo dallo stato, modulo filtro op_class):
--     pc_load        = '1' solo in MEM_WB
--     mem_we         = '1' solo in MEM_WB se op_class indica Store
--     rd_write_en    = '1' solo in MEM_WB se op_class indica ALU op / Load / Jump
--     regfile_a_sel  = '1' in MEM_WB (porta A del regfile = rd), '0' altrove (rs1)
--
--   op_class one-hot 5 bit:
--     bit 0 = O (ALU op),  bit 1 = S (Store),  bit 2 = L (Load),
--     bit 3 = B (Branch),  bit 4 = J (Jump)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity control_fsm is
    port (
        clk           : in  std_logic;
        reset         : in  std_logic;
        op_class      : in  std_logic_vector(4 downto 0);  -- OSLBJ one-hot
        pc_load       : out std_logic;
        mem_we        : out std_logic;
        rd_write_en   : out std_logic;
        regfile_a_sel : out std_logic;
        -- Stato corrente esposto per debugging in simulation
        state_out     : out std_logic_vector(1 downto 0)
    );
end control_fsm;

architecture Behavioral of control_fsm is
    type state_t is (S_FETCH, S_DECODE, S_EXECUTE, S_MEM_WB);
    signal pstate, nstate : state_t := S_FETCH;
begin

    --------------------------------------------------------------------
    -- Process 1: registro di stato (sincrono)
    -- Reset sincrono porta la FSM in FETCH.
    --------------------------------------------------------------------
    state_reg: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pstate <= S_FETCH;
            else
                pstate <= nstate;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Process 2: next state + uscite (combinatorio)
    -- Default values in cima per evitare latch involontari.
    --------------------------------------------------------------------
    next_state: process(pstate, op_class)
    begin
        -- Default: tutte le uscite a '0', stato successivo = stato corrente
        nstate         <= pstate;
        pc_load        <= '0';
        mem_we         <= '0';
        rd_write_en    <= '0';
        regfile_a_sel  <= '0';

        case pstate is
            when S_FETCH =>
                nstate <= S_DECODE;
                -- regfile_a_sel = '0' (rs1): non rileva qui, ma per coerenza

            when S_DECODE =>
                nstate <= S_EXECUTE;
                -- regfile_a_sel = '0' (rs1): IMPORTANTE, qui leggiamo rs1 dal regfile

            when S_EXECUTE =>
                nstate <= S_MEM_WB;
                -- regfile_a_sel = '0' (rs1): l'output del regfile è già latched
                --                            quindi non importa che indirizzo è su a_addr ora

            when S_MEM_WB =>
                nstate <= S_FETCH;
                pc_load       <= '1';   -- al rising_edge: PC <= pc_in, FSM <= FETCH
                regfile_a_sel <= '1';   -- porta A del regfile = rd (per la scrittura)

                -- mem_we = '1' SOLO se l'istruzione è uno Store
                if op_class(1) = '1' then
                    mem_we <= '1';
                end if;

                -- rd_write_en = '1' SOLO se ALU op / Load / Jump
                -- (NON per Branch e NON per Store)
                if op_class(0) = '1' or op_class(2) = '1' or op_class(4) = '1' then
                    rd_write_en <= '1';
                end if;
        end case;
    end process;

    --------------------------------------------------------------------
    -- Encoding dello stato in 2 bit per il debug in simulation
    --------------------------------------------------------------------
    with pstate select
        state_out <= "00" when S_FETCH,
                     "01" when S_DECODE,
                     "10" when S_EXECUTE,
                     "11" when S_MEM_WB;

end Behavioral;
