/*
   Miss Request FIFO
   Tag array miss
   - Miss req accepts line addr and miss_way only when !full
   - DECIDED: entries stay {line_addr, miss_way}. Tail-end coalescing is not
   needed because the tag array already coalesces misses: a second request
   to a pending line HITS the reserved tag (hit=1, ready=0) and never issues
   another miss, so one line never occupies two ROB entries. The RTL flags a
   queued duplicate with a sim-only $error (check_no_duplicate_miss).
   - Asserts accepted to fragment entry preparation buffer (miss_accepted & hit & hit_way
   are control signals for fragment commit)
   Memory request
   - Memory handshakes with FIFO, whenever available,
    with MR FIFO which pops off FIFO tail
   - Backend: src/miss_path.sv implements it (memory request = tail valid &&
   !rob_full, miss_pop = mem ready && !rob_full, ROB, in-order refill of the
   tag + data arrays). Integration is checked in testbenches/hit_path_temp.sv;
   the ROB alone in testbenches/reorder_buffer_tb.sv.

   - Test simultaneous miss & memory handshake, ie push & pop simultaneously
   - Test memory free to accept when FIFO empty
   - Test simulataneous tag miss and memory available when MR FIFO empty
   - DECIDED: no empty-FIFO bypass to memory and no tail-end coalescing.
   Coalescing is redundant (see above). A bypass would only save one cycle
   on a memory round trip; it is not worth the extra mux and comb path.
   FULL_BYPASS (push+pop while full) exists as a parameter, default off,
   and is tested below with a DEPTH = 2 instance.

   NOTE: there is no empty bypass today, so "tag miss and memory available while
   empty" must result in a push only; the request becomes visible at the tail
   one cycle later. This TB checks that. It also checks the current
   (ROB-less) pop qualification: miss_pop && miss_tail_valid.

   Additional testcases (added, to be reviewed; NOT implemented below)
   - miss_ready deasserts the same cycle count reaches DEPTH, and reasserts the
     cycle after a pop (no extra bubble)
   - simultaneous push & pop while FULL: push is refused (miss_ready = 0), only
     the pop happens -> count = DEPTH-1 (same ready semantics as frag_fifo)
   - miss_tail_addr / miss_tail_way are zero while empty (no stale entry leak)
   - miss_way is carried with its address through a full wrap of the pointers
   - duplicate line address pushed twice is stored twice AND the sim-only
     check_no_duplicate_miss $error fires (expected-error run)
   - misaligned miss_addr (low OFFSET_W bits non-zero) with miss_valid high:
     the sim-only $fatal fires. Needs its own run / expected-failure wrapper.
   - async reset while entries are queued: empty, count = 0, miss_tail_valid
     low, miss_ready back high
   - DEPTH = 1 override: PTR_W edge case in advance(), full after one push
*/

`timescale 1ns/1ps
`include "src/miss_request_fifo.sv"

