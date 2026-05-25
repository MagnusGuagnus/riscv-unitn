# Vivado — Guida pratica per il progetto RISC-V

Vivado è l'IDE di AMD/Xilinx per progettare su FPGA della famiglia 7-series, Zynq, UltraScale, ecc. Copre tutto il flusso: editing del codice HDL, simulazione, sintesi, place & route, generazione bitstream, programmazione della board, debug live.

---

## 1. Cosa fa Vivado, in 30 secondi

```
   tu scrivi VHDL
        │
        ▼
   ┌────────────┐
   │ Simulation │  ← verifichi il comportamento (testbench)
   └────────────┘
        │ ok
        ▼
   ┌────────────┐
   │ Synthesis  │  ← traduce il VHDL in gate/LUT/FF (netlist)
   └────────────┘
        │
        ▼
   ┌────────────┐
   │ Implem.    │  ← place & route: assegna LUT/FF fisiche e collega i fili
   └────────────┘  ← qui si fanno i timing analysis
        │
        ▼
   ┌────────────┐
   │ Bitstream  │  ← file .bit da caricare sull'FPGA
   └────────────┘
        │
        ▼
   programma la board (USB-JTAG)
```

Ogni passaggio è "incrementale": se cambi una cosa piccola, Vivado rifa solo le fasi necessarie.

---

## 2. Creare un nuovo progetto

**File → New Project → Next**.

1. **Project name & location**: chiama il progetto `risc_v_cpu`, location = la cartella `RISC-V Proj/` (Vivado creerà una sottocartella).
2. **Project type**: `RTL Project`. **NON** mettere la spunta "Do not specify sources at this time" (lasciala se vuoi aggiungere dopo, va bene comunque).
3. **Add Sources**: puoi saltare ora e aggiungerli dopo. Lingua di default: VHDL.
4. **Add Constraints**: salta, aggiungerai dopo.
5. **Default Part / Board**: il corso supporta due board, scegli una delle due:
   - **Nexys4 DDR** (consigliata): tab **Parts** → cerca `xc7a100tcsg324-1` (Artix-7 XC7A100T).
   - **Zedboard**: tab **Boards** → cerca "ZedBoard Zynq Evaluation and Development Kit" (richiede board files installati; in alternativa Part `xc7z020clg484-1`).

   Il prof fornisce gli XDC master di entrambe nei materiali del corso ("Board resources"): `Nexys4DDR Master xdc file` e `zedboard master XDC RevC D v2`. Scaricali e copiali in `constraints/`.
6. **Finish**.

Risultato: una struttura di progetto Vivado con `Sources / Constraints / Simulation Sources`.

---

## 3. Aggiungere file VHDL al progetto

Due strade:

**a) Da menu**: `Add Sources` (icona o `Alt+A`) → scegli `Add or create design sources` → `Add Files` → seleziona i `.vhd` dalla cartella `src/core/`, `src/memory/`, `src/peripherals/`. **Spunta "Copy sources into project"** se vuoi che Vivado faccia copia, oppure togli la spunta se vuoi che il progetto Vivado **referenzi** i file in-place (più comodo per Git, più rischioso se sposti le cartelle).

**b) Trascinamento**: puoi trascinare i file dall'esplora risorse direttamente nel pannello Sources.

Per i **testbench**: `Add Sources → Add or create simulation sources`.

Per i **constraint**: `Add Sources → Add or create constraints` (file `.xdc`).

Convenzione consigliata: tieni sources e simulation in cartelle separate (lo abbiamo già impostato così: `src/` e `sim/`).

---

## 4. Set Top — qual è il modulo top-level

Nel pannello **Sources**, click destro sul modulo che è il "top" → `Set as Top`. Quello diventa il modulo che verrà sintetizzato.

- Per simulazione: il top è il **testbench** (es. `tb_alu`). Ha colore diverso nel pannello.
- Per sintesi: il top è il **wrapper di tutto il chip** (es. `cpu_top` o un wrapper della board).

