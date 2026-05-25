# VHDL — Cheat Sheet & ripasso strutturato

Riferimento veloce per il progetto RISC-V. Tutti gli esempi sono pensati per Vivado / sintetizzabili.

---

## 1. Anatomia di un file VHDL

Ogni file VHDL ha **tre parti** che si scrivono sempre in quest'ordine:

```vhdl
-- 1. LIBRARY: importi le librerie standard
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;   -- tipi std_logic, std_logic_vector
use IEEE.NUMERIC_STD.ALL;      -- signed, unsigned, conversioni

-- 2. ENTITY: l'interfaccia "esterna" del modulo (i pin)
entity nome_modulo is
    port (
        clk    : in  std_logic;
        rst    : in  std_logic;
        d_in   : in  std_logic_vector(7 downto 0);
        d_out  : out std_logic_vector(7 downto 0)
    );
end nome_modulo;

-- 3. ARCHITECTURE: l'implementazione "interna" del modulo
architecture Behavioral of nome_modulo is
    -- dichiarazioni di signal, costanti, type, componenti
    signal counter : unsigned(7 downto 0) := (others => '0');
begin
    -- corpo: statement concorrenti e processi
    d_out <= std_logic_vector(counter);
end Behavioral;
```

**Mental model**: l'`entity` è il "contratto" (cosa entra ed esce dal chip), l'`architecture` è la circuiteria interna. Puoi avere più architetture per la stessa entity (Behavioral, Structural, RTL…) ma in pratica nel corso ne userai una sola per modulo.

---

## 2. Libraries — quali importare e perché

```vhdl
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;   -- SEMPRE: tipi base std_logic e operatori logici
use IEEE.NUMERIC_STD.ALL;      -- QUASI SEMPRE: signed/unsigned, +, -, conversioni
```

**Da NON usare** (legacy, causano problemi in sintesi):
- `IEEE.STD_LOGIC_ARITH` — vecchia, sostituita da NUMERIC_STD
- `IEEE.STD_LOGIC_UNSIGNED` / `STD_LOGIC_SIGNED` — non standard

**Per pacchetti tuoi**:
```vhdl
use work.pieces_encoding.all;   -- importa il package "pieces_encoding" del progetto
```

---

## 3. Tipi di dato fondamentali

