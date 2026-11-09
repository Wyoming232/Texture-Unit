/*
 Frontend
 - Fragment entry preparation buffer
    - Waits for all taps before entering
    - test 1, 2, 3, and 4 cycle entries
    - ready should be asserted when about to pass to FIFO
 - Tag array and FIFO interaction
    - Should not push when full
    - Should only push when hit or pseudo-hit(miss entry accepted in miss request FIFO)
 Backend
 - Payload preparation buffer
    - Wait for all entries in a batch to be ready before sending to TMU
    - Stall everything until ready
 - FIFO and data array interaction
    - Should not pop when empty
    - Should not pop until data is filled from ROB
 - Test same cycle push and pop

 NOTE: the preparation buffers, tag-array gating and ROB gating above live in
 the (not yet written) hit-path coordinator. Only the FIFO-level behaviour is
 testable against src/frag_fifo.sv today; the rest is deferred to the wrapper TB.
 Implemented here: reset state, no push when full, no pop when empty,
 same cycle push and pop (empty / mid / full), ordering and payload integrity.

 Additional testcases (added, to be reviewed; NOT implemented below)
 - batch_committed is a one-cycle pulse per accepted PIXEL, never asserted when
   valid_in is high but ready_in is low (full)
 - tail_data is forced to zero while empty, and shows the oldest entry (not the
   newest) the cycle after the first push
 - pointer wrap: push/pop more than DEPTH entries total and verify order is
   still FIFO after wr_ptr/rd_ptr wrap around
 - count never exceeds DEPTH and never underflows during random push/pop traffic
 - asynchronous reset mid-traffic: full/empty/count return to reset values
   and ready_in is low while n_rst is low
 - payload RAM is intentionally not reset: after reset, tail_valid must be low
   so stale entries are never exposed
 - all four pixels of one batch share batch_id; verify entries are not
   reordered across the batch boundary (needed by the backend prep buffer)
 - DEPTH = 1 parameter override (PTR_W edge case in advance())
*/


`timescale 1ns/1ps
`include "src/frag_fifo.sv"

module fragment_fifo_tb;
    import cache_pkg::*;
    localparam int DEPTH = FRAG_DEPTH;
    localparam int COUNT_W = $clog2(DEPTH + 1);

    logic clk;
    logic n_rst;
    logic valid_in, ready_in, batch_committed;
    frag_data_t frag_in;
    logic pop, tail_valid, full, empty;
    frag_data_t tail_data;
    logic [COUNT_W-1:0] count;

    always #5 clk = ~clk;

    frag_fifo #(.DEPTH(DEPTH)) dut (
        .clk(clk), .n_rst(n_rst), .valid_in(valid_in), .ready_in(ready_in),
        .frag_in(frag_in), .batch_committed(batch_committed), .pop(pop),
        .tail_valid(tail_valid), .tail_data(tail_data),
        .full(full), .empty(empty), .count(count)
    );

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        valid_in = 1'b0;
        frag_in = '0;
        pop = 1'b0;
        @(negedge clk);
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase: enqueue one pixel, hold it, then dequeue it.
        @(negedge clk);
        frag_in.batch_id = 8'd1;
        frag_in.pixel_id = 2'd0;
        frag_in.used = 4'b0001;
        frag_in.hit = 4'b0001;
        frag_in.data_ready = 4'b0001;
        frag_in.addr[0] = 32'h0000_1000;
        frag_in.hit_way[0] = 2'd2;
        valid_in = 1'b1;
        // Before next rising edge: ready_in=1, batch_committed=1.
        @(negedge clk);
        valid_in = 1'b0;
        // Now count=1, tail_valid=1, empty=0; tail_data equals frag_in.
        @(negedge clk);
        // The same entry is still at the tail; take ownership on next edge.
        pop = 1'b1;
        @(negedge clk);
        pop = 1'b0;
        // Now count=0, empty=1, tail_valid=0, tail_data=0.
        #10;

        // Add the next manual testcase here.
        $finish;
    end
endmodule
