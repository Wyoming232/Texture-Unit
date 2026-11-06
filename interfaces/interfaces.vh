`ifndef TEXTURE_UNIT_INTERFACES_VH
`define TEXTURE_UNIT_INTERFACES_VH
`include "packages/cache_pkg.sv"

// One transfer carries four pixels at one mip. Hold the complete payload
// stable until valid && ready; the frontend releases it after pixel 3 commits.
interface texture_cache_request_if;
    logic valid, ready;
    cache_pkg::texture_cache_request_t payload;

    modport sender (output valid, payload, input ready);
    modport receiver (input valid, payload, output ready);
    modport addr_calc (input valid, payload, output ready);
endinterface : texture_cache_request_if

// One transfer returns the whole quad requested by one texture_cache_request_if
// transfer, in request order. Hold payload stable until valid && ready.
// Owner (driver): hit_path_temp payload buffer. Consumer: TMU.
interface texture_cache_return_if;
    logic valid, ready;
    cache_pkg::texture_cache_return_t payload;

    modport sender (output valid, payload, input ready);
    modport receiver (input valid, payload, output ready);
endinterface : texture_cache_return_if

// Line-granular memory port used by the miss path (miss_path_simplified.png).
// Request: owner miss_path. req_id is the ROB slot that will receive the line.
//   req_valid = miss FIFO non-empty && ROB not full; hold until req_ready.
// Return: owner memory. rsp_id must be an id previously issued and not yet
//   returned; returns may arrive in any order. rsp_ready is always high today.
interface mem_if;
    logic req_valid, req_ready;
    logic [cache_pkg::ADDR_W-1:0] req_addr;
    logic [cache_pkg::ROB_ID_W-1:0] req_id;
    logic rsp_valid, rsp_ready;
    logic [cache_pkg::ROB_ID_W-1:0] rsp_id;
    logic [cache_pkg::LINE_BITS-1:0] rsp_data;

    modport cache (output req_valid, req_addr, req_id, rsp_ready,
                   input req_ready, rsp_valid, rsp_id, rsp_data);
    modport memory (input req_valid, req_addr, req_id, rsp_ready,
                    output req_ready, rsp_valid, rsp_id, rsp_data);
endinterface : mem_if

`include "interfaces/tag_array_if.sv"

// The original unscoped modport sketches are preserved verbatim in
// docs/legacy_interfaces.vh.txt. They were not legal standalone interfaces.
// Block-internal FIFO/ROB/refill connections are plain port lists inside
// miss_path / hit_path_temp; only cross-boundary channels are interfaces.
`endif
