# Architettura RISC-V — specifica del Prof. Passerone

Riferimento al PDF `21.RISCV_guidelines.pdf`. Questa è **la** spec da seguire — sostituisce qualsiasi convenzione "Patterson textbook" che avevo usato in precedenza.

---

## 1. Scelta architetturale: multi-cycle FSM, NON single-cycle

Il prof specifica un'architettura **multi-cycle a 4 fasi** controllata da una **state machine**:

```
   ┌──────┐ pc_load=1 ┌──────┐         ┌─────────┐         ┌─────────┐
   │FETCH │──────────▶│DECODE│────────▶│ EXECUTE │────────▶│ MEM/WB  │──┐
   └──────┘           └──────┘         └─────────┘         └─────────┘  │
       ▲                                                                 │
       └─────────────────────────────────────────────────────────────────┘
                          (fine istruzione, ricomincia)
```

| Fase | Cosa succede | Output disponibile |
|---|---|---|
| **FETCH** | PC carica nuovo valore, BRAM IMEM in lettura, segnale `pc_load=1` | (a fine fase) — IMEM darà l'istruzione al ciclo successivo |
| **DECODE** | `instruction` arrivata, decoder produce segnali di controllo, register file legge `rs1` e `rs2`, immediate generator estrae imm | `rs1_value`, `rs2_value`, `immediate`, segnali decoder (latched) |
| **EXECUTE** | ALU calcola risultato. `alu_pre_result` (combinatorio) già disponibile per indirizzare DMEM. Comparatore valuta condizione branch | `alu_result` (latched), `alu_pre_result` (no latch), `branch_cond` (latched) |
| **MEM/WB** | Per Store: scrive DMEM. Per Load: legge DMEM. Selezione `rd_value` (= ALU result, mem_out, o next_pc per JAL). Aggiornamento PC. `rd_write_en=1` se serve | `rd_value`, `pc_out`, `mem_out` |

**Una istruzione = 4 cicli di clock** (modulo eventuali ottimizzazioni / load-use stalls).

**Perché non single-cycle?** Perché le BRAM su FPGA hanno output sincrono → la lettura della IMEM/DMEM costa 1 ciclo di clock. Per nascondere questa latenza il prof spezza l'esecuzione in fasi e fa coincidere ogni "lettura" con una transizione di fase.

---

## 2. ISA ridotta — solo 14 istruzioni

Solo queste vanno implementate (le colorate nelle slide 6 e 7 del PDF):

| Mnemonico | Tipo | opcode | funct3 | funct7 | Note |
|---|---|---|---|---|---|
| `JAL`  | J | `1101111` | — | — | salto incondizionato + salva return address |
| `BEQ`  | B | `1100011` | `000` | — | branch if equal |
| `BNE`  | B | `1100011` | `001` | — | branch if not equal |
| `BLT`  | B | `1100011` | `100` | — | branch if less than (signed) |
| `BGE`  | B | `1100011` | `101` | — | branch if greater or equal (signed) |
| `LW`   | I | `0000011` | `010` | — | load word (32 bit) |
| `SW`   | S | `0100011` | `010` | — | store word (32 bit) |
| `ADDI` | I | `0010011` | `000` | — | rs1 + imm |
| `XORI` | I | `0010011` | `100` | — | rs1 XOR imm |
| `ORI`  | I | `0010011` | `110` | — | rs1 OR imm |
| `ANDI` | I | `0010011` | `111` | — | rs1 AND imm |
| `ADD`  | R | `0110011` | `000` | `0000000` | rs1 + rs2 |
| `SUB`  | R | `0110011` | `000` | `0100000` | rs1 - rs2 |
| `XOR`  | R | `0110011` | `100` | `0000000` | rs1 XOR rs2 |
| `OR`   | R | `0110011` | `110` | `0000000` | rs1 OR rs2 |
| `AND`  | R | `0110011` | `111` | `0000000` | rs1 AND rs2 |

**NON ci sono**: shift (SLL/SRL/SRA/SLLI/SRLI/SRAI), confronti (SLT/SLTU/SLTI/SLTIU), branch unsigned (BLTU/BGEU), JALR, LUI, AUIPC, LB/LH/LBU/LHU, SB/SH, ECALL/EBREAK/FENCE.

---

## 3. Moduli specifici e segnali

### 3.1 Instruction Fetch (slide 14)

```
    ┌────────────────────────────────────────────────┐
    │              INSTRUCTION FETCH                 │
    │                                                │
    │   pc_in[11:0] ──▶ ┌────┐                       │
    │       load_en ──▶ │ PC │── pc[11:0] ─┬──▶ +4 ──── next_pc[11:0]
    │                   └────┘             │                            │
    │                                      │                            │
    │                                      └─▶ pc[11:2] ──▶ addra (BRAM)│
    │                                                  ┌─────────────┐  │
    │                                                  │ Instr Mem   │── instruction[31:0]
    │                                                  │ 1024 × 32   │  │
    │                                                  │   BRAM      │  │
    │                                                  │ (sync read) │  │
    │                                                  └─────────────┘  │
    │   pc_load ──▶ load_en del PC                                      │
    └────────────────────────────────────────────────────────────────────┘
```

