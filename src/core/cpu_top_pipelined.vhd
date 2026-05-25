----------------------------------------------------------------------------------
-- Module Name : cpu_top_pipelined - Behavioral
--
-- VERSIONE PIPELINED 5-STAGE della CPU RISC-V (estensione architetturale).
--
-- Convive in parallelo con cpu_top.vhd (versione multi-cycle). Scegli quale
-- usare in sintesi con "Set as Top" nel pannello Sources di Vivado, o
-- istanziandone uno o l'altro nel wrapper di board.
--
-- ARCHITETTURA
-- ============
--   IF  -> ID  -> EX  -> MEM -> WB
--     |     |     |     |     |
--     v     v     v     v     v
--   IF/ID  ID/EX  EX/MEM  MEM/WB     (4 pipeline registers)
--
--   IF  : PC + IMEM read
--   ID  : decoder + regfile dual-port (2 read async) + immediate_gen
--   EX  : forwarding mux + ALU (uso alu_pre_result combinatorio) + branch
--         resolution (comparator replicato combinatoriamente qui per evitare
--         la latenza del registro interno del modulo comparator esistente)
--   MEM : memory_map (DMEM + UART + GPIO)
--   WB  : mux sorgente writeback (alu_result / mem_out / pc_next per JAL)
--         e scrittura sul regfile dual-port
--
-- HAZARD GESTITI
-- ==============
--   - Data hazard RAW: forwarding EX/MEM -> EX e MEM/WB -> EX (modulo
--     forwarding_unit). Risolve senza stall.
--   - Load-use hazard: stall di 1 ciclo (modulo hazard_unit) + bolla NOP
--     iniettata in ID/EX.
--   - Control hazard (branch/jump taken): branch risolto in EX, flush
--     dei 2 stadi precedenti (IF/ID e ID/EX -> NOP), redirect PC al
--     branch target. Penalita' = 2 cicli per branch taken.
--
-- INTERFACCIA ESTERNA
-- ===================
-- Identica a cpu_top.vhd (multi-cycle) per facilitare lo swap nel wrapper:
-- stessi generic (CLK_HZ/BAUD/PROGRAM_SEL) e stesso port (clk/reset/
-- uart_tx_pin/led_out/sw_in/dbg_*).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity cpu_top_pipelined is
    generic (
        CLK_HZ      : integer := 100_000_000;
        BAUD        : integer := 115_200;
        PROGRAM_SEL : integer := 0
    );
    port (
        clk             : in  std_logic;
        reset           : in  std_logic;
        uart_tx_pin     : out std_logic;
        led_out         : out std_logic_vector(15 downto 0);
        sw_in           : in  std_logic_vector(15 downto 0);
        -- Debug (riusati per simulazione, mostrano lo stato dello stadio EX)
        dbg_pc          : out std_logic_vector(11 downto 0);
        dbg_instr       : out std_logic_vector(31 downto 0);
        dbg_state       : out std_logic_vector(1 downto 0);   -- placeholder
        dbg_alu_result  : out std_logic_vector(31 downto 0);
        dbg_mem_out     : out std_logic_vector(31 downto 0);
        dbg_rd_value    : out std_logic_vector(31 downto 0)
    );
end cpu_top_pipelined;

