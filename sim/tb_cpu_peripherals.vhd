----------------------------------------------------------------------------------
-- Testbench: tb_cpu_peripherals
-- Verifica end-to-end del sistema CPU + memory_map + UART + GPIO che esegue
-- il programma "Hello World" precaricato in IMEM (PROGRAM_SEL=1).
--
-- Strategia:
--   - Istanzia cpu_top con BAUD_DIV=4 (CLK_HZ=100M, BAUD=25M) per simulare veloce.
--   - Un process "stim" gestisce reset e verifica gli output LED e UART idle.
--   - Un process "rx_sniffer" funge da mini-UART receiver: osserva tx_pin,
--     riconosce gli start bit, campiona 8 bit a metà di ogni bit-period
--     (oversampling 1x, sufficiente in sim) e accumula i byte in rx_buffer.
--
-- Cosa il programma deve produrre:
--   1. led_out → 0x000F  (4 LED bassi accesi, "in esecuzione")
--   2. UART trasmette in ordine: 0x48 'H', 0x65 'e', 0x6C 'l', 0x6C 'l', 0x6F 'o'
--   3. led_out → 0x0055  (pattern finale, "stringa inviata")
--   4. PC fermo a 0x48 (= jal x0, 0 = halt)
--
-- Tempistiche stimate (con BAUD_DIV=4, 10 ns/clock):
--   - Setup CPU + LED iniziali:  ~ 400 ns
--   - Send loop 5 byte:          ~ 3000 ns
--   - LED finale + halt:         ~ 100 ns
--   - Ultima TX UART completa:   ~ 400 ns
--   Totale ~ 4 µs; il tb simula fino a 8 µs per margine.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_cpu_peripherals is
end tb_cpu_peripherals;

architecture sim of tb_cpu_peripherals is
    --------------------------------------------------------------------
    -- Parametri di simulazione
    --------------------------------------------------------------------
    constant CLK_PERIOD   : time    := 10 ns;
    constant BAUD_DIV_SIM : integer := 4;
    constant BIT_PERIOD   : time    := BAUD_DIV_SIM * CLK_PERIOD;  -- 40 ns

    --------------------------------------------------------------------
    -- Segnali DUT
    --------------------------------------------------------------------
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal uart_tx_pin    : std_logic;
    signal led_out        : std_logic_vector(15 downto 0);
    signal sw_in          : std_logic_vector(15 downto 0) := (others => '0');
    signal dbg_pc         : std_logic_vector(11 downto 0);
    signal dbg_instr      : std_logic_vector(31 downto 0);
    signal dbg_state      : std_logic_vector(1 downto 0);
    signal dbg_alu_result : std_logic_vector(31 downto 0);
    signal dbg_mem_out    : std_logic_vector(31 downto 0);
    signal dbg_rd_value   : std_logic_vector(31 downto 0);

    --------------------------------------------------------------------
    -- Buffer per i byte catturati dall'UART RX sniffer
    --------------------------------------------------------------------
    type byte_array is array (0 to 4) of std_logic_vector(7 downto 0);
    signal rx_buffer  : byte_array := (others => x"00");
    signal rx_count   : integer range 0 to 5 := 0;

    --------------------------------------------------------------------
    -- Stringa attesa "Hello" (ASCII)
    --------------------------------------------------------------------
    constant EXPECTED : byte_array := (
        0 => x"48",   -- 'H'
        1 => x"65",   -- 'e'
        2 => x"6C",   -- 'l'
        3 => x"6C",   -- 'l'
        4 => x"6F"    -- 'o'
    );

