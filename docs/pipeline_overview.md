# Pipeline 5-stage — overview architetturale e nota di progetto

Documento di riferimento per la versione **pipelined** della CPU RISC-V
(estensione architetturale rispetto alla versione multi-cycle, per il voto
pieno). Pensato per:

1. Capire **cosa è cambiato** rispetto alla CPU multi-cycle.
2. Sapere **cosa dire al prof** in demo.
3. Avere chiari **i 5 file nuovi** che compongono la pipeline.

---

## 1. Perché una pipeline

La CPU multi-cycle attuale (`cpu_top.vhd`) esegue **una istruzione per
volta** in 4 cicli di clock (FETCH → DECODE → EXECUTE → MEM/WB → ripeti).
Throughput: 1 istruzione ogni 4 cicli, cioè 0.25 istruzioni per ciclo (IPC).

La pipeline a 5 stadi divide l'esecuzione in 5 stadi distinti, e fa fluire
**5 istruzioni contemporaneamente** (una in ciascuno stadio). Schema temporale
in steady state:

```
Ciclo:        1     2     3     4     5     6     7
Istr 1 :    [IF ][ ID ][ EX ][MEM ][ WB ]
Istr 2 :          [IF ][ ID ][ EX ][MEM ][ WB ]
Istr 3 :                [IF ][ ID ][ EX ][MEM ][ WB ]
Istr 4 :                      [IF ][ ID ][ EX ][MEM ][ WB ]
Istr 5 :                            [IF ][ ID ][ EX ][MEM ][ WB ]
```

Throughput ideale: **1 istruzione per ciclo** (IPC = 1). Speedup teorico
rispetto alla versione multi-cycle: 4x. Reale (per via di stall e flush):
circa 3x. La latenza per singola istruzione non migliora (anzi peggiora
leggermente, è 5 cicli invece di 4), ma il throughput sì.

---

## 2. I 5 stadi della pipeline

| Stadio | Cosa fa | Cosa produce |
|---|---|---|
| **IF** (Instruction Fetch) | Legge il PC, indirizza la BRAM IMEM, calcola PC+4 | `instruction`, `pc_next` |
| **ID** (Instruction Decode) | Decoder estrae opcode/funct, legge regfile (2 read async simultanei), generates immediate | `op_class`, `alu_opcode`, `cond_opcode`, `rs1_value`, `rs2_value`, `immediate` |
| **EX** (Execute) | Forwarding mux davanti agli operandi, ALU calcola, comparator decide se branch è preso | `alu_result`, `branch_taken`, `branch_target` |
| **MEM** (Memory access) | Accesso al bus memory-mapped (DMEM/UART/GPIO via `memory_map`) | `mem_out` (per LW) |
| **WB** (Write Back) | Mux della sorgente del writeback, scrittura sul regfile | aggiornamento del regfile |

Tra ogni coppia di stadi c'è un **pipeline register**, cioè un set di
flip-flop che congelano allo `rising_edge(clk)` tutti i segnali che servono
allo stadio successivo. I 4 pipeline register sono:

- **IF/ID** : `pc`, `pc_next`, `instruction`
- **ID/EX** : `pc`, `pc_next`, `rs1_value`, `rs2_value`, `immediate`,
              `rs1_addr`, `rs2_addr`, `rd_addr`, `op_class`, `alu_op`,
              `cond_op`, `a_sel`, `b_sel`
- **EX/MEM**: `alu_result`, `rs2_value` (per store), `pc_next`, `rd_addr`,
              `op_class`, `regwrite`, `memwrite`
- **MEM/WB**: `alu_result`, `mem_out`, `pc_next`, `rd_addr`, `op_class`,
              `regwrite`

Il numero di bit "in flight" nei pipeline register è molto alto (≈ 300 bit
complessivi), ma sono tutti flip-flop semplici. Vivado li sintetizza
naturalmente.

---

## 3. Gli hazard — i 3 problemi della pipeline

Senza precauzioni, far girare 5 istruzioni contemporaneamente produce
risultati sbagliati. Tre famiglie di problemi (hazard), e tre soluzioni.

### 3.1 Data hazard (RAW: Read After Write)

**Esempio**:
```
add x1, x2, x3      # x1 = x2 + x3
sub x4, x1, x5      # x4 = x1 - x5     ← legge x1 prima che add abbia scritto
```

Quando `sub` arriva in ID per leggere il regfile, `add` è ancora in EX
(non ha ancora scritto x1). `sub` leggerebbe il vecchio valore di x1 → bug.

**Soluzione: forwarding (bypass)**

