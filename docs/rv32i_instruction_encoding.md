# RV32I — Instruction Encoding Reference

Riferimento completo dei 6 formati di istruzione RV32I e di tutti i campi che il decoder deve estrarre. Da tenere aperto mentre scrivi `decoder.vhd` e `control_unit.vhd`.

---

## 0. Concetto chiave: istruzione vs register file

**Istruzione** = 32 bit letti dalla **instruction memory** ad ogni ciclo di clock. È il "comando" che la CPU deve eseguire. Esempi: `0x002080B3` (= `add x3, x1, x2`).

**Register file** = memoria interna alla CPU, separata, con 32 registri da 32 bit ciascuno. È **il dato**, non l'istruzione.

L'istruzione **contiene gli indirizzi** dei registri da usare (campi `rs1`, `rs2`, `rd`), ma l'istruzione e il register file sono due cose distinte:

```
┌────────────────────┐                  ┌──────────────────────┐
│  Instruction Mem   │                  │   Register File      │
│   (programma)      │                  │   (dati)             │
│                    │                  │                      │
│  PC → 32 bit ──────┼─→ decoder ──┬───→│  rs1_addr = 5 bit    │
│                    │             │    │  → ritorna 32 bit    │
│                    │             ├───→│  rs2_addr = 5 bit    │
│                    │             │    │  → ritorna 32 bit    │
│                    │             └───→│  rd_addr  = 5 bit    │
│                    │                  │  ← scrive 32 bit     │
└────────────────────┘                  └──────────────────────┘
```

Il decoder è il "ponte" tra le due: prende l'istruzione, ne estrae i 5-bit `rs1/rs2/rd`, e li passa al register file.

---

## 1. Layout generico — campi comuni

In RV32I **tutte** le istruzioni sono 32 bit e condividono questi campi nelle stesse posizioni (questo è uno dei design goal di RISC-V: rendere il decoder semplice):

```
 31        25 24      20 19      15 14    12 11        7 6           0
┌─────────────┬──────────┬──────────┬────────┬──────────┬─────────────┐
│   bit 31:25 │  24:20   │  19:15   │ 14:12  │  11:7    │   6:0       │
└─────────────┴──────────┴──────────┴────────┴──────────┴─────────────┘
   funct7 /     rs2 /      rs1       funct3    rd /         opcode
   imm[11:5] /  shamt /                        imm[4:0]
   imm…       imm[4:0]
```

I campi che **non cambiano mai posizione** sono:

| Campo | Bit | Largh. | Cosa contiene |
|---|---|---|---|
| `opcode` | `[6:0]` | 7 | dice di che tipo è l'istruzione (ADD vs LW vs BEQ vs …) |
| `rd` | `[11:7]` | 5 | indirizzo del registro destinazione (per le istruzioni che scrivono) |
| `funct3` | `[14:12]` | 3 | "sotto-tipo" dell'opcode (es: distingue ADD da SUB, BEQ da BNE) |
| `rs1` | `[19:15]` | 5 | indirizzo del primo registro sorgente |
| `rs2` | `[24:20]` | 5 | indirizzo del secondo registro sorgente (oppure shamt/imm) |
| `funct7` | `[31:25]` | 7 | ulteriore distinzione (es: ADD vs SUB hanno stesso opcode+funct3, diverso funct7) |

**Tradotto in VHDL** (questo te lo metterò nel decoder):
```vhdl
opcode <= instr(6 downto 0);
rd     <= instr(11 downto 7);
funct3 <= instr(14 downto 12);
rs1    <= instr(19 downto 15);
rs2    <= instr(24 downto 20);
funct7 <= instr(31 downto 25);
```

A seconda del **tipo** di istruzione, alcuni di questi campi sono interpretati diversamente o non esistono (vedi sotto).

---

## 2. I 6 formati

### 2.1 R-type (registro–registro)

Per istruzioni puramente registro-su-registro: `add`, `sub`, `and`, `or`, `xor`, `sll`, `srl`, `sra`, `slt`, `sltu`.

```
 31      25 24   20 19   15 14  12 11    7 6      0
┌─────────┬───────┬───────┬─────┬───────┬─────────┐
│ funct7  │  rs2  │  rs1  │funct│  rd   │ opcode  │
│         │       │       │  3  │       │         │
└─────────┴───────┴───────┴─────┴───────┴─────────┘
```

