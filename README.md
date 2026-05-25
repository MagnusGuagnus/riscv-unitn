# RISC-V on FPGA — Advanced Logic Design Project

Progetto per il corso di Advanced Logic Design (Prof. Roberto Passerone, UniTN).

## Obiettivo

Implementare un processore RV32I in VHDL con almeno una estensione architetturale significativa (pipeline 5-stage + forwarding) e periferiche per I/O (UART, GPIO).

## Architettura di riferimento

Si segue la spec ufficiale del prof in `21.RISCV_guidelines.pdf` — vedi documento dedicato [`docs/prof_architecture_spec.md`](docs/prof_architecture_spec.md).

In sintesi:
- **Multi-cycle FSM-based** (4 stati: fetch / decode / execute / mem-wb), NON single-cycle.
- **ISA ridotta a 14 istruzioni** (no shift, no SLT, no LUI/AUIPC/JALR, no LB/LH/LBU/LHU/SB/SH, no BLTU/BGEU).
- ALU custom 3-bit (6 op), comparatore separato 3-bit (4 op).
- IMEM 4 kB (1024×32), DMEM 16 kB (4096×32), entrambe BRAM sincrone.
- PC a 12 bit (4 kB byte-addressable).
- `op_class` 5-bit one-hot (O/S/L/B/J).

## Scope

### Core (obbligatorio per consegna — segue spec del prof)

- Datapath multi-cycle FSM con 4 stati.
- 14 istruzioni RV32I subset: JAL, BEQ/BNE/BLT/BGE, LW, SW, ADDI/XORI/ORI/ANDI, ADD/SUB/XOR/OR/AND.
- Register file 32×32-bit distributed RAM con shared read/write port (x0 hardwired a 0).
- ALU 6-op + comparatore separato 4-op.
- IMEM e DMEM su BRAM sincrone, programma caricato via initialization file.
- Programmi di test in assembly compilati con assembler online RISC-V (riscvasm.lucasteske.dev) o godbolt.org.
- Report tecnico + simulazioni + demo.

### Estensioni possibili (per voto pieno — da concordare col prof)

- **Pipelining**: convertire da multi-cycle a 5-stage pipelined (con forwarding e stall logic).
- **Periferica UART**: per stampare risultati su PC.
- **Periferica GPIO**: per LED/switch (Nexys4 DDR ne ha 16+16).
- **Estensione M**: moltiplicatore hardware (MUL/MULH/DIV/REM).
- **Estensione di istruzioni**: aggiungere SLT/SLTU/SLLI/SRLI/SRAI per ampliare l'ISA.
- **Branch predictor** (utile solo dopo aver pipelinato).

## Struttura cartelle

```
RISC-V Proj/
├── README.md             — questo file
├── docs/                 — report, schemi, appunti
│   └── (architecture diagrams, FSM, …)
├── src/
│   ├── core/             — CPU
│   │   ├── alu.vhd
│   │   ├── regfile.vhd
│   │   ├── decoder.vhd
│   │   ├── control_unit.vhd
│   │   ├── immediate_gen.vhd
│   │   ├── branch_unit.vhd
│   │   ├── pipeline_regs.vhd     (versione pipelined)
│   │   ├── hazard_unit.vhd       (versione pipelined)
│   │   ├── forwarding_unit.vhd   (versione pipelined)
│   │   └── cpu_top.vhd
│   ├── memory/
│   │   ├── instruction_memory.vhd
│   │   ├── data_memory.vhd
│   │   └── memory_map.vhd
│   └── peripherals/
│       ├── uart_tx.vhd
│       ├── uart_rx.vhd
│       ├── uart_top.vhd
│       └── gpio.vhd
├── sim/                  — testbench
│   ├── tb_alu.vhd
│   ├── tb_regfile.vhd
│   ├── tb_cpu_singlecycle.vhd
│   ├── tb_cpu_pipelined.vhd
│   └── tb_uart.vhd
├── sw/
│   ├── asm/              — programmi di test in assembly
│   └── c/                — programmi di test in C + linker script
├── constraints/          — file .xdc per la board target
└── email_proposta_progetto.md
```

## Target FPGA

Il corso supporta ufficialmente **due board** (master XDC forniti tra i materiali del corso):

