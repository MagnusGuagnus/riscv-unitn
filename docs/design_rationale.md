# Design Rationale — RISC-V VHDL su Nexys4 DDR

Documento di **design rationale** del progetto. Spiega:

1. L'architettura del sistema nel suo insieme.
2. Ogni componente VHDL: cosa fa, come è strutturato, perché è strutturato così.
3. Le scelte architetturali fatte (e le alternative scartate).
4. I trade-off significativi e i compromessi accettati.

È pensato come riferimento per la **demo del prof** (sapere cosa rispondere) e
per il **report finale** (avere le motivazioni delle scelte già scritte).

> Documenti complementari nel repo:
> - [`prof_architecture_spec.md`](prof_architecture_spec.md) — la spec autoritativa del prof
> - [`peripherals_overview.md`](peripherals_overview.md) — UART e GPIO
> - [`pipeline_overview.md`](pipeline_overview.md) — focus sulla pipeline 5-stage
> - [`vivado_guide.md`](vivado_guide.md) — flow di build
> - [`rv32i_instruction_encoding.md`](rv32i_instruction_encoding.md) — encoding ISA
> - [`vhdl_cheatsheet.md`](vhdl_cheatsheet.md) — promemoria sintassi

---

## 1. Visione d'insieme

Il progetto implementa la stessa ISA — un sottoinsieme di **RV32I a 14
istruzioni** — in **due microarchitetture distinte** che coesistono nel repo:

1. **Versione multi-cycle a FSM 4 stati** (`cpu_top.vhd`). Segue alla lettera
   la spec del prof (slide 14-22 del PDF di corso). È la versione *minima*
   per la consegna del progetto.
2. **Versione pipelined a 5 stadi** (`cpu_top_pipelined.vhd`). È
   l'**estensione architetturale** per il voto pieno. Stessa ISA, stesso
   memory map, ma architettura completamente ridisegnata internamente.

Entrambe le versioni:
- Eseguono lo stesso codice binario (compatibile a livello istruzione).
- Si interfacciano con le stesse periferiche memory-mapped (UART TX, GPIO).
- Hanno la stessa interfaccia esterna verso il wrapper di scheda, così si
  possono swappare con una sola modifica nel wrapper.

```
                    ISA condivisa (14 istruzioni RV32I subset)
                                    │
                  ┌─────────────────┴─────────────────┐
                  ▼                                   ▼
        ┌──────────────────┐                ┌─────────────────────┐
        │  cpu_top.vhd     │                │ cpu_top_pipelined   │
        │  (multi-cycle    │                │ (5-stage pipeline,  │
        │   FSM 4 stati)   │                │  forwarding+hazard) │
        └────────┬─────────┘                └──────────┬──────────┘
                 │                                     │
                 └──────────┬──────────────────────────┘
                            ▼
              ┌──────────────────────────────┐
              │  Stessa interfaccia verso    │
              │  memory_map + periferiche    │
              │  e verso il wrapper di board │
              └──────────────────────────────┘
                            │
                            ▼
              ┌──────────────────────────────┐
              │  nexys4ddr_top.vhd           │
              │  (board adapter: inverte     │
              │   reset, PROGRAM_SEL=1,      │
              │   pin mapping via XDC)       │
              └──────────────────────────────┘
                            │
                            ▼
                   Scheda fisica Nexys4 DDR
```

### 1.1 ISA implementata (14 istruzioni)

| Categoria | Istruzioni |
|---|---|
| ALU R-type | ADD, SUB, XOR, OR, AND |
| ALU I-type | ADDI, XORI, ORI, ANDI |
| Load (I-type) | LW |
| Store (S-type) | SW |
| Branch (B-type) | BEQ, BNE, BLT, BGE |
| Jump (J-type) | JAL |

Volutamente esclusi (per restare nello scope): shift, comparisons (SLT/SLTU),
branch unsigned, JALR, LUI, AUIPC, byte/half load-store, ECALL/EBREAK/FENCE,
estensione M.

---

## 2. Componenti del core (versione multi-cycle)

I 9 moduli "foglia" del core sono progettati per essere **riusati** dalla
versione pipelined senza modifiche (tranne il regfile, che è dual-port nella
pipeline). Ogni modulo ha responsabilità limitata e ben definita.

### 2.1 ALU — `src/core/alu.vhd`

**Cosa fa**: esegue una delle 6 operazioni aritmetico/logiche su due
operandi a 32 bit. Output a 32 bit.

