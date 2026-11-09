onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -group Inputs /hit_path_temp_tb/tmu_req/valid
add wave -noupdate -group Inputs /hit_path_temp_tb/tmu_req/ready
add wave -noupdate -group Inputs /hit_path_temp_tb/tmu_req/payload
add wave -noupdate -group Outputs /hit_path_temp_tb/tmu_rsp/valid
add wave -noupdate -group Outputs /hit_path_temp_tb/tmu_rsp/ready
add wave -noupdate -group Outputs /hit_path_temp_tb/tmu_rsp/payload
add wave -noupdate -group Mem /hit_path_temp_tb/mem/req_valid
add wave -noupdate -group Mem /hit_path_temp_tb/mem/req_ready
add wave -noupdate -group Mem /hit_path_temp_tb/mem/req_addr
add wave -noupdate -group Mem /hit_path_temp_tb/mem/req_id
add wave -noupdate -group Mem /hit_path_temp_tb/mem/rsp_valid
add wave -noupdate -group Mem /hit_path_temp_tb/mem/rsp_ready
add wave -noupdate -group Mem /hit_path_temp_tb/mem/rsp_id
add wave -noupdate -group Mem /hit_path_temp_tb/mem/rsp_data
add wave -noupdate -expand -group DUT /hit_path_temp_tb/dut/clk
add wave -noupdate -expand -group DUT /hit_path_temp_tb/dut/n_rst
add wave -noupdate -expand -group DUT -group Errors /hit_path_temp_tb/dut/data_protocol_error
add wave -noupdate -expand -group DUT -group Errors /hit_path_temp_tb/dut/miss_protocol_error
add wave -noupdate -expand -group DUT -group Errors /hit_path_temp_tb/dut/replay_error
add wave -noupdate -expand -group DUT -group Errors /hit_path_temp_tb/dut/protocol_error
add wave -noupdate -expand -group DUT -group {TMU req} /hit_path_temp_tb/dut/req
add wave -noupdate -expand -group DUT -group {TMU req} /hit_path_temp_tb/dut/tmu_quad_info
add wave -noupdate -expand -group DUT -group {TMU req} /hit_path_temp_tb/dut/batch_id
add wave -noupdate -expand -group DUT -group {TMU req} /hit_path_temp_tb/dut/tmu_pixel_info
add wave -noupdate -expand -group DUT -group {TMU req} /hit_path_temp_tb/dut/pixel_taps
add wave -noupdate -expand -group DUT -group {Mip addressing} /hit_path_temp_tb/dut/base_info
add wave -noupdate -expand -group DUT -group {Mip addressing} /hit_path_temp_tb/dut/base_addr
add wave -noupdate -expand -group DUT -group {Mip addressing} /hit_path_temp_tb/dut/exp_lw
add wave -noupdate -expand -group DUT -group {Mip addressing} /hit_path_temp_tb/dut/exp_lh
add wave -noupdate -expand -group DUT -group {pixel selection} /hit_path_temp_tb/dut/pixel_done
add wave -noupdate -expand -group DUT -group {pixel selection} /hit_path_temp_tb/dut/pixel_id
add wave -noupdate -expand -group DUT -group {pixel selection} /hit_path_temp_tb/dut/pixel_tap_sel
add wave -noupdate -expand -group DUT -group {pixel selection} /hit_path_temp_tb/dut/pixel_metadata_sel
add wave -noupdate -expand -group DUT -group {address calculation} /hit_path_temp_tb/dut/coa_addr_out
add wave -noupdate -expand -group DUT -group {tag/fragment dispatch} /hit_path_temp_tb/dut/tag_req
add wave -noupdate -expand -group DUT -group {tag/fragment dispatch} /hit_path_temp_tb/dut/frag_in
add wave -noupdate -expand -group DUT -group {tag/fragment dispatch} /hit_path_temp_tb/dut/req_sent
add wave -noupdate -expand -group DUT -group {tag/fragment dispatch} /hit_path_temp_tb/dut/frag_ready_in
add wave -noupdate -expand -group DUT -group {tag/fragment dispatch} /hit_path_temp_tb/dut/frag_batch_committed
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_pop
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_tail_valid
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_full
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_empty
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_tail
add wave -noupdate -expand -group DUT -group {Fragment FIFO} /hit_path_temp_tb/dut/frag_count
add wave -noupdate -expand -group DUT -group {Miss/refill tracking} /hit_path_temp_tb/dut/line_ready
add wave -noupdate -expand -group DUT -group {Miss/refill tracking} /hit_path_temp_tb/dut/miss_fire
add wave -noupdate -expand -group DUT -group {Miss/refill tracking} /hit_path_temp_tb/dut/fill_fire
add wave -noupdate -expand -group DUT -group {Miss/refill tracking} /hit_path_temp_tb/dut/miss_bank
add wave -noupdate -expand -group DUT -group {Miss/refill tracking} /hit_path_temp_tb/dut/miss_idx
add wave -noupdate -expand -group DUT -group {active fragment} /hit_path_temp_tb/dut/cur_valid
add wave -noupdate -expand -group DUT -group {active fragment} /hit_path_temp_tb/dut/cur_free
add wave -noupdate -expand -group DUT -group {active fragment} /hit_path_temp_tb/dut/pb_alloc_ready
add wave -noupdate -expand -group DUT -group {active fragment} /hit_path_temp_tb/dut/cur
add wave -noupdate -expand -group DUT -group {active fragment} /hit_path_temp_tb/dut/cur_pending
add wave -noupdate -expand -group DUT -group {tap issue/replay} /hit_path_temp_tb/dut/tap_ok
add wave -noupdate -expand -group DUT -group {tap issue/replay} /hit_path_temp_tb/dut/issued
add wave -noupdate -expand -group DUT -group {tap issue/replay} /hit_path_temp_tb/dut/sel_tap
add wave -noupdate -expand -group DUT -group {tap issue/replay} /hit_path_temp_tb/dut/stale_issue
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_valid
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_ready
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_set
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_way
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_byte_offset
add wave -noupdate -expand -group DUT -group {data array read request} /hit_path_temp_tb/dut/rd_cookie
add wave -noupdate -expand -group DUT -group {Data array read response} /hit_path_temp_tb/dut/rd_rsp_cookie
add wave -noupdate -expand -group DUT -group {Data array read response} /hit_path_temp_tb/dut/rd_rsp_data
add wave -noupdate -expand -group DUT -group {Data array read response} /hit_path_temp_tb/dut/rd_rsp_valid
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_valid
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_ready
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_bank
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_set
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_way
add wave -noupdate -expand -group DUT -group {data array refill} /hit_path_temp_tb/dut/data_fill_line
add wave -noupdate -expand -group DUT -group {Miss FIFO/ROB status} /hit_path_temp_tb/dut/miss_req_empty
add wave -noupdate -expand -group DUT -group {Miss FIFO/ROB status} /hit_path_temp_tb/dut/miss_req_full
add wave -noupdate -expand -group DUT -group {Miss FIFO/ROB status} /hit_path_temp_tb/dut/rob_empty
add wave -noupdate -expand -group DUT -group {Miss FIFO/ROB status} /hit_path_temp_tb/dut/rob_full
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {320 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 246
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
WaveRestoreZoom {0 ps} {72841189 ps}
