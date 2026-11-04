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

`include "interfaces/tag_array_if.sv"

// The original unscoped modport sketches are preserved verbatim in
// docs/legacy_interfaces.vh.txt. They were not legal standalone interfaces.
// TODO: define the remaining FIFO/ROB/controller interfaces with their owners.
`endif