**Note implementative:**
- PC è un registro a 12 bit. Si carica solo quando `pc_load='1'` (controllato dalla FSM nella fase FETCH).
- Solo `pc[11:2]` va alla BRAM (indirizzo a livello word, non byte).
- BRAM è **sincrona**: `instruction` esce al ciclo successivo.
- `next_pc = pc + 4` calcolato **combinatoriamente** in parallelo (è un offset di byte).
- Il PC fa aritmetica a livello byte (perché RISC-V calcola offset dei branch a partire dal current PC, in byte).

**Domanda aperta** del prof (slide 14): "Need registers here?" — riferito a `next_pc`. Risposta tipica: sì, di solito lo registriamo per essere sicuri di propagarlo alle fasi dopo.

### 3.2 Instruction Decode (slide 16)

Tre componenti in parallelo:

**a) Register File** (distributed RAM, NON BRAM)
- 32 × 32 bit
- 2 porte: una shared read/write (`a` indirizza, `qspo` legge, `d/we` scrivono), una read-only (`dpra` indirizza, `qdpo` legge)
- `mux` davanti al port `a` sceglie tra `rd` (in scrittura) e `rs1` (in lettura) a seconda della fase
- Output **latched** (sopra c'è già un registro implicito nel ciclo successivo)
- `rd_write_en` generato dalla FSM, alto solo nella fase MEM/WB e solo per ALU ops/Loads/Jumps

**b) Decoder** (logica combinatoria)
- Input: `funct3`, `funct7`, `opcode`
- Output (tutti latched a fine fase DECODE):
  - `op_class[4:0]` — **one-hot**: bit 0 = O (ALU op), bit 1 = S (store), bit 2 = L (load), bit 3 = B (branch), bit 4 = J (jump)
  - `alu_opcode[2:0]` — derivato da funct3 (con eccezione per SUB)
  - `a_sel` — 0 = `curr_pc`, 1 = `rs1_value` (per scegliere primo input ALU)
  - `b_sel` — 0 = `rs2_value`, 1 = `immediate` (secondo input ALU)
  - `cond_opcode[2:0]` — derivato da funct3 per le branch

**c) Sign Extension** (logica combinatoria)
- Input: `instruction` + `opcode`
- Output: `immediate[31:0]` (latched a fine DECODE)
- Gestisce i tipi I, S, B, J (NON serve U perché niente LUI/AUIPC)

**Inoltre**: `next_pc[11:0]` e `curr_pc[11:0]` vengono **estesi a 32 bit** (zero-extension) per poter essere usati come operandi ALU (es. JAL fa `rd = curr_pc + 4`, quindi serve a 32 bit per finire nel register file).

### 3.3 Instruction Execute (slide 18)

```
    rs1_value ──┬─▶┌────┐               ┌─────┐
                │  │mux ├──▶┌─────┐     │ reg │── alu_result[31:0] (latched)
    curr_pc ────┘  └────┘   │ ALU │──┬──▶─────┘
                a_sel       │     │  │
                            │ 6op │  └─────────── alu_pre_result[31:0] (NON latched, combinatorio)
    rs2_value ──┬─▶┌────┐   └─────┘
                │  │mux ├──▶
    immediate ──┘  └────┘
                b_sel
                            ▲
              alu_opcode ───┘  (3 bit: 000 ADD, 001 ADDU, 010 SUB,
                                       100 XOR, 110 OR,  111 AND)

    rs1_value ──▶ ┌──────┐         ┌─────┐
    rs2_value ──▶ │ COMP │────────▶│ reg │── branch_cond (latched)
                  │ 4 op │         └─────┘
                  └──────┘
                  ▲
   cond_opcode ───┘  (3 bit: 000 EQ, 001 NEQ, 100 LT, 101 GE)
```

**Punto chiave**: `alu_pre_result` è il risultato combinatorio dell'ALU **senza il registro di latch**. Serve per indirizzare la DMEM **prima** che il latch lo registri, così quando si entra in fase MEM/WB la DMEM ha già fatto la sua lettura. È un trucco per nascondere la latenza della BRAM.

### 3.4 Memory Access + Write Back (slide 20)

```
    alu_pre_result[13:2] ──▶ addra (DMEM)
    rs2_value           ──▶ dina  (per store)
    op_class(S) AND mem_we_state ──▶ wea
                                ┌─────────────┐
                                │ Data Memory │── mem_out[31:0]
                                │ 4096 × 32   │
                                │   BRAM      │
                                └─────────────┘

    Mux finale per rd_value (selezionato da op_class):
       op_class = O → rd_value = alu_result
       op_class = L → rd_value = mem_out
       op_class = J → rd_value = next_pc

    Mux finale per pc_out (selezionato da op_class + branch_cond):
       op_class = J         → pc_out = alu_result   (jump target)
       op_class = B && cond → pc_out = alu_result   (branch taken)
       altrimenti           → pc_out = next_pc      (sequential)
```