begin
    --------------------------------------------------------------------
    -- DUT: CPU completa con generic per BAUD veloce e PROGRAM_SEL = Hello.
    --------------------------------------------------------------------
    uut: entity work.cpu_top
        generic map (
            CLK_HZ      => 100_000_000,
            BAUD        =>  25_000_000,   -- → BAUD_DIV = 4
            PROGRAM_SEL => 1              -- Hello World
        )
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

    -- Clock 100 MHz
    clk <= not clk after CLK_PERIOD / 2;

    --------------------------------------------------------------------
    -- Process di stimolo + verifica finale
    --------------------------------------------------------------------
    stim: process
    begin
        ----------------------------------------------------------------
        -- 1) Reset per 3 cicli
        ----------------------------------------------------------------
        reset <= '1';
        wait for 3 * CLK_PERIOD;
        reset <= '0';
        report "[1] Reset rilasciato, CPU parte" severity note;

        ----------------------------------------------------------------
        -- 2) Aspetta che la CPU esegua le 8 istruzioni di setup
        --    (3 lw + 3 addi + 1 addi + 1 sw GPIO_LED).
        --    A 4 cicli/istr × 10 ns = 320 ns + qualche margine.
        ----------------------------------------------------------------
        wait for 500 ns;
        assert led_out = x"000F"
            report "[2] led_out atteso 0x000F (setup completato, 4 LED bassi)"
            severity error;
        report "[2] LED iniziale 0x000F OK" severity note;

        ----------------------------------------------------------------
        -- 3) Lascia girare il send loop completo + halt.
        --    Stimato ~4 µs totali → aspetto fino a 7 µs per essere abbondante.
        ----------------------------------------------------------------
        wait for 6500 ns;

        ----------------------------------------------------------------
        -- 4) Verifica stato finale
        ----------------------------------------------------------------
        assert led_out = x"0055"
            report "[4] led_out finale atteso 0x0055"
            severity error;

        assert uart_tx_pin = '1'
            report "[4] uart_tx_pin atteso '1' (UART idle a fine programma)"
            severity error;

        assert dbg_pc = x"048"
            report "[4] dbg_pc atteso 0x048 (halt jal x0, 0 alla word 18)"
            severity error;

        report "[4] Stato finale OK: LED=0x0055, UART idle, PC fermo su halt"
            severity note;

        ----------------------------------------------------------------
        -- 5) Verifica buffer UART: deve contenere "Hello"
        ----------------------------------------------------------------
        assert rx_count = 5
            report "[5] rx_count atteso = 5 (5 byte catturati)" severity error;

        assert rx_buffer(0) = EXPECTED(0)
            report "[5] byte 0 atteso 'H' (0x48)" severity error;
        assert rx_buffer(1) = EXPECTED(1)
            report "[5] byte 1 atteso 'e' (0x65)" severity error;
        assert rx_buffer(2) = EXPECTED(2)
            report "[5] byte 2 atteso 'l' (0x6C)" severity error;
        assert rx_buffer(3) = EXPECTED(3)
            report "[5] byte 3 atteso 'l' (0x6C)" severity error;
        assert rx_buffer(4) = EXPECTED(4)
            report "[5] byte 4 atteso 'o' (0x6F)" severity error;

        report "[5] UART buffer = 'Hello' OK" severity note;

        ----------------------------------------------------------------
        report "tb_cpu_peripherals: Hello World eseguito correttamente"
            severity note;
        wait;
    end process;

    --------------------------------------------------------------------
    -- UART RX sniffer: process che osserva uart_tx_pin e ricostruisce
    -- i byte trasmessi. Strategia "8N1, oversampling 1x":
    --   1. Aspetta che tx_pin scenda a '0' (start bit).
    --   2. Attende metà bit-period per centrare lo slot.
    --   3. Verifica che siamo ancora a '0' (filtraggio di glitch).
    --   4. Avanza di un bit-period per arrivare al centro di bit 0.
    --   5. Campiona 8 bit consecutivi (LSB first), uno ogni bit-period.
    --   6. Verifica che il stop bit sia '1'.
    --   7. Salva il byte nel buffer e ricomincia.
    --
    -- Il process continua indefinitamente; rx_count limita il salvataggio
    -- ai primi 5 byte (oltre, il process continua a girare ma non scrive).
    --------------------------------------------------------------------
    rx_sniffer: process
        variable byte_recv : std_logic_vector(7 downto 0);
    begin
        wait until uart_tx_pin = '0';        -- start bit detected
        wait for BIT_PERIOD / 2;             -- centro dello start bit
        assert uart_tx_pin = '0'
            report "rx_sniffer: start bit non confermato a metà slot"
            severity warning;

        wait for BIT_PERIOD;                 -- centro del bit 0
        for i in 0 to 7 loop
            byte_recv(i) := uart_tx_pin;
            wait for BIT_PERIOD;
        end loop;

        -- Adesso siamo al centro dello stop bit
        assert uart_tx_pin = '1'
            report "rx_sniffer: stop bit mancante (atteso '1')"
            severity warning;

        if rx_count < 5 then
            rx_buffer(rx_count) <= byte_recv;
            rx_count <= rx_count + 1;
        end if;
    end process;

end sim;
