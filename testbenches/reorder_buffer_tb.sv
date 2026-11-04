/*
  Notes on the reorder buffer

  - holds outstanding misses and releases them in order
  - 
*/

`include "reorder_buffer.sv"

`timescale 1 ns / 1 ps

module reorder_buffer_tb;

  import cache_pkg::*;

  parameter PERIOD = 10ns;
  logic CLK = 0, n_rst;
  always #(PERIOD/2) CLK++;

  logic clk, n_rst, // asynchronous active-low reset
  logic [EPOCH_W-1:0] epoch_i, // increment on reset, chance data fills into wrong slot after reset TODO: don't do anything for now
  logic valid_in, // miss FIFO presents a line request
  logic [ADDR_W-1:0] miss_tail_addr, // address data is being requested from (tail of miss request fifo)
  logic miss_pop, // goes high when tail is being popped off of ROB (tail is oldest request)
  logic mem_req_valid, // TODO: don't worry about it for now
  logic ready, // memory request-ready
  logic [ADDR_W-1:0] mem_req_addr,
  logic [ID_WIDTH-1:0] mem_req_id,
  logic return_valid,
  logic return_ready,
  logic [ID_WIDTH-1:0] transaction_id,
  logic [LINE_BITS-1:0] t_load_in,
  logic tail_valid, // oldest entry is completed
  logic tex_rdy, // controller commits/accepts refill
  logic rob_entry tail_entry, // TODO: add width
  logic full, empty,
  logic [COUNT_W-1:0] count,
  logic bad_return, // one-cycle invalid/duplicate/stale return pulse
  logic id_exhausted, protocol_error // sticky until reset
  
  reorder_buffer DUT(.clk(CLK), .n_rst(n_rst), .*);

  task reset();
  begin
    n_rst = 0;
    @(posedge CLK);
    @(posedge CLK);
    @(posedge CLK);
    n_rst = 1;
    @(posedge CLK);
    @(posedge CLK);
  end
  endtask

  task test

  initial begin
    reset();    

    $finish;
  end

endmodule