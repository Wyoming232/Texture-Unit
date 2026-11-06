/*
    Tag bank test
    - Miss to line 1
    - Hit line 1
    - 3x miss to lines 2, 3, 4 all mapping to the same index as 1
    - Miss to line 5, also mapping to line 1 leading in an eviction
    - Miss to line 1
    Tag array test
    Pixel reqest (4 taps)
    - All 4 taps hit diff banks
    - All 4 taps hit same bank
    - 3 taps hit one bank
    - 2 taps hit one bank and 1 tap per two other banks
    - 2 taps hit one bank and 2 taps hit another two banks

    NOTE on the bank test: a line that was allocated but never filled has
    ready = 0, and tag_bank refuses to evict a pending line (replace_way =
    ~valid | ready). So "miss to line 5" STALLS (bank busy, rsp_valid low)
    until at least one of lines 1..4 is filled through the refill port. The
    TB observes that stall, fills ways 0..3, and expects line 5 to take way 0.
    Expected ways below come from tracing the tree-PLRU in tag_bank:
      commits w0(L1) w0(L1 hit) w1 w2 w3 -> lru = {b2=0,b1=0,b0=1}
      L5: first fill makes way 0 the only eligible way -> way 0 (evicts L1)
      L1 again: way 0 pending, ways 1..3 ready, lru = {0,1,0} -> right subtree,
                lru[2]=0 -> way 2 (evicts L3)

    NOTE on the array test: same-bank groups are serialized starting from
    route_ptr, which is cleared when each pixel is accepted, so same-bank
    groups are looked up in ascending group order. The TB checks "all
    distinct ways + matching miss stream" and, for the 4-in-one-bank pixel
    on a fresh set, the exact ways 0,1,2,3 in group order.

    PLRU order tests (fresh, fully filled sets, then hits, then one miss):
    - hits w0,w1,w2,w3 -> miss evicts w0
    - hits w3,w2,w1,w0 -> miss evicts w3 (depends on lru[2] set by the w2 commit)
    - hits w3,w0,w2    -> miss evicts w1 (depends on lru[0] set by the w2
      commit; without it the root would point right and pick w3)

    Additional testcases (added, to be reviewed; NOT implemented below)
    Tag bank
    - hit on a pending line returns hit=1, ready=0; after fill the same lookup
      returns hit=1, ready=1 (no new miss either time)
    - fill_ready is 0 for an invalid way and for an already-ready way; fill_en
      on such a slot must be ignored (no state change)
    - PLRU: four hits in order w0,w1,w2,w3 then a miss must evict w0; hits in
      order w3,w2,w1,w0 then a miss must evict w3
    - eviction never selects a valid-but-not-ready way, even when it is the
      PLRU victim (the other subtree must be chosen)
    - allocation prefers an invalid way over PLRU when both exist
    Tag array
    - miss_ready held low: rsp_valid must stay low, miss_valid/miss_addr/
      miss_way must hold stable (miss_lock), hits in OTHER banks may still
      complete through bank_result_valid
    - bank_result_ready[b] low for one bank only: that bank's result is held,
      other banks drain; rsp_valid waits for the stalled bank
    - two groups of one pixel map to the same bank AND same set with different
      tags while the set has one free way: second group must wait for the
      first allocation to commit, then allocate a different way (no double
      allocation of the same way)
    - two groups of one pixel with the SAME line (should never happen after
      coalescing) - document whether the second lookup hits the first's fresh
      allocation or double-allocates
    - rsp_ready held low after rsp_valid: rsp and rsp_valid hold, req_ready
      stays low (no new pixel accepted)
    - request with a valid group whose tap_mask is zero triggers the sim-only
      $fatal (expected failure run)
    - back-to-back pixels: req_valid held high across the rsp handshake, check
      no cycle is lost and route_ptr/miss_ptr rotation does not skip a group
    - inactive groups (valid=0) never produce a bank_result_valid or a miss
*/

