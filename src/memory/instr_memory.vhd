----------------------------------------------------------------------------------
-- Module Name: instr_memory - Behavioral
-- Description: Instruction Memory secondo la spec del prof (slide 14).
--   - BRAM sincrona 1024 × 32 bit (4 kB).
--   - Indirizzo: 10 bit (word-level), corrisponde a pc[11:2].
--   - Lettura sincrona: l'istruzione esce 1 ciclo dopo che addr è applicato.
--   - Read-only durante l'esecuzione (mai scritta dalla CPU).
--
--   Programmi disponibili (selezionati con generic PROGRAM_SEL):
--
--     PROGRAM_SEL = 0  (default) — programma di test core Fase A
--       Test minimo del datapath. Calcola 5+3=8, lo scrive in DMEM[0],
--       lo rilegge, poi halt. Usato da tb_cpu_system.vhd.
--
--     PROGRAM_SEL = 1 — Hello World su UART + LED pattern
--       Carica indirizzi periferiche da DMEM[0..2], accende 4 LED bassi
--       (0x000F), spedisce 'H','e','l','l','o' via UART con polling
--       di UART_STATUS, infine accende pattern 0x0055 sui LED e halt.
--       Usato da tb_cpu_peripherals.vhd.
--
--     PROGRAM_SEL = 2 — DEBUG: spara una singola 'X' via UART, poi halt
--       Programma minimale (4 istruzioni) per isolare il bug della Fase 3
--       (CPU completa Hello ma niente arriva al PC). Niente polling
--       UART_STATUS, niente loop: la UART e' ready dopo reset, quindi
--       la sw immediata parte di sicuro.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity instr_memory is
    generic (
        -- 0 = programma Fase A (test core), 1 = Hello World (Fase B demo)
        PROGRAM_SEL : integer := 0
    );
    port (
        clk         : in  std_logic;
        re          : in  std_logic := '1';
        addr        : in  std_logic_vector(9 downto 0);
        instruction : out std_logic_vector(31 downto 0)
    );
end instr_memory;

