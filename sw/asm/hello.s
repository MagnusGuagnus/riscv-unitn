# hello.s — Programma "Hello World" per il sistema CPU + UART + GPIO
#
# Trasmette la stringa "Hello" sulla UART (115200 baud sulla scheda reale,
# baud divisor parametrizzato in simulazione) e accende pattern sui LED
# per segnalare lo stato di esecuzione.
#
# === Vincoli ISA del prof ===
# L'ISA ridotta (14 istr) NON include:
#   - LUI / AUIPC      → impossibile caricare costanti grandi in 1 sola istr
#   - JALR             → impossibile fare return da subroutine
#   - shift, SLT, ecc. → niente operazioni "fancy"
#
# In particolare, l'immediato di lw/sw è 12 bit signed (-2048..+2047),
# quindi NON si può fare `sw x6, 0x10000(x0)` direttamente.
#
# === Workaround indirizzi periferiche ===
# I 3 indirizzi delle periferiche (0x10000, 0x10004, 0x10008) vengono
# precaricati come dati nei primi 3 word di DMEM (vedi data_memory.vhd):
#   DMEM[0] = 0x00010000  (&UART_DATA)
#   DMEM[1] = 0x00010004  (&UART_STATUS)
#   DMEM[2] = 0x00010008  (&GPIO_LED)
# All'inizio del programma li carichiamo con lw in registri (x10..x12),
# che fanno poi da "base address" per le sw/lw successive con offset 0.
#
# I 5 caratteri di "Hello" sono precaricati ai word 4..8 di DMEM:
#   DMEM[4..8] = 'H','e','l','l','o'  (un carattere per word, byte alti = 0)
# Indirizzo base byte = 4*4 = 16, l'iterazione del loop avanza di 4 byte.
#
# === Convenzione registri usati ===
#   x10 → &UART_DATA      (base address)
#   x11 → &UART_STATUS    (base address)
#   x12 → &GPIO_LED       (base address)
#   x20 → base byte address dei caratteri in DMEM (= 16)
#   x22 → indice corrente nel loop (byte offset, 0..16 con step 4)
#   x24 → limite del loop (= 20, cioè 5 caratteri × 4 byte)
#   x6  → temporaneo per pattern LED
#   x5  → carattere corrente da trasmettere
#   x7  → temporaneo per polling UART_STATUS
#   x23 → indirizzo del carattere corrente (= x20 + x22)
#
# === Mappatura word index → byte address (per branch e per encoding) ===
#   istr 0..7  setup
#   istr 8..15 send_loop (8 istruzioni, ripetuto 5 volte)
#   istr 16..17 LED finale
#   istr 18    halt (jal x0, 0)
# I branch beq/blt usano offset relativi al PC corrente in byte:
#   beq @ 0x30 → poll @ 0x28      offset = -8
#   blt @ 0x3C → send_loop @ 0x20 offset = -28
#   jal @ 0x48 → halt @ 0x48      offset = 0

    .section .text
    .globl _start

_start:
    # === Setup: carica indirizzi periferiche da DMEM ===
    lw   x10, 0(x0)         # x10 = &UART_DATA
    lw   x11, 4(x0)         # x11 = &UART_STATUS
    lw   x12, 8(x0)         # x12 = &GPIO_LED

    # === Inizializza variabili del loop ===
    addi x20, x0, 16        # base byte address dei caratteri in DMEM
    addi x22, x0, 0         # i = 0 (byte offset corrente)
    addi x24, x0, 20        # limite (5 caratteri × 4 byte)

    # === LED pattern iniziale: 4 LED bassi accesi ===
    addi x6, x0, 15         # 0x0F
    sw   x6, 0(x12)         # GPIO_LED <= 0x0F

# === Loop principale: spedisci 5 caratteri ===
send_loop:
    add  x23, x20, x22      # x23 = base + i = indirizzo char corrente
    lw   x5, 0(x23)         # x5 = carattere (32 bit, byte basso usato dalla UART)

poll:
    lw   x7, 0(x11)         # x7 = UART_STATUS (bit 0 = ready)
    andi x7, x7, 1          # isola bit 0
    beq  x7, x0, poll       # se 0 (busy), riprova

    sw   x5, 0(x10)         # UART_DATA <= byte → parte la TX

    addi x22, x22, 4        # i += 4 byte (1 word)
    blt  x22, x24, send_loop  # se i < limite, continua

    # === LED pattern finale: 0x55 (alternato 0101_0101) ===
    addi x6, x0, 85         # 0x55
    sw   x6, 0(x12)         # GPIO_LED <= 0x55

# === Halt: loop infinito su se stesso ===
halt:
    jal  x0, halt           # offset = 0 → PC resta sull'istruzione

# === Encoding (per riferimento; identico a instr_memory.vhd PROGRAM_B) ===
#  0x00  lw   x10, 0(x0)            0x00002503
#  0x04  lw   x11, 4(x0)            0x00402583
#  0x08  lw   x12, 8(x0)            0x00802603
#  0x0C  addi x20, x0, 16           0x01000A13
#  0x10  addi x22, x0, 0            0x00000B13
#  0x14  addi x24, x0, 20           0x01400C13
#  0x18  addi x6, x0, 15            0x00F00313
#  0x1C  sw   x6, 0(x12)            0x00662023
#  0x20  add  x23, x20, x22         0x016A0BB3   ← send_loop:
#  0x24  lw   x5, 0(x23)            0x000BA283
#  0x28  lw   x7, 0(x11)            0x0005A383   ← poll:
#  0x2C  andi x7, x7, 1             0x0013F393
#  0x30  beq  x7, x0, -8            0xFE038CE3
#  0x34  sw   x5, 0(x10)            0x00552023
#  0x38  addi x22, x22, 4           0x004B0B13
#  0x3C  blt  x22, x24, -28         0xFF8B42E3
#  0x40  addi x6, x0, 85            0x05500313
#  0x44  sw   x6, 0(x12)            0x00662023
#  0x48  jal  x0, 0                 0x0000006F   ← halt:
