#==============================================================================
# wave_hazard.tcl
#
# Crea una waveform PULITA e RAGGRUPPATA per mostrare, su PROGRAM_E, i due
# meccanismi di controllo della pipeline:
#   - LOAD-USE STALL (la "bubble")
#   - FORWARDING (EX/MEM -> EX e MEM/WB -> EX)
# Pensata per generare la figura che sostituisce/affianca la Figure 2 del report.
#
# USO in Vivado:
#   1. Set as Top il testbench  sim/tb_cpu_pipelined_hazard.vhd
#   2. Flow -> Run Simulation -> Run Behavioral Simulation
#   3. Nella Tcl Console (in basso) digita (graffe perche' il path ha uno spazio):
#         source {C:/Users/utente/Desktop/UniProjects/RISC-V Proj/sim/wave_hazard.tcl}
#      oppure:
#         cd {C:/Users/utente/Desktop/UniProjects/RISC-V Proj/sim}
#         source wave_hazard.tcl
#   4. La wave si popola, fa restart e gira 200 ns.
#   5. Zoom Fit, poi esporta: File -> Export -> Export Waveform Configuration
#      per il .wcfg, e per l'IMMAGINE: nella Waveform, tasto destro ->
#      "Export to Image..." (PNG/PDF).
#
# NB: i segnali interni (stall, fwd_a, ...) sono dentro l'istanza uut. Se un path
# non viene trovato, controlla il nome esatto nello Scope/Objects pane.
#==============================================================================

set TB  "/tb_cpu_pipelined_hazard"
set UUT "$TB/uut"

# Pulisci eventuale wave precedente
catch { remove_wave -of [get_wave_config] [get_waves *] }

# --- Clock / Reset ---------------------------------------------------------
set g [add_wave_group "clk / reset"]
add_wave -into $g            $TB/clk
add_wave -into $g            $TB/reset

# --- Fetch / Decode (cosa sta entrando in pipeline) ------------------------
set g [add_wave_group "fetch / decode"]
add_wave -into $g -radix hex $UUT/pc_if
add_wave -into $g -radix hex $UUT/id_instr
add_wave -into $g            $UUT/ifid_valid

# --- Controllo: STALL e FLUSH (la bubble si vede qui) ----------------------
set g [add_wave_group "control: stall / flush"]
add_wave -into $g            $UUT/stall
add_wave -into $g            $UUT/flush_ifid
add_wave -into $g            $UUT/flush_idex

# --- Forwarding: i selettori e gli indirizzi coinvolti ---------------------
#   fwd = 00 dal regfile, 01 da EX/MEM, 10 da MEM/WB
set g [add_wave_group "forwarding"]
add_wave -into $g -radix bin $UUT/fwd_a
add_wave -into $g -radix bin $UUT/fwd_b
add_wave -into $g -radix hex $UUT/idex_rs1_addr
add_wave -into $g -radix hex $UUT/idex_rs2_addr
add_wave -into $g -radix hex $UUT/exmem_rd_addr
add_wave -into $g -radix hex $UUT/memwb_rd_addr

# --- EX / risultato / firma ------------------------------------------------
set g [add_wave_group "EX / result"]
add_wave -into $g -radix hex $UUT/idex_rd_addr
add_wave -into $g -radix hex $UUT/alu_result_ex
add_wave -into $g -radix hex $TB/led_out

# --- Esegui ----------------------------------------------------------------
restart
run 200 ns
catch { wave_zoom_fit }
puts "wave_hazard.tcl: segnali caricati, simulazione a 200 ns. Cerca:"
puts "  * il ciclo con stall=1  -> e' la BUBBLE (load-use su x4)"
puts "  * il ciclo con fwd_a=10 e fwd_b=01 mentre in EX c'e' add x3,x1,x2 -> FORWARDING doppio"