**Scelte di design**:
- Opcode a **3 bit** anziché 4 (come in Patterson). Sufficiente per 6
  operazioni: ADD (000), ADDU (001), SUB (010), XOR (100), OR (110), AND
  (111). Scelta del prof, riduce decoder.
- Output **doppio**: `alu_pre_result` combinatorio (cammino diretto) +
  `alu_result` registrato (latched). La versione registrata è quella usata
  dalla CPU multi-cycle nella fase MEM/WB; quella combinatoria serve a
  pilotare l'indirizzo della DMEM **mentre** si sta eseguendo EX, così la
  lettura BRAM è già pronta in MEM/WB. È un trucco classico di
  *latency hiding* per nascondere il ciclo di latenza delle BRAM
  sincrone.
- Niente flag di overflow (non servono per l'ISA implementata, e il prof
  non li richiede).

**Riuso nella pipeline**: usato esattamente come è, con il segnale
`alu_pre_result` che entra direttamente nel pipeline register EX/MEM
(l'output registrato `alu_result` resta scollegato perché il pipeline
register stesso è il "registro" che chiude lo stadio).

### 2.2 Register File — `src/core/regfile.vhd` (multi-cycle) e `regfile_dp.vhd` (pipeline)

**Versione multi-cycle**: 32 registri × 32 bit, **una sola porta condivisa**
read/write. Un mux all'ingresso decide se la porta è in lettura (legge
`rs1` o `rs2`) o in scrittura (scrive `rd`). La FSM coordina le fasi: in
DECODE legge rs1 e rs2 in cicli successivi, in MEM/WB scrive rd.

**Scelta multi-cycle**: la spec del prof la richiede, è il pattern
"distributed RAM" più economico (poche LUT). Trade-off accettato:
serializza gli accessi.