---

## 4. Encoding op_class (one-hot 5 bit)

| Bit | Categoria | Istruzioni |
|---|---|---|
| 0 (O) | ALU operation | ADDI, XORI, ORI, ANDI, ADD, SUB, XOR, OR, AND |
| 1 (S) | Store | SW |
| 2 (L) | Load | LW |
| 3 (B) | Branch | BEQ, BNE, BLT, BGE |
| 4 (J) | Jump | JAL |

**One-hot** = solo 1 bit alto alla volta. Il decoder lo produce a partire dall'opcode.

---

## 5. Mappatura `alu_opcode` (3 bit)

Il prof usa una codifica derivata da funct3, **tranne per SUB** che ha funct3=000 (uguale a ADD) e si distingue dal funct7:

| `alu_opcode` | Operazione | Da quale funct3 (+funct7 per SUB) |
|---|---|---|
| `000` | ADD | funct3=000, funct7=0000000 |
| `001` | ADDU | usato per calcoli interni di indirizzo (immagino LW/SW/branch target) |
| `010` | SUB | funct3=000, funct7=0100000 |
| `100` | XOR | funct3=100 |
| `110` | OR | funct3=110 |
| `111` | AND | funct3=111 |

(La differenza tra ADD e ADDU non è strettamente necessaria nell'ISA RV32I — entrambi sono in pratica una somma a 32 bit. Probabilmente il prof la include per coerenza didattica con MIPS, o per gestire flag di overflow.)

---

## 6. Mappatura `cond_opcode` (3 bit) — comparatore per branch

| `cond_opcode` | Op | funct3 dell'istruzione |
|---|---|---|
| `000` | EQ  (rs1 == rs2) | BEQ funct3=000 |
| `001` | NEQ (rs1 != rs2) | BNE funct3=001 |
| `100` | LT  (rs1 <  rs2 signed) | BLT funct3=100 |
| `101` | GE  (rs1 >= rs2 signed) | BGE funct3=101 |

Per altri valori → `branch_cond=0` (mai prendere il branch).

---

## 7. FSM di controllo — segnali generati

| Segnale | FETCH | DECODE | EXECUTE | MEM/WB |
|---|---|---|---|---|
| `pc_load` | **1** | 0 | 0 | 0 |
| `mem_we` | 0 | 0 | 0 | **1** se Store |
| `rd_write_en` | 0 | 0 | 0 | **1** se ALU op / Load / Jump |
| `regfile.a_mux` | rs1 | rs1 | rd | rd |

E ovviamente `state` cicla `FETCH → DECODE → EXECUTE → MEM/WB → FETCH → …`.

---

## 8. Differenze rispetto alla "single-cycle Patterson textbook"

| | Patterson textbook | Spec del prof |
|---|---|---|
| Cicli per istruzione | 1 | 4 |
| ISA | RV32I completo (40 istr) | Subset 14 istr |
| ALU op | 10 operazioni, 4 bit | 6 operazioni, 3 bit |
| Comparatore | integrato in ALU (zero flag + SLT) | modulo separato |
| Memorie | combinatorie idealizzate | BRAM sincrone reali |
| PC | 32 bit | 12 bit |
| op_class | non esiste | 5-bit one-hot |
| Latency hiding | no | sì (`alu_pre_result`) |

---

## 9. Cosa devo riscrivere/aggiungere

- ✅ `regfile.vhd` — quasi OK, ma serve un mux davanti al port `a` per shared read/write (lo aggiungo io).
- ✅ `immediate_gen.vhd` — OK così, gestisce I/S/B/J. Il tipo U non serve.
- 🔄 `alu.vhd` — **da semplificare** a 6 operazioni (ADD/ADDU/SUB/XOR/OR/AND) con opcode 3 bit. Devo anche aggiungere `alu_pre_result` (uscita combinatoria pre-latch).
- 🆕 `comparator.vhd` — modulo separato per branch (4 op).
- 🆕 `decoder.vhd` — produce `op_class` one-hot, `alu_opcode`, `cond_opcode`, `a_sel`, `b_sel`, `imm_type`.
- 🆕 `pc_unit.vhd` — registro PC + `+4` + mux per pc_out.
- 🆕 `instr_memory.vhd` — wrapper su BRAM da 1024×32 con codice precaricato.
- 🆕 `data_memory.vhd` — wrapper su BRAM da 4096×32.
- 🆕 `control_fsm.vhd` — FSM 4 stati che genera `pc_load`, `mem_we`, `rd_write_en`, ecc.
- 🆕 `cpu_top.vhd` — integra tutto.