I due "top" sono indipendenti: Sources ha il top di sintesi, Simulation Sources ha il top di simulazione.

---

## 5. Simulazione — il flusso quotidiano del progetto

Il **90% del tempo** lo passi qui: scrivi un modulo, fai un testbench, lanci la simulazione, controlli le waveform, correggi.

### Lanciare la simulazione

Con un testbench come top di simulazione: `Flow Navigator → SIMULATION → Run Simulation → Run Behavioral Simulation`.

Si apre una finestra **waveform** con i segnali di interesse.

### Manipolare le waveform

- **Add signal**: trascina dal pannello "Scope" o "Objects" alla waveform.
- **Run All / Run for X ns**: i pulsanti in alto, oppure tasto destro `Run All`.
- **Restart**: ricomincia dalla simulazione zero.
- **Zoom**: rotellina, oppure `Zoom Fit` (icona) per vedere tutto.
- **Cursor / markers**: `Ctrl+click` per posizionare un cursore.
- **Radix**: tasto destro su un segnale → `Radix → Hexadecimal / Decimal / Signed Decimal / Binary / ASCII`. Cambia come visualizzi i numeri.
- **Group**: seleziona più segnali → tasto destro → `Group` per raggrupparli.

### Salvare la configurazione delle waveform

Il file `*.wcfg` salva quali segnali stai vedendo, con che radix, che gruppi. Salvalo (`File → Save Waveform Configuration`) così la prossima volta non perdi il lavoro. Hai già un file di questo tipo nel progetto chess: `tb_chess_core_behav.wcfg`.

### Re-launch dopo aver modificato il codice

Se modifichi un file VHDL: `Relaunch Simulation` (icona col cerchio verde con freccia). Vivado ricompila e ripartem mantenendo le waveform aperte.

### Tcl console

In basso c'è una **Tcl console**. Comandi utili:
- `add_force {/tb_alu/a} {00000001}` — forza un valore
- `restart` — riparte
- `run 100 ns` — corre per 100 ns
- `add_wave {/tb_alu/uut/result}` — aggiunge un segnale alla waveform

---

## 6. Synthesis — dal VHDL alla netlist

Una volta che il modulo simula correttamente, sintetizzi: `Flow Navigator → SYNTHESIS → Run Synthesis`.

Vivado:
1. Compila tutti i sorgenti.
2. Verifica che la grammatica sia corretta.
3. Inferisce gate, LUT, flip-flop, BRAM, DSP dal VHDL.
4. Produce una **netlist** (lista di componenti collegati).

### Cose a cui prestare attenzione nei warning di sintesi

Apri `Synthesis → Open Synthesized Design → Reports → Report Methodology` (o leggi il `Messages` panel):

- **"inferred latch on signal X"**: hai un latch involontario. Vai a guardare il processo combinatorio che assegna `X` e metti default values in cima.
- **"signal X never used"**: un signal scollegato. Forse hai dimenticato di collegarlo.
- **"multi-driven nets"**: errore grave, lo stesso signal è scritto da due processi.
- **"large RAM inferred"**: un array grande. Vivado lo mappa su BRAM (bene) o su LUT (male se troppo grande).
- **"Combinatorial loop detected"**: errore grave, hai un anello combinatorio (es. `y <= y or a;`). Da rompere con un registro.

### Report di sintesi

Nel pannello Synthesis, dopo che gira:
- **Utilization**: quante LUT, FF, BRAM, DSP hai usato e su quanto totale.
- **Timing summary**: stima preliminare del clock max raggiungibile (più affidabile dopo Implementation).

---

## 7. Implementation — place & route

`Flow Navigator → IMPLEMENTATION → Run Implementation`.

Vivado:
1. **Place**: assegna ogni cella della netlist a una posizione fisica nell'FPGA.
2. **Route**: collega le celle con i fili interni.
3. **Optimize**: ottimizza percorsi critici.

