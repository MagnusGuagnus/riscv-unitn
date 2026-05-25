# TODO — moduli core CPU

## Fase A (core multi-cycle) ✅ completata

- [x] `alu.vhd` — ALU 6 op (3-bit opcode) secondo spec del prof
- [x] `regfile.vhd` — register file 32x32 con x0 hardwired, porta A condivisa
- [x] `immediate_gen.vhd` — sign-extension per I/S/B/J
- [x] `decoder.vhd` — opcode/funct3/funct7 → op_class (one-hot 5b), alu_opcode, cond_opcode, a_sel, b_sel, imm_type
- [x] `comparator.vhd` — 4 op (EQ/NEQ/LT/GE) per branch
- [x] `pc_unit.vhd` — PC 12-bit + adder +4 + word address
- [x] `control_fsm.vhd` — FSM 4 stati (FETCH/DECODE/EXECUTE/MEM_WB)
- [x] `instr_memory.vhd` / `data_memory.vhd` — BRAM sincrone
- [x] `cpu_top.vhd` — datapath integrato

## Fase B (periferiche memory-mapped) ✅ completata

- [x] `peripherals/uart_tx.vhd` — UART TX 8N1, generic CLK_HZ/BAUD
- [x] `peripherals/gpio.vhd` — 16 LED + 16 switch con synchronizer 2-FF
- [x] `memory/memory_map.vhd` — address decoder + bus DMEM/UART/GPIO
- [x] `cpu_top.vhd` aggiornato: usa memory_map al posto di data_memory diretta;
       espone pin esterni uart_tx_pin, led_out[15:0], sw_in[15:0]

## Da scrivere — versione pipelined (Fase 4, voto pieno)

- [ ] `pipeline_regs.vhd` — IF/ID, ID/EX, EX/MEM, MEM/WB
- [ ] `hazard_unit.vhd` — load-use stall, control hazard flush
- [ ] `forwarding_unit.vhd` — forwarding EX→EX, MEM→EX
- [ ] `cpu_pipelined.vhd` — top con pipeline

## Note di design

- PC è 12 bit (spec prof, IMEM 4 kB byte-addressable).
- Tutte le istruzioni allineate a 4 byte (no compressed instructions).
- ECALL / EBREAK / FENCE: non implementati (fuori dall'ISA ridotta del prof).
- Memory map autoritativa (vedi `docs/peripherals_overview.md`):
  - `0x0000_0000` – `0x0000_3FFF` DMEM (16 KB, BRAM)
  - `0x0001_0000` UART_DATA   (W)  — byte da trasmettere
  - `0x0001_0004` UART_STATUS (R)  — bit 0 = ready (= NOT busy)
  - `0x0001_0008` GPIO_LED    (W)  — 16 LED Nexys4 DDR
  - `0x0001_000C` GPIO_SW     (R)  — 16 switch Nexys4 DDR
- Decoder: `addr[16]` (DMEM/periferiche), `addr[3]` (UART/GPIO), `addr[2]` (data/status).
- IMEM è indirizzata internamente dal PC, non è memory-mapped (vive in uno spazio
  indirizzi separato gestito direttamente da `pc_unit` + `instr_memory`).