**Versione pipeline** (`regfile_dp.vhd`, scritto come parte dell'estensione):
- **2 letture asincrone simultanee** (`rs1`, `rs2`) + **1 scrittura
  sincrona** (`rd` da WB). Necessario per la pipeline perché in ID
  dobbiamo leggere entrambi gli operandi nello stesso ciclo, mentre in WB
  c'è una scrittura concorrente di un'istruzione 2 passi indietro.
- `x0` hardwired a zero (ignora qualsiasi sw verso x0, conforme alla spec
  RISC-V).
- Letture asincrone: il valore esce nello stesso ciclo in cui cambia
  `rs1_addr`/`rs2_addr`. Vivado lo mappa in LUT-RAM distribuita (nessun
  BRAM consumato).
- Same-cycle write-then-read: la lettura restituisce il valore **vecchio**
  del registro. Per la pipeline è OK perché il forwarding_unit gestisce
  esplicitamente i casi in cui serve il valore "fresco".

**Alternative scartate**: usare una BRAM con dual-port + dummy second port,
spreco di risorse per 32 word. Usare una sola FIFO di register update,
overkill.

### 2.3 Decoder — `src/core/decoder.vhd`

**Cosa fa**: dato `instr` (= word a 32 bit appena letta dalla IMEM), estrae
i campi e produce i segnali di controllo per il datapath.

**Output**:
- `op_class[4:0]` — **one-hot 5-bit** che classifica l'istruzione: bit 0 =
  O (ALU op), bit 1 = S (Store), bit 2 = L (Load), bit 3 = B (Branch), bit
  4 = J (Jump). One-hot rende facilissimi i check downstream (es. `if
  op_class(2) = '1' then is_load`).
- `alu_opcode[2:0]` — pilota l'ALU. Derivato da `funct3` con eccezione
  per SUB (stesso funct3 di ADD, distinto da `funct7`).
- `cond_opcode[2:0]` — pilota il comparator per le branch.
- `a_sel`, `b_sel` — pilotano i mux davanti agli operandi ALU.
- `imm_type[2:0]` — pilota l'immediate generator.

**Scelta one-hot per op_class**: il prof la indica esplicitamente. Costa 1
bit extra in storage rispetto a un encoding binario 3-bit (= 8 categorie),
ma elimina completamente la decoding logic a valle. Trade-off classico
hardware: area vs ritardo. One-hot vince per ritardo.

### 2.4 Immediate Generator — `src/core/immediate_gen.vhd`

**Cosa fa**: estrae l'immediato dall'istruzione e fa sign-extension a 32 bit.

**Gestisce 4 formati**:
- **I-type**: imm[11:0] = instr[31:20]
- **S-type**: imm[11:5] = instr[31:25], imm[4:0] = instr[11:7]
- **B-type**: imm[12|10:5|4:1|11] = instr[31|30:25|11:8|7], poi shift
  left 1 (imm[0] sempre 0 perché branch sono word-aligned)
- **J-type**: imm[20|10:1|11|19:12] = instr[31|30:21|20|19:12], poi shift
  left 1

**Niente formato U**: perché LUI e AUIPC non sono nell'ISA.

**Scelta**: modulo puramente combinatorio, separato dal decoder.
Pulizia di responsabilità, e il prof lo richiede nella sua slide.

### 2.5 Comparator — `src/core/comparator.vhd`

**Cosa fa**: confronta `rs1` e `rs2` secondo `cond_opcode` e produce
`branch_cond` (= '1' se la condizione di branch è vera).

**4 operazioni** (3-bit code): EQ (000), NEQ (001), LT signed (100), GE
signed (101). Le altre combinazioni → output 0.

**Scelta del prof — modulo separato dall'ALU**: nella spec MIPS classica
il comparator è integrato nell'ALU (via flag Z e SLT). Qui è separato.
Vantaggio: parallelismo (ALU calcola target, comparator decide se prendere).
Costo: un po' più di logica duplicata. Per la nostra ISA semplice il
guadagno di tempo è significativo.

**Output latched nella versione multi-cycle**: questa è una "gotcha" che
ha effetti sulla pipeline. Nella pipeline 5-stage il branch deve essere
risolto in EX nello stesso ciclo, quindi non posso aspettare 1 ciclo di
latch. Soluzione adottata: replicare la logica del comparator
combinatorialmente dentro `cpu_top_pipelined.vhd`, lasciando intatto il
modulo `comparator.vhd` per la versione multi-cycle. È duplicazione
controllata, ma evita di toccare un file già verificato.

### 2.6 PC Unit — `src/core/pc_unit.vhd`

**Cosa fa**: tiene il Program Counter (12 bit) e calcola PC+4
combinatorialmente.

**Scelta del prof — PC a 12 bit**: la IMEM è 4 kB (= 1024 word × 32 bit),
quindi 12 bit di byte-address bastano. Risparmio rispetto a un PC a 32 bit
nativo RV32I, ma incompatibile con programmi grandi. Compromesso
didattico, accettabile per le demo (i nostri programmi sono < 30
istruzioni).

**Output**:
- `pc` — il valore corrente del PC (registrato)
- `next_pc` — `pc + 4` (combinatorio, calcolato in parallelo)
- `pc_word` — `pc[11:2]`, indirizzo word-level per la BRAM IMEM

Aggiornato solo quando `load_en = '1'`. Nella multi-cycle viene asserito
nella fase FETCH. Nella pipeline viene asserito ogni ciclo tranne in
stall.

### 2.7 Control FSM — `src/core/control_fsm.vhd` (solo multi-cycle)

**Cosa fa**: la state machine a 4 stati (FETCH/DECODE/EXECUTE/MEM_WB) che
genera i segnali di controllo della CPU multi-cycle.

**Stati**:
- **FETCH**: `pc_load = '1'`, PC carica il nuovo valore, IMEM legge.
- **DECODE**: decoder produce i segnali, regfile legge rs1 e rs2,
  immediate generator estrae l'immediato.
- **EXECUTE**: ALU calcola, comparator decide.
- **MEM_WB**: per store scrive in DMEM/periferiche; per load legge DMEM;
  per ALU op / load / jump scrive in rd via mux finale.

**Scelta del prof — 4 stati**: minimo numero di stati per nascondere la
latenza BRAM sincrona. Più stati permetterebbero di pipelinare (= già
qualcosa di simile al pipelined). Meno stati richiederebbero memorie
asincrone (non disponibili come BRAM).

**Nella pipeline questo modulo non viene istanziato**: tutta la logica di
controllo è "distribuita" nei segnali `op_class`/`regwrite`/`memwrite`
che fluiscono attraverso i pipeline register. Più moderno, più scalabile.

### 2.8 Instruction Memory — `src/memory/instr_memory.vhd`

**Cosa fa**: BRAM sincrona 1024 × 32 bit (= 4 kB) precaricata con un
programma. Read-only durante l'esecuzione.

**Scelta — parametrizzato con generic `PROGRAM_SEL`**:
- `0` (default) = programma di test Fase A (calcola 5+3, scrive/legge
  DMEM, jal halt)
- `1` = programma Hello World (Fase B): trasmette "Hello" via UART, fa
  pattern LED
- `2` = programma di DEBUG single-shot 'X' (per isolare bug di routing
  UART nella Fase 3)

I tre programmi sono `constant rom_t` separate, e una funzione
`select_program(sel)` decide quale assegnare a `signal mem` come init
value. Vivado riconosce il pattern e infersce BRAM con init.

**Trade-off**: alternativa sarebbe caricare il programma da un file
.coe/.mem esterno. Più pulito ma meno comodo per swappare programmi
durante lo sviluppo. La nostra scelta è pragmatica per progetto
didattico.

### 2.9 Data Memory — `src/memory/data_memory.vhd`

**Cosa fa**: BRAM sincrona 4096 × 32 bit (= 16 kB). Read/write
arbitraria, indirizzata via `addr` word-level (12 bit).

**Inizializzazione**: contiene gli indirizzi delle periferiche memory-mapped
(DMEM[0..2] = `&UART_DATA`, `&UART_STATUS`, `&GPIO_LED`) e i caratteri
ASCII della stringa "Hello" (DMEM[4..8]).

**Perché la pre-inizializzazione?** Il programma Hello deve scrivere su
`UART_DATA` (= 0x10000). RISC-V ADDI ha imm signed a 12 bit (max +2047),
non basta per costruire 0x10000 in un solo registro. Workaround: l'indirizzo
viene caricato da DMEM con `lw x10, 0(x0)`. Per farlo funzionare,
DMEM[0] deve essere già 0x10000 al power-on. Soluzione: pre-init via
`signal mem : ram_t := DATA_INIT;`.

**Read-first behavior**: in caso di simultaneous read+write sullo stesso
indirizzo, la read ritorna il valore **vecchio**. Non importa nella
multi-cycle (mai accadrà perché read e write sono in cicli diversi). Nella
pipeline può accadere ma è gestibile.

---

## 3. Integrazione: cpu_top (multi-cycle)

`src/core/cpu_top.vhd` è il top integrato della CPU multi-cycle. Istanzia
tutti i 9 moduli foglia e cabla:
- I mux esterni (regfile addr, ALU operandi, mux rd_value finale, mux pc_in).
- Le estensioni a 32 bit del PC (per usarlo come operando ALU).
- L'estrazione dei campi dell'istruzione (rs1, rs2, rd).
- Il `memory_map` (vedi sez. 4) che fa da bus tra CPU e periferiche.

**Generic propagati**: `CLK_HZ`, `BAUD` (vanno alla UART), `PROGRAM_SEL`
(va alla IMEM).

**Porte di debug** (`dbg_pc`, `dbg_instr`, `dbg_state`, `dbg_alu_result`,
`dbg_mem_out`, `dbg_rd_value`): esposte per agevolare la simulazione. Nel
wrapper di board vengono lasciate `=> open` (la sintesi le elimina).

**Scelta — top tutto-in-uno**: alternativa era avere un sub-top "datapath"
e un sub-top "control". Avrebbe aumentato la modularità ma anche il
boilerplate per un progetto didattico. Per la dimensione del nostro core
(9 moduli foglia), un singolo top è gestibile.

---

## 4. Periferiche memory-mapped

### 4.1 Memory map del sistema

Definita autoritativamente in [`peripherals_overview.md`](peripherals_overview.md):

| Indirizzo | Cosa è | R/W |
|---|---|---|
| `0x0000_0000 - 0x0000_3FFF` | DMEM (16 kB) | R/W |
| `0x0001_0000` | UART_DATA | W |
| `0x0001_0004` | UART_STATUS (bit 0 = ready) | R |
| `0x0001_0008` | GPIO_LED (16 bit) | W |
| `0x0001_000C` | GPIO_SW (16 bit) | R |

L'address decoder usa **3 bit specifici** di `addr` per fare il routing:
`bit[16]` distingue DMEM da periferiche, `bit[3]` distingue UART da GPIO,
`bit[2]` distingue data/status (per UART) o LED/SW (per GPIO).

**Scelta dei bit**: non arbitraria. `bit[16]` divide 64 kB di "spazio
DMEM" da 64 kB di "spazio periferiche". `bit[3]` e `bit[2]` allineano
ogni registro periferica su 4 byte (una word), che è la granularità
naturale di RISC-V per i load/store di parola.

### 4.2 `memory_map.vhd` — il bus

Modulo wrapper che istanzia DMEM + UART + GPIO e fa il routing combinatorio:
- `dmem_we` = `we AND addr[16] = '0'`
- `uart_tx_start` = `we AND addr[16] = '1' AND addr[3] = '0' AND addr[2] = '0'`
- `gpio_we` = `we AND addr[16] = '1' AND addr[3] = '1' AND addr[2] = '0'`

Mux di `dout` analogo per le letture.

**Scelte**:
- Modulo separato (non logica inline nel `cpu_top`). Permette di riusarlo
  identico nella versione pipelined.
- Routing combinatorio puro (non registrato). Le periferiche hanno già
  stato interno registrato, quindi la latenza apparente è 1 ciclo come la
  DMEM.
- "Soft" handling di errori: una `sw` su un read-only è ignorata, una
  `lw` da un write-only restituisce 0 (no fault). Convenzione tipica dei
  system-on-chip.

### 4.3 `uart_tx.vhd` — UART 8N1

**Cosa fa**: trasmettitore seriale asincrono. FSM a 4 stati
(IDLE/START/DATA/STOP) + baud counter + shift register.

**Scelte**:
- **Generic CLK_HZ e BAUD**: il divisore baud `BAUD_DIV = CLK_HZ / BAUD`
  si calcola in elaboration. Default 100 MHz / 115200 = 868 cicli/bit
  (= ~8.68 µs/bit, standard). In simulazione si può istanziare con
  `BAUD = 25_000_000` → `BAUD_DIV = 4` → simulazione 200× più rapida.
- **TX latch sull'output**: `tx_pin` è registrato (passa attraverso un
  flip-flop) per evitare glitch combinatori che il PC interpreterebbe
  come bit spuri.
