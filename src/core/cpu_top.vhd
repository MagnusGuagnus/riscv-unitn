----------------------------------------------------------------------------------
-- Module Name: cpu_top - Behavioral
-- Description: Top-level del processore RISC-V multi-cycle.
--   Integra tutti i sotto-moduli e cabla i fili secondo la spec del prof
--   (PDF 21.RISCV_guidelines, slide 14-22).
--
--   Sotto-moduli istanziati:
--     pc_unit         - registro PC + adder +4
--     instr_memory    - BRAM 1024x32 con programma precaricato
--     decoder         - genera segnali di controllo dall'istruzione
--     immediate_gen   - estrae e sign-extende l'immediato
--     regfile         - distributed RAM 32x32 con porta A condivisa
--     alu             - ALU 6 op (3-bit opcode)
--     comparator      - comparator 4 op (3-bit cond_opcode)
--     memory_map      - bus memory-mapped (DMEM + UART_TX + GPIO con
--                       address decoder su bit[16]/[3]/[2])
--     control_fsm     - FSM 4 stati
--
--   Mux esterni implementati qui:
--     - regfile.a_addr: tra rs1 (DECODE) e rd (MEM_WB)
--     - alu.a:          tra curr_pc (PC-relative) e rs1_value
--     - alu.b:          tra rs2_value e immediate
--     - rd_value:       tra alu_result (op_class=O), mem_out (L), next_pc (J)
--     - pc_in:          tra next_pc (default) e alu_result (J o branch taken)
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity cpu_top is
    generic (
        -- Propagati al memory_map → uart_tx.
        -- Default = configurazione sintetizzata sulla Nexys4 DDR.
        -- Nei testbench di sistema si può ridurre BAUD per simulare veloce.
        CLK_HZ      : integer := 100_000_000;
        BAUD        : integer := 115_200;
        -- Seleziona il programma precaricato in IMEM:
        --   0 = Fase A (test core, default)
        --   1 = Hello World (Fase B, demo periferiche)
        PROGRAM_SEL : integer := 0
    );
    port (
        clk       : in  std_logic;
        reset     : in  std_logic;
        -- Pin esterni verso la scheda (cablati via constraints/.xdc)
        uart_tx_pin : out std_logic;
        led_out     : out std_logic_vector(15 downto 0);
        sw_in       : in  std_logic_vector(15 downto 0);
        -- Esposti per debugging in simulation
        dbg_pc          : out std_logic_vector(11 downto 0);
        dbg_instr       : out std_logic_vector(31 downto 0);
        dbg_state       : out std_logic_vector(1 downto 0);
        dbg_alu_result  : out std_logic_vector(31 downto 0);
        dbg_mem_out     : out std_logic_vector(31 downto 0);
        dbg_rd_value    : out std_logic_vector(31 downto 0)
    );
end cpu_top;

architecture Behavioral of cpu_top is
    --------------------------------------------------------------------
    -- Segnali di interconnessione (i "fili" tra moduli)
    --------------------------------------------------------------------

    -- PC unit
    signal pc        : std_logic_vector(11 downto 0);
    signal next_pc   : std_logic_vector(11 downto 0);
    signal pc_word   : std_logic_vector(9 downto 0);
    signal pc_in     : std_logic_vector(11 downto 0);
    signal pc_load   : std_logic;

    -- IMEM
    signal instruction : std_logic_vector(31 downto 0);

    -- Decoder
    signal op_class    : std_logic_vector(4 downto 0);
    signal alu_opcode  : std_logic_vector(2 downto 0);
    signal cond_opcode : std_logic_vector(2 downto 0);
    signal a_sel       : std_logic;
    signal b_sel       : std_logic;
    signal imm_type    : std_logic_vector(2 downto 0);

    -- Campi dell'istruzione estratti per il regfile
    signal rs1_addr_field : std_logic_vector(4 downto 0);
    signal rs2_addr_field : std_logic_vector(4 downto 0);
    signal rd_addr_field  : std_logic_vector(4 downto 0);

    -- Regfile
    signal regfile_a_addr : std_logic_vector(4 downto 0);
    signal regfile_a_sel  : std_logic;
    signal regfile_we     : std_logic;
    signal rs1_value      : std_logic_vector(31 downto 0);
    signal rs2_value      : std_logic_vector(31 downto 0);
    signal rd_data        : std_logic_vector(31 downto 0);  -- = rd_value
    signal rd_write_en    : std_logic;

    -- Immediate generator
    signal immediate : std_logic_vector(31 downto 0);

    -- ALU
    signal alu_a          : std_logic_vector(31 downto 0);
    signal alu_b          : std_logic_vector(31 downto 0);
    signal alu_result     : std_logic_vector(31 downto 0);
    signal alu_pre_result : std_logic_vector(31 downto 0);
    signal curr_pc_32     : std_logic_vector(31 downto 0);
    signal next_pc_32     : std_logic_vector(31 downto 0);

    -- Comparator
    signal branch_cond : std_logic;

    -- Memory bus (DMEM + periferiche memory-mapped, gestito da memory_map)
    signal mem_we    : std_logic;
    signal mem_out   : std_logic_vector(31 downto 0);

    -- Mux finale rd_value
    signal rd_value : std_logic_vector(31 downto 0);

    -- FSM
    signal state : std_logic_vector(1 downto 0);