A questo punto i report di **timing** sono affidabili: ti dicono se il design "chiude" il timing (ovvero se il clock che vuoi è raggiungibile).

### Report di timing — cosa guardare

`Open Implemented Design → Reports → Report Timing Summary`:

- **WNS (Worst Negative Slack)**: se è positivo, il timing è OK. Se è negativo, il design è troppo lento per il clock richiesto.
- **TNS (Total Negative Slack)**: somma di tutti gli slack negativi.
- **Critical paths**: i percorsi più lenti. Sono quelli da ottimizzare se WNS < 0.

Per il report del progetto, una sezione "performance" con WNS, critical path, e utilization è quasi obbligatoria.

---

## 8. Generate Bitstream e program

`Generate Bitstream` produce il file `.bit`. `Open Hardware Manager → Open Target → Auto Connect` collega la board via USB-JTAG. `Program Device` carica il bitstream sull'FPGA.

Sulle Zynq (Zedboard) c'è un passaggio in più perché c'è anche il PS (Processing System ARM): di solito basta `Program Device` per il PL puro.

---

## 9. Constraint file (.xdc) — collegare il design ai pin fisici

Senza constraint, il design è "teorico". Per farlo girare sulla board reale devi dire a Vivado:

1. **A quale pin fisico** collegare ogni porta del top-level.
2. **Qual è il clock e a che frequenza** gira.
3. (Opzionale) **Quale standard elettrico** usare (LVCMOS33, LVDS, ecc.).

Esempio per uno switch e un LED su Nexys A7:

```tcl
# clock 100 MHz
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

# switch SW0
set_property -dict { PACKAGE_PIN J15  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]

# LED LD0
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]

# UART TX/RX
set_property -dict { PACKAGE_PIN C4   IOSTANDARD LVCMOS33 } [get_ports uart_rxd_in]
set_property -dict { PACKAGE_PIN D4   IOSTANDARD LVCMOS33 } [get_ports uart_txd_out]
```

I file `.xdc` di esempio per ogni board ufficiale sono scaricabili dal sito del produttore (Digilent, AMD/Xilinx). **Non scriverli da zero**: parti dal master file della tua board e decommenta solo i pin che usi.

---

## 10. IP Catalog — usare blocchi pre-fatti

`Project Manager → IP Catalog`.

Cataloghi utili per il progetto RISC-V:
- **Block Memory Generator**: per BRAM con porte personalizzate (utile per IMEM/DMEM con dimensioni custom).
- **Clocking Wizard**: per generare clock derivati (es. da 100 MHz fai 50 MHz per la CPU + 25 MHz per VGA).
- **AXI UART Lite**: UART pronto, ma per il progetto fattelo da te.
- **Floating Point**: FP unit auto-generata (ma il prof preferisce che la fai a mano).
- **MicroBlaze**: soft-core processor — non ti serve, fai il tuo.

Per il progetto, in linea generale, **scrivi tutto a mano** in VHDL — l'unico IP "lecito" che ha senso usare è la BRAM (e anche quella puoi inferirla con un pattern VHDL, come hai già fatto in `RAM_chess_board.vhd`).

---

## 11. Workflow tipico per ogni nuovo modulo

1. Crea il file `.vhd` in `src/core/` (o cartella appropriata).
2. Aggiungilo a Sources del progetto Vivado.
3. Crea il testbench corrispondente in `sim/`.
4. Aggiungilo a Simulation Sources.
5. Set as Top quel testbench.
6. Run Simulation.
7. Verifica le waveform e gli `assert`.
8. Quando tutto OK, lancia `Run Synthesis` per controllare che si sintetizzi pulito (warning ridotti).
9. Quando hai più moduli integrati, fai una simulazione end-to-end del top.

Ripeti per ogni modulo. Solo alla fine, quando il top integrato gira in simulazione, fai bitstream + program della board.

