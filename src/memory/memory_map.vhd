----------------------------------------------------------------------------------
-- Module Name: memory_map - Behavioral
-- Description: Bus memory-mapped della CPU multi-cycle.
--   Wrapper che istanzia DMEM + UART_TX + GPIO e fa il routing in base a
--   alcuni bit dell'indirizzo (alu_pre_result).
--
--   Memory map (autoritativa, da docs/peripherals_overview.md):
--     DMEM        0x0000_0000 – 0x0000_3FFF   (16 kB, BRAM)   bit[16]=0
--     UART_DATA   0x0001_0000  (W)            bit[16]=1, bit[3]=0, bit[2]=0
--     UART_STATUS 0x0001_0004  (R, bit 0 = ready)             bit[16]=1, bit[3]=0, bit[2]=1
--     GPIO_LED    0x0001_0008  (W)            bit[16]=1, bit[3]=1, bit[2]=0
--     GPIO_SW     0x0001_000C  (R)            bit[16]=1, bit[3]=1, bit[2]=1
--
--   Address decoder (logica combinatoria):
--     sel_periph    = addr[16]   (0=DMEM, 1=periferiche)
--     sel_uart_gpio = addr[3]    (0=UART, 1=GPIO)
--     sel_reg       = addr[2]    (0=data/LED, 1=status/SW)
--
--   Routing del write enable (mutuamente esclusivi per costruzione):
--     dmem_we       = we AND sel_periph='0'
--     uart_tx_start = we AND sel_periph='1' AND sel_uart_gpio='0' AND sel_reg='0'
--     gpio_we       = we AND sel_periph='1' AND sel_uart_gpio='1' AND sel_reg='0'
--
--   Mux di dout (lettura):
--     sel_periph='0'                                → dmem.dout
--     sel_uart_gpio='0' AND sel_reg='1' (UART_STATUS) → bit 0 = NOT uart.tx_busy
--     sel_uart_gpio='1' AND sel_reg='1' (GPIO_SW)     → x"0000" & gpio.sw_value
--     altrimenti                                       → (others => '0')
--
--   Latenza: il modulo presenta la stessa latenza della DMEM (output
--   disponibile 1 ciclo dopo l'indirizzo). Le periferiche sono già
--   registrate internamente (uart_tx_busy e gpio.sw_value vengono da FF),
--   quindi il mux combinatorio è OK: in MEM/WB l'indirizzo è stabile e
--   il dout di lettura è valido.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity memory_map is
    generic (
        -- Propagati alla UART per facilitare la simulazione.
        -- In synth: 100 MHz / 115200 → BAUD_DIV = 868.
        CLK_HZ : integer := 100_000_000;
        BAUD   : integer := 115_200
    );
    port (
        clk      : in  std_logic;
        reset    : in  std_logic;
        -- Interfaccia verso la CPU (lato datapath)
        addr     : in  std_logic_vector(31 downto 0);   -- alu_pre_result
        we       : in  std_logic;                        -- mem_we dalla FSM
        din      : in  std_logic_vector(31 downto 0);    -- rs2_value
        dout     : out std_logic_vector(31 downto 0);    -- mem_out verso il regfile
        -- Interfaccia verso la scheda (lato pin esterni)
        uart_tx_pin : out std_logic;
        led_out     : out std_logic_vector(15 downto 0);
        sw_in       : in  std_logic_vector(15 downto 0)
    );
end memory_map;

architecture Behavioral of memory_map is
    --------------------------------------------------------------------
    -- Address decoder: selettori derivati da addr (combinatorio)
    --------------------------------------------------------------------
    signal sel_periph    : std_logic;
    signal sel_uart_gpio : std_logic;
    signal sel_reg       : std_logic;

    --------------------------------------------------------------------
    -- Routing del write enable (mutuamente esclusivi)
    --------------------------------------------------------------------
    signal dmem_we       : std_logic;
    signal uart_tx_start : std_logic;
    signal gpio_we       : std_logic;

    --------------------------------------------------------------------
    -- Segnali interni di interconnessione
    --------------------------------------------------------------------
    signal dmem_dout     : std_logic_vector(31 downto 0);
    signal uart_tx_busy  : std_logic;
    signal gpio_sw_value : std_logic_vector(15 downto 0);

begin

    --------------------------------------------------------------------
    -- 1) Address decoder (3 fili)
    --------------------------------------------------------------------
    sel_periph    <= addr(16);
    sel_uart_gpio <= addr(3);
    sel_reg       <= addr(2);

    --------------------------------------------------------------------
    -- 2) Distribuzione del write enable.
    --   Per costruzione, al massimo uno di questi 3 segnali è '1' in
    --   qualsiasi istante.
    --------------------------------------------------------------------
    dmem_we <= we when sel_periph = '0' else '0';

    uart_tx_start <= we when (sel_periph    = '1'
                          and sel_uart_gpio = '0'
                          and sel_reg       = '0') else '0';

    gpio_we <= we when (sel_periph    = '1'
                    and sel_uart_gpio = '1'
                    and sel_reg       = '0') else '0';

    --------------------------------------------------------------------
    -- 3) Istanziazione DMEM
    --   Indirizzo word-level: bit [13:2] di addr (= 12 bit = 4096 word).
    --------------------------------------------------------------------
    u_dmem: entity work.data_memory
        port map (
            clk  => clk,
            we   => dmem_we,
            addr => addr(13 downto 2),
            din  => din,
            dout => dmem_dout
        );

    --------------------------------------------------------------------
    -- 4) Istanziazione UART TX
    --   tx_data prende gli 8 bit bassi di din (rs2_value[7:0]).
    --   tx_start è un impulso di 1 ciclo quando la CPU fa "sw" su UART_DATA.
    --------------------------------------------------------------------
    u_uart: entity work.uart_tx
        generic map (
            CLK_HZ => CLK_HZ,
            BAUD   => BAUD
        )
        port map (
            clk      => clk,
            reset    => reset,
            tx_data  => din(7 downto 0),
            tx_start => uart_tx_start,
            tx_pin   => uart_tx_pin,
            tx_busy  => uart_tx_busy
        );

    --------------------------------------------------------------------
    -- 5) Istanziazione GPIO
    --   din prende i 16 bit bassi di rs2_value (i LED sono 16 bit).
    --   sw_in viene dai pin fisici della scheda (passa attraverso il
    --   synchronizer 2-stadi interno al modulo gpio).
    --------------------------------------------------------------------
    u_gpio: entity work.gpio
        port map (
            clk      => clk,
            reset    => reset,
            we       => gpio_we,
            din      => din(15 downto 0),
            led_out  => led_out,
            sw_in    => sw_in,
            sw_value => gpio_sw_value
        );

    --------------------------------------------------------------------
    -- 6) Mux di dout (read path)
    --   Restituisce alla CPU il dato letto dalla "regione" indirizzata.
    --   UART_STATUS: bit 0 = '1' se UART pronta a trasmettere
    --                       = '0' se UART occupata
    --                Si usa NOT uart_tx_busy.
    --                Gli altri 31 bit alti sono zero.
    --   GPIO_SW    : zero-extension a 32 bit del valore sincronizzato
    --                degli switch.
    --   Altri indirizzi non mappati ritornano zero.
    --------------------------------------------------------------------
    dout <= dmem_dout
              when sel_periph = '0'
       else (31 downto 1 => '0') & (not uart_tx_busy)
              when (sel_periph = '1' and sel_uart_gpio = '0' and sel_reg = '1')
       else x"0000" & gpio_sw_value
              when (sel_periph = '1' and sel_uart_gpio = '1' and sel_reg = '1')
       else (others => '0');

end Behavioral;