- **No buffer interno**: la CPU deve fare polling di `tx_busy` prima del
  prossimo kick. Trade-off: più semplice del FIFO + interrupt, costa un
  micro-loop in software.

### 4.4 `gpio.vhd` — LED + switch

**Cosa fa**: 16 LED in scrittura (memory-mapped), 16 switch in lettura
(con synchronizer 2-FF per metastability).

**Scelta del synchronizer 2-FF**: gli switch sono segnali asincroni
(mossi a mano in tempi non correlati al clock). Senza synchronizer,
campionarli direttamente in un FF rischia metastabilità (il FF cattura
un valore intermedio mentre lo switch sta cambiando livello). Due FF in
cascata riducono la probabilità di metastability a livelli accettabili
(MTBF anni).

---

## 5. Pipeline 5-stage (estensione)

Vedi [`pipeline_overview.md`](pipeline_overview.md) per la trattazione
dettagliata. Qui solo i **rationale di design** più rilevanti.

### 5.1 Stage layout (IF/ID/EX/MEM/WB)

Lo split classico in 5 stadi della letteratura RISC è il "punto di
partenza obbligato" per pipelinare in modo equilibrato. Alternative
considerate:

- **4 stadi** (fonde EX e MEM): riduce branch penalty da 2 a 1, ma alza
  il critical path (= clock più lento). Per il nostro design probabilmente
  fattibile (BRAM single-cycle), non è stato esplorato per restare allineati
  al modello "Patterson canonical".