---

## 12. Tcl scripting — riproducibilità del progetto

Vivado è 100% scriptabile in Tcl. Per il **report finale** è utile avere uno script che ricrea il progetto da zero, perché Vivado XPR file sono grossi e poco diff-friendly.

**Salvare la "ricetta" del progetto:**
```tcl
File → Project → Write Tcl
```

Questo genera uno script che, eseguito con `vivado -mode batch -source build.tcl`, ricrea l'intero progetto.

Comandi Tcl utili (da eseguire in Tcl Console):
```tcl
# liste / info
get_files                       # tutti i file del progetto
get_property TOP [current_fileset]
report_utilization
report_timing_summary

# build flow
launch_runs synth_1 -jobs 4
launch_runs impl_1 -jobs 4 -to_step write_bitstream
```

---

## 13. Errori comuni di Vivado e cosa significano

| Errore | Significato | Cosa fare |
|---|---|---|
| `[Synth 8-XXX] Combinatorial loop detected` | hai un loop logico senza FF | aggiungi un registro nel loop |
| `[DRC NSTD-1]` su un pin | pin senza I/O standard | aggiungi `IOSTANDARD` nel `.xdc` |
| `[Place 30-574]` failed to route | timing impossibile o pin sbagliati | controlla pin assignment e clock |
| `Top file is empty / mismatch` | il top non corrisponde | Set as Top sul modulo giusto |
| simulazione non trova un signal | nome del path sbagliato | usa `find_signal` in Tcl o esplora "Scope" |
| `INFO: [Common 17-206] Exiting Vivado` di colpo | crash, di solito RAM esaurita | chiudi altre finestre, riavvia |

---

## 14. Per il progetto RISC-V, in pratica

**Sequenza concreta:**

1. Crea progetto Vivado `risc_v_cpu` dentro `RISC-V Proj/`.
2. Aggiungi i 3 sorgenti già scritti (`alu.vhd`, `regfile.vhd`, `immediate_gen.vhd`).
3. Aggiungi `tb_alu.vhd` come simulation source.
4. Set as Top → `tb_alu`. Run Simulation. Verifica che gli `assert` non sparino.
5. Scrivi il prossimo modulo (`decoder.vhd`), il suo testbench, ripeti.
6. Una volta che hai tutti i pezzi, scrivi `cpu_top.vhd` che li integra, e un testbench `tb_cpu_singlecycle.vhd` che carica un mini-programma in IMEM ed esegue qualche istruzione.
7. Quando la simulazione end-to-end funziona, aggiungi UART, scrivi un programma "Hello World" in assembly, esegui sulla CPU virtuale, vedi che la UART scriva i byte giusti.
8. Aggiungi il file `.xdc` della tua board, set top di sintesi al wrapper della board, run synthesis + implementation + bitstream.
9. Programma la board e verifica che la UART vera sputi i byte attesi sul terminale (es. PuTTY a 115200 baud).
10. Refactor a pipeline.
11. Report.

**Tempo medio per padroneggiare Vivado**: una settimana se è la prima volta, 1-2 giorni se l'hai già usato. La maggior parte delle frustrazioni viene da:
- pin assignment sbagliato (constraint)
- clock non dichiarato come tale (manca `create_clock`)
- top sbagliato in synthesis vs simulation

---

## 15. Risorse extra

- **UG901 — Synthesis User Guide** (AMD/Xilinx): cosa Vivado riconosce e come, lista pattern sintetizzabili.
- **UG903 — Constraints Guide**: tutto su `.xdc`.
- **UG937 — Design Suite Tutorial: Logic Simulation**: tutorial step-by-step della simulazione.
- **YouTube "Vivado tutorial"**: tantissimi video pratici, anche per board specifiche.
- **Digilent Reference**: master XDC delle board Digilent (Zedboard, Nexys, ecc.).
