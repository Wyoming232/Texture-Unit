`include "interfaces/interfaces.vh"
`include "packages/cache_pkg.sv"
`include "src/address_calculation.sv"
`include "src/coalesced_fragment_adapter.sv"
`include "src/tag_array.sv"
`include "src/data_array.sv"
`include "src/frag_fifo.sv"
`include "src/miss_path.sv"
`include "src/payload_buffer.sv"

// Texture cache top (documentation/reference/top_level_simplified.png).
// Hit path: TMU quad -> signal reorganisation -> round-robin pixel arbiter
//   -> address_calculation -> coalesced_fragment_adapter -> tag_array
//   -> frag_fifo -> read issue -> data_array -> payload_buffer -> TMU.
// Miss path: tag_array miss channel -> miss_path (miss FIFO, memory, ROB)
//   -> refill of tag_array + data_array.
// One pixel is in the frontend at a time: its tag request is issued once,
// and the pixel is "done" when its complete tag response is pushed into the
// fragment FIFO. The TMU quad is released (tmu_req.ready) when pixel 3 is done.
module hit_path_temp #(
    parameter int READ_LATENCY = 1
) (
    input logic clk, n_rst,
    texture_cache_request_if.addr_calc tmu_req,   // valid, payload in; ready out
    texture_cache_return_if.sender tmu_rsp,       // one return per request, in order
    mem_if.cache mem,                             // line requests / out-of-order returns
    output logic protocol_error,   // sticky: data array or ROB protocol violation
    output logic replay_error      // sticky: a queued pixel's line was evicted before it was read
);
    import cache_pkg::*;
    localparam int COOKIE_W = 4;   // {pixel_id, tap}

    // ----------------TMU->T$ SIGNAL REORGANIZATION----------------//
    texture_cache_request_t req;
    assign req = tmu_req.payload;

    // STARTING ADDRESS CALCULATION
    base_address_t base_info;
    always_comb begin : tmu_req_base_info
        base_info = '{
            mip_0_log2_height : req.texture_header.log2_height,
            mip_0_log2_width  : req.texture_header.log2_width,
            base_addr         : req.texture_header.base_addr,
            mip_level         : req.mip_level,
            max_mip_level     : req.texture_header.max_mip_level,
            log2_width        : req.log2_width,
            log2_height       : req.log2_height
        };
    end
    logic [31:0] base_addr;
    mip_base_addr base_addr_calc (.base_info(base_info), .mip_adjusted_base_addr(base_addr));

    // QUAD SPECIFIC FRAGMENT INFO; NO CONSUMPTION / PASS THROUGH
    tmu_quad_metadata_t tmu_quad_info;
    always_comb begin : tmu_req_quad_info
        tmu_quad_info = '{
            reserved     : req.texture_header.reserved,
            warp_id      : req.warp_id,
            rd           : req.rd,
            quad_index   : req.quad_index,
            filter_mode  : req.filter_mode,
            lod_fraction : req.lod_fraction,
            upper_mip    : req.upper_mip
        };
    end

    // PIXEL SPECIFIC FRAGMENT INFO (pass through) AND TEXEL REQUEST INFO
    tmu_pixel_metadata_t [3:0] tmu_pixel_info;
    pixel_taps_t [3:0] pixel_taps;
    always_comb begin : tmu_req_pixel_info
        for (int p = 0; p < 4; p++) begin
            tmu_pixel_info[p] = '{
                tmu_quad_metadata : tmu_quad_info,
                u_frac            : req.u_frac[p],
                v_frac            : req.v_frac[p]
            };
            pixel_taps[p] = '{x : req.x[p], y : req.y[p]};
        end
    end

    // ----------------PIXEL ARBITRATION----------------//
    logic pixel_done;
    logic [1:0] pixel_id;
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;

    round_robin_arbiter arbiter (
        .clk(clk), .n_rst(n_rst), .tmu_valid(tmu_req.valid),
        .pixel_taps_in(pixel_taps), .pixel_metadata_in(tmu_pixel_info),
        .pixel_done(pixel_done), .pixel_id(pixel_id),
        .pixel_tap_sel(pixel_tap_sel), .pixel_metadata_sel(pixel_metadata_sel)
    );

    // Release the TMU's quad only when pixel 3 is accepted.
    assign tmu_req.ready = tmu_req.valid && (pixel_id == 2'd3) && pixel_done;

    // batch_id is shared by the four pixels of one quad.
    logic [BATCH_ID_W-1:0] batch_id;
    always_ff @(posedge clk or negedge n_rst) begin : batch_counter
        if (!n_rst) batch_id <= '0;
        else if (tmu_req.valid && tmu_req.ready) batch_id <= batch_id + 1'b1;
    end

    // ----------------ADDRESS_CALCULATION----------------//
    coalesced_addr_out_t coa_addr_out;
    address_calculation addr_calc_wrapper (
        .base_addr(base_addr), .log2_width(req.log2_width), .log2_height(req.log2_height),
        .pixel_tap_sel(pixel_tap_sel), .pixel_metadata_sel(pixel_metadata_sel),
        .batch_id(batch_id), .pixel_id(pixel_id), .coa_addr_out(coa_addr_out)
    );

    // ----------------TAG ARRAY----------------//
    tag_array_if tag_if();
    tag_lookup_t [LANES-1:0] tag_req;
    frag_data_t frag_in;
    logic req_sent, frag_ready_in;

    coalesced_fragment_adapter adapter (
        .coa_addr_out(coa_addr_out), .tag_result(tag_if.rsp),
        .tag_req(tag_req), .frag_in(frag_in)
    );
    tag_array tags (.clk(clk), .n_rst(n_rst), .tag_if(tag_if));

    // The selected pixel is looked up exactly once. The address calculation
    // output stays stable meanwhile (pixel_id and the TMU payload are held),
    // so frag_in = {coa_addr_out, held rsp} is the pixel's complete entry.
    assign tag_if.req_valid = tmu_req.valid && !req_sent;
    assign tag_if.req = tag_req;
    assign tag_if.bank_result_ready = '1;   // only the complete rsp is consumed
    assign tag_if.rsp_ready = frag_ready_in;
    assign pixel_done = tag_if.rsp_valid && tag_if.rsp_ready;

    always_ff @(posedge clk or negedge n_rst) begin : lookup_issue_tracking
        if (!n_rst) req_sent <= 1'b0;
        else if (pixel_done) req_sent <= 1'b0;
        else if (tag_if.req_valid && tag_if.req_ready) req_sent <= 1'b1;
    end

    // ----------------FRAGMENT FIFO----------------//
    logic frag_batch_committed, frag_pop, frag_tail_valid, frag_full, frag_empty;
    frag_data_t frag_tail;
    logic [$clog2(FRAG_DEPTH+1)-1:0] frag_count;

    frag_fifo frag_q (
        .clk(clk), .n_rst(n_rst),
        .valid_in(tag_if.rsp_valid), .ready_in(frag_ready_in), .frag_in(frag_in),
        .batch_committed(frag_batch_committed),
        .pop(frag_pop), .tail_valid(frag_tail_valid), .tail_data(frag_tail),
        .full(frag_full), .empty(frag_empty), .count(frag_count)
    );

    // ----------------LINE STATE MIRROR----------------//
    // Mirrors the tag array's per-way ready state from the two events that
    // change it: a committed miss allocation (miss handshake) and a refill.
    // A fragment snapshot (data_ready) goes stale while it waits in the FIFO;
    // the mirror tells the read stage when a pending line has landed. The
    // mirrored tag detects a line evicted before a queued pixel read it.
    logic [BANKS-1:0][SETS_PER_BANK-1:0][WAYS-1:0] line_ready;
    logic [TAG_W-1:0] line_tag [BANKS][SETS_PER_BANK][WAYS];
    logic miss_fire, fill_fire;
    logic [BANK_W-1:0] miss_bank;
    logic [INDEX_W-1:0] miss_idx;

    assign miss_fire = tag_if.miss_valid && tag_if.miss_ready;
    assign fill_fire = tag_if.fill_en && tag_if.fill_ready;
    assign miss_bank = tag_if.miss_addr[OFFSET_W +: BANK_W];
    assign miss_idx  = tag_if.miss_addr[OFFSET_W+BANK_W +: INDEX_W];

    always_ff @(posedge clk or negedge n_rst) begin : line_ready_mirror
        if (!n_rst) line_ready <= '0;
        else begin
            if (miss_fire) line_ready[miss_bank][miss_idx][tag_if.miss_way] <= 1'b0;
            if (fill_fire) line_ready[tag_if.fill_bank][tag_if.fill_idx][tag_if.fill_way] <= 1'b1;
        end
    end
    always_ff @(posedge clk) begin : line_tag_mirror
        if (miss_fire)
            line_tag[miss_bank][miss_idx][tag_if.miss_way] <= tag_if.miss_addr[ADDR_W-1 -: TAG_W];
    end

    // ----------------DATA ARRAY READ ISSUE----------------//
    // The FIFO tail is popped (ownership transfer) into cur when the previous
    // pixel has issued all its reads AND the payload buffer has its slot.
    // Each bank issues the lowest pending tap that maps to it and whose line
    // is ready; same-bank taps serialise. A faulted pixel issues nothing.
    logic cur_valid, cur_free, pb_alloc_ready;
    frag_data_t cur;
    logic [LANES-1:0] cur_pending, tap_ok, issued;
    logic [BANKS-1:0][1:0] sel_tap;
    logic [BANKS-1:0] stale_issue;
    logic [BANKS-1:0] rd_valid, rd_ready, rd_rsp_valid;
    logic [BANKS-1:0][SET_W-1:0] rd_set;
    logic [BANKS-1:0][WAY_W-1:0] rd_way;
    logic [BANKS-1:0][OFFSET_W-1:0] rd_byte_offset;
    logic [BANKS-1:0][COOKIE_W-1:0] rd_cookie, rd_rsp_cookie;
    logic [BANKS-1:0][TEXEL_BITS-1:0] rd_rsp_data;

    always_comb begin : read_issue_select
        for (int t = 0; t < LANES; t++)
            tap_ok[t] = cur_valid && cur_pending[t] && line_ready[cur.bank[t]][cur.idx[t]][cur.hit_way[t]];
        rd_valid = '0;
        sel_tap = '0;
        for (int b = 0; b < BANKS; b++) begin
            for (int t = LANES-1; t >= 0; t--)   // descending: lowest tap wins
                if (tap_ok[t] && cur.bank[t] == BANK_W'(b)) begin
                    rd_valid[b] = 1'b1;
                    sel_tap[b] = 2'(t);
                end
            rd_set[b] = cur.idx[sel_tap[b]];
            rd_way[b] = cur.hit_way[sel_tap[b]];
            rd_byte_offset[b] = cur.offset[sel_tap[b]];
            rd_cookie[b] = {cur.pixel_id, sel_tap[b]};
        end
    end

    // Separate block: rd_ready depends on rd_set/rd_way/rd_byte_offset.
    always_comb begin : read_issue_accept
        issued = '0;
        stale_issue = '0;
        for (int b = 0; b < BANKS; b++)
            if (rd_valid[b] && rd_ready[b]) begin
                issued[sel_tap[b]] = 1'b1;
                stale_issue[b] = line_tag[b][rd_set[b]][rd_way[b]]
                                 != cur.addr[sel_tap[b]][ADDR_W-1 -: TAG_W];
            end
    end

    assign cur_free = !cur_valid || ((cur_pending & ~issued) == '0);
    assign frag_pop = frag_tail_valid && cur_free && pb_alloc_ready;

    always_ff @(posedge clk or negedge n_rst) begin : read_issue_state
        if (!n_rst) begin
            cur_valid <= 1'b0;
            cur_pending <= '0;
            cur <= '0;
            replay_error <= 1'b0;
        end else begin
            if (frag_pop) begin
                cur_valid <= 1'b1;
                cur <= frag_tail;
                cur_pending <= (|(frag_tail.used & frag_tail.addr_error)) ? '0 : frag_tail.used;
            end else if (cur_free) begin
                cur_valid <= 1'b0;
                cur_pending <= '0;
            end else begin
                cur_pending <= cur_pending & ~issued;
            end
            // No replay engine yet: the read proceeds (wrong data) and the
            // condition is reported. See README "Known gaps".
            if (|stale_issue) replay_error <= 1'b1;
        end
    end

    // ----------------DATA ARRAY----------------//
    logic data_fill_valid, data_fill_ready, data_protocol_error;
    logic [BANK_W-1:0] data_fill_bank;
    logic [SET_W-1:0] data_fill_set;
    logic [WAY_W-1:0] data_fill_way;
    logic [LINE_BITS-1:0] data_fill_line;

    data_array #(.READ_LATENCY(READ_LATENCY), .COOKIE_W(COOKIE_W)) data (
        .clk(clk), .n_rst(n_rst),
        .rd_valid(rd_valid), .rd_ready(rd_ready), .rd_set(rd_set), .rd_way(rd_way),
        .rd_byte_offset(rd_byte_offset), .rd_cookie(rd_cookie),
        .rd_rsp_valid(rd_rsp_valid), .rd_rsp_data(rd_rsp_data), .rd_rsp_cookie(rd_rsp_cookie),
        .fill_valid(data_fill_valid), .fill_ready(data_fill_ready),
        .fill_bank(data_fill_bank), .fill_set(data_fill_set), .fill_way(data_fill_way),
        .fill_line(data_fill_line), .protocol_error(data_protocol_error)
    );

    // ----------------PAYLOAD BUFFER -> TMU----------------//
    payload_buffer #(.COOKIE_W(COOKIE_W)) payload (
        .clk(clk), .n_rst(n_rst),
        .alloc_valid(frag_tail_valid && cur_free), .alloc_ready(pb_alloc_ready),
        .alloc_frag(frag_tail),
        .wr_valid(rd_rsp_valid), .wr_cookie(rd_rsp_cookie), .wr_data(rd_rsp_data),
        .rsp_valid(tmu_rsp.valid), .rsp_ready(tmu_rsp.ready), .rsp_payload(tmu_rsp.payload)
    );

    // ----------------MISS PATH----------------//
    logic miss_req_empty, miss_req_full, rob_empty, rob_full, miss_protocol_error;
    miss_path misses (
        .clk(clk), .n_rst(n_rst),
        .tag_miss(tag_if), .tag_refill(tag_if), .mem(mem),
        .data_fill_valid(data_fill_valid), .data_fill_ready(data_fill_ready),
        .data_fill_bank(data_fill_bank), .data_fill_set(data_fill_set),
        .data_fill_way(data_fill_way), .data_fill_line(data_fill_line),
        .miss_req_empty(miss_req_empty), .miss_req_full(miss_req_full),
        .rob_empty(rob_empty), .rob_full(rob_full), .protocol_error(miss_protocol_error)
    );

    assign protocol_error = data_protocol_error || miss_protocol_error;

`ifndef SYNTHESIS
    // base_address_t fields the datapath does not consume are cross-checked
    // against the layout mip_base_addr assumes (see cache_pkg open question).
    int unsigned exp_lw, exp_lh;
    always @(posedge clk) if (n_rst && tmu_req.valid) begin : check_mip_descriptor
        exp_lw = (req.texture_header.log2_width  > req.mip_level)
                 ? req.texture_header.log2_width  - req.mip_level : 0;
        exp_lh = (req.texture_header.log2_height > req.mip_level)
                 ? req.texture_header.log2_height - req.mip_level : 0;
        if (req.mip_level > req.texture_header.max_mip_level)
            $error("hit_path_temp: mip_level %0d > max_mip_level %0d",
                   req.mip_level, req.texture_header.max_mip_level);
        if (req.log2_width != exp_lw || req.log2_height != exp_lh)
            $error("hit_path_temp: selected mip is 2^%0d x 2^%0d, layout expects 2^%0d x 2^%0d",
                   req.log2_width, req.log2_height, exp_lw, exp_lh);
    end
