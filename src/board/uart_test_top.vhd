----------------------------------------------------------------------------------
-- Module Name: uart_test_top - Behavioral
--
-- DEBUG-ONLY: NON e' parte del design finale.
--
-- Cosa fa
-- =======
-- Design minimale che bypassa completamente la CPU RISC-V e usa SOLO
-- il modulo uart_tx per spedire continuamente il carattere 'A' (0x41 ASCII)
-- via UART. Serve per isolare un bug nella catena fisica:
--
--     pin D4 (FPGA) ---> chip FT2232HQ ---> USB ---> driver Windows ---> PuTTY
--
-- Se PuTTY mostra "AAAAAAA..." in un fiume continuo, la catena UART funziona
-- e il bug era nel programma RISC-V o nel timing del polling UART_STATUS.
--
-- Se PuTTY NON mostra niente nemmeno con questo design, il problema e'
-- davvero fisico: pin D4 non collegato, chip FTDI canale UART disabilitato,
-- mismatch di voltage I/O bank, o scheda guasta.
--
-- Cosa fanno i LED
-- ================
--   LED 0 = "heartbeat" che cambia stato a ogni trigger UART
--           A 100 ms di periodo si vede lampeggiare a 5 Hz (visibile a occhio).
--           Se NON lampeggia, la logica VHDL e' bloccata in reset o non
--           sintetizzata correttamente.
--   LED 1 = tx_busy diretto. A 115200 baud un byte dura ~87 us, su 100 ms
--           e' un duty cycle dello 0.09% -> ad occhio sembrera' sempre
--           spento (normale).
--   LED 2..15 = sempre spenti.
--
-- Come usarlo in Vivado
-- =====================
--   1. Aggiungi questo file come Design Source.
--   2. Tasto destro su uart_test_top -> Set as Top.
--      Adesso il top di sintesi e' uart_test_top, NON nexys4ddr_top.
--   3. Run Synthesis -> Run Implementation -> Generate Bitstream.
--      Sara' rapidissimo (poca logica).
--   4. Program Device.
--   5. Apri PuTTY / TeraTerm su COM4 a 115200 8N1.
--   6. Premi CPU_RESET sulla scheda (oppure aspetta, parte da solo).
--   7. Osserva: LED 0 deve lampeggiare a 5 Hz E PuTTY deve mostrare 'A'
--      in modo continuo (~10 caratteri al secondo).
--
-- Quando hai finito il test, basta tornare su nexys4ddr_top come top
-- di sintesi e rigenerare il bitstream per ripristinare il design completo.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_test_top is
    port (
        -- Stesse identiche porte di nexys4ddr_top, cosi' lo stesso XDC
        -- continua a funzionare senza modifiche.
        clk         : in  std_logic;
        cpu_resetn  : in  std_logic;
        uart_tx_pin : out std_logic;
        led_out     : out std_logic_vector(15 downto 0);
        sw_in       : in  std_logic_vector(15 downto 0)   -- unused
    );
end uart_test_top;

architecture Behavioral of uart_test_top is

    -- Reset interno (active-high) — stesso pattern del wrapper principale
    signal reset_int : std_logic;

    -- Contatore per il timer di 100 ms.
    -- 100 ms a 100 MHz = 10_000_000 cicli -> 24 bit sono sufficienti.
    constant PERIOD_CYCLES : unsigned(23 downto 0) := to_unsigned(10_000_000, 24);
    signal counter         : unsigned(23 downto 0) := (others => '0');

    -- Impulso di 1 ciclo che pilota tx_start del modulo UART.
    signal tx_start_pulse : std_logic := '0';

    -- LED heartbeat: cambia stato a ogni tx_start_pulse.
    signal heartbeat : std_logic := '0';

    -- Segnali di interfaccia con uart_tx
    signal tx_busy : std_logic;

    -- Byte da trasmettere: 'A' = 0x41 = 65 decimale = "01000001"
    constant CHAR_A : std_logic_vector(7 downto 0) := x"41";

begin

    --------------------------------------------------------------------
    -- Inversione di polarita' del reset (CPU_RESETN e' active-low).
    --------------------------------------------------------------------
    reset_int <= not cpu_resetn;

    --------------------------------------------------------------------
    -- Generatore di trigger periodico.
    -- Ogni PERIOD_CYCLES cicli di clock (= 100 ms) emette un impulso
    -- di 1 ciclo su tx_start_pulse e toggla il LED heartbeat.
    --------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset_int = '1' then
                counter        <= (others => '0');
                tx_start_pulse <= '0';
                heartbeat      <= '0';
            else
                -- Default: nessun impulso
                tx_start_pulse <= '0';

                if counter = PERIOD_CYCLES - 1 then
                    counter        <= (others => '0');
                    tx_start_pulse <= '1';
                    heartbeat      <= not heartbeat;
                else
                    counter <= counter + 1;
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------------
    -- Istanza UART_TX (stesso modulo usato dal design completo).
    -- tx_data e' fissato a 'A'; tx_start arriva dal trigger periodico.
    --------------------------------------------------------------------
    u_uart: entity work.uart_tx
        generic map (
            CLK_HZ => 100_000_000,
            BAUD   =>     115_200
        )
        port map (
            clk      => clk,
            reset    => reset_int,
            tx_data  => CHAR_A,
            tx_start => tx_start_pulse,
            tx_pin   => uart_tx_pin,
            tx_busy  => tx_busy
        );

    --------------------------------------------------------------------
    -- LED di debug
    --------------------------------------------------------------------
    led_out(0)            <= heartbeat;             -- 5 Hz blink visibile
    led_out(1)            <= tx_busy;               -- impercettibile (~0.09% duty)
    led_out(15 downto 2)  <= (others => '0');       -- spenti

end Behavioral;
