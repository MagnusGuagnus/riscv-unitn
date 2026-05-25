# Periferiche — UART TX e GPIO

Documento di riferimento per le 2 periferiche del progetto. Pensato per:
1. Capire **cosa sono** e come funzionano.
2. Sapere **cosa dire al prof** quando ti chiede dettagli.
3. Avere chiari i **memory-mapped registers** prima di scrivere il codice.

---

## 1. Memory-mapped I/O — il concetto generale

La nostra CPU comunica con le periferiche **come se fossero memoria**. Cioè:
- Per scrivere un byte sulla UART, il programma esegue `sw x5, UART_DATA(x0)`.
- Per leggere lo stato degli switch, il programma esegue `lw x5, GPIO_SW(x0)`.

L'hardware riconosce a quale "regione di indirizzi" stiamo accedendo e instrada la load/store verso la giusta destinazione (DMEM, UART, GPIO…). Tutto trasparente al programma assembly.

### Memory map del progetto

| Regione | Range indirizzi | Cosa è |
|---|---|---|
| **IMEM** | (interna, indirizzata dal PC) | Memoria programma, 4 kB |
| **DMEM** | `0x0000_0000` – `0x0000_3FFF` | Memoria dati, 16 kB |
| **UART_DATA** | `0x0001_0000` (W) | Byte da trasmettere via UART |
| **UART_STATUS** | `0x0001_0004` (R) | bit 0 = `'1'` se UART pronta a trasmettere |
| **GPIO_LED** | `0x0001_0008` (W) | 16 LED della Nexys4 DDR |
| **GPIO_SW** | `0x0001_000C` (R) | 16 switch della Nexys4 DDR |

(Gli indirizzi sono scelti in modo che bastino i bit `alu_pre_result[16]` per distinguere DMEM da periferiche.)

### Come l'hardware "instrada" le store/load

Nel `cpu_top.vhd` c'è un modulo dedicato `memory_map.vhd` che fa da **bus**:
istanzia DMEM/UART/GPIO e fa il routing in base a 3 bit di `alu_pre_result`.

```
                                         alu_pre_result[16]=0 → DMEM
                                         alu_pre_result[16]=1 → periferiche
                                                                 │
                                                                 ├─ bit[3]=0 → UART
                                                                 │           ├─ bit[2]=0 → DATA  (W)
                                                                 │           └─ bit[2]=1 → STATUS (R)
                                                                 │
                                                                 └─ bit[3]=1 → GPIO
                                                                             ├─ bit[2]=0 → LED   (W)
                                                                             └─ bit[2]=1 → SW    (R)
```

### Lookup table del routing — riassunto operativo

Tabella di consultazione veloce: dati i 3 bit selettori (16/3/2) di `alu_pre_result`,
indica cosa succede a una `sw` e cosa torna a una `lw` su quell'indirizzo.

| `addr[16]` | `addr[3]` | `addr[2]` | Indirizzo | Una `sw` finisce in… | Una `lw` legge… |
|---|---|---|---|---|---|
| 0 | x | x | DMEM (0x0000–0x3FFF) | DMEM (BRAM 16 kB) | DMEM |
| 1 | 0 | 0 | UART_DATA   (0x10000) | parte la UART (kick) | 0 (write-only) |
| 1 | 0 | 1 | UART_STATUS (0x10004) | ignorata (read-only) | bit 0 = `NOT tx_busy` |
| 1 | 1 | 0 | GPIO_LED    (0x10008) | registro LED (16 bit) | 0 (write-only) |
| 1 | 1 | 1 | GPIO_SW     (0x1000C) | ignorata (read-only) | zero-ext degli switch |

**Note**:
- `sw` su read-only e `lw` da write-only **non causano errori**: rispettivamente
  vengono ignorate o ritornano 0. Comportamento "soft" tipico dei system-on-chip.
- Il routing è puramente combinatorio (3 condizioni `and` mutuamente esclusive),
  quindi al massimo **una** periferica vede `we='1'` in un dato ciclo di clock.