`endif
endmodule

module round_robin_arbiter (
    input  logic clk,
    input  logic n_rst,

    // TMU holds the entire quad stable until tmu_valid && tmu_ready.
    input  logic tmu_valid,

    // [pixel]; taps: c00, c10, c01, c11.
    input  cache_pkg::pixel_taps_t [3:0] pixel_taps_in,
    // Per-pixel metadata travels with the selected pixel through
    // address_calculation (coa_addr_out.pixel_metadata) into the fragment.
    input  cache_pkg::tmu_pixel_metadata_t [3:0] pixel_metadata_in,

    // The selected pixel's complete tag response was pushed into the
    // fragment FIFO this cycle (driven by hit_path_temp).
    input  logic pixel_done,

    // Selected pixel, its four taps and its metadata.
    output logic [1:0] pixel_id,
    output cache_pkg::pixel_taps_t pixel_tap_sel,
    output cache_pkg::tmu_pixel_metadata_t pixel_metadata_sel
);

    assign pixel_tap_sel      = pixel_taps_in[pixel_id];
    assign pixel_metadata_sel = pixel_metadata_in[pixel_id];

    always_ff @(posedge clk or negedge n_rst) begin
        if (!n_rst)
            pixel_id <= 2'd0;
        else if (tmu_valid && pixel_done)
            pixel_id <= pixel_id + 2'd1; // Wraps: 0 -> 1 -> 2 -> 3 -> 0.
    end

endmodule

module mip_base_addr #(
    parameter int unsigned TEXEL_BYTES = cache_pkg::TEXEL_BYTES
) (
    input  cache_pkg::base_address_t base_info,
    output logic [31:0] mip_adjusted_base_addr
);
    logic [63:0] mip_offset_bytes;
    logic [63:0] full_base_addr;
    int unsigned level_log2_width;
    int unsigned level_log2_height;

    always_comb begin
        mip_offset_bytes  = 64'd0;
        level_log2_width  = 0;
        level_log2_height = 0;

        // Add the storage occupied by every preceding mip.
        // Fixed loop bound makes this combinational hardware.
        for (int level = 0; level < 31; level++) begin
            level_log2_width =
                (int'(base_info.mip_0_log2_width) > level)
                ? int'(base_info.mip_0_log2_width) - level : 0;

            level_log2_height =
                (int'(base_info.mip_0_log2_height) > level)
                ? int'(base_info.mip_0_log2_height) - level : 0;

            if (level < int'(base_info.mip_level))
                mip_offset_bytes = mip_offset_bytes
                    + (64'(TEXEL_BYTES)
                       << (level_log2_width + level_log2_height));
        end

        full_base_addr =
            {32'd0, base_info.base_addr} + mip_offset_bytes;

        mip_adjusted_base_addr = full_base_addr[31:0];
    end
endmodule
