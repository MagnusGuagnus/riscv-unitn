----------------------------------------------------------------------------------
-- Module Name: comparator - Behavioral
-- Description: Comparator per le istruzioni di branch (slide 18 del PDF prof).
--   Confronta rs1_value con rs2_value secondo cond_opcode (3 bit) e produce
--   branch_cond (1 bit, latched).
--
--   Encoding cond_opcode:
--     000  EQ   (rs1 == rs2)        BEQ
--     001  NEQ  (rs1 != rs2)        BNE
--     100  LT   (rs1 <  rs2 signed) BLT
--     101  GE   (rs1 >= rs2 signed) BGE
--     altri valori → branch_cond = '0' (mai preso)
--
--   Lavora SEMPRE (combinatorio interno), ma il suo risultato è usato
--   dal mux finale del PC solo quando op_class indica un branch.
--   L'output è registrato (latched) per essere disponibile alla fase MEM/WB.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity comparator is
    port (
        clk         : in  std_logic;
        rs1_value   : in  std_logic_vector(31 downto 0);
        rs2_value   : in  std_logic_vector(31 downto 0);
        cond_opcode : in  std_logic_vector(2 downto 0);
        branch_cond : out std_logic
    );
end comparator;

architecture Behavioral of comparator is
    signal cond_comb : std_logic;
begin
    -- Logica combinatoria del confronto
    process(rs1_value, rs2_value, cond_opcode)
    begin
        case cond_opcode is
            when "000" =>  -- EQ
                if rs1_value = rs2_value then cond_comb <= '1';
                else                          cond_comb <= '0';
                end if;
            when "001" =>  -- NEQ
                if rs1_value /= rs2_value then cond_comb <= '1';
                else                           cond_comb <= '0';
                end if;
            when "100" =>  -- LT (signed)
                if signed(rs1_value) < signed(rs2_value) then cond_comb <= '1';
                else                                          cond_comb <= '0';
                end if;
            when "101" =>  -- GE (signed)
                if signed(rs1_value) >= signed(rs2_value) then cond_comb <= '1';
                else                                           cond_comb <= '0';
                end if;
            when others =>
                -- 010, 011, 110, 111 → riservati / fuori subset → branch mai preso
                cond_comb <= '0';
        end case;
    end process;

    -- Latch sincrono: branch_cond del ciclo corrente è cond_comb del ciclo precedente.
    -- Allinea il risultato del comparator alla fine della fase EXECUTE,
    -- pronto per essere usato in MEM/WB dal mux finale del PC.
    process(clk)
    begin
        if rising_edge(clk) then
            branch_cond <= cond_comb;
        end if;
    end process;
end Behavioral;
