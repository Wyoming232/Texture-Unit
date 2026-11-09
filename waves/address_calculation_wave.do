onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -divider {TOP LEVEL IO}
add wave -noupdate -expand -group Inputs -label base_addr /address_calculation_tb/base_addr
add wave -noupdate -expand -group Inputs -label pixel_tap_sel -expand /address_calculation_tb/pixel_tap_sel
add wave -noupdate -expand -group Inputs -label pixel_metadata_sel /address_calculation_tb/pixel_metadata_sel
add wave -noupdate -expand -group Inputs -label batch_id /address_calculation_tb/batch_id
add wave -noupdate -expand -group Inputs -label pixel_id /address_calculation_tb/pixel_id
add wave -noupdate -group Outputs -label coa_addr_out /address_calculation_tb/coa_addr_out
add wave -noupdate -divider {DUT signals}
add wave -noupdate -expand -group addrs -label addr0 -expand /address_calculation_tb/dut/coalescer/addr0
add wave -noupdate -expand -group addrs -label addr1 /address_calculation_tb/dut/coalescer/addr1
add wave -noupdate -expand -group addrs -label addr2 /address_calculation_tb/dut/coalescer/addr2
add wave -noupdate -expand -group addrs -label addr3 /address_calculation_tb/dut/coalescer/addr3
add wave -noupdate -label used /address_calculation_tb/dut/coalescer/used
add wave -noupdate -group {coalescing signals} -label coa_0_1 /address_calculation_tb/dut/coalescer/coa_0_1
add wave -noupdate -group {coalescing signals} -label coa_0_2 /address_calculation_tb/dut/coalescer/coa_0_2
add wave -noupdate -group {coalescing signals} -label coa_0_3 /address_calculation_tb/dut/coalescer/coa_0_3
add wave -noupdate -group {coalescing signals} -label coa_1_2 /address_calculation_tb/dut/coalescer/coa_1_2
add wave -noupdate -group {coalescing signals} -label coa_1_3 /address_calculation_tb/dut/coalescer/coa_1_3
add wave -noupdate -group {coalescing signals} -label coa_2_3 /address_calculation_tb/dut/coalescer/coa_2_3
add wave -noupdate -group {coalesced addrs} -label coa_addrs0 /address_calculation_tb/dut/coalescer/coa_addrs0
add wave -noupdate -group {coalesced addrs} -label coa_addrs1 /address_calculation_tb/dut/coalescer/coa_addrs1
add wave -noupdate -group {coalesced addrs} -label coa_addrs2 /address_calculation_tb/dut/coalescer/coa_addrs2
add wave -noupdate -group {coalesced addrs} -label coa_addrs3 /address_calculation_tb/dut/coalescer/coa_addrs3
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {6530 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {0 ps} {21 ns}
