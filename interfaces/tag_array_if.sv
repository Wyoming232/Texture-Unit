`ifndef TAG_ARRAY_IF_SV
`define TAG_ARRAY_IF_SV
`include "packages/cache_pkg.sv"

// One request is one pixel's up-to-four UNIQUE lines, not four banks.
// Same-bank groups must be serialized internally and returned in group order.
interface tag_array_if;
    logic req_valid, req_ready;
    cache_pkg::tag_lookup_t [cache_pkg::LANES-1:0] req;

    // Assert only when every active group is resolved AND all new miss work
    // has been retained through the miss channel (or owned downstream staging).
    // Hold rsp and rsp_valid
    // stable until rsp_ready. rsp[i] corresponds to req[i], even after bank
    // arbitration. hit=1,ready=0 is a pending-line match, not a new miss.
    // Capture the original outcome: allocating a new tag must not change its
    // response from hit=0 to hit=1 before the miss request is retained.
    logic rsp_valid, rsp_ready;
    cache_pkg::tag_out_t [cache_pkg::LANES-1:0] rsp;

    // Stream one newly allocated line to the miss path at a time, including
    // while other groups of this pixel still wait for a bank/set. Each tag
    // reservation must have a retained miss descriptor. Do not wait for the
    // whole pixel to finish before sending these requests: that can deadlock
    // if an unfinished lookup waits for a refill of an earlier reservation.
    // miss_addr is reconstructed as {tag,index,bank,{OFFSET_W{1'b0}}}.
    // Keep the reserved way with the request through refill bookkeeping.
    logic miss_valid, miss_ready;
    logic [cache_pkg::ADDR_W-1:0] miss_addr;
    logic [cache_pkg::WAY_W-1:0] miss_way;

    // The lookup engine reserves a way/tag for each accepted new miss. Refill
    // marks that exact bank/set/way ready only when its data write is accepted.
    // No fill tag is needed under this reservation contract.
    logic fill_en, fill_ready;
    logic [cache_pkg::BANK_W-1:0] fill_bank;
    logic [cache_pkg::INDEX_W-1:0] fill_idx;
    logic [cache_pkg::WAY_W-1:0] fill_way;

    modport frontend (
        output req_valid, req, rsp_ready,
        input req_ready, rsp_valid, rsp
    );

    modport refill (
        output fill_en, fill_bank, fill_idx, fill_way,
        input fill_ready
    );

    modport miss_path (
        input miss_valid, miss_addr, miss_way,
        output miss_ready
    );

    modport tag_array (
        input req_valid, req, rsp_ready, miss_ready,
              fill_en, fill_bank, fill_idx, fill_way,
        output req_ready, rsp_valid, rsp, fill_ready,
               miss_valid, miss_addr, miss_way
    );
endinterface : tag_array_if
`endif
