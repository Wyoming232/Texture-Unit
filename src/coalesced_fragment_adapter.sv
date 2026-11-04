`include "packages/cache_pkg.sv"

// Pure payload conversion. The coordinator qualifies tag_req with req_valid
// and qualifies frag_in with the COMPLETE tag response and atomic commit.
// No FIFO push, tag allocation, bank arbitration, or state is hidden here.
module coalesced_fragment_adapter (
    input cache_pkg::coalesced_addr_out_t coa_addr_out,
    input cache_pkg::tag_out_t [cache_pkg::LANES-1:0] tag_result,
    output cache_pkg::tag_lookup_t [cache_pkg::LANES-1:0] tag_req,
    output cache_pkg::frag_data_t frag_in
);
    import cache_pkg::*;
    always_comb begin
        tag_req = '0;
        frag_in = '0;
        frag_in.batch_id = coa_addr_out.batch_id;
        frag_in.pixel_id = coa_addr_out.pixel_id;
        frag_in.pixel_metadata = coa_addr_out.pixel_metadata;
        frag_in.used = coa_addr_out.used;
        frag_in.addr_error = coa_addr_out.addr_error;
        frag_in.offset = coa_addr_out.offset;

        for (int group = 0; group < LANES; group++) begin
            // An address fault rejects the whole pixel before any tag work.
            tag_req[group].valid = (|coa_addr_out.lines[group].tap_mask)
                                   && !(|coa_addr_out.addr_error);
            tag_req[group].bank =
                coa_addr_out.lines[group].line_addr[OFFSET_W +: BANK_W];
            tag_req[group].index =
                coa_addr_out.lines[group].line_addr[OFFSET_W+BANK_W +: INDEX_W];
            tag_req[group].tag =
                coa_addr_out.lines[group].line_addr[ADDR_W-1 -: TAG_W];

            for (int tap = 0; tap < LANES; tap++) begin
                if (coa_addr_out.lines[group].tap_mask[tap]) begin
                    frag_in.bank[tap] = tag_req[group].bank;
                    frag_in.idx[tap] = tag_req[group].index;
                    frag_in.addr[tap] = coa_addr_out.lines[group].line_addr
                                       | ADDR_W'(coa_addr_out.offset[tap]);
                    frag_in.hit[tap] = tag_result[group].hit;
                    frag_in.data_ready[tap] = tag_result[group].hit
                                             && tag_result[group].ready;
                    frag_in.hit_way[tap] = tag_result[group].hit_way;
                end
            end
        end
    end
endmodule