- `opcode` = `0110011` per tutte le R-type ALU
- `funct3` + `funct7` distinguono l'operazione specifica
- **Nessun immediato**

**Esempio** `add x3, x1, x2`:
```
funct7  rs2    rs1    funct3 rd     opcode
0000000 00010  00001  000    00011  0110011
   ↓      ↓      ↓     ↓      ↓       ↓
   0      2      1     ADD    3     R-ALU
```

### 2.2 I-type (immediato)

Per istruzioni con un immediato a 12 bit: `addi`, `andi`, `ori`, `xori`, `slti`, `sltiu`, `slli`, `srli`, `srai`, **load** (`lw`, `lh`, `lb`, `lhu`, `lbu`), **`jalr`**, **`ecall`/`ebreak`**.

```
 31              20 19   15 14  12 11    7 6      0
┌──────────────────┬───────┬─────┬───────┬─────────┐
│   imm[11:0]      │  rs1  │funct│  rd   │ opcode  │
│                  │       │  3  │       │         │
└──────────────────┴───────┴─────┴───────┴─────────┘
```

- L'immediato è 12 bit, sign-extended a 32 bit dal mio `immediate_gen`
- **Niente rs2, niente funct7** (quei bit sono l'immediato)
- Eccezione: per `slli/srli/srai` i bit `[24:20]` sono lo shamt (5 bit, perché max shift = 31), e i bit `[31:25]` distinguono SRLI da SRAI

**Esempi:**
- `addi x3, x1, 100` → `imm=100, rs1=1, funct3=000, rd=3, opcode=0010011`
- `lw x5, 8(x2)` → `imm=8, rs1=2, funct3=010, rd=5, opcode=0000011`

### 2.3 S-type (store)

Per istruzioni di store: `sw`, `sh`, `sb`. **Non hanno `rd`** (non scrivono in un registro), quindi quei 5 bit ospitano i bit bassi dell'immediato.

```
 31      25 24   20 19   15 14  12 11        7 6      0
┌─────────┬───────┬───────┬─────┬───────────┬─────────┐
│imm[11:5]│  rs2  │  rs1  │funct│ imm[4:0]  │ opcode  │
└─────────┴───────┴───────┴─────┴───────────┴─────────┘
```

Perché i bit dell'imm sono sparsi? Per **mantenere `rs1` e `rs2` nelle stesse posizioni** delle altre istruzioni → decoder più semplice, register file legge sempre dagli stessi bit.

**Esempio** `sw x5, 8(x2)`:
- `rs1=2` (base address), `rs2=5` (data to store), `imm=8` (offset), `funct3=010`, `opcode=0100011`
- imm `0000000 01000` (12 bit) → split in `imm[11:5]=0000000` e `imm[4:0]=01000`

### 2.4 B-type (branch condizionale)

Per i branch: `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`. Niente `rd`. L'immediato è 13 bit (12 + il bit 0 implicito = 0), ma i bit sono ancora più sparsi.

```
 31      30      25 24   20 19   15 14  12 11      8 7        6      0
┌────┬────────────┬───────┬───────┬─────┬──────────┬────┬──────────┐
│ b12│ imm[10:5]  │  rs2  │  rs1  │funct│ imm[4:1] │b11 │  opcode  │
└────┴────────────┴───────┴───────┴─────┴──────────┴────┴──────────┘
```

- L'immediato è in **byte** ma il bit 0 è sempre 0 (i branch saltano sempre a indirizzi pari)
- Il bit 12 (segno) è in posizione 31, il bit 11 è in posizione 7 (sì, è strano — è uno dei trick per uniformare i decoder)
- Sign-extended a 32 bit

**Esempio** `beq x1, x2, label` (con offset = +16):
- offset = 16 = `0 000000 0 1000 0` (13 bit, LSB=0 implicito)
- Codifica: `imm[12]=0, imm[10:5]=000000, imm[4:1]=1000, imm[11]=0`

### 2.5 U-type (upper immediate)

Solo 2 istruzioni: `lui` (load upper immediate) e `auipc` (add upper immediate to PC). Caricano i 20 bit alti di una costante in un registro; i 12 bit bassi sono fissati a 0.

```
 31                              12 11    7 6      0
┌─────────────────────────────────┬───────┬─────────┐
│           imm[31:12]            │  rd   │ opcode  │
└─────────────────────────────────┴───────┴─────────┘
```

- Niente `rs1`, niente `rs2`, niente `funct3`, niente `funct7`
- **Non sign-extended**: l'immediato è già 32 bit (20 dell'istruzione + 12 zeri sotto)