- **6+ stadi** (split di EX o ID): più paralellismo, ma più branch penalty
  e più complessità del forwarding. Eccessivo per ISA semplice.

### 5.2 Branch in EX (non in ID)

Risolvere il branch in ID (Patterson "RISC-V canonical") richiederebbe il
forwarding anticipato sui valori letti dal regfile in ID. È fattibile ma
complica la logica e probabilmente allunga il critical path di ID.

Risolverlo in EX costa **2 cicli di branch penalty** per ogni branch
taken. Per i nostri programmi (con pochi branch a confronto col totale
di istruzioni) è un costo trascurabile.

Trade-off scelto: semplicità sopra ottimizzazione.

### 5.3 Forwarding + stall, non solo stall

L'alternativa "solo stall" (= fermare la pipeline ogni volta che c'è un
RAW hazard) è più semplice da implementare ma riduce il throughput
sensibilmente (~50% sui programmi tipici). Il forwarding aggiunge ~30
righe di logica (un mux 3:1 davanti a ciascun operando ALU + il modulo
`forwarding_unit.vhd`) ma ricupera quasi tutto il throughput perso.

Il load-use hazard è l'unico caso dove serve uno stall obbligatorio (1
ciclo). Statisticamente è meno frequente di un RAW puro.

### 5.4 Coesistenza, non sostituzione