- La latenza di lettura è uniforme con DMEM (1 ciclo dopo `addr` applicato),
  perché le periferiche hanno il loro stato già registrato internamente.

---

## 2. UART TX — Universal Asynchronous Receiver-Transmitter (solo trasmissione)

### Cos'è in 3 frasi

UART è un **protocollo seriale a 1 filo** (più il GND). Trasmette i byte un bit alla volta, senza clock condiviso (per questo "asynchronous"): mittente e ricevente devono solo accordarsi sulla **velocità** (baud rate), tipicamente **115200 baud** (= bit/sec).

La Nexys4 DDR ha un chip USB-UART integrato che fa da ponte tra un pin del FPGA e una porta USB. Sul PC apri un terminale (PuTTY, TeraTerm, screen) configurato a 115200 baud, 8N1, e vedi i byte che la CPU spedisce.

### Anatomia di un byte UART (frame 8N1)

Per trasmettere il byte `0x41` (= ASCII 'A' = `01000001` binario), la linea TX fa così:

```
Tempo →
Idle (linea alta '1')  ───────┐                                                       ┌────── idle
                              │  start    bit0  bit1  bit2  bit3  bit4  bit5  bit6  bit7   stop
                              │  '0'      '1'   '0'   '0'   '0'   '0'   '0'   '1'   '0'    '1'
                              │   |        |     |     |     |     |     |     |     |      |
                              └───┴────────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴──────┘
                                  ←─────── 10 bit period × (1 / 115200 sec ciascuno) ──────→
```

- **Start bit**: la linea va a `'0'` per 1 periodo di bit. Segnala "comincia un byte".
- **8 data bit**: il byte, **LSB first** (bit 0 prima).
- **Stop bit**: la linea torna a `'1'` per ≥1 periodo. Pausa minima tra byte.
- **8N1** = 8 data bits, No parity, 1 stop bit. Standard, supportato da ogni terminale.

### Tempistica

A 115200 baud: 1 bit dura `1/115200 ≈ 8.68 µs`. Un byte completo (10 bit) dura ~87 µs. La nostra CPU che gira al clock di 100 MHz (= periodo 10 ns) deve "tenere stabile" ogni bit per `8680 / 10 = 868 cicli di clock`. Quindi il modulo UART avrà al suo interno un **contatore baud rate** che ogni 868 cicli avanza al bit successivo.

### Struttura del modulo `uart_tx.vhd`

In ingresso:
- `clk`, `reset`
- `tx_data[7:0]` (byte da trasmettere)
- `tx_start` (impulso di 1 ciclo: "spedisci tx_data ora")

In uscita:
- `tx_pin` (filo serial verso il chip USB-UART)
- `tx_busy` (`'1'` mentre sta trasmettendo, `'0'` quando è libero)

Logica interna:
- Una FSM con stati: `IDLE → START → BIT0 → BIT1 → ... → BIT7 → STOP → IDLE`
- Un contatore baud rate (868 cicli)
- Uno shift register per i bit dati

### Come la CPU lo usa

In assembly RISC-V (programma di test):

```asm
# Trasmetti 'A' = 0x41
again:
    lw    x5, 0x10004(x0)   # leggi UART_STATUS
    andi  x5, x5, 1         # isola bit 0 (busy/ready)
    beq   x5, x0, again     # se busy, riprova
    addi  x6, x0, 0x41      # x6 = 'A'
    sw    x6, 0x10000(x0)   # scrivi UART_DATA → parte la TX
```

Pattern classico: **polling** dello status fino a quando la UART è libera, poi scrittura del byte.

### Cosa puoi dire al prof

> *"Implemento una UART TX a 115200 baud, frame 8N1, memory-mapped. Il modulo ha una FSM a 11 stati (idle + start + 8 data + stop) con un contatore baud-rate che divide il clock di 100 MHz per ottenere il periodo di bit. La CPU vede 2 registri memory-mapped: UART_DATA in scrittura per il byte e UART_STATUS in lettura per controllare se è libera. Niente RX nel core base, eventualmente in estensione."*

---

## 3. GPIO — General Purpose I/O

