`include "packages/cache_pkg.sv"
`include "interfaces/tag_array_if.sv"

module tag_array (
    input logic clk, n_rst,
    tag_array_if.tag_array tag_if
);
    import cache_pkg::*;
    localparam int GROUP_W = (LANES > 1) ? $clog2(LANES) : 1;

    // Retain the accepted pixel. Each group is cleared exactly once.
    tag_lookup_t [LANES-1:0] req_q;
    tag_out_t [LANES-1:0] rsp_q;
    logic active;
    logic [LANES-1:0] pending;
    logic req_fire, rsp_fire;

    assign tag_if.req_ready = n_rst && !active;
    assign tag_if.busy = active;
    assign tag_if.rsp_valid = n_rst && active && !(|pending);
    assign tag_if.rsp = rsp_q;
    assign req_fire = tag_if.req_valid && tag_if.req_ready;
    assign rsp_fire = tag_if.rsp_valid && tag_if.rsp_ready;

    // One lookup/result register per bank. A captured candidate retains its
    // group, way, address and original outcome through any downstream stall.
    logic [BANKS-1:0] selected, bank_busy, result_pending;
    logic [BANKS-1:0] bank_fire, lookup_capture, bank_fill_ready;
    logic [BANKS-1:0][GROUP_W-1:0] selected_group, result_group, route_ptr;
    tag_out_t [BANKS-1:0] lookup_result, result_q;
    logic [BANKS-1:0][LANES-1:0] mask_q;
    logic [BANKS-1:0][ADDR_W-1:0] addr_q;
    logic [BANKS-1:0][INDEX_W-1:0] bank_idx;
    logic [BANKS-1:0][TAG_W-1:0] bank_tag;

    // TODO : route_ptr persists across pixels, so same-bank groups of a new pixel are
    // looked up starting from a history-dependent group (rsp[i]<->req[i] still holds). Decide if intended.
    always_comb begin : route_pending_groups
        selected = '0;
        selected_group = '0;
        bank_idx = '0;
        bank_tag = '0;
        for (int b = 0; b < BANKS; b++) begin
            for (int offset = 0; offset < LANES; offset++) begin
                if (active && !result_pending[b] && !selected[b] &&
                    pending[(int'(route_ptr[b])+offset)%LANES] &&
                    req_q[(int'(route_ptr[b])+offset)%LANES].bank == BANK_W'(b)) begin
                    selected[b] = 1'b1;
                    selected_group[b] = GROUP_W'((int'(route_ptr[b])+offset)%LANES);
                end
            end
            bank_idx[b] = req_q[selected_group[b]].index;
            bank_tag[b] = req_q[selected_group[b]].tag;
        end
    end
    assign lookup_capture = selected & ~bank_busy;

    // Single-port miss enqueue arbiter. Lock the selected bank while the
    // queue stalls so newly arriving bank candidates cannot change its payload.
    logic miss_selected, miss_lock;
    logic [BANK_W-1:0] miss_bank, locked_bank, miss_ptr;
    logic miss_fire;

    always_comb begin : select_miss_bank
        miss_selected = 1'b0;
        miss_bank = locked_bank;
        if (miss_lock) begin
            miss_selected = result_pending[locked_bank];
        end else begin
            for (int offset = 0; offset < BANKS; offset++) begin
                if (!miss_selected && result_pending[(int'(miss_ptr)+offset)%BANKS] &&
                    !result_q[(int'(miss_ptr)+offset)%BANKS].hit &&
                    tag_if.bank_result_ready[(int'(miss_ptr)+offset)%BANKS]) begin
                    miss_selected = 1'b1;
                    miss_bank = BANK_W'((int'(miss_ptr)+offset)%BANKS);
                end
            end
        end
    end

    // Hits do not depend on miss-FIFO space. A new miss has two destinations:
    // preparation capacity is RESERVED; queue acceptance and bank acceptance
    // therefore commit on the same edge. Neither sink receives a partial miss.
    always_comb begin : accepted_bank_results
        tag_if.bank_result = result_q;
        tag_if.bank_tap_mask = mask_q;
        tag_if.bank_result_valid = '0;
        tag_if.miss_valid = n_rst && miss_selected && tag_if.bank_result_ready[miss_bank];
        tag_if.miss_addr = miss_selected ? addr_q[miss_bank] : '0;
        tag_if.miss_way = miss_selected ? result_q[miss_bank].hit_way : '0;
        for (int b = 0; b < BANKS; b++) begin
            if (n_rst && result_pending[b]) begin
                if (result_q[b].hit)
                    tag_if.bank_result_valid[b] = 1'b1;
                else if (miss_selected && miss_bank == BANK_W'(b))
                    tag_if.bank_result_valid[b] = tag_if.miss_ready;
            end
        end
        bank_fire = tag_if.bank_result_valid & tag_if.bank_result_ready;
    end
    assign miss_fire = tag_if.miss_valid && tag_if.miss_ready;

    always_ff @(posedge clk or negedge n_rst) begin : pixel_and_result_tracking
        if (!n_rst) begin
            active <= 1'b0;
            pending <= '0;
            req_q <= '0;
            rsp_q <= '0;
            result_pending <= '0;
            result_q <= '0;
            result_group <= '0;
            route_ptr <= '0;
            mask_q <= '0;
            addr_q <= '0;
            miss_lock <= 1'b0;
            locked_bank <= '0;
            miss_ptr <= '0;
        end else begin
            if (req_fire) begin
                active <= 1'b1;
                req_q <= tag_if.req;
                rsp_q <= '0;
                for (int g = 0; g < LANES; g++) pending[g] <= tag_if.req[g].valid;
            end
            if (rsp_fire) active <= 1'b0;
            for (int b = 0; b < BANKS; b++) begin
                if (lookup_capture[b]) begin
                    result_pending[b] <= 1'b1;
                    result_q[b] <= lookup_result[b];
                    result_group[b] <= selected_group[b];
                    mask_q[b] <= req_q[selected_group[b]].tap_mask;
                    addr_q[b] <= {bank_tag[b], bank_idx[b], BANK_W'(b), {OFFSET_W{1'b0}}};
                end
                if (bank_fire[b]) begin
                    result_pending[b] <= 1'b0;
                    pending[result_group[b]] <= 1'b0;
                    rsp_q[result_group[b]] <= result_q[b];
                    route_ptr[b] <= (result_group[b] == GROUP_W'(LANES-1))
                                    ? '0 : result_group[b] + 1'b1;
                end
            end
            if (miss_selected && !miss_fire && !miss_lock) begin
                miss_lock <= 1'b1;
                locked_bank <= miss_bank;
            end
            if (miss_fire) begin
                miss_lock <= 1'b0;
                miss_ptr <= (miss_bank == BANK_W'(BANKS-1)) ? '0 : miss_bank + 1'b1;
            end
        end
    end

    // Refill has a separate acceptance event and cannot create a new tag.
    assign tag_if.fill_ready = n_rst && bank_fill_ready[tag_if.fill_bank];
    for (genvar b = 0; b < BANKS; b++) begin : banks
        tag_bank bank (
            .clk(clk), .n_rst(n_rst),
            .look_en(selected[b]), .look_idx(bank_idx[b]), .look_tag(bank_tag[b]),
            .out(lookup_result[b]), .busy(bank_busy[b]),
            .look_commit(bank_fire[b]),
            .alloc_en(bank_fire[b] && !result_q[b].hit),
            .commit_idx(addr_q[b][OFFSET_W+BANK_W +: INDEX_W]),
            .commit_tag(addr_q[b][ADDR_W-1 -: TAG_W]),
            .commit_way(result_q[b].hit_way),
            .fill_en(tag_if.fill_en && tag_if.fill_bank == BANK_W'(b)),
            .fill_idx(tag_if.fill_idx), .fill_way(tag_if.fill_way),
            .fill_ready(bank_fill_ready[b])
        );
    end

`ifndef SYNTHESIS
    initial begin
        if (WAYS != 4 || BANKS != 4 || LANES != 4 ||
            ADDR_W != TAG_W+INDEX_W+BANK_W+OFFSET_W)
            $fatal(1, "Tag engine requires four ways, four banks, four tap groups");
    end
    always @(posedge clk) begin : check_result_reservation
        if (n_rst && miss_lock && !tag_if.bank_result_ready[locked_bank])
            $fatal(1, "Preparation capacity was withdrawn from a pending miss");
        if (req_fire) begin
            for (int g = 0; g < LANES; g++)
                if (tag_if.req[g].valid && tag_if.req[g].tap_mask == '0)
                    $fatal(1, "Active tag group has no taps");
        end
    end
`endif
endmodule

module tag_bank (
    input logic clk, n_rst,
    input logic look_en,
    input logic [cache_pkg::INDEX_W-1:0] look_idx,
    input logic [cache_pkg::TAG_W-1:0] look_tag,
    output cache_pkg::tag_out_t out,
    output logic busy,
    input logic look_commit, alloc_en,
    input logic [cache_pkg::INDEX_W-1:0] commit_idx,
    input logic [cache_pkg::TAG_W-1:0] commit_tag,
    input logic [cache_pkg::WAY_W-1:0] commit_way,
    input logic fill_en,
    input logic [cache_pkg::INDEX_W-1:0] fill_idx,
    input logic [cache_pkg::WAY_W-1:0] fill_way,
    output logic fill_ready
);
    import cache_pkg::*;
    logic [WAYS-1:0] valid [SETS_PER_BANK];
    logic [WAYS-1:0] ready [SETS_PER_BANK];
    logic [TAG_W-1:0] tag [SETS_PER_BANK][WAYS];
    // Exactly three tree-PLRU bits per set, retaining the existing lru name.
    logic [2:0] lru [SETS_PER_BANK];
    logic [WAYS-1:0] match, replace_way;
    logic [WAY_W-1:0] alloc_way;
    logic found_invalid, choose_left;
    logic alloc_fire;

    // TODO : a set whose four ways are all allocated-but-unfilled stalls the bank (busy) until a
    // refill lands; the controller must guarantee fills can progress or this deadlocks.
    // Root bit 1 prefers the left pair; child bit 1 prefers its higher way.
    // Skip a subtree with no eligible ways. Invalid ways take priority.
    always_comb begin : lookup_and_replacement
        match = '0;
        replace_way = ~valid[look_idx] | ready[look_idx];
        alloc_way = '0;
        found_invalid = 1'b0;
        choose_left = (lru[look_idx][0] && (|replace_way[1:0])) ||
                      !(|replace_way[3:2]);
        for (int w = 0; w < WAYS; w++) begin
            match[w] = valid[look_idx][w] && tag[look_idx][w] == look_tag;
            if (!found_invalid && !valid[look_idx][w]) begin
                found_invalid = 1'b1;
                alloc_way = WAY_W'(w);
            end
        end
        if (!found_invalid) begin
            if (choose_left)
                alloc_way = ((lru[look_idx][1] && replace_way[1]) || !replace_way[0])
                            ? 2'd1 : 2'd0;
            else
                alloc_way = ((lru[look_idx][2] && replace_way[3]) || !replace_way[2])
                            ? 2'd3 : 2'd2;
        end
        out = '0;
        busy = n_rst && look_en && !(|match) && !(|replace_way);
        if (n_rst && look_en && !busy) begin
            out.hit = |match;
            out.ready = |(match & ready[look_idx]);
            out.hit_way = (|match) ? {match[3] | match[2], match[3] | match[1]}
                                  : alloc_way;
        end
    end
    assign fill_ready = n_rst && valid[fill_idx][fill_way] && !ready[fill_idx][fill_way];
    assign alloc_fire = n_rst && alloc_en && look_commit;

    always_ff @(posedge clk or negedge n_rst) begin : tag_and_plru_update
        if (!n_rst) begin
            for (int s = 0; s < SETS_PER_BANK; s++) begin
                valid[s] <= '0;
                ready[s] <= '0;
                lru[s] <= '0;
            end
        end else begin
            if (fill_en && fill_ready) ready[fill_idx][fill_way] <= 1'b1;
            if (look_commit) begin
                case (commit_way)
                    2'd0: begin lru[commit_idx][0] <= 1'b0; lru[commit_idx][1] <= 1'b1; end
                    2'd1: begin lru[commit_idx][0] <= 1'b0; lru[commit_idx][1] <= 1'b0; end
                    2'd2: begin lru[commit_idx][0] <= 1'b1; lru[commit_idx][2] <= 1'b1; end
                    2'd3: begin lru[commit_idx][0] <= 1'b1; lru[commit_idx][2] <= 1'b0; end
                endcase
            end
            if (alloc_en && look_commit) begin
                valid[commit_idx][commit_way] <= 1'b1;
                ready[commit_idx][commit_way] <= 1'b0;
            end
        end
    end
    // Tag payload is masked by valid; avoid resetting the payload RAM.
    always_ff @(posedge clk) begin : tag_payload_write
        if (alloc_fire) tag[commit_idx][commit_way] <= commit_tag;
    end
endmodule