begin

    --------------------------------------------------------------------
    -- Estrazione campi dall'istruzione (cablaggi puri)
    --------------------------------------------------------------------
    rs1_addr_field <= instruction(19 downto 15);
    rs2_addr_field <= instruction(24 downto 20);
    rd_addr_field  <= instruction(11 downto 7);

    --------------------------------------------------------------------
    -- Estensioni a 32 bit per uso nell'ALU
    --------------------------------------------------------------------
    curr_pc_32 <= x"00000" & pc;
    next_pc_32 <= x"00000" & next_pc;

    --------------------------------------------------------------------
    -- 1) PC unit
    --------------------------------------------------------------------
    u_pc: entity work.pc_unit
        port map (
            clk     => clk,
            reset   => reset,
            load_en => pc_load,
            pc_in   => pc_in,
            pc      => pc,
            next_pc => next_pc,
            pc_word => pc_word
        );

    --------------------------------------------------------------------
    -- 2) Instruction Memory
    --   Il programma da eseguire è scelto via generic PROGRAM_SEL,
    --   propagato dal top di sistema o dal testbench.
    --------------------------------------------------------------------
    u_imem: entity work.instr_memory
        generic map (
            PROGRAM_SEL => PROGRAM_SEL
        )
        port map (
            clk         => clk,
            addr        => pc_word,
            instruction => instruction
        );

    --------------------------------------------------------------------
    -- 3) Decoder
    --------------------------------------------------------------------
    u_decoder: entity work.decoder
        port map (
            instr       => instruction,
            op_class    => op_class,
            alu_opcode  => alu_opcode,
            cond_opcode => cond_opcode,
            a_sel       => a_sel,
            b_sel       => b_sel,
            imm_type    => imm_type
        );

    --------------------------------------------------------------------
    -- 4) Immediate Generator
    --------------------------------------------------------------------
    u_imm: entity work.immediate_gen
        port map (
            instr    => instruction,
            imm_type => imm_type,
            imm_out  => immediate
        );

    --------------------------------------------------------------------
    -- 5) Register File
    --   Mux esterno sulla porta A:
    --     a_sel=0 (FETCH/DECODE/EXECUTE) → rs1_addr_field
    --     a_sel=1 (MEM_WB)               → rd_addr_field
    --------------------------------------------------------------------
    regfile_a_addr <= rs1_addr_field when regfile_a_sel = '0'
                      else rd_addr_field;

    regfile_we <= rd_write_en;  -- alias per leggibilità

    u_regfile: entity work.regfile
        port map (
            clk       => clk,
            we        => regfile_we,
            a_addr    => regfile_a_addr,
            rs2_addr  => rs2_addr_field,
            rd_data   => rd_value,
            rs1_value => rs1_value,
            rs2_value => rs2_value
        );

    --------------------------------------------------------------------
    -- 6) Muxe degli operandi ALU
    --   a_sel=0 → curr_pc (per branch target e JAL target)
    --   a_sel=1 → rs1_value (per ALU op, LW, SW)
    --   b_sel=0 → rs2_value (per R-type ALU)
    --   b_sel=1 → immediate (per I-type, S, B, J)
    --------------------------------------------------------------------
    alu_a <= curr_pc_32 when a_sel = '0' else rs1_value;
    alu_b <= rs2_value  when b_sel = '0' else immediate;

    --------------------------------------------------------------------
    -- 7) ALU
    --------------------------------------------------------------------
    u_alu: entity work.alu
        port map (
            clk            => clk,
            a              => alu_a,
            b              => alu_b,
            alu_opcode     => alu_opcode,
            alu_pre_result => alu_pre_result,
            alu_result     => alu_result
        );

    --------------------------------------------------------------------
    -- 8) Comparator
    --------------------------------------------------------------------
    u_cmp: entity work.comparator
        port map (
            clk         => clk,
            rs1_value   => rs1_value,
            rs2_value   => rs2_value,
            cond_opcode => cond_opcode,
            branch_cond => branch_cond
        );

    --------------------------------------------------------------------
    -- 9) Memory Map (DMEM + UART + GPIO, memory-mapped)
    --   addr  = alu_pre_result (32 bit). Il memory_map dentro fa:
    --             - estrae bit[13:2] per DMEM (word address)
    --             - estrae bit[16]/[3]/[2] come selettori address decoder
    --   we    = mem_we dalla FSM (alto solo in MEM_WB se Store).
    --             Il memory_map smista questo we verso dmem/uart/gpio.
    --   din   = rs2_value. Le periferiche prendono i bit bassi che gli
    --             servono (UART: [7:0], GPIO: [15:0]); DMEM li usa tutti.
    --   dout  = mem_out, mux tra dmem.dout, UART_STATUS, GPIO_SW, o 0.
    --
    --   Il modulo espone anche i pin esterni (uart_tx_pin, led_out, sw_in)
    --   verso la scheda fisica.
    --------------------------------------------------------------------
    u_mmap: entity work.memory_map
        generic map (
            CLK_HZ => CLK_HZ,
            BAUD   => BAUD
        )
        port map (
            clk         => clk,
            reset       => reset,
            addr        => alu_pre_result,
            we          => mem_we,
            din         => rs2_value,
            dout        => mem_out,
            uart_tx_pin => uart_tx_pin,
            led_out     => led_out,
            sw_in       => sw_in
        );

    --------------------------------------------------------------------
    -- 10) Control FSM
    --------------------------------------------------------------------
    u_fsm: entity work.control_fsm
        port map (
            clk           => clk,
            reset         => reset,
            op_class      => op_class,
            pc_load       => pc_load,
            mem_we        => mem_we,
            rd_write_en   => rd_write_en,
            regfile_a_sel => regfile_a_sel,
            state_out     => state
        );

    --------------------------------------------------------------------
    -- Mux finale rd_value (slide 20 del PDF prof)
    --   op_class=L (Load)    → rd_value = mem_out
    --   op_class=J (Jump)    → rd_value = next_pc (= return address)
    --   op_class=O (ALU op)  → rd_value = alu_result (default)
    --   op_class=S, B        → rd_value = qualsiasi (write_en sarà 0)
    --------------------------------------------------------------------
    rd_value <= mem_out    when op_class(2) = '1'   -- Load
           else next_pc_32 when op_class(4) = '1'   -- Jump (JAL salva pc+4)
           else alu_result;                          -- ALU op (default)

    --------------------------------------------------------------------
    -- Mux finale pc_in (slide 20 del PDF prof)
    --   se op_class=J → pc_in = alu_result[11:0] (jump target)
    --   se op_class=B AND branch_cond='1' → pc_in = alu_result[11:0] (branch taken)
    --   altrimenti → pc_in = next_pc (sequential)
    --------------------------------------------------------------------
    pc_in <= alu_result(11 downto 0) when op_class(4) = '1'  -- JAL
        else alu_result(11 downto 0) when (op_class(3) = '1' and branch_cond = '1')  -- branch taken
        else next_pc;

    --------------------------------------------------------------------
    -- Output di debug per le waveform
    --------------------------------------------------------------------
    dbg_pc         <= pc;
    dbg_instr      <= instruction;
    dbg_state      <= state;
    dbg_alu_result <= alu_result;
    dbg_mem_out    <= mem_out;
    dbg_rd_value   <= rd_value;

end Behavioral;