**Esempio** `lui x3, 0x12345`:
- imm[31:12] = `0001 0010 0011 0100 0101`
- Risultato: `x3 = 0x12345000`

### 2.6 J-type (jump incondizionato)

Solo `jal` (jump and link). Salva `PC+4` in `rd` e salta a `PC + offset`. Offset 21 bit (20 + LSB=0 implicito).

```
 31    30      21 20      19              12 11    7 6      0
┌────┬───────────┬────┬──────────────────┬───────┬─────────┐
│ b20│ imm[10:1] │b11 │   imm[19:12]     │  rd   │ opcode  │
└────┴───────────┴────┴──────────────────┴───────┴─────────┘
```

Stesso "scrambling" del B-type, sempre per uniformare le posizioni di altri campi.

---

## 3. Tabella opcodes — i 7 valori che esistono in RV32I

Sono solo **7 opcode "primari"** in RV32I (più ECALL/EBREAK/FENCE che hanno opcode dedicati). Il decoder distingue questi 7, poi raffina con funct3/funct7.

| Opcode (bin) | Hex | Tipo | Categoria | Istruzioni |
|---|---|---|---|---|
| `0110011` | 0x33 | R | Register-Register ALU | ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU |
| `0010011` | 0x13 | I | Register-Immediate ALU | ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI |
| `0000011` | 0x03 | I | Load | LB, LH, LW, LBU, LHU |
| `0100011` | 0x23 | S | Store | SB, SH, SW |
| `1100011` | 0x63 | B | Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| `1101111` | 0x6F | J | Jump | JAL |
| `1100111` | 0x67 | I | Jump Register | JALR |
| `0110111` | 0x37 | U | LUI | LUI |
| `0010111` | 0x17 | U | AUIPC | AUIPC |
| `1110011` | 0x73 | I | System | ECALL, EBREAK |
| `0001111` | 0x0F | I | Memory ordering | FENCE |

---

## 4. Tabella funct3 + funct7 — discriminazione fine

### 4.1 R-type (`opcode = 0110011`)

| funct3 | funct7 | Istruzione |
|---|---|---|
| 000 | 0000000 | ADD |
| 000 | 0100000 | SUB |
| 001 | 0000000 | SLL |
| 010 | 0000000 | SLT |
| 011 | 0000000 | SLTU |
| 100 | 0000000 | XOR |
| 101 | 0000000 | SRL |
| 101 | 0100000 | SRA |
| 110 | 0000000 | OR |
| 111 | 0000000 | AND |

Nota: il **bit 30** dell'istruzione (cioè `funct7[5]`) è quello "speciale" che distingue ADD/SUB e SRL/SRA. Tutti gli altri bit di funct7 sono 0.

### 4.2 I-type ALU (`opcode = 0010011`)

| funct3 | funct7 (per shift) | Istruzione |
|---|---|---|
| 000 | — | ADDI |
| 010 | — | SLTI |
| 011 | — | SLTIU |
| 100 | — | XORI |
| 110 | — | ORI |
| 111 | — | ANDI |
| 001 | 0000000 | SLLI |
| 101 | 0000000 | SRLI |
| 101 | 0100000 | SRAI |

### 4.3 Load (`opcode = 0000011`)

| funct3 | Istruzione | Note |
|---|---|---|
| 000 | LB | byte signed |
| 001 | LH | halfword signed |
| 010 | LW | word (32 bit) |
| 100 | LBU | byte unsigned |
| 101 | LHU | halfword unsigned |

### 4.4 Store (`opcode = 0100011`)

| funct3 | Istruzione |
|---|---|
| 000 | SB |
| 001 | SH |
| 010 | SW |

### 4.5 Branch (`opcode = 1100011`)

| funct3 | Istruzione | Condizione |
|---|---|---|
| 000 | BEQ | rs1 == rs2 |
| 001 | BNE | rs1 != rs2 |
| 100 | BLT | rs1 < rs2  (signed) |
| 101 | BGE | rs1 >= rs2 (signed) |
| 110 | BLTU | rs1 < rs2  (unsigned) |
| 111 | BGEU | rs1 >= rs2 (unsigned) |

### 4.6 JALR (`opcode = 1100111`)

Solo `funct3 = 000` (gli altri sono riservati).

---

## 5. Cosa deve fare il `decoder.vhd`