Invece di aspettare che `add` finisca WB, instradiamo direttamente il
risultato di `add` (= `exmem_alu_result`, dal pipeline register EX/MEM)
all'input dell'ALU di `sub` nello stadio EX, bypassando il regfile.

Il `forwarding_unit.vhd` rileva il match `idex_rs1 == exmem_rd` (o `==
memwb_rd` per istruzioni 2 passi avanti) e produce un selettore 2-bit
(`fwd_a`, `fwd_b`) che pilota un mux davanti all'ALU:
- `00` = valore dal regfile (default, nessun hazard)
- `01` = valore da EX/MEM (istruzione precedente, 1 passo avanti)
- `10` = valore da MEM/WB (istruzione 2 passi avanti)

Priorità: EX/MEM > MEM/WB (la più recente vince).

### 3.2 Load-use hazard (caso speciale di RAW)

**Esempio**:
```
lw  x1, 0(x2)       # carica x1 dalla memoria
sub x4, x1, x5      # USA x1 subito dopo
```

Il forwarding NON basta perché il valore di `lw` arriva solo alla fine di
MEM (non in EX). Quando `sub` è in EX al ciclo 3, `lw` è in MEM al ciclo 3
— `mem_out` non è ancora disponibile.

**Soluzione: stall + bolla**

`hazard_unit.vhd` rileva la situazione (`idex_is_load = '1'` AND
`idex_rd == ifid_rs1` o `ifid_rs2`) e produce `stall = '1'`. Quando
`stall = '1'`:
- il PC NON avanza (resta sullo stesso valore)
- il pipeline register IF/ID NON viene aggiornato (congelato)
- il pipeline register ID/EX viene caricato con NOP (bolla che si propaga)

Costo: 1 ciclo di stall per ogni load-use. Al ciclo successivo `lw` è in
WB (o quasi) e `sub` può leggere x1 via forwarding MEM/WB → EX.

### 3.3 Control hazard (branch e jump)

**Esempio**:
```
beq x1, x2, target  # se uguali, salta a target
add x3, x4, x5      # questa istruzione è già in IF al ciclo successivo
sub ...             # questa è in IF al ciclo dopo ancora
target:
```

Quando il `beq` arriva in EX e scopriamo che il branch è taken, le 2
istruzioni successive sono già state caricate in IF e ID — istruzioni
"sbagliate" che non dovevano essere eseguite.

**Soluzione: flush**

Quando `branch_taken = '1'` in EX:
- redirigi il PC al target del branch (= `alu_result`, calcolato dall'ALU
  che ha sommato pc + immediato)
- "flusha" (invalida) i pipeline register IF/ID e ID/EX, sostituendoli con
  NOP, così le 2 istruzioni in volo non producono effetti

Costo: 2 cicli di "branch penalty" per ogni branch taken. Branch non
taken: zero costo (le 2 istruzioni che seguono nel codice sono quelle
giuste).

---

## 4. I 5 file nuovi della pipeline

| File | Cosa contiene | Righe |
|---|---|---|
| `src/core/regfile_dp.vhd` | Regfile dual-port: 2 letture asincrone simultanee + 1 scrittura sincrona | ~50 |
| `src/core/forwarding_unit.vhd` | Combinatorio: produce `fwd_a` e `fwd_b` per i mux davanti all'ALU | ~70 |
| `src/core/hazard_unit.vhd` | Combinatorio: produce `stall` su load-use hazard | ~50 |
| `src/core/cpu_top_pipelined.vhd` | Top integrato con i 4 pipeline register inline, riusa tutti i moduli foglia esistenti | ~370 |
| `sim/tb_cpu_pipelined.vhd` | Testbench: esegue il programma Fase A sulla pipeline e verifica PC finale | ~110 |

### 4.1 `regfile_dp.vhd` — dual-port

Differenza chiave rispetto a `regfile.vhd` originale (multi-cycle):
quello aveva una sola porta di lettura condivisa con la scrittura, mossa
in tempi diversi dalla FSM. La pipeline deve leggere `rs1` e `rs2`
**simultaneamente** nello stadio ID, mentre WB sta scrivendo `rd` di
un'istruzione 2 passi indietro — servono 3 accessi concorrenti.

Implementazione: lettura asincrona (combinatoria) per `rs1` e `rs2`,
scrittura sincrona sul `rising_edge`. `x0` è hardwired a zero. Vivado
sintetizza tutto in distributed RAM (LUT-RAM), nessun BRAM consumato.

### 4.2 `forwarding_unit.vhd`