Una scelta di processo importante: **non rimuovere la versione multi-cycle
quando si introduce la pipeline**. Entrambe convivono nel repo. Vantaggi:
- Demo del prof: posso mostrare il confronto.
- Backup: se la pipeline ha bug, la versione multi-cycle (già consegnabile)
  resta intatta.
- Speedup measurable: contare i cicli di un programma noto su entrambe
  per produrre il numero "speedup misurato" nel report.

---

## 6. Board adapter — `nexys4ddr_top.vhd` + `NEXYS4DDR.xdc`

### 6.1 Perché un wrapper di board

`cpu_top.vhd` è **board-agnostic**: ha porte neutre (`clk`, `reset` active-
high, `uart_tx_pin`, `led_out`, `sw_in`), generic default "neutri", e
porte di debug per simulazione. Non sa nulla della Nexys4 DDR.

`nexys4ddr_top.vhd` (wrapper) fa l'**adattamento board-specific**:
1. Inverte la polarità del reset (CPU_RESETN della Nexys4 DDR è active-low).
2. Forza `PROGRAM_SEL = 1` (carica Hello World nella IMEM).
3. Lascia le 6 porte `dbg_*` di cpu_top `=> open` (Vivado elimina la
   logica associata in sintesi, niente warning sui pin non assegnati).

**Vantaggi architetturali**:
- Per portare il design su un'altra scheda (es. Zedboard, Basys3), scrivo
  un altro wrapper (`zedboard_top.vhd`) con la sua polarità reset e i
  suoi pin. cpu_top non cambia.
- La separazione CPU ↔ board è lo standard industriale dei progetti FPGA.
  Pattern che il prof riconosce.

### 6.2 File XDC

Il file `constraints/NEXYS4DDR.xdc` mappa le porte del wrapper ai pin
fisici del chip Artix-7. Punti notevoli:

- **`create_clock` su pin E3**: dichiara che sul pin E3 entra un clock
  periodico T = 10 ns (= 100 MHz). Senza questa riga Vivado non fa
  timing analysis (= rischio di non chiudere a 100 MHz senza accorgersene).
- **sw_in[8] e sw_in[9] hanno `IOSTANDARD LVCMOS18`**: il banco I/O 34
  della Nexys4 DDR è alimentato a 1.8V. Mismatch di voltage darebbe
  errore DRC in implementation.
- **`UNUSEDPIN PULLUP`**: tutti i pin non nominati nell'XDC vengono
  tenuti con pull-up interno, per evitare floating inputs.

---

## 7. Trade-off significativi e scelte controverse

### 7.1 ISA ridotta vs RV32I completo

**Scelta**: 14 istruzioni anziché 40+. La spec del prof lo richiede.

**Pro**: decoder minimale, ALU 6 operazioni, niente shifter. Tempo di
sviluppo dimezzato.

**Contro**: niente compiler standard. Devo scrivere assembly a mano e
calcolare gli encoding (oppure usare un assembler online filtrato).
Programmi limitati nella complessità (es. niente moltiplicazione, niente
spostamento di bit).

### 7.2 Coesistenza vs sostituzione delle 2 CPU

**Scelta**: tenerle entrambe.

**Pro**: vedi sez. 5.4.