Dato l'`instr` 32-bit in input, il decoder deve produrre questi segnali di uscita:

| Segnale | Larghezza | Cosa è |
|---|---|---|
| `opcode` | 7 | `instr[6:0]` (passa avanti per la control unit) |
| `funct3` | 3 | `instr[14:12]` |
| `funct7` | 7 | `instr[31:25]` |
| `rs1_addr` | 5 | `instr[19:15]` (al register file) |
| `rs2_addr` | 5 | `instr[24:20]` (al register file) |
| `rd_addr` | 5 | `instr[11:7]` (al register file) |
| `imm_type` | 3 | codice per il mio `immediate_gen` (000=I, 001=S, 010=B, 011=U, 100=J) |
| `alu_op` | 4 | codice operazione per la mia ALU |
| `alu_src` | 1 | 0 = secondo operando = `rs2_data`, 1 = secondo operando = `imm` |
| `mem_read` | 1 | è un load? |
| `mem_write` | 1 | è uno store? |
| `mem_to_reg` | 1 | scrivi nel reg il dato letto da memoria? (load) |
| `reg_write` | 1 | scrivi un risultato nel register file? |
| `branch` | 1 | è un branch? |
| `jump` | 1 | è un JAL/JALR? |
| `jalr` | 1 | è un JALR? (per il calcolo del target diverso da JAL) |

Lo strutturerò come **due processi case**:
1. Un grosso `case opcode is` che tira fuori i segnali "globali" (alu_src, mem_read/write, reg_write, branch, jump, imm_type).
2. Un `case` su funct3+funct7 (o un mini decoder dedicato chiamato `alu_control`) che decide il valore esatto di `alu_op` per l'ALU.

Te lo scrivo io quando vuoi. Il punto è che senza questo documento sotto mano il `decoder.vhd` è un **gigante case statement misterioso** — con questo documento aperto a fianco, è solo "tradurre tabelle in VHDL".

---

## 6. Decoder — esempio passo-passo

Prendiamo `addi x3, x1, 100` = `0x06408193`. In binario:

```
0000 0110 0100 0000 1000 0001 1001 0011
```

Tagliato secondo le posizioni:

```
imm[11:0]    = 000001100100   = 100  (decimale)
rs1          = 00001          = 1    (x1)
funct3       = 000
rd           = 00011          = 3    (x3)
opcode       = 0010011                (= I-type ALU)
```

Cosa fa il decoder con questo:
1. Vede `opcode = 0010011` → "è I-type ALU"
2. Setta `imm_type = 000` (I), `alu_src = 1` (usa imm), `reg_write = 1`, tutto il resto a 0.
3. Vede `funct3 = 000` → `alu_op = 0000` (ADD).
4. Estrae `rs1_addr = 1`, `rd_addr = 3` per il register file.
5. Mette tutti questi segnali in uscita.

Poi nel datapath:
- Register file legge `x1` → `rs1_data`.
- ImmediateGen legge `imm_type=000` e `instr` → produce `100` sign-extended.
- ALU riceve `a=rs1_data, b=100, alu_op=ADD` → calcola.
- Al rising_edge, `result` finisce in `x3`.

Tutto in 1 ciclo di clock.

---

## 7. Riassunto — cheatsheet veloce dei bit

```
RV32I, tutte le istruzioni 32 bit:

bit:    31     25 24   20 19  15 14 12 11   7 6     0
        ┌─funct7─┬─rs2──┬─rs1─┬funct3┬──rd──┬opcode┐
        └────────┴──────┴─────┴──────┴──────┴──────┘

               ↓ a seconda del tipo, alcuni campi si trasformano:

R: funct7 │ rs2  │ rs1 │ funct3 │ rd     │ opcode      (ADD, SUB, AND, ...)
I: imm[11:0]    │ rs1 │ funct3 │ rd     │ opcode      (ADDI, LW, JALR, ...)
S: imm[11:5]│rs2│ rs1 │ funct3 │imm[4:0]│ opcode      (SW, SH, SB)
B: imm[12|10:5]│rs2│rs1│funct3│imm[4:1|11]│opcode    (BEQ, BNE, ...)
U: imm[31:12]                  │ rd     │ opcode      (LUI, AUIPC)
J: imm[20|10:1|11|19:12]       │ rd     │ opcode      (JAL)
```

Stampalo, attaccalo al monitor mentre lavori. È la cosa che si va a riguardare 50 volte mentre si scrive il decoder.
