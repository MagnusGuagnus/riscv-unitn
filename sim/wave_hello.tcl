#==============================================================================
# wave_hello.tcl  --  waveform "Hello su UART" (PROGRAM_H) per il report.
#
# USO (path con spazio -> graffe):
#   1. Set as Top: sim/tb_hello_wave.vhd
#   2. Run Behavioral Simulation
#   3. Tcl Console:
#        source {C:/Users/utente/Desktop/UniProjects/RISC-V Proj/sim/wave_hello.tcl}
#   4. Esporta lo screenshot della waveform (Win+Shift+S) come
#        docs/report/hello_wave.png
#
# Da inquadrare: la linea uart_tx_pin con i frame 8N1 (start/8 dati/stop) e
# il led_out che passa da 0x000F (avvio) a 0x0055 (fine "Hello").
#==============================================================================
set TB  "/tb_hello_wave"
set UUT "$TB/uut"
catch { remove_wave -of [get_wave_config] [get_waves *] }

set g [add_wave_group "clk / reset"]
add_wave -into $g            $TB/clk
add_wave -into $g            $TB/reset

set g [add_wave_group "fetch / decode"]
add_wave -into $g -radix hex $UUT/pc_if
add_wave -into $g -radix hex $UUT/id_instr

set g [add_wave_group "UART"]
add_wave -into $g            $TB/uart_tx_pin
add_wave -into $g            $UUT/u_mmap/uart_tx_start
add_wave -into $g            $UUT/u_mmap/u_uart/state
add_wave -into $g            $UUT/u_mmap/u_uart/tx_busy
add_wave -into $g            $UUT/u_mmap/uart_status_q

set g [add_wave_group "GPIO"]
add_wave -into $g -radix hex $TB/led_out

restart
run 6 us
catch { wave_zoom_fit }
puts "wave_hello.tcl: cerca i frame su uart_tx_pin (start/8 dati/stop) e led_out 0x000F -> 0x0055"
