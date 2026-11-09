onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -divider {TOP LEVEL IO}
add wave -noupdate -divider Inputs
add wave -noupdate /data_array_tb/clk
add wave -noupdate /data_array_tb/n_rst
add wave -noupdate -group {Read request} /data_array_tb/rd_valid
add wave -noupdate -group {Read request} /data_array_tb/rd_set
add wave -noupdate -group {Read request} /data_array_tb/rd_way
add wave -noupdate -group {Read request} /data_array_tb/rd_byte_offset
add wave -noupdate -group {Refill request} /data_array_tb/fill_valid
add wave -noupdate -group {Refill request} /data_array_tb/fill_bank
add wave -noupdate -group {Refill request} /data_array_tb/fill_set
add wave -noupdate -group {Refill request} /data_array_tb/fill_way
add wave -noupdate -group {Refill request} /data_array_tb/fill_line
add wave -noupdate -divider Outputs
add wave -noupdate -group read_handshake /data_array_tb/rd_ready
add wave -noupdate -group {read response} /data_array_tb/rd_cookie
add wave -noupdate -group {read response} /data_array_tb/rd_rsp_cookie
add wave -noupdate -group {read response} /data_array_tb/rd_rsp_valid
add wave -noupdate -group {read response} /data_array_tb/rd_rsp_data
add wave -noupdate -group {Refill handshake} /data_array_tb/fill_ready
add wave -noupdate -group Status /data_array_tb/protocol_error
add wave -noupdate -divider {Testbench Check}
add wave -noupdate /data_array_tb/expected_error
add wave -noupdate /data_array_tb/coord_ok
add wave -noupdate /data_array_tb/expected_ready
add wave -noupdate /data_array_tb/expected_fill_ready
add wave -noupdate /data_array_tb/reads
add wave -noupdate /data_array_tb/fills
add wave -noupdate /data_array_tb/cycles
add wave -noupdate /data_array_tb/rng
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {460 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {0 ps} {22680 ns}