| Tipo | Quando usarlo | Esempio |
|---|---|---|
| `std_logic` | 1 bit di segnale fisico | `signal x : std_logic;` |
| `std_logic_vector(N downto 0)` | bus di N+1 bit, "puro" | `signal bus : std_logic_vector(31 downto 0);` |
| `unsigned(N downto 0)` | numero senza segno (per +, -, *, confronti) | `signal cnt : unsigned(7 downto 0);` |
| `signed(N downto 0)` | numero con segno in complemento a 2 | `signal val : signed(31 downto 0);` |
| `integer range a to b` | utile per indici e contatori, sintetizzato come bit minimi | `signal i : integer range 0 to 63;` |
| `boolean` | true/false (NON sintetizzato direttamente, usa per flag interni) | `signal done : boolean;` |
| `std_logic` valori | `'0'`, `'1'`, `'Z'` (alta impedenza), `'X'` (unknown), `'-'` (don't care) | |

**Regola pratica**: usa `std_logic_vector` per le porte (interfaccia pulita), e converti a `unsigned`/`signed` internamente quando devi fare aritmetica.

### Conversioni più frequenti

```vhdl
-- da std_logic_vector a unsigned/signed
signal a : std_logic_vector(7 downto 0);
signal u : unsigned(7 downto 0);
u <= unsigned(a);

-- da unsigned/signed a std_logic_vector
a <= std_logic_vector(u);

-- da integer a unsigned di N bit
signal i : integer range 0 to 255;
u <= to_unsigned(i, 8);

-- da unsigned a integer
i <= to_integer(u);

-- sign extension di un vettore di 12 a 32 bit (signed)
signal short : std_logic_vector(11 downto 0);
signal ext   : std_logic_vector(31 downto 0);
ext <= std_logic_vector(resize(signed(short), 32));
```

---

## 4. Operatori

```
Logici:        and  or  nand  nor  xor  xnor  not
Aritmetici:    +  -  *  /  mod  rem  abs  **    (richiedono numeric_std)
Confronto:     =  /=  <  <=  >  >=
Shift:         sll  srl  sla  sra  rol  ror     (su unsigned/signed)
Concatenazione: &
```

**Esempi:**
```vhdl
result <= a and b;
sum    <= std_logic_vector(unsigned(a) + unsigned(b));   -- somma
shifted <= std_logic_vector(shift_left(unsigned(a), 4)); -- a << 4
joined <= "00" & x(7 downto 0) & "11";                   -- concatena
```

---

## 5. Statement concorrenti (fuori dai processi)

Tutto quello che è scritto direttamente nel corpo dell'`architecture`, **fuori dai processi**, è **concorrente**: tutti gli statement si eseguono "in parallelo" — l'ordine in cui li scrivi non conta.

### 5.1 Assegnamento semplice

```vhdl
y <= a and b;
```

### 5.2 Assegnamento condizionale `when/else`

```vhdl
mux_out <= a when sel = '0' else b;

-- a 4 vie:
result <= reg1 when sel = "00" else
          reg2 when sel = "01" else
          reg3 when sel = "10" else
          reg4;
```

### 5.3 Assegnamento selezionato `with/select`

Equivalente a un `case`:

```vhdl
with sel select
    result <= a when "00",
              b when "01",
              c when "10",
              d when others;
```

`when others` è quasi sempre obbligatorio.

---

## 6. Processi (statement sequenziali)

Un `process` racchiude statement che si eseguono **in ordine sequenziale**, ma il processo intero è esso stesso uno statement concorrente.

### 6.1 Processo combinatorio (sensitivity list completa)

```vhdl
comb: process(a, b, sel)
begin
    if sel = '1' then
        y <= a;
    else
        y <= b;
    end if;
end process;
```

**Regola**: in un processo combinatorio, **ogni signal letto** deve essere nella sensitivity list, **ogni signal in uscita** deve essere assegnato in tutti i rami (altrimenti si genera un latch involontario — è un bug grave). VHDL-2008 permette `process(all)`.

### 6.2 Processo sincrono (registro / FF)

```vhdl
seq: process(clk)
begin
    if rising_edge(clk) then
        if rst = '1' then
            q <= (others => '0');
        else
            q <= d;
        end if;
    end if;
end process;
```

Questo è il **template di un flip-flop con reset sincrono**. Quasi tutto il tuo design userà varianti di questo.

### 6.3 Statement disponibili nei processi

```vhdl
-- if / elsif / else
if cond1 then ...
elsif cond2 then ...
else ...
end if;

-- case
case sel is
    when "00" => y <= a;
    when "01" => y <= b;
    when others => y <= '0';
end case;

-- loop (sintetizzabile solo se i bound sono costanti / static)
for i in 0 to 7 loop
    arr(i) <= '0';
end loop;

-- exit / next per uscire / saltare iterazione
```

---

## 7. Signal vs Variable

| | Signal | Variable |
|---|---|---|
| Dichiarata in | architecture o process | **solo dentro process** |
| Aggiornamento | alla fine del processo (delta cycle) | **immediato** |
| Operatore assegnamento | `<=` | `:=` |
| Quando usare | quasi sempre | per calcoli temporanei intra-processo |

**Esempio della differenza:**
```vhdl
-- con signal: x e y assumono il valore VECCHIO di a all'esecuzione
process(clk)
begin
    if rising_edge(clk) then
        a <= a + 1;
        x <= a;        -- x prende il valore PRECEDENTE di a
        y <= a + 1;    -- y prende il valore PRECEDENTE di a + 1
    end if;
end process;

-- con variable: x e y vedono il valore aggiornato istantaneamente
process(clk)
    variable v : integer := 0;
begin
    if rising_edge(clk) then
        v := v + 1;
        x <= std_logic_vector(to_unsigned(v, 8));   -- x prende v aggiornato
    end if;
end process;
```

---

## 8. Pattern ricorrenti (templates)

### 8.1 Logica combinatoria pura (no clock)

```vhdl
y <= a xor b;                              -- one-liner concorrente
y <= '1' when a > b else '0';              -- conditional
```

### 8.2 Registro semplice

```vhdl
process(clk)
begin
    if rising_edge(clk) then
        if rst = '1' then q <= (others => '0');
        else              q <= d;
        end if;
    end if;
end process;
```

### 8.3 Contatore

```vhdl
process(clk)
begin
    if rising_edge(clk) then
        if rst = '1' then
            cnt <= (others => '0');
        elsif enable = '1' then
            cnt <= cnt + 1;
        end if;
    end if;
end process;
```

### 8.4 FSM (Finite State Machine) — pattern a 2 processi

```vhdl
type state_t is (IDLE, LOAD, COMPUTE, DONE);
signal pstate, nstate : state_t;

-- Processo 1: registro di stato (sincrono)
state_reg: process(clk)
begin
    if rising_edge(clk) then
        if rst = '1' then pstate <= IDLE;
        else              pstate <= nstate;
        end if;
    end if;
end process;

-- Processo 2: logica di transizione + uscite (combinatorio)
next_state: process(pstate, start, data_ready)
begin
    -- default values
    nstate <= pstate;
    busy   <= '0';
    done   <= '0';

    case pstate is
        when IDLE =>
            if start = '1' then nstate <= LOAD; end if;
        when LOAD =>
            busy <= '1';
            if data_ready = '1' then nstate <= COMPUTE; end if;
        when COMPUTE =>
            busy <= '1';
            nstate <= DONE;
        when DONE =>
            done <= '1';
            nstate <= IDLE;
    end case;
end process;
```

Hai già usato esattamente questo pattern in `chess_core.vhd`. È il pattern standard.

### 8.5 RAM single-port

```vhdl
type ram_t is array (0 to 63) of std_logic_vector(7 downto 0);
signal mem : ram_t := (others => (others => '0'));

process(clk)
begin
    if rising_edge(clk) then
        if we = '1' then
            mem(to_integer(unsigned(addr))) <= din;
        end if;
        dout <= mem(to_integer(unsigned(addr)));
    end if;
end process;
```

Vivado riconosce questo pattern e lo mappa automaticamente su BRAM.

### 8.6 ROM con valori inizializzati

```vhdl
type rom_t is array (0 to 7) of std_logic_vector(7 downto 0);
constant ROM_DATA : rom_t := (
    0 => x"01",
    1 => x"02",
    2 => x"04",
    3 => x"08",
    others => x"00"
);

process(clk)
begin
    if rising_edge(clk) then
        dout <= ROM_DATA(to_integer(unsigned(addr)));
    end if;
end process;
```

---

## 9. Istanziare un componente (component instantiation)

Hai due stili — **direct entity instantiation** è più semplice e moderno:

```vhdl
-- nel corpo dell'architecture
u_alu : entity work.alu
    port map (
        a      => operand_a,
        b      => operand_b,
        alu_op => ctrl_alu_op,
        result => alu_result,
        zero   => alu_zero
    );
```

`work` è la libreria del progetto corrente. `u_alu` è il **nome dell'istanza** (etichetta univoca, serve a Vivado per il debug).

### Stile vecchio con `component` declaration (a volte richiesto)

```vhdl
architecture rtl of top is
    component alu is
        port (
            a, b   : in  std_logic_vector(31 downto 0);
            alu_op : in  std_logic_vector(3 downto 0);
            result : out std_logic_vector(31 downto 0);
            zero   : out std_logic
        );
    end component;
begin
    u_alu : alu port map ( ... );
end rtl;
```

Il primo stile (entity work.xyz) è preferibile.

---

## 10. Package — condividere costanti, tipi, funzioni

```vhdl
-- file: my_pkg.vhd
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package my_pkg is
    constant DATA_WIDTH : integer := 32;
    type opcode_t is (OP_ADD, OP_SUB, OP_AND);
    function is_branch(op : std_logic_vector) return boolean;
end package my_pkg;

package body my_pkg is
    function is_branch(op : std_logic_vector) return boolean is
    begin
        return op = "1100011";
    end function;
end package body my_pkg;
```

E poi nei file che lo usano:
```vhdl
use work.my_pkg.all;
```

Hai già fatto questo in `pieces_encoding.vhd`.

---

## 11. Generic — moduli parametrici

```vhdl
entity counter is
    generic (
        WIDTH : integer := 8
    );
    port (
        clk : in  std_logic;
        rst : in  std_logic;
        cnt : out std_logic_vector(WIDTH-1 downto 0)
    );
end counter;
```

E si istanzia con:
```vhdl
u_cnt : entity work.counter
    generic map ( WIDTH => 16 )
    port map ( clk => clk, rst => rst, cnt => count );
```

---

## 12. Generate — replicare strutture

```vhdl
gen_regs: for i in 0 to 31 generate
    u_reg : entity work.reg32
        port map (
            clk  => clk,
            d    => data_in(i),
            q    => data_out(i)
        );
end generate;
```

Utile per istanziare 32 registri, banchi di multiplexer, ecc.

---

## 13. Errori e trappole comuni

| Sintomo | Causa | Soluzione |
|---|---|---|
| "inferred latch" warning | processo combinatorio con un signal non assegnato in qualche ramo | metti default values in cima al processo |
| simulazione OK, sintesi diversa | uso di `wait`, `after`, ritardi numerici | rimuovili, sono solo per testbench |
| segnali "rossi" in waveform | tipo `'X'` (unknown) — di solito un signal non resettato | aggiungi reset, inizializza |
| "multiple drivers" | stesso signal assegnato in 2 processi diversi | un signal = un solo "driver" (un processo o un assegnamento) |
| sintesi fallisce su `for` loop | bound non statico | usa solo costanti / generic come bound |
| `to_integer` su un vettore con `'X'` | input non inizializzato | reset sincrono, oppure default `(others => '0')` |
| `if rising_edge(clk) and rst = '1'` non funziona | reset asincrono male implementato | `if rst = '1' then ... elsif rising_edge(clk) then ... end if;` |

---

## 14. Testbench — struttura minima

```vhdl
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_alu is end tb_alu;   -- testbench: nessuna porta

architecture sim of tb_alu is
    signal a, b, result : std_logic_vector(31 downto 0);
    signal alu_op       : std_logic_vector(3 downto 0);
    signal zero         : std_logic;
    signal clk          : std_logic := '0';
begin
    -- DUT (Device Under Test)
    uut: entity work.alu
        port map ( a => a, b => b, alu_op => alu_op,
                   result => result, zero => zero );

    -- clock generator (10 ns period = 100 MHz)
    clk <= not clk after 5 ns;

    -- stimoli
    stim: process
    begin
        a <= x"00000005"; b <= x"00000003"; alu_op <= "0000";
        wait for 10 ns;
        assert result = x"00000008" report "ADD failed" severity error;

        wait for 100 ns;
        report "Test completato" severity note;
        wait;   -- sospende il processo per sempre (fine simulazione)
    end process;
end sim;
```

Punti chiave del testbench:
- **non ha porte**, è il top della simulazione.
- Può usare costrutti **non sintetizzabili** (`wait`, `after`, scrittura su file…).
- Usa `assert` per verificare risultati attesi.
- `wait` finale evita che lo stimolo riparta in loop.

---

## 15. Tabella sintetizzabilità — cosa NON si può sintetizzare

| Costrutto | Sintesi | Note |
|---|---|---|
| `wait for 10 ns` | NO | solo testbench |
| `after 5 ns` | NO | solo testbench |
| `report` / `assert` | NO (o ignorato) | solo testbench |
| `file_open`, `read`, `write` | NO | solo testbench |
| `real`, `time` | spesso NO | usa integer / unsigned |
| ricorsione | dipende | meglio evitare |
| `loop` con bound dinamico | NO | bound deve essere statico |
| inizializzazioni di signal `:= ...` | sì in Vivado, no in tutti i tool | considerale "iniziale al power-on" |

**Regola d'oro**: se nel modulo "core" ti serve `wait` o `after`, stai sbagliando. Quei costrutti vivono solo nel testbench.

---

## 16. Convenzioni di stile consigliate

- nomi entity/signal in `snake_case`, package con suffisso `_pkg`
- prefisso `u_` per istanze di componenti (`u_alu`, `u_regfile`)
- prefisso `tb_` per testbench
- segnali di reset: `rst` se sincrono attivo alto, `rst_n` se asincrono attivo basso
- segnali di clock: `clk` (un solo dominio), `clk_50`, `clk_100` se più domini
- usare `(others => '0')` invece di `"0000…0"` per i reset di vettori
- mai due driver sullo stesso signal
- un processo combinatorio ha **default values in cima**