architecture Behavioral of cpu_top_pipelined is

    -- Costante NOP (= addi x0, x0, 0) per iniettare bolle e flush
    constant NOP_INSTR : std_logic_vector(31 downto 0) := x"00000013";

    --------------------------------------------------------------------
    -- IF STAGE
    --------------------------------------------------------------------
    signal pc_if         : std_logic_vector(11 downto 0) := (others => '0');
    signal pc_next_if    : std_logic_vector(11 downto 0);
    signal pc_in         : std_logic_vector(11 downto 0);
    signal instruction_if: std_logic_vector(31 downto 0);
    signal pc_word_if    : std_logic_vector(9 downto 0);
    signal pc_write_en   : std_logic;
    signal pc_redirect   : std_logic;       -- '1' se branch/jump taken in EX
    signal pc_target     : std_logic_vector(11 downto 0);

    --------------------------------------------------------------------
    -- IF/ID PIPELINE REGISTER
    --------------------------------------------------------------------
    signal ifid_pc        : std_logic_vector(11 downto 0) := (others => '0');
    signal ifid_pc_next   : std_logic_vector(11 downto 0) := (others => '0');
    signal ifid_instr     : std_logic_vector(31 downto 0) := NOP_INSTR;
    signal ifid_valid     : std_logic := '0';

    --------------------------------------------------------------------
    -- ID STAGE
    --------------------------------------------------------------------
    signal rs1_addr_id : std_logic_vector(4 downto 0);
    signal rs2_addr_id : std_logic_vector(4 downto 0);
    signal rd_addr_id  : std_logic_vector(4 downto 0);
    signal rs1_value_id: std_logic_vector(31 downto 0);
    signal rs2_value_id: std_logic_vector(31 downto 0);
    signal immediate_id: std_logic_vector(31 downto 0);
    signal op_class_id : std_logic_vector(4 downto 0);
    signal alu_op_id   : std_logic_vector(2 downto 0);
    signal cond_op_id  : std_logic_vector(2 downto 0);
    signal a_sel_id    : std_logic;
    signal b_sel_id    : std_logic;
    signal imm_type_id : std_logic_vector(2 downto 0);

    --------------------------------------------------------------------
    -- ID/EX PIPELINE REGISTER
    --------------------------------------------------------------------
    signal idex_pc        : std_logic_vector(11 downto 0) := (others => '0');
    signal idex_pc_next   : std_logic_vector(11 downto 0) := (others => '0');
    signal idex_rs1_value : std_logic_vector(31 downto 0) := (others => '0');
    signal idex_rs2_value : std_logic_vector(31 downto 0) := (others => '0');
    signal idex_immediate : std_logic_vector(31 downto 0) := (others => '0');
    signal idex_rs1_addr  : std_logic_vector(4 downto 0)  := (others => '0');
    signal idex_rs2_addr  : std_logic_vector(4 downto 0)  := (others => '0');
    signal idex_rd_addr   : std_logic_vector(4 downto 0)  := (others => '0');
    signal idex_op_class  : std_logic_vector(4 downto 0)  := (others => '0');
    signal idex_alu_op    : std_logic_vector(2 downto 0)  := (others => '0');
    signal idex_cond_op   : std_logic_vector(2 downto 0)  := (others => '0');
    signal idex_a_sel     : std_logic := '0';
    signal idex_b_sel     : std_logic := '0';

    -- Comodita': "questa istruzione e' un load?" estratto da op_class(2)
    signal idex_is_load   : std_logic;

    --------------------------------------------------------------------
    -- EX STAGE
    --------------------------------------------------------------------
    signal fwd_a, fwd_b      : std_logic_vector(1 downto 0);
    signal rs1_fwd, rs2_fwd  : std_logic_vector(31 downto 0);  -- dopo forwarding
    signal alu_a_ex, alu_b_ex: std_logic_vector(31 downto 0);
    signal pc_ex_32          : std_logic_vector(31 downto 0);
    signal alu_result_ex     : std_logic_vector(31 downto 0);  -- alu_pre_result (combinatorio)
    signal alu_result_latched: std_logic_vector(31 downto 0);  -- alu_result (latched, non usato)
    signal branch_cond_ex    : std_logic;
    signal branch_taken_ex   : std_logic;

    --------------------------------------------------------------------
    -- EX/MEM PIPELINE REGISTER
    --------------------------------------------------------------------
    signal exmem_alu_result : std_logic_vector(31 downto 0) := (others => '0');
    signal exmem_rs2_value  : std_logic_vector(31 downto 0) := (others => '0');
    signal exmem_pc_next    : std_logic_vector(11 downto 0) := (others => '0');
    signal exmem_rd_addr    : std_logic_vector(4 downto 0)  := (others => '0');
    signal exmem_op_class   : std_logic_vector(4 downto 0)  := (others => '0');
    signal exmem_regwrite   : std_logic := '0';
    signal exmem_memwrite   : std_logic := '0';

    --------------------------------------------------------------------
    -- MEM STAGE
    --------------------------------------------------------------------
    signal mem_out_mem      : std_logic_vector(31 downto 0);

    --------------------------------------------------------------------
    -- MEM/WB PIPELINE REGISTER
    --------------------------------------------------------------------
    signal memwb_alu_result : std_logic_vector(31 downto 0) := (others => '0');
    signal memwb_mem_out    : std_logic_vector(31 downto 0) := (others => '0');
    signal memwb_pc_next_32 : std_logic_vector(31 downto 0) := (others => '0');
    signal memwb_rd_addr    : std_logic_vector(4 downto 0)  := (others => '0');
    signal memwb_op_class   : std_logic_vector(4 downto 0)  := (others => '0');
    signal memwb_regwrite   : std_logic := '0';

    --------------------------------------------------------------------
    -- WB STAGE
    --------------------------------------------------------------------
    signal wb_data : std_logic_vector(31 downto 0);

    --------------------------------------------------------------------
    -- HAZARD / STALL / FLUSH
    --------------------------------------------------------------------
    signal stall      : std_logic;       -- da hazard_unit (load-use)
    signal flush_ifid : std_logic;       -- '1' se branch taken in EX
    signal flush_idex : std_logic;       -- '1' se branch taken in EX (o stall)

begin

    --==================================================================
    -- IF STAGE
    --==================================================================

    -- PC + 4
    pc_next_if <= std_logic_vector(unsigned(pc_if) + 4);

    -- Mux PC in: redirect (branch taken) vince su sequential
    pc_in <= pc_target when pc_redirect = '1' else pc_next_if;

    -- PC e' aggiornato sempre tranne quando stalliamo
    pc_write_en <= not stall;

    -- PC register
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pc_if <= (others => '0');
            elsif pc_write_en = '1' then
                pc_if <= pc_in;
            end if;
        end if;
    end process;

    -- IMEM: lettura sincrona (instruction esce 1 ciclo dopo pc_word_if applicato).
    -- Equivale a "instruction_if e' l'istruzione del PC del ciclo precedente".
    -- Nel pipeline schema standard questa latenza e' assorbita dal IF/ID register.
    pc_word_if <= pc_if(11 downto 2);

    u_imem: entity work.instr_memory
        generic map (
            PROGRAM_SEL => PROGRAM_SEL
        )
        port map (
            clk         => clk,
            addr        => pc_word_if,
            instruction => instruction_if
        );

    --==================================================================
    -- IF/ID PIPELINE REGISTER
    --==================================================================
    -- Controllo: reset -> NOP, flush -> NOP, stall -> congela, altrimenti avanza.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ifid_pc      <= (others => '0');
                ifid_pc_next <= (others => '0');
                ifid_instr   <= NOP_INSTR;
                ifid_valid   <= '0';
            elsif flush_ifid = '1' then
                ifid_pc      <= (others => '0');
                ifid_pc_next <= (others => '0');
                ifid_instr   <= NOP_INSTR;
                ifid_valid   <= '0';
            elsif stall = '1' then
                -- Congelato: mantiene il valore corrente
                null;
            else
                ifid_pc      <= pc_if;
                ifid_pc_next <= pc_next_if;
                ifid_instr   <= instruction_if;
                ifid_valid   <= '1';
            end if;
        end if;
    end process;

    --==================================================================
    -- ID STAGE
    --==================================================================
    rs1_addr_id <= ifid_instr(19 downto 15);
    rs2_addr_id <= ifid_instr(24 downto 20);
    rd_addr_id  <= ifid_instr(11 downto 7);

    u_decoder: entity work.decoder
        port map (
            instr       => ifid_instr,
            op_class    => op_class_id,
            alu_opcode  => alu_op_id,
            cond_opcode => cond_op_id,
            a_sel       => a_sel_id,
            b_sel       => b_sel_id,
            imm_type    => imm_type_id
        );

    u_imm: entity work.immediate_gen
        port map (
            instr    => ifid_instr,
            imm_type => imm_type_id,
            imm_out  => immediate_id
        );

    u_regfile: entity work.regfile_dp
        port map (
            clk      => clk,
            we       => memwb_regwrite,
            wr_addr  => memwb_rd_addr,
            wr_data  => wb_data,
            rs1_addr => rs1_addr_id,
            rs1_data => rs1_value_id,
            rs2_addr => rs2_addr_id,
            rs2_data => rs2_value_id
        );

    --==================================================================
    -- HAZARD UNIT (combinatorio, deve essere collegato PRIMA di ID/EX)
    --==================================================================
    idex_is_load <= idex_op_class(2);

    u_hazard: entity work.hazard_unit
        port map (
            idex_is_load => idex_is_load,
            idex_rd      => idex_rd_addr,
            ifid_rs1     => rs1_addr_id,
            ifid_rs2     => rs2_addr_id,
            stall        => stall
        );

    -- flush_idex e' alto se branch taken in EX, OPPURE se siamo in stall
    -- (in entrambi i casi voglio iniettare una NOP nel pipeline register ID/EX).
    flush_idex <= pc_redirect or stall;

    --==================================================================
    -- ID/EX PIPELINE REGISTER
    --==================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or flush_idex = '1' then
                -- Bolla NOP: azzera tutti i control signal cosi' EX/MEM/WB
                -- non producono effetti collaterali.
                idex_pc        <= (others => '0');
                idex_pc_next   <= (others => '0');
                idex_rs1_value <= (others => '0');
                idex_rs2_value <= (others => '0');
                idex_immediate <= (others => '0');
                idex_rs1_addr  <= (others => '0');
                idex_rs2_addr  <= (others => '0');
                idex_rd_addr   <= (others => '0');
                idex_op_class  <= (others => '0');  -- tutti zero = NOP (niente regwrite/memwrite/branch)
                idex_alu_op    <= (others => '0');
                idex_cond_op   <= (others => '0');
                idex_a_sel     <= '0';
                idex_b_sel     <= '0';
            else
                idex_pc        <= ifid_pc;
                idex_pc_next   <= ifid_pc_next;
                idex_rs1_value <= rs1_value_id;
                idex_rs2_value <= rs2_value_id;
                idex_immediate <= immediate_id;
                idex_rs1_addr  <= rs1_addr_id;
                idex_rs2_addr  <= rs2_addr_id;
                idex_rd_addr   <= rd_addr_id;
                idex_op_class  <= op_class_id;
                idex_alu_op    <= alu_op_id;
                idex_cond_op   <= cond_op_id;
                idex_a_sel     <= a_sel_id;
                idex_b_sel     <= b_sel_id;
            end if;
        end if;
    end process;

    --==================================================================
    -- EX STAGE
    --==================================================================

    -- Forwarding unit: combinatoriamente decide se prendere i valori
    -- da regfile (00), da EX/MEM (01), o da MEM/WB (10).
    u_forward: entity work.forwarding_unit
        port map (
            idex_rs1       => idex_rs1_addr,
            idex_rs2       => idex_rs2_addr,
            exmem_rd       => exmem_rd_addr,
            exmem_regwrite => exmem_regwrite,
            memwb_rd       => memwb_rd_addr,
            memwb_regwrite => memwb_regwrite,
            fwd_a          => fwd_a,
            fwd_b          => fwd_b
        );

    -- Mux di forwarding sui due operandi
    rs1_fwd <= exmem_alu_result when fwd_a = "01"
          else wb_data          when fwd_a = "10"
          else idex_rs1_value;

    rs2_fwd <= exmem_alu_result when fwd_b = "01"
          else wb_data          when fwd_b = "10"
          else idex_rs2_value;

    -- Mux operandi ALU (a_sel: 0=PC, 1=rs1; b_sel: 0=rs2, 1=imm)
    pc_ex_32 <= x"00000" & idex_pc;
    alu_a_ex <= pc_ex_32 when idex_a_sel = '0' else rs1_fwd;
    alu_b_ex <= rs2_fwd  when idex_b_sel = '0' else idex_immediate;

    u_alu: entity work.alu
        port map (
            clk            => clk,
            a              => alu_a_ex,
            b              => alu_b_ex,
            alu_opcode     => idex_alu_op,
            alu_pre_result => alu_result_ex,
            alu_result     => alu_result_latched   -- not used in pipeline
        );

    --------------------------------------------------------------------
    -- Comparator combinatorio replicato qui (il modulo work.comparator
    -- ha output latched, non adatto al branch in EX nello stesso ciclo).
    --   cond_op_id semantica (uguale a comparator.vhd):
    --     000 EQ, 001 NEQ, 100 LT signed, 101 GE signed, altri -> 0
    --------------------------------------------------------------------
    process(idex_cond_op, rs1_fwd, rs2_fwd)
        variable sa, sb : signed(31 downto 0);
    begin
        sa := signed(rs1_fwd);
        sb := signed(rs2_fwd);
        branch_cond_ex <= '0';   -- default
        case idex_cond_op is
            when "000"  => if sa = sb  then branch_cond_ex <= '1'; end if;
            when "001"  => if sa /= sb then branch_cond_ex <= '1'; end if;
            when "100"  => if sa < sb  then branch_cond_ex <= '1'; end if;
            when "101"  => if sa >= sb then branch_cond_ex <= '1'; end if;
            when others => null;
        end case;
    end process;

    -- Branch taken: B-type con condizione vera OPPURE J-type (sempre)
    branch_taken_ex <= (idex_op_class(3) and branch_cond_ex)
                   or  idex_op_class(4);

    -- Quando branch taken, ridirigi il PC al target (= alu_result_ex)
    pc_redirect <= branch_taken_ex;
    pc_target   <= alu_result_ex(11 downto 0);
    flush_ifid  <= pc_redirect;

    --==================================================================
    -- EX/MEM PIPELINE REGISTER
    --==================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                exmem_alu_result <= (others => '0');
                exmem_rs2_value  <= (others => '0');
                exmem_pc_next    <= (others => '0');
                exmem_rd_addr    <= (others => '0');
                exmem_op_class   <= (others => '0');
                exmem_regwrite   <= '0';
                exmem_memwrite   <= '0';
            else
                exmem_alu_result <= alu_result_ex;
                exmem_rs2_value  <= rs2_fwd;
                exmem_pc_next    <= idex_pc_next;
                exmem_rd_addr    <= idex_rd_addr;
                exmem_op_class   <= idex_op_class;
                -- Controlli precalcolati dal op_class:
                -- regwrite = O or L or J
                exmem_regwrite <= idex_op_class(0)
                              or  idex_op_class(2)
                              or  idex_op_class(4);
                -- memwrite = S
                exmem_memwrite <= idex_op_class(1);
            end if;
        end if;
    end process;

    --==================================================================
    -- MEM STAGE: memory_map (DMEM + UART + GPIO)
    --==================================================================
    u_mmap: entity work.memory_map
        generic map (
            CLK_HZ => CLK_HZ,
            BAUD   => BAUD
        )
        port map (
            clk         => clk,
            reset       => reset,
            addr        => exmem_alu_result,
            we          => exmem_memwrite,
            din         => exmem_rs2_value,
            dout        => mem_out_mem,
            uart_tx_pin => uart_tx_pin,
            led_out     => led_out,
            sw_in       => sw_in
        );

    --==================================================================
    -- MEM/WB PIPELINE REGISTER
    --==================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                memwb_alu_result <= (others => '0');
                memwb_mem_out    <= (others => '0');
                memwb_pc_next_32 <= (others => '0');
                memwb_rd_addr    <= (others => '0');
                memwb_op_class   <= (others => '0');
                memwb_regwrite   <= '0';
            else
                memwb_alu_result <= exmem_alu_result;
                memwb_mem_out    <= mem_out_mem;
                memwb_pc_next_32 <= x"00000" & exmem_pc_next;
                memwb_rd_addr    <= exmem_rd_addr;
                memwb_op_class   <= exmem_op_class;
                memwb_regwrite   <= exmem_regwrite;
            end if;
        end if;
    end process;

    --==================================================================
    -- WB STAGE: mux della sorgente del writeback
    --==================================================================
    --   op_class(L) -> mem_out (LW)
    --   op_class(J) -> pc_next (JAL, return address)
    --   default     -> alu_result (ALU op)
    --   (S, B non scrivono il regfile, controllato dal memwb_regwrite)
    --==================================================================
    wb_data <= memwb_mem_out    when memwb_op_class(2) = '1'   -- Load
          else memwb_pc_next_32 when memwb_op_class(4) = '1'   -- Jump
          else memwb_alu_result;                                 -- ALU op

    --==================================================================
    -- DEBUG OUTPUT (per simulazione)
    --==================================================================
    dbg_pc         <= pc_if;
    dbg_instr      <= ifid_instr;
    dbg_state      <= "00";   -- placeholder: la pipeline non ha "stati"
    dbg_alu_result <= alu_result_ex;
    dbg_mem_out    <= mem_out_mem;
    dbg_rd_value   <= wb_data;

end Behavioral;