**Contro**: due cppu_top da mantenere se trovo un bug comune (es. una
modifica all'ALU richiede aggiornare entrambe le simulazioni). Mitigato
dal fatto che condividono i moduli foglia.

### 7.3 Comparator replicato inline nella pipeline

**Scelta**: nella pipeline, il comparator viene replicato come logica
combinatoria dentro `cpu_top_pipelined.vhd`, anziché istanziare il modulo
`comparator.vhd` esistente.

**Pro**: comparator combinatorio (senza latch interno) permette branch in
EX nello stesso ciclo, riducendo branch penalty a 2 invece di 3.

**Contro**: duplicazione di logica. Se cambio la semantica del comparator
(es. aggiungo BLTU/BGEU all'ISA), devo aggiornare 2 punti.

### 7.4 BRAM init con function VHDL vs file esterno

**Scelta**: `signal mem : rom_t := select_program(PROGRAM_SEL)` dove
`select_program` è una funzione che ritorna PROGRAM_A/B/C.

**Pro**: il programma è nel sorgente VHDL, versionato in Git, leggibile.
Switch tra programmi via generic.

**Contro**: per cambiare programma serve re-synthesis (no live reloading).
Per programmi lunghi (es. >100 istruzioni) il file diventa ingestibile.

**Alternativa scartata**: caricare da file .mem/.coe. Più scalabile ma
introduce dipendenza esterna nel build flow.

### 7.5 Wrapper di board separato vs cpu_top board-aware

**Scelta**: wrapper separato (sez. 6.1).

**Pro**: cpu_top resta neutro, testbench intatti, porting su altra board
trivial.

**Contro**: un file in più. Set as Top in Vivado deve puntare al wrapper
(facile dimenticarselo).

---

## 8. Il flusso di esecuzione di una istruzione (esempio: `add x3, x1, x2`)

Tracciamo come la CPU multi-cycle esegue una `add`:

**Ciclo 1 — FETCH**:
- `pc_load = 1` → PC carica il valore prossimo (es. 0x008).
- BRAM IMEM riceve `addr = pc[11:2] = 0x002`.
- `instruction` non è ancora pronto (BRAM sincrona).

**Ciclo 2 — DECODE**:
- `instruction = 0x002081B3` arriva (encoding di `add x3, x1, x2`).
- Decoder: `op_class = "00001"` (O), `alu_opcode = "000"` (ADD), `a_sel
  = '1'` (= rs1), `b_sel = '0'` (= rs2), `imm_type = "000"` (R-type, niente
  imm).
- Regfile (con shared port): a_addr = rs1 = 1 → rs1_value = 5 (esempio).
- Anche rs2 letto come "dual phase" → rs2_value = 3.
- Immediate ignored (R-type non ha imm).

**Ciclo 3 — EXECUTE**:
- ALU input: a = rs1_value = 5, b = rs2_value = 3, opcode = ADD.
- `alu_pre_result = 8` (combinatorio).
- `alu_result = 8` (registrato a fine ciclo).
- Comparator non rilevante (no branch).

**Ciclo 4 — MEM/WB**:
- DMEM non attivata (op_class = O, niente memwrite né load).
- Mux finale rd_value: op_class(0) = '1' → rd_value = alu_result = 8.
- `rd_write_en = '1'` (op_class = O).
- Regfile (con shared port, in scrittura): a_addr = rd = 3 → regfile[3] = 8.

Totale: 4 cicli per una `add`. In pipeline lo stesso `add` finirebbe in
5 cicli isolata, ma 1 ciclo in throughput (steady state).

---

## 9. Stato attuale e roadmap

| Fase | Stato | File chiave |
|---|---|---|
| A — Core multi-cycle | OK | 9 moduli in `src/core/` + `cpu_top.vhd` |
| B — Periferiche UART + GPIO | OK | `src/peripherals/`, `src/memory/memory_map.vhd` |
| 3 — Bring-up scheda | Parziale (bug aperto) | `src/board/nexys4ddr_top.vhd`, `constraints/NEXYS4DDR.xdc` |
| 4 — Pipeline | Scheletro pronto | `src/core/{regfile_dp,forwarding_unit,hazard_unit,cpu_top_pipelined}.vhd` + `sim/tb_cpu_pipelined.vhd` |
| 5 — Report + demo | Da fare | (questo doc è il punto di partenza per il report) |

**Issue aperto (Fase 3)**: il design completo gira sulla scheda, la CPU
completa il programma Hello (LED a 0x0055), ma 0 byte arrivano al PC. Test
di isolamento (`uart_test_top` che spedisce 'A' continuamente) ha
dimostrato che la catena hardware UART funziona. Il bug è specifico al
routing `sw → uart_tx_start` nel design completo. Da debuggare con un
probe LED in nexys4ddr_top.

**Next session priority**:
1. Simulare `tb_cpu_pipelined` in xsim.
2. Bug fix della pipeline se necessario.
3. Scrivere programma di test con hazard espliciti (load-use + forwarding chain).
4. Risolvere issue Fase 3 con probe LED.
5. Misurare cicli Hello World su pipeline vs multi-cycle (= speedup numerico
   per slide demo).
