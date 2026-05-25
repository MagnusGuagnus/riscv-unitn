----------------------------------------------------------------------------------
-- Module Name : nexys4ddr_top - Behavioral
--
-- PERCHE' ESISTE QUESTO FILE
-- ===========================
-- "nexys4ddr_top" e' un WRAPPER (un involucro) che istanzia "cpu_top"
-- e fa solo "adattamento" tra il mondo della scheda Nexys4 DDR e il
-- mondo astratto della CPU.
--
-- La CPU (cpu_top) e' stata scritta per essere "board-agnostic":
--   - reset attivo-alto
--   - default PROGRAM_SEL = 0 (programma di test del core, Fase A)
--   - 6 porte di debug (dbg_pc, dbg_instr, ...) utili in simulazione
--
-- La scheda Nexys4 DDR invece impone vincoli fisici suoi:
--   - il bottone "CPU RESET" e' cablato attivo-BASSO (active-low)
--   - serve un programma che faccia qualcosa di visibile (Hello World)
--   - le 6 porte di debug richiederebbero 142 pin fisici inesistenti
--
-- Questo wrapper risolve i tre disallineamenti in un unico posto,
-- lasciando cpu_top intatto e simulabile senza modifiche.
--
-- VANTAGGI ARCHITETTURALI DI QUESTA SCELTA
-- ========================================
--   1. cpu_top resta "pulita" e portabile: se domani volessimo portare
--      il design su una board diversa (Zedboard, Basys3, ecc.) basta
--      scrivere un nuovo wrapper "<nuova_board>_top.vhd" con la sua
--      polarita' di reset e la sua mappatura di pin. cpu_top non cambia.
--
--   2. Tutti i testbench gia' scritti continuano a usare cpu_top
--      direttamente, con le sue porte dbg_* per gli assert in waveform.
--      Non servono trucchi (alias VHDL-2008 / external names).
--
--   3. La separazione "CPU core" <-> "board adapter" e' lo standard
--      industriale per i progetti FPGA. Pattern che il prof riconoscera'.
--
-- COSA FA QUESTO WRAPPER, IN CONCRETO
-- ===================================
--   a) Inversione di polarita' del reset:
--          reset_internal <= NOT cpu_resetn;
--      Il bottone fisico vale '0' quando premuto; la CPU vuole '1' per
--      resettare. Una sola porta NOT risolve il conflitto.
--
--   b) Selezione del programma:
--          PROGRAM_SEL => 1     (Hello World)
--      Forziamo il generic della CPU al valore "demo per board".
--
--   c) Scollegamento delle porte di debug:
--          dbg_pc => open, dbg_instr => open, ...
--      "open" e' la keyword VHDL per dire "questa porta in uscita non
--      la collego da nessuna parte". Vivado capisce e durante la sintesi
--      elimina la logica associata (dead-code elimination), liberando
--      risorse e azzerando i pin richiesti.
--
-- COME SI INTEGRA NEL FLUSSO DI BUILD
-- ===================================
--   - Per la SIMULAZIONE: il top continua a essere il testbench corrispondente
--     (tb_cpu_system o tb_cpu_peripherals), che istanzia direttamente cpu_top.
--     Questo wrapper NON viene istanziato in simulazione (e va bene cosi').
--
--   - Per la SINTESI verso scheda Nexys4 DDR: il top di sintesi e' QUESTO file,
--     non cpu_top. In Vivado: tasto destro su nexys4ddr_top.vhd nel pannello
--     Sources -> "Set as Top". Solo a questo punto l'XDC (che usa i nomi
--     clk/cpu_resetn/uart_tx_pin/led_out/sw_in) si aggancia correttamente.
--
-- DIAGRAMMA DELLA GERARCHIA
-- =========================
--                                      Mondo della scheda Nexys4 DDR
--           ┌────────────────────────────────────────────────────────────┐
--           │  pin E3 (clock 100 MHz)                                    │
--           │  pin C12 (CPU_RESETN button, active-low)                   │
--           │  pin D4  (UART TX verso chip USB-UART → terminale PC)      │
--           │  16 pin (LED0..LED15)                                      │
--           │  16 pin (SW0..SW15)                                        │
--           └─────────────────┬──────────────────────────────────────────┘
--                             │ (constraints/NEXYS4DDR.xdc associa pin
--                             │  fisici alle porte qui sotto)
--           ┌─────────────────▼──────────────────────────────────────────┐
--           │  nexys4ddr_top  (QUESTO FILE)                              │
--           │  - inverte cpu_resetn -> reset_int                         │
--           │  - forza PROGRAM_SEL = 1 (Hello World)                     │
--           │  - lascia dbg_* "open"                                     │
--           └─────────────────┬──────────────────────────────────────────┘
--                             │
--           ┌─────────────────▼──────────────────────────────────────────┐
--           │  cpu_top  (intatto, board-agnostic)                        │
--           │  - reset active-high                                       │
--           │  - integra core (alu, regfile, decoder, fsm, memorie)      │
--           │  - integra memory_map + UART TX + GPIO                     │
--           └────────────────────────────────────────────────────────────┘
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity nexys4ddr_top is
    port (
        -- Clock di sistema: 100 MHz dall'oscillatore on-board (pin E3)
        clk         : in  std_logic;

        -- Reset attivo-basso dal bottone rosso "CPU RESET" (pin C12).
        -- A riposo (bottone non premuto) vale '1'. Premuto vale '0'.
        cpu_resetn  : in  std_logic;

        -- TX UART verso il chip USB-UART FTDI (pin D4). 115200 baud 8N1.
        -- Si vedra' sul terminale PC (PuTTY/TeraTerm) come byte ricevuti
        -- sulla porta COM virtuale creata dal driver FTDI.
        uart_tx_pin : out std_logic;

        -- 16 LED bianchi della board (LD0..LD15)
        led_out     : out std_logic_vector(15 downto 0);

        -- 16 slide switch (SW0..SW15)
        sw_in       : in  std_logic_vector(15 downto 0)
    );
