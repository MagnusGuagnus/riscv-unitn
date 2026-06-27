#==============================================================================
# wave_switch.tcl  --  waveform "switch -> LED echo" (PROGRAM_F) per il report.
#
# USO (path con spazio -> graffe):
#   1. Set as Top: sim/tb_switch_wave.vhd
#   2. Run Behavioral Simulation
#   3. Tcl Console:
#        source {C:/Users/utente/Desktop/UniProjects/RISC-V Proj/sim/wave_switch.tcl}
#   4. Esporta lo screenshot (Win+Shift+S) come  docs/report/switch_wave.png
#
# Da inquadrare: sw_in che cambia (0x1234 -> 0x00FF -> 0xAA55 -> 0xFFFF) e
# led_out che lo insegue dopo pochi cicli (read periferico + latenza pipeline).
#==============================================================================
set TB  "/tb_switch_wave"
set UUT "$TB/uut"
catch { remove_wave -of [get_wave_config] [get_waves *] }

set g [add_wave_group "clk / reset"]
add_wave -into $g            $TB/clk
add_wave -into $g            $TB/reset

set g [add_wave_group "input"]
add_wave -into $g -radix hex $TB/sw_in

set g [add_wave_group "internal path"]
add_wave -into $g -radix hex $UUT/exmem_alu_result
add_wave -into $g            $UUT/exmem_memwrite
add_wave -into $g -radix hex $UUT/mem_out_mem
add_wave -into $g -radix hex $UUT/wb_data

set g [add_wave_group "output"]
add_wave -into $g -radix hex $TB/led_out

restart
run 1100 ns
catch { wave_zoom_fit }
puts "wave_switch.tcl: sw_in cambia e led_out lo insegue (echo switch->LED)"
