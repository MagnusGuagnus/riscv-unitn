----------------------------------------------------------------------------------
-- Module Name: regfile - Behavioral
-- Description: Register file 32 x 32 bit secondo la spec del prof (slide 16).
--   - Distributed RAM (Vivado lo inferisce dal pattern VHDL).
--   - Porta A: shared read/write
--       - Indirizzo a_addr scelto da un mux esterno tra rs1 (DECODE) e rd (MEM/WB)
--       - Scrittura sincrona (rising_edge) quando we='1'
--       - Lettura asincrona, output qspo
--   - Porta B (dpra): solo lettura asincrona da rs2_addr, output qdpo
--   - Output rs1_value e rs2_value sono LATCHED (registrati al rising_edge)
--     per essere stabili per tutta la fase EXECUTE / MEM-WB.
--   - x0 hardwired a 0: lettura sempre 0, scrittura ignorata.
--
--   Note: il mux sull'indirizzo della porta A è ESTERNO a questo modulo.
--   Il segnale a_addr arriva già "muxato" dalla cpu_top.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity regfile is
    port (
        clk        : in  std_logic;
        we         : in  std_logic;                       -- write enable porta A
        a_addr     : in  std_logic_vector(4 downto 0);    -- porta A: rs1 in DECODE, rd in MEM/WB (mux esterno)
        rs2_addr   : in  std_logic_vector(4 downto 0);    -- porta B: solo lettura
        rd_data    : in  std_logic_vector(31 downto 0);   -- dato da scrivere su porta A
        rs1_value  : out std_logic_vector(31 downto 0);   -- letto da porta A, latched
        rs2_value  : out std_logic_vector(31 downto 0)    -- letto da porta B, latched
    );
end regfile;

architecture Behavioral of regfile is
    type reg_array is array (0 to 31) of std_logic_vector(31 downto 0);
    signal regs : reg_array := (others => (others => '0'));

    -- Letture combinatorie dalla distributed RAM
    signal qspo, qdpo : std_logic_vector(31 downto 0);
begin
    --------------------------------------------------------------------
    -- Scrittura sincrona sulla porta A.
    -- x0 (indirizzo "00000") protetto: scrittura ignorata se a_addr=0.
    -- Questo è il pattern che Vivado riconosce per inferire distributed RAM:
    --   - 1 write port sincrona
    --   - le letture (sotto) sono asincrone
    --   - array piccolo (32 × 32)
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if we = '1' and a_addr /= "00000" then
                regs(to_integer(unsigned(a_addr))) <= rd_data;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Letture asincrone (combinatorie). Sono i due output "raw" dalla
    -- distributed RAM, non ancora latched.
    -- x0 hardwired a 0: se l'indirizzo è 0, l'output è forzato a 0
    -- indipendentemente dal contenuto di regs(0).
    --------------------------------------------------------------------
    qspo <= (others => '0') when a_addr   = "00000"
            else regs(to_integer(unsigned(a_addr)));

    qdpo <= (others => '0') when rs2_addr = "00000"
            else regs(to_integer(unsigned(rs2_addr)));

    --------------------------------------------------------------------
    -- Latch sincrono sulle uscite, allinea i dati alla fine di DECODE.
    -- rs1_value e rs2_value restano stabili per tutta la fase EXECUTE
    -- e MEM-WB anche se nel frattempo a_addr cambia (es. passa da rs1 a rd
    -- per la futura scrittura).
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rs1_value <= qspo;
            rs2_value <= qdpo;
        end if;
    end process;

end Behavioral;
