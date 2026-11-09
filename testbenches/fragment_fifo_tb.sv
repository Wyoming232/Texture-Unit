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
    localparam int DEPTH = 4; // Small capacity for explicit manual full/wrap tests.
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

    frag_data_t expected0, expected1, expected2, expected3;

    // A missing handshake must fail instead of hanging the simulation.
    initial begin
        #20000;
        $fatal(1, "fragment_fifo_tb.sv: simulation timeout");
    end

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        valid_in = 1'b0;
        frag_in = '0;
        pop = 1'b0;
        expected0 = '0;
        expected1 = '0;
        expected2 = '0;
        expected3 = '0;
        @(negedge clk);
        assert (count === 0 && empty === 1'b1 && full === 1'b0 &&
                ready_in === 1'b0 && tail_valid === 1'b0 && tail_data === '0)
            else $fatal(1, "Reset: FIFO status");
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase 1: one pixel's entire payload survives a consumer stall.
        @(negedge clk);
        frag_in.batch_id = 8'd1; // Shared by pixels 0..3 of this quad.
        frag_in.pixel_id = 2'd0;
        frag_in.used = 4'b1111;
        frag_in.hit = 4'b0101;
        frag_in.data_ready = 4'b0001;
        frag_in.addr_error = 4'b1000;
        frag_in.addr = {32'h1180,32'h1108,32'h1080,32'h1000};
        frag_in.bank = {2'd3,2'd2,2'd1,2'd0};
        frag_in.idx = {3'd7,3'd6,3'd5,3'd4};
        frag_in.hit_way = {2'd0,2'd1,2'd2,2'd3};
        frag_in.offset = {7'd120,7'd16,7'd8,7'd0};
        frag_in.pixel_metadata.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        frag_in.pixel_metadata.tmu_quad_metadata.rd = 5'd7;
        frag_in.pixel_metadata.u_frac = 8'd64;
        frag_in.pixel_metadata.v_frac = 8'd128;
        expected0 = frag_in;
        valid_in = 1'b1;
        #1;
        assert (ready_in === 1'b1 && batch_committed === 1'b1)
            else $fatal(1, "TC1: accepted pixel must commit");
        @(negedge clk);
        valid_in = 1'b0;
        #1;
        assert (count === 1 && tail_valid === 1'b1 && tail_data === expected0 && batch_committed === 1'b0)
            else $fatal(1, "TC1: stored fragment");
        @(negedge clk);
        assert (count === 1 && tail_data === expected0)
            else $fatal(1, "TC1: stalled fragment changed");
        pop = 1'b1;
        @(negedge clk);
        pop = 1'b0;
        #1;
        assert (count === 0 && empty === 1'b1 && tail_valid === 1'b0 && tail_data === '0)
            else $fatal(1, "TC1: dequeue");

        // Testcase 2: empty pop does nothing; empty push+pop retains the push.
        pop = 1'b1;
        @(negedge clk);
        assert (count === 0 && tail_data === '0)
            else $fatal(1, "TC2: empty pop underflow");
        frag_in = expected0;
        valid_in = 1'b1;
        @(negedge clk);
        assert (count === 1 && tail_data === expected0)
            else $fatal(1, "TC2: no empty bypass");

        // Testcase 3: simultaneous push+pop replaces the only queued entry.
        frag_in.pixel_id = 2'd1;
        frag_in.pixel_metadata.u_frac = 8'd65;
        frag_in.addr[0] = 32'h2000;
        expected1 = frag_in;
        @(negedge clk);
        assert (count === 1 && tail_data === expected1)
            else $fatal(1, "TC3: simultaneous transfers/order");
        pop = 1'b0;

        // Testcase 4: fill four entries, reject overflow, wrap, then drain.
        // DEPTH=4 keeps this capacity testcase entirely hand-written.
        frag_in.pixel_id = 2'd2;
        frag_in.addr[0] = 32'h3000;
        expected2 = frag_in;
        @(negedge clk);
        assert (count === 2 && tail_data === expected1)
            else $fatal(1, "TC4: second entry");
        frag_in.pixel_id = 2'd3;
        frag_in.addr[0] = 32'h4000;
        expected3 = frag_in;
        @(negedge clk);
        frag_in = expected0;
        @(negedge clk);
        assert (count === DEPTH && full === 1'b1 && ready_in === 1'b0 &&
                batch_committed === 1'b0 && tail_data === expected1)
            else $fatal(1, "TC4: full status");
        frag_in = '1; // Must never overwrite a retained entry while full.
        @(negedge clk);
        assert (count === DEPTH && tail_data === expected1 && batch_committed === 1'b0)
            else $fatal(1, "TC4: overflow rejected");
        pop = 1'b1; // Default FULL_BYPASS=0: only the pop is accepted.
        #1;
        assert (ready_in === 1'b0 && batch_committed === 1'b0)
            else $fatal(1, "TC4: full simultaneous transfer must reject push");
        @(negedge clk);
        valid_in = 1'b0;
        assert (count === 3 && tail_data === expected2)
            else $fatal(1, "TC4: full pop");
        @(negedge clk);
        assert (count === 2 && tail_data === expected3)
            else $fatal(1, "TC4: wrapped order, pixel 3");
        @(negedge clk);
        assert (count === 1 && tail_data === expected0)
            else $fatal(1, "TC4: wrapped order, final payload");
        @(negedge clk);
        pop = 1'b0;
        #1;
        assert (count === 0 && empty === 1'b1 && tail_valid === 1'b0 && tail_data === '0)
            else $fatal(1, "TC4: drained FIFO");

        $display("PASS: fragment_fifo_tb");
        $finish;
    end
endmodule