architecture Behavioral of instr_memory is
    type rom_t is array (0 to 1023) of std_logic_vector(31 downto 0);

    --------------------------------------------------------------------
    -- PROGRAM A (PROGRAM_SEL = 0) — test di base del core
    --   0: addi x1, x0, 5      → x1 = 5
    --   1: addi x2, x0, 3      → x2 = 3
    --   2: add  x3, x1, x2     → x3 = 8
    --   3: sw   x3, 0(x0)      → DMEM[0] = 8
    --   4: lw   x4, 0(x0)      → x4 = DMEM[0] = 8
    --   5: jal  x0, 0          → loop infinito (halt)
    --------------------------------------------------------------------
    constant PROGRAM_A : rom_t := (
        0 => x"00500093",   -- addi x1, x0, 5
        1 => x"00300113",   -- addi x2, x0, 3
        2 => x"002081B3",   -- add  x3, x1, x2
        3 => x"00302023",   -- sw   x3, 0(x0)
        4 => x"00002203",   -- lw   x4, 0(x0)
        5 => x"0000006F",   -- jal  x0, 0
        others => x"00000013"  -- nop (addi x0, x0, 0)
    );

    --------------------------------------------------------------------
    -- PROGRAM B (PROGRAM_SEL = 1) — Hello World su UART + GPIO
    -- Vedi sw/asm/hello.s per il sorgente assembly e il calcolo encoding.
    --
    -- DMEM preinizializzata (vedi data_memory.vhd):
    --   DMEM[0] = 0x00010000  &UART_DATA
    --   DMEM[1] = 0x00010004  &UART_STATUS
    --   DMEM[2] = 0x00010008  &GPIO_LED
    --   DMEM[4] = 0x00000048  'H'
    --   DMEM[5] = 0x00000065  'e'
    --   DMEM[6] = 0x0000006C  'l'
    --   DMEM[7] = 0x0000006C  'l'
    --   DMEM[8] = 0x0000006F  'o'
    --
    -- Mapping word index → byte address per i branch:
    --   istr 0  @ 0x00      istr 10 @ 0x28 (poll:)
    --   istr 1  @ 0x04      istr 11 @ 0x2C
    --   istr 2  @ 0x08      istr 12 @ 0x30   beq -8  → 0x28
    --   istr 3  @ 0x0C      istr 13 @ 0x34
    --   istr 4  @ 0x10      istr 14 @ 0x38
    --   istr 5  @ 0x14      istr 15 @ 0x3C   blt -28 → 0x20 (send_loop:)
    --   istr 6  @ 0x18      istr 16 @ 0x40
    --   istr 7  @ 0x1C      istr 17 @ 0x44
    --   istr 8  @ 0x20      istr 18 @ 0x48   jal 0   → 0x48 (halt)
    --   istr 9  @ 0x24
    --------------------------------------------------------------------
    constant PROGRAM_B : rom_t := (
        0  => x"00002503",  -- lw   x10, 0(x0)        x10 = &UART_DATA
        1  => x"00402583",  -- lw   x11, 4(x0)        x11 = &UART_STATUS
        2  => x"00802603",  -- lw   x12, 8(x0)        x12 = &GPIO_LED
        3  => x"01000A13",  -- addi x20, x0, 16       x20 = base byte addr caratteri
        4  => x"00000B13",  -- addi x22, x0, 0        x22 = indice corrente
        5  => x"01400C13",  -- addi x24, x0, 20       x24 = limite (5 chars * 4 byte)
        6  => x"00F00313",  -- addi x6, x0, 15        x6 = 0x0F (LED iniziali)
        7  => x"00662023",  -- sw   x6, 0(x12)        GPIO_LED <= 0x0F
        8  => x"016A0BB3",  -- add  x23, x20, x22     x23 = &chars[i]   (send_loop:)
        9  => x"000BA283",  -- lw   x5, 0(x23)        x5 = chars[i]
        10 => x"0005A383",  -- lw   x7, 0(x11)        x7 = UART_STATUS   (poll:)
        11 => x"0013F393",  -- andi x7, x7, 1         isola bit 0 (ready)
        12 => x"FE038CE3",  -- beq  x7, x0, -8        se busy, ricicla   (-> poll)
        13 => x"00552023",  -- sw   x5, 0(x10)        UART_DATA <= byte  (kick UART)
        14 => x"004B0B13",  -- addi x22, x22, 4       i += 4
        15 => x"FF8B42E3",  -- blt  x22, x24, -28     se i < 20, continua (-> send_loop)
        16 => x"05500313",  -- addi x6, x0, 85        x6 = 0x55 (LED finali)
        17 => x"00662023",  -- sw   x6, 0(x12)        GPIO_LED <= 0x55
        18 => x"0000006F",  -- jal  x0, 0             halt (loop su se stessa)
        others => x"00000013"
    );

    --------------------------------------------------------------------
    -- PROGRAM C (PROGRAM_SEL = 2) — DEBUG single-shot 'X' con LED probe
    -- 9 istruzioni. I LED segnalano lo stato dell'esecuzione:
    --   - LED = 0xAA = 10101010 = "fase pre-kick UART" (CPU viva)
    --   - LED = 0x11 = 00010001 = "fase post-kick UART" (sw eseguita)
    --   - LED tutti spenti     = CPU non sta eseguendo PROGRAM_C
    --
    -- Niente polling UART_STATUS: la UART dopo reset e' in IDLE/ready.
    --
    --   0: lw   x12, 8(x0)   -> x12 = DMEM[2] = 0x00010008 (&GPIO_LED)
    --   1: addi x6, x0, 170  -> x6  = 0xAA pattern visibile
    --   2: sw   x6, 0(x12)   -> GPIO_LED <= 0xAA   (probe 1: CPU viva)
    --   3: lw   x10, 0(x0)   -> x10 = DMEM[0] = 0x00010000 (&UART_DATA)
    --   4: addi x5, x0, 88   -> x5  = 0x58 = 'X' ASCII
    --   5: sw   x5, 0(x10)   -> UART_DATA <= 'X'   (kick UART una volta)
    --   6: addi x6, x0, 17   -> x6  = 0x11 pattern post-kick
    --   7: sw   x6, 0(x12)   -> GPIO_LED <= 0x11   (probe 2: sw eseguita)
    --   8: jal  x0, 0        -> halt loop infinito
    --
    -- Encoding verificati a mano (i pattern coincidono con quelli di
    -- PROGRAM_B dove possibile):
    --   lw x12, 8(x0)        -> 0x00802603
    --   addi x6, x0, 170     -> 0x0AA00313  (170 = 0x0AA in 12-bit signed)
    --   sw x6, 0(x12)        -> 0x00662023
    --   lw x10, 0(x0)        -> 0x00002503
    --   addi x5, x0, 88      -> 0x05800293  (88 = 0x058)
    --   sw x5, 0(x10)        -> 0x00552023
    --   addi x6, x0, 17      -> 0x01100313  (17 = 0x011)
    --   sw x6, 0(x12)        -> 0x00662023
    --   jal x0, 0            -> 0x0000006F
    --------------------------------------------------------------------
    constant PROGRAM_C : rom_t := (
        0 => x"00802603",   -- lw   x12, 8(x0)     x12 = &GPIO_LED
        1 => x"0AA00313",   -- addi x6, x0, 170    x6  = 0xAA
        2 => x"00662023",   -- sw   x6, 0(x12)     LED <= 0xAA  (probe 1)
        3 => x"00002503",   -- lw   x10, 0(x0)     x10 = &UART_DATA
        4 => x"05800293",   -- addi x5, x0, 88     x5  = 'X'
        5 => x"00552023",   -- sw   x5, 0(x10)     kick UART
        6 => x"01100313",   -- addi x6, x0, 17     x6  = 0x11
        7 => x"00662023",   -- sw   x6, 0(x12)     LED <= 0x11  (probe 2)
        8 => x"0000006F",   -- jal  x0, 0          halt
        others => x"00000013"
    );

    --------------------------------------------------------------------
    -- PROGRAM D (PROGRAM_SEL = 3) — DEBUG senza DMEM[0]: calcola &UART_DATA
    -- da x12 (= &GPIO_LED = 0x00010008) con addi x10, x12, -8.
    -- Bypassa completamente DMEM[0] per isolare il bug di inizializzazione.
    --
    -- Se con PROGRAM_C LED15='0' (uart_tx_start non scatta):
    --   PROGRAM_D rimuove la lw x10, 0(x0) e usa addi x10, x12, -8.
    --   Se LED15 diventa '1' → DMEM[0] non è inizializzato in HW.
    --   Se LED15 resta '0'   → il problema è altrove.
    --
    --   0: lw   x12, 8(x0)      0x00802603  x12 = DMEM[2] = 0x00010008 (&GPIO_LED)
    --   1: addi x6, x0, 170     0x0AA00313  x6  = 0xAA
    --   2: sw   x6, 0(x12)      0x00662023  LED <= 0xAA  (probe 1)
    --   3: addi x10, x12, -8    0xFF860513  x10 = x12 - 8 = 0x00010000 (&UART_DATA)
    --   4: addi x5, x0, 88      0x05800293  x5  = 'X' = 0x58
    --   5: sw   x5, 0(x10)      0x00552023  UART_DATA <= 'X'  (kick UART)
    --   6: addi x6, x0, 17      0x01100313  x6  = 0x11
    --   7: sw   x6, 0(x12)      0x00662023  LED <= 0x11  (probe 2)
    --   8: jal  x0, 0           0x0000006F  halt
    --------------------------------------------------------------------
    constant PROGRAM_D : rom_t := (
        0 => x"00802603",   -- lw   x12, 8(x0)      x12 = &GPIO_LED
        1 => x"0AA00313",   -- addi x6, x0, 170     x6  = 0xAA
        2 => x"00662023",   -- sw   x6, 0(x12)      LED <= 0xAA  (probe 1)
        3 => x"FF860513",   -- addi x10, x12, -8    x10 = 0x00010000  (NO lw da DMEM[0]!)
        4 => x"05800293",   -- addi x5, x0, 88      x5  = 'X'
        5 => x"00552023",   -- sw   x5, 0(x10)      kick UART
        6 => x"01100313",   -- addi x6, x0, 17      x6  = 0x11
        7 => x"00662023",   -- sw   x6, 0(x12)      LED <= 0x11  (probe 2)
        8 => x"0000006F",   -- jal  x0, 0           halt
        others => x"00000013"
    );

    --------------------------------------------------------------------
    -- PROGRAM E (PROGRAM_SEL = 4) — HAZARD TEST per la pipeline a 5 stadi.
    -- Test auto-verificante: esercita forwarding, load-use stall, branch
    -- condizionale (preso E non preso) e jal con link (rd != x0), poi scrive
    -- una "firma" su GPIO_LED. La firma e' corretta SOLO se tutti gli hazard
    -- si comportano bene.
    --
    --   Firma attesa su led_out = 0x004F (= 79 = 30 + 5 + 44).
    --   PC finale fermo a 0x040 (jal self-loop alla istr 16).
    --
    --   0  addi x1,x0,10     x1=10
    --   1  addi x2,x0,20     x2=20
    --   2  add  x3,x1,x2     x3=30        forwarding (x1 da MEM/WB, x2 da EX/MEM)
    --   3  sw   x3,12(x0)    DMEM[3]=30   forwarding di x3
    --   4  lw   x4,12(x0)    x4=30        (load)
    --   5  add  x6,x4,x0     x6=30        LOAD-USE -> stall di 1 ciclo
    --   6  beq  x4,x3,+8     30==30 PRESO -> salta istr 7
    --   7  addi x6,x0,255    canarino (deve essere SALTATA)
    --   8  bne  x4,x3,+8     30!=30 falso -> NON preso
    --   9  addi x7,x0,5      x7=5 (deve ESEGUIRE)
    --  10  jal  x8,+8        x8=PC+4=44, salta istr 11 (link rd!=x0)
    --  11  addi x7,x0,238    canarino (deve essere SALTATA)
    --  12  lw   x12,8(x0)    x12 = &GPIO_LED = 0x00010008
    --  13  add  x5,x6,x7     x5 = 30+5 = 35
    --  14  add  x5,x5,x8     x5 = 35+44 = 79 = 0x4F
    --  15  sw   x5,0(x12)    GPIO_LED <= 0x4F   (firma)
    --  16  jal  x0,0         halt (self-loop)
    --------------------------------------------------------------------
    constant PROGRAM_E : rom_t := (
         0 => x"00A00093",   -- addi x1,x0,10
         1 => x"01400113",   -- addi x2,x0,20
         2 => x"002081B3",   -- add  x3,x1,x2     forwarding x1,x2
         3 => x"00302623",   -- sw   x3,12(x0)    forwarding x3
         4 => x"00C02203",   -- lw   x4,12(x0)    load
         5 => x"00020333",   -- add  x6,x4,x0     LOAD-USE -> stall
         6 => x"00320463",   -- beq  x4,x3,+8     branch PRESO
         7 => x"0FF00313",   -- addi x6,x0,255    canarino (skip)
         8 => x"00321463",   -- bne  x4,x3,+8     branch NON preso
         9 => x"00500393",   -- addi x7,x0,5      esegue
        10 => x"0080046F",   -- jal  x8,+8        link rd=x8, salta istr 11
        11 => x"0EE00393",   -- addi x7,x0,238    canarino (skip)
        12 => x"00802603",   -- lw   x12,8(x0)    &GPIO_LED
        13 => x"007302B3",   -- add  x5,x6,x7     35
        14 => x"008282B3",   -- add  x5,x5,x8     79 = 0x4F
        15 => x"00562023",   -- sw   x5,0(x12)    GPIO_LED <= firma
        16 => x"0000006F",   -- jal  x0,0         halt
        others => x"00000013"
    );

    --------------------------------------------------------------------
    -- Function di selezione del programma a partire dal generic.
    -- Restituisce uno dei cinque programmi precaricati a seconda di PROGRAM_SEL.
    --------------------------------------------------------------------
    function select_program(sel : integer) return rom_t is
    begin
        if sel = 1 then
            return PROGRAM_B;
        elsif sel = 2 then
            return PROGRAM_C;
        elsif sel = 3 then
            return PROGRAM_D;
        elsif sel = 4 then
            return PROGRAM_E;
        else
            return PROGRAM_A;
        end if;
    end function;

    signal mem : rom_t := select_program(PROGRAM_SEL);
begin
    -- BRAM sincrona, lettura registrata al rising_edge.
    -- È il pattern che Vivado riconosce come BRAM.
    process(clk)
    begin
        if rising_edge(clk) then
            if re = '1' then
                instruction <= mem(to_integer(unsigned(addr)));
            end if;
        end if;
    end process;
end Behavioral;