Combinatorio puro. Decide se gli operandi dell'ALU devono venire dal
regfile (caso normale) o da pipeline register più avanti (caso hazard).

Logica:
- se `exmem_regwrite='1'` AND `exmem_rd != 0` AND `exmem_rd == idex_rs1`
  → `fwd_a = "01"` (forward da EX/MEM)
- else se `memwb_regwrite='1'` AND `memwb_rd != 0` AND `memwb_rd == idex_rs1`
  → `fwd_a = "10"` (forward da MEM/WB)
- else `fwd_a = "00"` (regfile)

Stesso per `fwd_b` con `idex_rs2`.

### 4.3 `hazard_unit.vhd`

Combinatorio puro. Una riga di logica:
```
stall = (idex_is_load = '1')
    AND (idex_rd != x0)
    AND (idex_rd == ifid_rs1 OR idex_rd == ifid_rs2)
```

Quando `stall = '1'`, nel top `cpu_top_pipelined`:
- il process del PC vede `pc_write_en = '0'` e non aggiorna
- il process di IF/ID congela
- il process di ID/EX inietta NOP

### 4.4 `cpu_top_pipelined.vhd`

Il file grosso. Riusa **tutti** i moduli foglia già esistenti
(`decoder`, `immediate_gen`, `alu`, `memory_map`, `instr_memory`) e
istanzia i 3 nuovi (`regfile_dp`, `forwarding_unit`, `hazard_unit`).

Struttura interna a blocchi:
1. Sezione IF: PC + IMEM + mux pc_in (sequential vs branch target).
2. Pipeline register IF/ID con logica di reset / flush / stall.
3. Sezione ID: decoder, immediate_gen, regfile_dp (porte read).
4. Hazard unit (combinatorio).
5. Pipeline register ID/EX (con bolla NOP quando flush_idex).
6. Sezione EX: forwarding_unit + 2 mux + ALU + comparator combinatorio
   replicato inline + branch resolution.
7. Pipeline register EX/MEM.
8. Sezione MEM: memory_map.
9. Pipeline register MEM/WB.
10. Sezione WB: mux della sorgente writeback + connessione alla porta
    write del regfile_dp.

**Nota tecnica sul comparator**: il modulo `comparator.vhd` esistente ha
output **registrato** (latched), il che aggiungerebbe 1 ciclo di latenza al
branch (lo risolverei in MEM invece di EX → 3 cicli di flush invece di 2).
Per non modificare il file di Fase A, la logica del comparator (EQ, NEQ,
LT signed, GE signed) è **replicata combinatorialmente inline** dentro
`cpu_top_pipelined`. È un trade-off di duplicazione vs riusabilità: per la
demo è la scelta più pratica.

### 4.5 `tb_cpu_pipelined.vhd`

Testbench minimo. Esegue il programma di Fase A (PROGRAM_SEL=0):
```
addi x1, x0, 5    addi x2, x0, 3    add x3, x1, x2
sw x3, 0(x0)      lw x4, 0(x0)      jal x0, 0
```
Verifica che dopo 250 ns il PC sia fermo a 0x014 (loop JAL su sé stessa).

Il programma esercita: forwarding RAW sull'`add` (legge x1 di `addi`
ancora in volo), forwarding sulla `sw` (legge x3 di `add` ancora in volo),
flush del jal incondizionato. Niente load-use hazard (la lw è seguita da
jal che non usa x4), quindi questo test non esercita lo stall —
testeremo lo stall con un programma dedicato in una sessione successiva.

---

## 5. Come si integra con il resto del progetto

**Interfaccia esterna identica a cpu_top.vhd**: stessi generic (`CLK_HZ`,
`BAUD`, `PROGRAM_SEL`), stesse porte (`clk`, `reset`, `uart_tx_pin`,
`led_out`, `sw_in`, 6 porte `dbg_*`). Questo è voluto: per swappare
la CPU multi-cycle con la CPU pipelined nel wrapper di board basta
cambiare `entity work.cpu_top` → `entity work.cpu_top_pipelined`.

**Coesistenza con la versione multi-cycle**: `cpu_top.vhd` e
`cpu_top_pipelined.vhd` convivono nel progetto. Vivado sintetizza solo
quello scelto come top. Per la demo del prof si può presentare entrambe
e fare il confronto in slide.

**Come usarlo in Vivado**:
1. Add Sources dei 4 file di `src/core/` (regfile_dp, forwarding_unit,
   hazard_unit, cpu_top_pipelined) e del testbench in `sim/`.
