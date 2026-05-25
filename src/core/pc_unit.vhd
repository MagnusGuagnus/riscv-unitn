----------------------------------------------------------------------------------
-- Module Name: pc_unit - Behavioral
-- Description: Program Counter unit per la CPU multi-cycle.
--   Contiene:
--     - Registro PC 12 bit, sincrono, con load enable e reset asincrono.
--     - Adder combinatorio per calcolare next_pc = pc + 4.
--     - Estrazione di pc[11:2] (10 bit) per indirizzare la BRAM IMEM
--       (la IMEM è word-addressable: 1024 word × 4 byte = 4 kB).
--
--   Inputs:
--     clk      : clock di sistema
--     reset    : reset sincrono (mette pc a 0)
--     load_en  : se '1', al prossimo rising_edge pc <= pc_in
--     pc_in    : nuovo valore di PC, scelto fuori dal modulo dal mux
--                finale (next_pc per istruzioni sequenziali, alu_result
--                per branch presi e jump).
--
--   Outputs:
--     pc       : valore corrente del PC (12 bit, byte-level).
--     next_pc  : pc + 4 combinatorio (per il mux finale e per JAL).
--     pc_word  : pc[11:2], 10 bit, da connettere ad addra della IMEM.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pc_unit is
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        load_en  : in  std_logic;
        pc_in    : in  std_logic_vector(11 downto 0);
        pc       : out std_logic_vector(11 downto 0);
        next_pc  : out std_logic_vector(11 downto 0);
        pc_word  : out std_logic_vector(9 downto 0)
    );
end pc_unit;

architecture Behavioral of pc_unit is
    signal pc_reg : std_logic_vector(11 downto 0) := (others => '0');
begin
    -- Registro PC: aggiornamento sincrono.
    -- Reset sincrono mette pc a 0 (la CPU ricomincia dall'istruzione 0).
    -- Senza load_en, il PC mantiene il valore precedente (è il caso delle
    -- fasi DECODE/EXECUTE/MEM-WB in cui non vogliamo che il PC cambi).
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pc_reg <= (others => '0');
            elsif load_en = '1' then
                pc_reg <= pc_in;
            end if;
        end if;
    end process;

    -- Output del PC corrente
    pc <= pc_reg;

    -- next_pc = pc + 4, combinatorio. Sempre disponibile.
    next_pc <= std_logic_vector(unsigned(pc_reg) + to_unsigned(4, 12));

    -- pc_word: i 10 bit superiori, indirizzo word per la BRAM IMEM.
    -- I 2 bit bassi sono sempre 0 perché le istruzioni RISC-V sono allineate a 4 byte.
    pc_word <= pc_reg(11 downto 2);

end Behavioral;
