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

    logic clk = 0; always #5 clk = ~clk;
    logic n_rst = 0;
    logic valid_in = 0, ready_in;
    frag_data_t frag_in = '0;
    logic batch_committed;
    logic pop = 0, tail_valid;
    frag_data_t tail_data;
    logic full, empty;
    logic [COUNT_W-1:0] count;

    frag_fifo dut (.*);

    // FULL_BYPASS = 1 instance, DEPTH = 2, directed test only.
    logic bp_valid_in = 0, bp_ready_in, bp_batch_committed, bp_pop = 0, bp_tail_valid;
    logic bp_full, bp_empty;
    logic [1:0] bp_count;
    frag_data_t bp_frag_in = '0, bp_tail_data;
    frag_fifo #(.DEPTH(2), .FULL_BYPASS(1'b1)) dut_bypass (
        .clk(clk), .n_rst(n_rst), .valid_in(bp_valid_in), .ready_in(bp_ready_in),
        .frag_in(bp_frag_in), .batch_committed(bp_batch_committed), .pop(bp_pop),
        .tail_valid(bp_tail_valid), .tail_data(bp_tail_data), .full(bp_full),
        .empty(bp_empty), .count(bp_count));


    // Reference model: SystemVerilog queue of the entries we expect inside.
    frag_data_t model [$];
    int errors = 0, checks = 0, pushes = 0, pops = 0;
    int seq = 0;

    function automatic frag_data_t make_frag(input int salt);
        frag_data_t f = '0;
        f.batch_id = BATCH_ID_W'(salt >> 2);
        f.pixel_id = 2'(salt);
        f.used = 4'b1111;
        f.hit = 4'(salt);
        f.hit_way = 8'(salt * 5);
        f.pixel_metadata.u_frac = 8'(salt * 3);
        f.pixel_metadata.v_frac = 8'(salt * 7);
        for (int t = 0; t < LANES; t++) begin
            f.offset[t] = OFFSET_W'(salt * 8 + t * 8);
            f.addr[t] = 32'h1000 * salt + 32'(t * 128);
        end
        return f;
    endfunction

    // Check all status outputs against the model (call at a stable point).
    task automatic check_status(input string where);
        checks++;
        if (count !== COUNT_W'(model.size()) ||
            full !== (model.size() == DEPTH) ||
            empty !== (model.size() == 0) ||
            ready_in !== (n_rst && model.size() != DEPTH) ||
            tail_valid !== (n_rst && model.size() != 0)) begin
            errors++;
            $error("[%s] count=%0d full=%0b empty=%0b ready_in=%0b tail_valid=%0b (model size %0d)",
                   where, count, full, empty, ready_in, tail_valid, model.size());
        end
        if (model.size() == 0) begin
            if (tail_data !== '0) begin errors++; $error("[%s] tail_data not zero while empty", where); end
        end else if (tail_data !== model[0]) begin
            errors++;
            $error("[%s] tail_data mismatch: batch %0d pix %0d expected batch %0d pix %0d",
                   where, tail_data.batch_id, tail_data.pixel_id, model[0].batch_id, model[0].pixel_id);
        end
    endtask

    // One clock with the given stimulus; updates the model from the handshake.
    task automatic step(input bit do_push, input bit do_pop, input string where);
        bit push_fire, pop_fire;
        valid_in = do_push;
        pop = do_pop;
        if (do_push) frag_in = make_frag(seq);
        #1;
        push_fire = valid_in && ready_in;
        pop_fire = pop && tail_valid;
        if (batch_committed !== push_fire) begin
            errors++;
            $error("[%s] batch_committed=%0b but push_fire=%0b", where, batch_committed, push_fire);
        end
        if (do_push && !push_fire && !full) begin
            errors++; $error("[%s] push refused while not full", where);
        end
        if (do_pop && !pop_fire && !empty) begin
            errors++; $error("[%s] pop refused while not empty", where);
        end
        @(posedge clk);
        if (pop_fire) begin void'(model.pop_front()); pops++; end
        if (push_fire) begin model.push_back(frag_in); pushes++; seq++; end
        #1;
        valid_in = 0; pop = 0;
        check_status(where);
    endtask

    // Fill the 2-deep bypass FIFO, then push+pop while full every cycle:
    // both must fire, count stays 2, and order is preserved.
    task automatic bypass_test;
        frag_data_t exp [$];
        for (int i = 0; i < 2; i++) begin
            bp_frag_in = make_frag(100 + i); bp_valid_in = 1; #1;
            if (!bp_ready_in) begin errors++; $error("[bypass] refused while not full"); end
            exp.push_back(bp_frag_in);
            @(posedge clk); #1;
        end
        for (int i = 2; i < 10; i++) begin
            checks++;
            bp_frag_in = make_frag(100 + i); bp_valid_in = 1; bp_pop = 0; #1;
            if (!bp_full || bp_ready_in) begin errors++; $error("[bypass] full without pop must refuse"); end
            bp_pop = 1; #1;
            if (!bp_ready_in) begin errors++; $error("[bypass] push+pop on full refused"); end
            if (bp_tail_data !== exp[0]) begin errors++; $error("[bypass] order broken at %0d", i); end
            void'(exp.pop_front()); exp.push_back(bp_frag_in);
            @(posedge clk); #1;
            if (bp_count !== 2'd2) begin errors++; $error("[bypass] count=%0d expected 2", bp_count); end
        end
        bp_valid_in = 0;
        while (exp.size() > 0) begin
            bp_pop = 1; #1;
            if (bp_tail_data !== exp[0]) begin errors++; $error("[bypass] drain order"); end
            void'(exp.pop_front());
            @(posedge clk); #1;
        end
        bp_pop = 0;
        if (!bp_empty) begin errors++; $error("[bypass] not empty after drain"); end
    endtask

    task automatic reset_fifo;
        n_rst = 0; valid_in = 0; pop = 0;
        model.delete();
        repeat (2) @(posedge clk); #1;
        if (ready_in !== 0 || tail_valid !== 0 || batch_committed !== 0 ||
            count !== 0 || !empty || full) begin
            errors++; $error("outputs not quiet during reset");
        end
        n_rst = 1; #1;
        check_status("after reset");
    endtask

    initial begin
        reset_fifo();

        // ---- Should not pop when empty ----
        step(0, 1, "pop on empty");
        // ---- Same cycle push and pop while EMPTY: only the push happens ----
        step(1, 1, "push+pop on empty");
        if (model.size() != 1) begin errors++; $error("expected one entry"); end

        // ---- Fill to full, then should not push when full ----
        while (model.size() < DEPTH) step(1, 0, "fill");
        if (!full) begin errors++; $error("FIFO should be full"); end
        step(1, 0, "push on full");
        // ---- Same cycle push and pop while FULL ----
        // ready_in = !full is registered state, so the push is REFUSED this
        // cycle even though a slot frees up: only the pop happens (count = DEPTH-1).
        step(1, 1, "push+pop on full");
        if (model.size() != DEPTH - 1) begin errors++; $error("push+pop on full: expected pop only"); end

        // ---- Drain in order ----
        while (model.size() > 0) step(0, 1, "drain");
        step(0, 1, "pop after drain");

        // ---- Same cycle push and pop at mid fill ----
        repeat (DEPTH / 2) step(1, 0, "half fill");
        repeat (3 * DEPTH) step(1, 1, "push+pop mid");   // also wraps the pointers
        if (model.size() != DEPTH / 2) begin errors++; $error("mid-fill level drifted"); end

        // ---- Random traffic ----
        for (int c = 0; c < 2000; c++)
            step(($urandom_range(99) < 55), ($urandom_range(99) < 50), "random");
        while (model.size() > 0) step(0, 1, "final drain");

        // ---- FULL_BYPASS = 1: push+pop while full both fire ----
        bypass_test();

        if (errors == 0)
            $display("PASS fragment_fifo_tb: %0d checks, %0d pushes, %0d pops", checks, pushes, pops);
        else
            $fatal(1, "FAIL fragment_fifo_tb: %0d errors", errors);
        $finish;
    end
    initial begin #2000000; $fatal(1, "fragment_fifo_tb timeout"); end
endmodule