`timescale 1ns/1ps
`include "interfaces/interfaces.vh"
`include "src/tag_array.sv"

module tag_array_tb;
    import cache_pkg::*;

    logic clk = 0; always #5 clk = ~clk;
    logic n_rst = 0;
    tag_array_if tag_if();
    tag_array dut (.clk(clk), .n_rst(n_rst), .tag_if(tag_if));

    int errors = 0, checks = 0;
    localparam int RSP_TIMEOUT = 100;

    // --------------------------- helpers ---------------------------
    function automatic logic [ADDR_W-1:0] line(input int tag, idx, bank);
        return {TAG_W'(tag), INDEX_W'(idx), BANK_W'(bank), {OFFSET_W{1'b0}}};
    endfunction

    function automatic tag_lookup_t group(input logic [LANES-1:0] mask,
                                          input logic [ADDR_W-1:0] addr);
        tag_lookup_t g = '0;
        g.valid = |mask;
        g.tap_mask = mask;
        g.bank = addr[OFFSET_W +: BANK_W];
        g.index = addr[OFFSET_W+BANK_W +: INDEX_W];
        g.tag = addr[ADDR_W-1 -: TAG_W];
        return g;
    endfunction

    // --------------------------- monitors ---------------------------
    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic [WAY_W-1:0] way;
    } miss_t;
    miss_t miss_log [$];
    typedef struct packed {
        logic [BANK_W-1:0] bank;
        logic [LANES-1:0] mask;
        tag_out_t result;
    } bank_rsp_t;
    bank_rsp_t bank_log [$];

    miss_t miss_seen;
    bank_rsp_t bank_seen;
    always @(posedge clk) if (n_rst) begin
        if (tag_if.miss_valid && tag_if.miss_ready) begin
            miss_seen.addr = tag_if.miss_addr; miss_seen.way = tag_if.miss_way;
            miss_log.push_back(miss_seen);
        end
        for (int b = 0; b < BANKS; b++)
            if (tag_if.bank_result_valid[b] && tag_if.bank_result_ready[b]) begin
                bank_seen.bank = BANK_W'(b); bank_seen.mask = tag_if.bank_tap_mask[b];
                bank_seen.result = tag_if.bank_result[b];
                bank_log.push_back(bank_seen);
            end
        // Miss descriptors must be line aligned.
        if (tag_if.miss_valid && tag_if.miss_addr[OFFSET_W-1:0] != '0) begin
            errors++; $error("misaligned miss_addr %h", tag_if.miss_addr);
        end
    end

    // --------------------------- drivers ---------------------------
    // Present one pixel (up to four groups), wait for the full response.
    task automatic request(input string name, input tag_lookup_t [LANES-1:0] req,
                           output tag_out_t [LANES-1:0] rsp, output int cycles);
        tag_if.req = req;
        tag_if.req_valid = 1'b1;
        #1;
        while (!tag_if.req_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        tag_if.req_valid = 1'b0;
        tag_if.req = '0;
        cycles = 0;
        while (!tag_if.rsp_valid) begin
            @(posedge clk); #1;
            cycles++;
            if (cycles > RSP_TIMEOUT) begin
                errors++; $error("[%s] no response after %0d cycles", name, cycles);
                rsp = '0;
                return;
            end
        end
        if (!tag_if.busy) begin errors++; $error("[%s] busy low while responding", name); end
        rsp = tag_if.rsp;
        @(posedge clk); #1;   // rsp_ready is held high: handshake completes here
        if (!tag_if.req_ready || tag_if.busy) begin
            errors++; $error("[%s] engine did not release after rsp handshake", name);
        end
    endtask

    // Start a request but do not wait for it (used for the stall test).
    task automatic request_nowait(input tag_lookup_t [LANES-1:0] req);
        tag_if.req = req;
        tag_if.req_valid = 1'b1;
        #1;
        while (!tag_if.req_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        tag_if.req_valid = 1'b0;
        tag_if.req = '0;
    endtask

    // Companion of request_nowait: rsp_ready is low meanwhile so the response
    // is held until we are ready to look at it.
    task automatic wait_rsp(input string name, output tag_out_t [LANES-1:0] rsp);
        int cycles = 0;
        while (!tag_if.rsp_valid) begin
            @(posedge clk); #1; cycles++;
            if (cycles > RSP_TIMEOUT) begin
                errors++; $error("[%s] no response", name); rsp = '0; return;
            end
        end
        rsp = tag_if.rsp;
        tag_if.rsp_ready = 1'b1;
        @(posedge clk); #1;
    endtask

    task automatic fill(input int bank, idx, way);
        tag_if.fill_bank = BANK_W'(bank);
        tag_if.fill_idx = INDEX_W'(idx);
        tag_if.fill_way = WAY_W'(way);
        tag_if.fill_en = 1'b1;
        #1;
        checks++;
        if (!tag_if.fill_ready) begin
            errors++; $error("fill_ready low for allocated, unfilled b%0d/s%0d/w%0d", bank, idx, way);
        end
        @(posedge clk); #1;
        tag_if.fill_en = 1'b0;
        if (tag_if.fill_ready) begin
            errors++; $error("fill_ready still high after filling b%0d/s%0d/w%0d", bank, idx, way);
        end
    endtask

    // --------------------------- checkers ---------------------------
    task automatic expect_group(input string name, input int g, input tag_out_t got,
                                input bit hit, ready, input int way);
        checks++;
        if (got.hit !== hit || got.ready !== ready || got.hit_way !== WAY_W'(way)) begin
            errors++;
            $error("[%s] rsp[%0d] hit=%0b ready=%0b way=%0d expected %0b/%0b/%0d",
                   name, g, got.hit, got.ready, got.hit_way, hit, ready, way);
        end
    endtask

    // Compare the miss log against an expected multiset, then clear it.
    task automatic expect_misses(input string name, input miss_t exp [$]);
        int idx [$];
        checks++;
        foreach (exp[i]) begin
            idx = miss_log.find_first_index(m) with (m == exp[i]);
            if (idx.size() == 0) begin
                errors++; $error("[%s] missing miss %h way %0d", name, exp[i].addr, exp[i].way);
            end else miss_log.delete(idx[0]);
        end
        foreach (miss_log[i]) begin
            errors++; $error("[%s] unexpected miss %h way %0d", name, miss_log[i].addr, miss_log[i].way);
        end
        miss_log.delete();
    endtask

    // Every active group must produce exactly one bank result carrying its tap_mask.
    task automatic expect_bank_results(input string name, input tag_lookup_t [LANES-1:0] req);
        int idx [$];
        checks++;
        for (int g = 0; g < LANES; g++) begin
            if (!req[g].valid) continue;
            idx = bank_log.find_first_index(r) with (r.bank == req[g].bank && r.mask == req[g].tap_mask);
            if (idx.size() == 0) begin
                errors++; $error("[%s] group %0d (bank %0d mask %b) never fired bank_result", name, g, req[g].bank, req[g].tap_mask);
            end else bank_log.delete(idx[0]);
        end
        if (bank_log.size() != 0) begin
            errors++; $error("[%s] %0d extra bank_result handshakes", name, bank_log.size());
        end
        bank_log.delete();
    endtask

    // ================================ TEST ================================
    tag_lookup_t [LANES-1:0] req;
    tag_out_t [LANES-1:0] rsp;
    miss_t exp [$];
    int cyc;

    function automatic void add_exp(input logic [ADDR_W-1:0] addr, input int way);
        miss_t m; m.addr = addr; m.way = WAY_W'(way); exp.push_back(m);
    endfunction

    // Same-bank groups are serialized (ascending group order, route_ptr is
    // cleared per pixel). Check that every listed group missed and that their
    // ways are all distinct; the miss stream is then expected to carry exactly
    // those (addr, way) pairs. Exact ways are checked separately on fresh sets.
    task automatic expect_serialized_misses(input string name, input tag_lookup_t [LANES-1:0] r,
                                            input tag_out_t [LANES-1:0] got, input int groups [$]);
        logic [WAYS-1:0] seen = '0;
        checks++;
        foreach (groups[i]) begin
            int g = groups[i];
            if (got[g].hit !== 1'b0 || got[g].ready !== 1'b0) begin
                errors++; $error("[%s] rsp[%0d] should be a new miss", name, g);
            end
            if (seen[got[g].hit_way]) begin
                errors++; $error("[%s] way %0d allocated twice in one set", name, got[g].hit_way);
            end
            seen[got[g].hit_way] = 1'b1;
            add_exp({r[g].tag, r[g].index, r[g].bank, {OFFSET_W{1'b0}}}, int'(got[g].hit_way));
        end
    endtask

    // Fill bank/index 3 with four ready lines (tags base..base+3 -> ways 0..3),
    // hit the ways in hit_order, then miss with tag base+4 and check the victim.
    task automatic plru_order(input string name, input int bank, input int base_tag,
                              input int hit_order [$], input int exp_victim);
        tag_lookup_t [LANES-1:0] r;
        tag_out_t [LANES-1:0] got;
        int c;
        for (int w = 0; w < 4; w++) begin
            r = '0; r[0] = group(4'b0001, line(base_tag + w, 3, bank));
            request(name, r, got, c);
            expect_group({name, " alloc"}, 0, got[0], 0, 0, w);
        end
        for (int w = 0; w < 4; w++) fill(bank, 3, w);
        foreach (hit_order[i]) begin
            r = '0; r[0] = group(4'b0001, line(base_tag + hit_order[i], 3, bank));
            request(name, r, got, c);
            expect_group({name, " hit"}, 0, got[0], 1, 1, hit_order[i]);
        end
        r = '0; r[0] = group(4'b0001, line(base_tag + 4, 3, bank));
        request(name, r, got, c);
        expect_group({name, " victim"}, 0, got[0], 0, 0, exp_victim);
        miss_log.delete(); bank_log.delete();
    endtask

    // Bank test: bank 0, index 0, tags 1..5
    localparam logic [ADDR_W-1:0] L1 = line(1, 0, 0), L2 = line(2, 0, 0), L3 = line(3, 0, 0),
                                  L4 = line(4, 0, 0), L5 = line(5, 0, 0);

    initial begin
        tag_if.req_valid = 0; tag_if.req = '0; tag_if.rsp_ready = 1;
        tag_if.miss_ready = 1; tag_if.bank_result_ready = '1;
        tag_if.fill_en = 0; tag_if.fill_bank = 0; tag_if.fill_idx = 0; tag_if.fill_way = 0;
        repeat (2) @(posedge clk); #1;
        if (tag_if.req_ready || tag_if.rsp_valid || tag_if.miss_valid || tag_if.busy) begin
            errors++; $error("outputs not quiet in reset");
        end
        n_rst = 1; #1;
        if (!tag_if.req_ready) begin errors++; $error("req_ready low after reset"); end

        // ------------------------------------------------------------------
        // Tag bank test (single group per pixel)
        // ------------------------------------------------------------------
        req = '0; req[0] = group(4'b0001, L1);
        request("miss L1", req, rsp, cyc);
        expect_group("miss L1", 0, rsp[0], 0, 0, 0);
        exp = {}; add_exp(L1, 0); expect_misses("miss L1", exp);
        expect_bank_results("miss L1", req);

        request("hit L1", req, rsp, cyc);
        expect_group("hit L1", 0, rsp[0], 1, 0, 0);   // pending line: hit, not ready
        exp = {}; expect_misses("hit L1", exp);
        expect_bank_results("hit L1", req);

        req[0] = group(4'b0001, L2); request("miss L2", req, rsp, cyc);
        expect_group("miss L2", 0, rsp[0], 0, 0, 1);
        req[0] = group(4'b0001, L3); request("miss L3", req, rsp, cyc);
        expect_group("miss L3", 0, rsp[0], 0, 0, 2);
        req[0] = group(4'b0001, L4); request("miss L4", req, rsp, cyc);
        expect_group("miss L4", 0, rsp[0], 0, 0, 3);
        exp = {}; add_exp(L2, 1); add_exp(L3, 2);
        add_exp(L4, 3); expect_misses("miss L2-4", exp);
        bank_log.delete();

        // Miss L5: set is full of pending lines -> must stall until a fill.
        tag_if.rsp_ready = 1'b0;
        req[0] = group(4'b0001, L5); request_nowait(req);
        repeat (8) begin
            @(posedge clk); #1;
            if (tag_if.rsp_valid || tag_if.miss_valid) begin
                errors++; $error("L5 progressed with no evictable way");
            end
        end
        checks++;
        if (!tag_if.busy || !dut.bank_busy[0]) begin errors++; $error("bank 0 should report busy"); end
        fill(0, 0, 0);                   // L1 ready -> L5 evicts way 0
        fill(0, 0, 1); fill(0, 0, 2); fill(0, 0, 3);
        wait_rsp("miss L5", rsp);
        expect_group("miss L5", 0, rsp[0], 0, 0, 0);
        exp = {}; add_exp(L5, 0); expect_misses("miss L5", exp);
        expect_bank_results("miss L5", req);

        // L1 was evicted: miss again. Way 0 pending, PLRU points right -> way 2.
        req[0] = group(4'b0001, L1); request("miss L1 again", req, rsp, cyc);
        expect_group("miss L1 again", 0, rsp[0], 0, 0, 2);
        exp = {}; add_exp(L1, 2); expect_misses("miss L1 again", exp);
        expect_bank_results("miss L1 again", req);

        // ------------------------------------------------------------------
        // Tag array test (four groups per pixel); fresh sets so ways are
        // allocated lowest-invalid-first and the expectations are deterministic.
        // ------------------------------------------------------------------
        // All 4 groups in different banks (index 5): all miss, each way 0.
        for (int g = 0; g < 4; g++) req[g] = group(4'b0001 << g, line(16'h10, 5, g));
        request("4 banks miss", req, rsp, cyc);
        for (int g = 0; g < 4; g++) expect_group("4 banks miss", g, rsp[g], 0, 0, 0);
        exp = {}; for (int g = 0; g < 4; g++) add_exp(line(16'h10, 5, g), 0);
        expect_misses("4 banks miss", exp); expect_bank_results("4 banks miss", req);
        checks++; if (cyc > 8) begin errors++; $error("4-bank pixel took %0d cycles", cyc); end

        // Same pixel again: all hit (pending). Then mixed: groups 1,3 new tags -> way 1.
        request("4 banks hit", req, rsp, cyc);
        for (int g = 0; g < 4; g++) expect_group("4 banks hit", g, rsp[g], 1, 0, 0);
        exp = {}; expect_misses("4 banks hit", exp); expect_bank_results("4 banks hit", req);
        req[1] = group(4'b0010, line(16'h11, 5, 1)); req[3] = group(4'b1000, line(16'h11, 5, 3));
        request("4 banks mixed", req, rsp, cyc);
        expect_group("4 banks mixed", 0, rsp[0], 1, 0, 0); expect_group("4 banks mixed", 1, rsp[1], 0, 0, 1);
        expect_group("4 banks mixed", 2, rsp[2], 1, 0, 0); expect_group("4 banks mixed", 3, rsp[3], 0, 0, 1);
        exp = {}; add_exp(line(16'h11, 5, 1), 1); add_exp(line(16'h11, 5, 3), 1);
        expect_misses("4 banks mixed", exp); expect_bank_results("4 banks mixed", req);

        // All 4 groups in the same bank (bank 1, index 6, four tags): serialized,
        // every group allocates a distinct way (order follows route_ptr).
        for (int g = 0; g < 4; g++) req[g] = group(4'b0001 << g, line(16'h20 + g, 6, 1));
        request("same bank", req, rsp, cyc);
        exp = {}; expect_serialized_misses("same bank", req, rsp, {0, 1, 2, 3});
        // route_ptr is cleared per pixel: ascending group order on a fresh set.
        for (int g = 0; g < 4; g++) expect_group("same bank order", g, rsp[g], 0, 0, g);
        expect_misses("same bank", exp); expect_bank_results("same bank", req);
        checks++; if (cyc < 8) begin errors++; $error("same-bank pixel finished suspiciously fast (%0d cycles)", cyc); end

        // 3 groups in bank 2 (index 7) + 1 group in bank 3 (index 7).
        for (int g = 0; g < 3; g++) req[g] = group(4'b0001 << g, line(16'h30 + g, 7, 2));
        req[3] = group(4'b1000, line(16'h30, 7, 3));
        request("3+1", req, rsp, cyc);
        exp = {}; expect_serialized_misses("3+1", req, rsp, {0, 1, 2});
        expect_group("3+1", 3, rsp[3], 0, 0, 0);
        add_exp(line(16'h30, 7, 3), 0);
        expect_misses("3+1", exp); expect_bank_results("3+1", req);

        // 2 groups in bank 0 (index 1) + 1 in bank 1 + 1 in bank 2.
        req[0] = group(4'b0011, line(16'h40, 1, 0)); req[1] = group(4'b0100, line(16'h41, 1, 0));
        req[2] = group(4'b1000, line(16'h40, 1, 1)); req[3] = '0;
        // use a 3-group pixel here: group 3 inactive proves inactive groups are skipped
        request("2+1+1", req, rsp, cyc);
        exp = {}; expect_serialized_misses("2+1+1", req, rsp, {0, 1});
        expect_group("2+1+1", 2, rsp[2], 0, 0, 0);
        checks++; if (rsp[3] !== '0) begin errors++; $error("inactive group produced a response"); end
        add_exp(line(16'h40, 1, 1), 0);
        expect_misses("2+1+1", exp); expect_bank_results("2+1+1", req);

        // 2 groups in bank 2 (index 2) + 2 groups in bank 3 (index 2).
        req[0] = group(4'b0001, line(16'h50, 2, 2)); req[1] = group(4'b0010, line(16'h51, 2, 2));
        req[2] = group(4'b0100, line(16'h50, 2, 3)); req[3] = group(4'b1000, line(16'h51, 2, 3));
        request("2+2", req, rsp, cyc);
        exp = {}; expect_serialized_misses("2+2", req, rsp, {0, 1});
        expect_serialized_misses("2+2", req, rsp, {2, 3});
        expect_misses("2+2", exp); expect_bank_results("2+2", req);

        // ------------------------------------------------------------------
        // PLRU order tests (index 3, banks 0/1/2 are untouched so far)
        // ------------------------------------------------------------------
        plru_order("plru w0..w3", 0, 16'h60, '{0, 1, 2, 3}, 0);
        plru_order("plru w3..w0", 1, 16'h70, '{3, 2, 1, 0}, 3);
        plru_order("plru w3,w0,w2", 2, 16'h80, '{3, 0, 2}, 1);

        if (errors == 0)
            $display("PASS tag_array_tb: %0d checks", checks);
        else
            $fatal(1, "FAIL tag_array_tb: %0d errors in %0d checks", errors, checks);
        $finish;
    end
    initial begin #500000; $fatal(1, "tag_array_tb timeout"); end
endmodule
