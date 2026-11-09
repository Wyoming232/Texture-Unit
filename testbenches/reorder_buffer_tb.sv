/*
  Notes on the reorder buffer

  - holds outstanding misses and releases them in order
  - transaction id = slot index handed out at allocation (rob_next_free_entry)
  - memory may return in any order; only a completed TAIL can be popped
  - a return landing on the tail is forwarded the same cycle

  Decisions recorded from the old sketch of this TB:
  - epoch_i: not implemented. Returns to an unallocated or already-completed
    slot are dropped and flagged (bad_return pulse, sticky protocol_error).
    A pre-reset return reaching a slot re-allocated after reset cannot be
    detected; the memory subsystem is assumed to reset with the cache.
  - mem_req_valid: lives in miss_path (miss FIFO tail valid && !rob_full);
    the ROB only sees the accepted request as miss_push.
  - tail entry type is cache_pkg::rob_entry_t.

  Testcases
  - reset: empty, not full, count 0, no protocol_error
  - allocation hands out ids 0,1,2,... and carries line_addr + way
  - out-of-order returns: tail is not poppable until ITS line returns,
    younger completed entries are held
  - return on the tail + rob_pop in the same cycle: pops with forwarded data
  - full: miss_push refused, rob_full high, count = DEPTH
  - bad return to an unallocated slot and a duplicate return: dropped,
    bad_return pulses, protocol_error sticks, no state change
  - random push / return / pop traffic against a model (pointer wrap)
*/

`timescale 1ns/1ps
`include "src/reorder_buffer.sv"

module reorder_buffer_tb;
    import cache_pkg::*;
    localparam int DEPTH = ROB_DEPTH;
    localparam int PW = $clog2(DEPTH);

    logic clk, n_rst;
    logic miss_push;
    logic [ADDR_W-1:0] miss_tail_addr;
    logic [WAY_W-1:0] miss_tail_way;
    logic [PW-1:0] rob_next_free_entry;
    logic mem_return_valid;
    logic [PW-1:0] transaction_id;
    logic [LINE_BITS-1:0] tex_load_in;
    logic rob_return_ready, rob_pop;
    rob_entry_t rob_tail_entry;
    logic rob_empty, rob_full;
    logic [PW:0] rob_count;
    logic bad_return, protocol_error;
    logic [PW-1:0] issued_id;

    always #5 clk = ~clk;

    reorder_buffer #(.DEPTH(DEPTH)) dut (
        .clk(clk), .n_rst(n_rst), .miss_push(miss_push),
        .miss_tail_addr(miss_tail_addr), .miss_tail_way(miss_tail_way),
        .rob_next_free_entry(rob_next_free_entry),
        .mem_return_valid(mem_return_valid), .transaction_id(transaction_id),
        .tex_load_in(tex_load_in), .rob_return_ready(rob_return_ready),
        .rob_pop(rob_pop), .rob_tail_entry(rob_tail_entry),
        .rob_empty(rob_empty), .rob_full(rob_full), .rob_count(rob_count),
        .bad_return(bad_return), .protocol_error(protocol_error)
    );

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        miss_push = 1'b0;
        miss_tail_addr = '0;
        miss_tail_way = '0;
        mem_return_valid = 1'b0;
        transaction_id = '0;
        tex_load_in = '0;
        rob_pop = 1'b0;
        issued_id = '0;
        @(negedge clk);
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase: allocate one miss and remember its memory transaction ID.
        @(negedge clk);
        issued_id = rob_next_free_entry;
        miss_tail_addr = 32'h0000_1000;
        miss_tail_way = 2'd2;
        miss_push = 1'b1;
        @(negedge clk);
        miss_push = 1'b0;
        // rob_count=1; tail valid=1, completed=0, line_addr=0x1000, way=2.

        // Manually return its line from memory.
        @(negedge clk);
        transaction_id = issued_id;
        tex_load_in[63:0] = 64'hCAFE_BABE_1234_5678;
        mem_return_valid = 1'b1;
        @(negedge clk);
        mem_return_valid = 1'b0;
        // Tail completed=1, data[63:0]=0xCAFEBABE12345678; no error flags.
        @(negedge clk);
        rob_pop = 1'b1;
        @(negedge clk);
        rob_pop = 1'b0;
        // rob_count=0, rob_empty=1, rob_tail_entry=0.
        #10;

        // Add the next manual testcase here.
        $finish;
    end
endmodule