| Board | Part | LUT | BRAM | Note |
|---|---|---|---|---|
| **Nexys4 DDR** ← scelta consigliata | `xc7a100tcsg324-1` (Artix-7 XC7A100T) | 63k | 135 | FPGA puro. 16 switch, 16 LED, 7-seg×8, VGA, UART USB, microfono, accelerometro. Setup semplice. |
| **Zedboard** | `xc7z020clg484-1` (Zynq Z-7020) | 53k | 140 | FPGA + dual-core ARM. Configurazione Vivado più complessa (PS da disabilitare). HDMI, OLED. |

**Nota**: il Chess project dell'anno scorso era erroneamente impostato su `xc7k70tfbv676-1` (Kintex-7 KC705) — Part sbagliata, ma in simulazione il codice gira identico. Quando si crea il nuovo progetto Vivado, scegliere correttamente la Part della board reale.

**Constraint .xdc**: i master XDC delle due board sono **già forniti dal prof** nei materiali del corso (sezione "Board resources"):
- `zedboard master XDC RevC D v2`
- `Nexys4DDR Master xdc file`

Vanno scaricati e copiati in `constraints/`, poi de-commentati i pin che si usano effettivamente nel progetto.

## ISA implementata (14 istruzioni)

| Categoria | Istruzioni |
|---|---|
| R-type ALU | ADD, SUB, XOR, OR, AND |
| I-type ALU | ADDI, XORI, ORI, ANDI |
| I-type Load | LW |
| S-type Store | SW |
| B-type Branch | BEQ, BNE, BLT, BGE |
| J-type Jump | JAL |

## Architettura — multi-cycle FSM (4 stati)

```
   ┌──────┐ pc_load=1 ┌──────┐         ┌─────────┐         ┌─────────┐
   │FETCH │──────────▶│DECODE│────────▶│ EXECUTE │────────▶│ MEM/WB  │──┐
   └──────┘           └──────┘         └─────────┘         └─────────┘  │
       ▲                                                                 │
       └─────────────────────────────────────────────────────────────────┘
                          (fine istruzione, ricomincia)

   FETCH:    PC carica nuovo valore, BRAM IMEM in lettura
   DECODE:   instruction decodificata, regfile letto, immediate estratto
   EXECUTE:  ALU + comparator
   MEM/WB:   accesso DMEM (load/store), writeback nel regfile, update PC
```

Vedi [`docs/prof_architecture_spec.md`](docs/prof_architecture_spec.md) per i block diagram dettagliati di ogni fase.

## Roadmap sviluppo (ordine consigliato)

1. **Setup ambiente** — Vivado project, RISC-V GCC toolchain, board files
2. **Single-cycle CPU** — partire da qua, debug più facile
   1. ALU + testbench
   2. Register file + testbench
   3. Decoder + immediate generator
   4. Datapath integrato single-cycle
   5. Test con programma asm trivial (somma due numeri, scrive in dmem)
3. **Memorie** — IMEM/DMEM in BRAM, conversione .hex da assembler
4. **UART** — TX prima, poi RX, testbench, integrazione memory-mapped
5. **Programmi di test** — "Hello World" via UART
6. **Pipelining** — refactor del datapath, registri di pipeline, hazard unit
7. **Forwarding** — EX→EX, MEM→EX
8. **Branch handling** — flush IF/ID, gestione control hazards
9. **GPIO** + integrazione finale
10. **Programmi dimostrativi** — Fibonacci, ordinamento, eco UART
11. **Analisi** — critical path, resource usage, performance
12. **Report + demo**

## Stima tempi (solo, ~10h/settimana)

| Fase | Settimane |
|---|---|
| Single-cycle + UART + test base | 4-5 |
| Conversione a pipeline + forwarding | 4-5 |
| GPIO + programmi demo + analisi | 1-2 |
| Report + preparazione demo | 1-2 |
| **Totale** | **~10-14 settimane** |

## Risorse di riferimento

- **Spec ufficiale**: "The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA" (riscv.org/specifications)
- **Reference design didattici**:
  - PicoRV32 (https://github.com/YosysHQ/picorv32) — singolo file, molto leggibile
  - NEORV32 (https://github.com/stnolting/neorv32) — completo, modulare
  - DarkRISCV — minimale
- **Toolchain**: `riscv32-unknown-elf-gcc` (binari precompilati o compilazione da sorgenti)
- **Patterson & Hennessy** "Computer Organization and Design — RISC-V Edition" — capitolo 4 per il datapath
- **Slide del corso**: lezioni su RISC-V e pipelining