### Cos'è in 2 frasi

GPIO è la periferica **più semplice** possibile: pin del FPGA collegati direttamente a LED (output) o switch (input). Memory-mapped: il programma scrive un valore e quei bit pilotano i LED; il programma legge un valore e ottiene lo stato dei switch.

### Struttura del modulo `gpio.vhd`

In ingresso:
- `clk`, `reset`
- `we` (write enable, dalla CPU)
- `din[15:0]` (valore da scrivere sui LED)
- `sw_in[15:0]` (segnali dai 16 switch fisici della Nexys4 DDR)

In uscita:
- `led_out[15:0]` (verso i 16 LED fisici della Nexys4 DDR)
- `sw_value[15:0]` (verso la CPU per la lettura)

Logica interna:
- Un singolo registro `led_reg(15:0)` che si aggiorna quando `we='1'`
- `sw_value <= sw_in` (passa diretto, magari con un latch per sincronizzare al clock)

È letteralmente 15 righe di VHDL. La complessità sta nei constraint XDC per il mapping pin.

### Come la CPU lo usa

```asm
# Accendi i 4 LED bassi
addi  x5, x0, 0x000F
sw    x5, 0x10008(x0)        # GPIO_LED <= 0x000F

# Leggi lo stato degli switch
lw    x6, 0x1000C(x0)        # x6 = stato 16 switch
```

### Constraint XDC necessari (commento per riferimento)

Dal master XDC della Nexys4 DDR, le righe rilevanti da decommentare sono:

```tcl
# 16 LED
set_property -dict { PACKAGE_PIN H17  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN K15  IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
# ... fino a led[15]

# 16 switch
set_property -dict { PACKAGE_PIN J15  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN L16  IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
# ... fino a sw[15]

# UART USB
set_property -dict { PACKAGE_PIN D4   IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]
# (uart_txd_in non lo usiamo per ora)

# Clock 100 MHz
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 [get_ports clk]
```

### Cosa puoi dire al prof

> *"Implemento un GPIO memory-mapped a 32 bit: in scrittura pilota i 16 LED della Nexys4 DDR, in lettura legge il valore dei 16 switch. È un registro singolo con write enable, banalissimo. Lo uso per visualizzare lo stato della CPU durante l'esecuzione (LED) e come input dati dinamico (switch) per i programmi di test."*

---

## 4. Programmi dimostrativi che useremo per la demo

Idee per programmi di test che esercitano CPU + periferiche:

1. **"Hello World"**: stringa "Hello\n" inviata via UART, un byte alla volta.
2. **Echo switch sui LED**: copia continuamente lo stato dei 16 switch sui 16 LED. Verifica GPIO read+write.
3. **Contatore visualizzato sui LED**: incrementa un registro e mostra gli ultimi 16 bit sui LED. Verifica ALU + GPIO.
4. **Fibonacci che stampa via UART**: calcola la sequenza e stampa i numeri formattati in ASCII via UART. Verifica ALU + branch + UART.
5. **Sort di un array in DMEM**: bubble sort su 10 numeri, poi stampa il risultato via UART. Verifica load/store/branch/UART.

Li scriveremo dopo aver verificato che le periferiche funzionano in simulazione, prima di andare alla fase di bitstream + scheda.

---

## 5. Riassunto in 1 minuto

| | UART TX | GPIO |
|---|---|---|
| Cosa fa | trasmette byte verso il PC | pilota LED + legge switch |
| Complessità VHDL | media (~60-80 righe + FSM) | bassa (~20 righe) |
| Effort | 8-12 h | 2-3 h |
| Memory-mapped @ | `0x0001_0000` (data), `0x0001_0004` (status) | `0x0001_0008` (LED), `0x0001_000C` (SW) |
| Pin XDC | 1 (TX) | 32 (16 LED + 16 SW) |
| Visibilità demo | alta (terminal PuTTY) | alta (LED che si accendono) |
| Cosa dire al prof | "UART 115200 baud 8N1, FSM 11 stati, memory-mapped" | "GPIO 16-bit in + 16-bit out, memory-mapped" |