2. Tasto destro su `tb_cpu_pipelined` → Set as Top (sotto Simulation
   Sources).
3. Run Simulation → Run Behavioral Simulation → Run All.
4. Verifica console: nessun `severity error`. PC finale a 0x014.

Per portare la pipeline sulla scheda Nexys4 DDR (sostituendo la multi-cycle):
nel wrapper `nexys4ddr_top.vhd` sostituire `entity work.cpu_top` con
`entity work.cpu_top_pipelined`. Tutto il resto (XDC, memory_map,
periferiche) resta invariato.

---

## 6. Cosa dire al prof in demo

> *"Ho implementato la stessa ISA RV32I a 14 istruzioni in due
> microarchitetture distinte. Quella multi-cycle a FSM 4 stati segue alla
> lettera la spec del PDF del corso (slide 14-22). Quella pipelined a 5
> stadi (IF/ID/EX/MEM/WB) è l'estensione architetturale: forwarding
> EX/MEM → EX e MEM/WB → EX risolve i data hazard RAW, stall di 1 ciclo
> con iniezione di NOP risolve il load-use hazard, e flush dei 2 stadi
> precedenti su branch taken risolve i control hazard. Il branch viene
> risolto in EX, quindi la penalità per branch taken è 2 cicli. Il
> regfile è stato riscritto come dual-port (2 read asincroni + 1 write
> sincrono) per supportare la lettura simultanea di rs1 e rs2 in ID."*

Domande probabili e risposte:
- **"Perché il branch è in EX e non in ID?"** → In ID i valori di
  rs1/rs2 non sono ancora sottoposti a forwarding, quindi un branch su
  registri appena scritti darebbe risultati sbagliati. Risolverlo in ID
  richiederebbe forwarding anticipato (più complesso, e accorcia il time
  budget di ID critical). 2 cicli di branch penalty su una ISA piccola
  sono accettabili.
- **"Qual è il critical path della pipeline?"** → Probabilmente il
  cammino EX: forwarding mux → ALU adder 32 bit → flip-flop EX/MEM. Da
  misurare con Report Timing dopo Implementation.
- **"Speedup misurato?"** → Da fare: contare i cicli per un programma
  noto (es. Hello World) su entrambe le versioni e fare il rapporto.
  Atteso ~3x.
- **"Perché non hai pipelinato il comparator?"** → Il comparator
  originale ha output latched, l'ho replicato combinatorialmente nel top
  per non modificare il file. Trade-off di duplicazione vs riusabilità.

---

## 7. Stato attuale del progetto (snapshot 2026-05-23)

| Fase | Stato | Note |
|---|---|---|
| A — Core multi-cycle | Completata | 9 moduli VHDL, simulazione OK |
| B — Periferiche UART + GPIO | Completata | Hello World OK in xsim |
| 3 — Bring-up su scheda | Parziale | Bitstream OK, LED arrivano a 0x55 (CPU completa Hello) ma 0 byte arrivano al PC. Test 3 con `uart_test_top` ha dimostrato che la catena hardware UART funziona, quindi il bug è in `sw → uart_tx_start` (vedi `memory/project_phase3_status.md` per i dettagli) |
| 4 — Pipeline | Scheletro pronto | 4 file VHDL + 1 testbench scritti. Da: simulare, eventuali bug fix, programma di test con hazard espliciti |
| 5 — Report + demo | Da fare | |

---

## 8. TODO immediati (prossima sessione)

**Per la pipeline**:
1. Lanciare `tb_cpu_pipelined` in xsim e verificare che passi (PC = 0x014).
2. Se non passa, identificare il bug (con grande probabilità sarà uno
   dei classici: off-by-one sui pipeline register, segnale di stall che
   non flusha bene, branch target sbagliato).
3. Scrivere un programmino con hazard espliciti per testare forwarding
   e stall in modo mirato.
4. Misurare il count di cicli per Hello World su pipeline vs
   multi-cycle → numero per la slide "speedup".

**Per il bring-up Fase 3** (issue ancora aperto):
1. Aggiungere LED15 = latch di "uart_tx_pin è mai sceso a 0" nel
   wrapper, per confermare se la CPU pilota davvero la linea TX.
2. Se LED15 si accende → il problema è elsewhere (improbabile dopo
   Test 3).
3. Se LED15 resta spento → uart_tx_start non viene mai asserito
   nonostante la CPU esegua la sw verso 0x10000. Da investigare con
   "Open Synthesized Design" in Vivado e cercare il signal
   `u_mmap/uart_tx_start` per vedere com'è stato sintetizzato.