end nexys4ddr_top;

architecture Behavioral of nexys4ddr_top is

    -- Segnale interno: reset attivo-alto da passare a cpu_top
    signal reset_int : std_logic;

begin

    --------------------------------------------------------------------
    -- Inversione di polarita' del reset.
    -- Una sola NOT, un solo posto: tutto il resto del design vede
    -- un reset attivo-alto "tradizionale".
    --------------------------------------------------------------------
    reset_int <= not cpu_resetn;

    --------------------------------------------------------------------
    -- Istanza della CPU.
    -- Generic forzati per la configurazione di demo su scheda:
    --   - CLK_HZ = 100_000_000 : si propaga al divisore baud della UART
    --   - BAUD   = 115_200     : standard PuTTY/TeraTerm
    --   - PROGRAM_SEL = 1      : carica in IMEM il programma Hello World
    --
    -- Le 6 porte di debug (dbg_*) sono lasciate "open" perche' qui non
    -- servono e in sintesi richiederebbero pin fisici che non abbiamo.
    -- Vivado elimina la logica associata in fase di optimization.
    --------------------------------------------------------------------
    u_cpu: entity work.cpu_top
        generic map (
            CLK_HZ      => 100_000_000,
            BAUD        =>     115_200,
            PROGRAM_SEL =>           1
        )
        port map (
            clk            => clk,
            reset          => reset_int,
            uart_tx_pin    => uart_tx_pin,
            led_out        => led_out,
            sw_in          => sw_in,
            dbg_pc         => open,
            dbg_instr      => open,
            dbg_state      => open,
            dbg_alu_result => open,
            dbg_mem_out    => open,
            dbg_rd_value   => open
        );

end Behavioral;
