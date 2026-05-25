----------------------------------------------------------------------------------
-- Testbench: tb_cpu_system
-- Verifica end-to-end della CPU multi-cycle che esegue il programmino precaricato
-- nella IMEM (6 istruzioni):
--   0: addi x1, x0, 5      → x1 = 5
--   1: addi x2, x0, 3      → x2 = 3
--   2: add  x3, x1, x2     → x3 = 8
--   3: sw   x3, 0(x0)      → DMEM[0] = 8
--   4: lw   x4, 0(x0)      → x4 = DMEM[0] = 8
--   5: jal  x0, 0          → loop infinito (halt)
--
-- Ogni istruzione dura 4 cicli. Per arrivare oltre la LW:
--   reset (1 ciclo) + 6 istruzioni × 4 cicli = ~25 cicli.
-- Eseguiamo per 60 cicli per essere comodi e vedere il loop infinito di JAL.
--
-- Cosa controllare nelle waveform:
--   - dbg_pc: deve scorrere 0x000, 0x004, 0x008, 0x00C, 0x010, 0x014, poi
--             restare fisso a 0x014 (perché JAL salta a sé stesso).
--   - dbg_state: cicla 00 (FETCH) → 01 (DECODE) → 10 (EXECUTE) → 11 (MEM_WB) → 00 ...
--   - dbg_instr: l'istruzione corrente in fase DECODE (=letta dalla IMEM).
--   - dbg_alu_result: dopo ogni EXECUTE mostra il risultato dell'ALU
--                      (5, 3, 8, 0, 0, 0x014 per JAL target).
--   - dbg_mem_out: dopo l'esecuzione della LW, deve essere 0x00000008.
--   - dbg_rd_value: durante MEM_WB della LW (~ciclo 22), deve essere 0x00000008.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_cpu_system is
end tb_cpu_system;

architecture sim of tb_cpu_system is
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    -- Nuovi pin esterni (post Fase B): non li usiamo in questo TB di core,
    -- ma vanno cablati per compilare. sw_in tenuto a 0, gli output lasciati
    -- non controllati (verranno verificati in tb_cpu_peripherals).
    signal uart_tx_pin    : std_logic;
    signal led_out        : std_logic_vector(15 downto 0);
    signal sw_in          : std_logic_vector(15 downto 0) := (others => '0');
    signal dbg_pc         : std_logic_vector(11 downto 0);
    signal dbg_instr      : std_logic_vector(31 downto 0);
    signal dbg_state      : std_logic_vector(1 downto 0);
    signal dbg_alu_result : std_logic_vector(31 downto 0);
    signal dbg_mem_out    : std_logic_vector(31 downto 0);
    signal dbg_rd_value   : std_logic_vector(31 downto 0);
begin
    uut: entity work.cpu_top
        port map (
            clk            => clk,
            reset          => reset,
            uart_tx_pin    => uart_tx_pin,
            led_out        => led_out,
            sw_in          => sw_in,
            dbg_pc         => dbg_pc,
            dbg_instr      => dbg_instr,
            dbg_state      => dbg_state,
            dbg_alu_result => dbg_alu_result,
            dbg_mem_out    => dbg_mem_out,
            dbg_rd_value   => dbg_rd_value
        );

    -- Clock 100 MHz (period 10 ns)
    clk <= not clk after 5 ns;

    stim: process
    begin
        ------------------------------------------------------------------
        -- 1) Reset per 2 cicli
        ------------------------------------------------------------------
        reset <= '1';
        wait for 20 ns;
        assert dbg_pc = x"000" report "Dopo reset, PC deve essere 0" severity error;
        assert dbg_state = "00" report "Dopo reset, stato deve essere FETCH" severity error;

        ------------------------------------------------------------------
        -- 2) Rilascia reset, aspetta che la LW arrivi in MEM_WB.
        --    Conteggio (clock 10 ns, FSM 4-stati):
        --      reset rilasciato a t=20, primo rising "utile" a t=25.
        --      istr 0 (ADDI): 25-65 ns
        --      istr 1 (ADDI): 65-105 ns
        --      istr 2 (ADD):  105-145 ns
        --      istr 3 (SW):   145-185 ns
        --      istr 4 (LW):   185-225 ns
        --        - DECODE 185-195, EXEC 195-205, MEM_WB 205-215.
        --    Dopo t=225 inizia la JAL e dbg_rd_value diventa next_pc_32.
        --    Quindi campioniamo a t=210 ns: piena MEM_WB della LW,
        --    rd_value = mem_out = 8.
        ------------------------------------------------------------------
        reset <= '0';
        wait for 190 ns;   -- arrivo a t = 210 ns, dentro MEM_WB della LW

        ------------------------------------------------------------------
        -- 3) A questo punto la LW ha letto DMEM[0] e dbg_rd_value mostra 8.
        --    Verifichiamolo PRIMA che la JAL avanzi e cambi rd_value.
        ------------------------------------------------------------------
        assert dbg_rd_value = x"00000008"
            report "LW: rd_value dovrebbe essere 0x8 (= 5+3 letto da DMEM[0])"
            severity error;

        ------------------------------------------------------------------
        -- 4) Continua l'esecuzione: JAL entrera' nel suo loop infinito
        ------------------------------------------------------------------
        wait for 400 ns;

        ------------------------------------------------------------------
        -- 5) PC fermo a 0x014 (= indirizzo JAL all'offset 5*4=20)
        --    perche' JAL salta su se stesso (loop infinito = halt).
        ------------------------------------------------------------------
        assert dbg_pc = x"014"
            report "PC dovrebbe essere fermo a 0x014 (loop JAL)" severity error;

        report "tb_cpu_system: programma eseguito correttamente" severity note;
        report "PC fermo su JAL, LW ha letto 8 da DMEM[0]" severity note;
        report "Controlla le waveform per dettagli sui 4 stati FSM" severity note;

        wait;
    end process;

end sim;