module miss_request_fifo_tb;
    import cache_pkg::*;
    localparam int DEPTH = MISS_REQ_DEPTH;
    localparam int COUNT_W = $clog2(DEPTH + 1);

    logic clk = 0; always #5 clk = ~clk;
    logic n_rst = 0;
    logic miss_valid = 0, miss_ready;
    logic [ADDR_W-1:0] miss_addr = '0;
    logic [WAY_W-1:0] miss_way = '0;
    logic miss_pop = 0, miss_tail_valid;
    logic [ADDR_W-1:0] miss_tail_addr;
    logic [WAY_W-1:0] miss_tail_way;
    logic full, empty;
    logic [COUNT_W-1:0] count;

    miss_request_fifo dut (.*);

    // FULL_BYPASS = 1 instance, DEPTH = 2, directed test only.
    logic bp_valid = 0, bp_ready, bp_pop = 0, bp_tail_valid, bp_full, bp_empty;
    logic [ADDR_W-1:0] bp_addr = '0, bp_tail_addr;
    logic [WAY_W-1:0] bp_way = '0, bp_tail_way;
    logic [1:0] bp_count;
    miss_request_fifo #(.DEPTH(2), .FULL_BYPASS(1'b1)) dut_bypass (
        .clk(clk), .n_rst(n_rst), .miss_valid(bp_valid), .miss_ready(bp_ready),
        .miss_addr(bp_addr), .miss_way(bp_way), .miss_pop(bp_pop),
        .miss_tail_valid(bp_tail_valid), .miss_tail_addr(bp_tail_addr),
        .miss_tail_way(bp_tail_way), .full(bp_full), .empty(bp_empty), .count(bp_count));

    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic [WAY_W-1:0] way;
    } model_entry_t;
    model_entry_t model [$];
    int errors = 0, checks = 0, pushes = 0, pops = 0, seq = 0;

    // Line-aligned addresses that walk tag/index/bank; way cycles 0..3.
    function automatic model_entry_t make_req(input int salt);
        model_entry_t e;
        e.addr = {20'(salt * 7 + 1), 3'(salt), 2'(salt >> 1), {OFFSET_W{1'b0}}};
        e.way = WAY_W'(salt);
        return e;
    endfunction

    task automatic check_status(input string where);
        checks++;
        if (count !== COUNT_W'(model.size()) ||
            full !== (model.size() == DEPTH) ||
            empty !== (model.size() == 0) ||
            miss_ready !== (n_rst && model.size() != DEPTH) ||
            miss_tail_valid !== (n_rst && model.size() != 0)) begin
            errors++;
            $error("[%s] count=%0d full=%0b empty=%0b miss_ready=%0b tail_valid=%0b (model %0d)",
                   where, count, full, empty, miss_ready, miss_tail_valid, model.size());
        end
        if (model.size() == 0) begin
            if (miss_tail_addr !== '0 || miss_tail_way !== '0) begin
                errors++; $error("[%s] tail not zero while empty", where);
            end
        end else if (miss_tail_addr !== model[0].addr || miss_tail_way !== model[0].way) begin
            errors++;
            $error("[%s] tail %h/%0d expected %h/%0d", where,
                   miss_tail_addr, miss_tail_way, model[0].addr, model[0].way);
        end
    endtask

    task automatic step(input bit do_push, input bit do_pop, input string where);
        bit push_fire, pop_fire;
        model_entry_t e;
        miss_valid = do_push;
        miss_pop = do_pop;
        if (do_push) begin e = make_req(seq); miss_addr = e.addr; miss_way = e.way; end
        #1;
        push_fire = miss_valid && miss_ready;
        pop_fire = miss_pop && miss_tail_valid;
        if (do_push && !push_fire && !full) begin errors++; $error("[%s] push refused while not full", where); end
        if (do_push && push_fire && full) begin errors++; $error("[%s] push accepted while full", where); end
        if (do_pop && !pop_fire && !empty) begin errors++; $error("[%s] pop refused while not empty", where); end
        @(posedge clk);
        if (pop_fire) begin void'(model.pop_front()); pops++; end
        if (push_fire) begin model.push_back(e); pushes++; seq++; end
        #1;
        miss_valid = 0; miss_pop = 0;
        check_status(where);
    endtask

    task automatic reset_fifo;
        n_rst = 0; miss_valid = 0; miss_pop = 0;
        model.delete();
        repeat (2) @(posedge clk); #1;
        if (miss_ready !== 0 || miss_tail_valid !== 0 || count !== 0 || !empty || full) begin
            errors++; $error("outputs not quiet during reset");
        end
        n_rst = 1; #1;
        check_status("after reset");
    endtask

    task automatic bypass_test;
        model_entry_t exp [$], e;
        for (int i = 0; i < 10; i++) begin
            checks++;
            e = make_req(5000 + i);
            bp_valid = 1; bp_addr = e.addr; bp_way = e.way;
            bp_pop = (exp.size() == 2); #1;
            if (!bp_ready) begin errors++; $error("[bypass] push refused (size %0d)", exp.size()); end
            if (bp_pop) begin
                if (bp_tail_addr !== exp[0].addr || bp_tail_way !== exp[0].way) begin
                    errors++; $error("[bypass] order broken at %0d", i);
                end
                void'(exp.pop_front());
            end
            exp.push_back(e);
            @(posedge clk); #1;
        end
        bp_valid = 0; bp_pop = 1;
        while (exp.size() > 0) begin
            #1;
            if (bp_tail_addr !== exp[0].addr) begin errors++; $error("[bypass] drain order"); end
            void'(exp.pop_front());
            @(posedge clk); #1;
        end
        bp_pop = 0;
        if (!bp_empty) begin errors++; $error("[bypass] not empty after drain"); end
    endtask

    initial begin
        reset_fifo();

        // ---- Memory free to accept when FIFO empty: pop must not fire ----
        step(0, 1, "mem ready, FIFO empty");

        // ---- Simultaneous tag miss and memory available while EMPTY ----
        // No bypass: push happens, pop does not; the entry is at the tail next cycle.
        step(1, 1, "miss + mem ready on empty");
        if (model.size() != 1) begin errors++; $error("expected exactly one entry after push on empty"); end
        step(0, 1, "drain the one entry");

        // ---- Accepts only when !full ----
        while (model.size() < DEPTH) step(1, 0, "fill");
        step(1, 0, "push on full");
        step(1, 1, "push+pop on full");          // pop only (see notes)
        if (model.size() != DEPTH - 1) begin errors++; $error("push+pop on full: expected pop only"); end
        while (model.size() > 0) step(0, 1, "drain in order");

        // ---- Simultaneous miss & memory handshake at mid fill (wraps pointers) ----
        repeat (DEPTH / 2) step(1, 0, "half fill");
        repeat (3 * DEPTH) step(1, 1, "push+pop mid");
        if (model.size() != DEPTH / 2) begin errors++; $error("mid-fill level drifted"); end

        // ---- Random traffic ----
        for (int c = 0; c < 2000; c++)
            step(($urandom_range(99) < 55), ($urandom_range(99) < 50), "random");
        while (model.size() > 0) step(0, 1, "final drain");

        // ---- FULL_BYPASS = 1: push+pop while full both fire ----
        bypass_test();

        if (errors == 0)
            $display("PASS miss_request_fifo_tb: %0d checks, %0d pushes, %0d pops", checks, pushes, pops);
        else
            $fatal(1, "FAIL miss_request_fifo_tb: %0d errors", errors);
        $finish;
    end
    initial begin #2000000; $fatal(1, "miss_request_fifo_tb timeout"); end
endmodule
