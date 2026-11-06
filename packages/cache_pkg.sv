`timescale 1ns/1ps
`ifndef CACHE_PKG_SV
`define CACHE_PKG_SV
package cache_pkg;
    parameter integer ADDR_W=32;
    parameter integer CACHE_BYTES=16384;
    parameter integer LINE_BYTES=128;
    parameter integer WAYS=4;
    parameter integer BANKS=4;
    parameter integer LANES=4;
    parameter integer TEXEL_BYTES=8;
    parameter integer BATCH_ID_W=8;

    parameter integer MISS_REQ_DEPTH=32;
    
    localparam integer LINE_BITS=LINE_BYTES*8;
    localparam integer TEXEL_BITS=TEXEL_BYTES*8;
    localparam integer SETS_PER_BANK=CACHE_BYTES/(BANKS*WAYS*LINE_BYTES);
    localparam integer BANK_W=(BANKS>1)?$clog2(BANKS):1;
    localparam integer SET_W=(SETS_PER_BANK>1)?$clog2(SETS_PER_BANK):1;
    localparam integer WAY_W=(WAYS>1)?$clog2(WAYS):1;
    localparam integer OFFSET_W=(LINE_BYTES>1)?$clog2(LINE_BYTES):1;
    localparam integer INDEX_W=SET_W;
    localparam integer TAG_W=ADDR_W-OFFSET_W-BANK_W-SET_W;

    // ---------------------TMU REQUEST---------------------
    // Shared request declarations from the TMU/cache interface document.
    typedef enum logic [1:0] {
        FILTER_NEAREST   = 2'b00,
        FILTER_BILINEAR  = 2'b01,
        FILTER_TRILINEAR = 2'b10
    } filter_mode_e;

    // Mip-zero descriptor. base_addr is not adjusted to the selected mip.
    typedef struct packed {
        logic [16:0] reserved;
        logic [4:0]  max_mip_level;
        logic [4:0]  log2_height;
        logic [4:0]  log2_width;
        logic [31:0] base_addr;
    } texture_header_t;

    typedef struct packed {
        // discarded, only for base_addr calc
        texture_header_t texture_header;
        // discarded, only for base_addr calc
        logic [4:0] mip_level, log2_width, log2_height;
        // this gets converted into taps and returned
        logic [3:0][3:0][15:0] x, y;
        // Per-pixel bilinear fractions; each weight is encoded as value/256.
        logic [3:0][7:0] u_frac, v_frac;
        logic warp_id;
        logic [4:0] rd;
        logic [2:0] quad_index;
        filter_mode_e filter_mode;
        // Quad-wide trilinear fraction and lower(0)/upper(1) packet marker.
        logic [7:0] lod_fraction;
        logic upper_mip;
    } texture_cache_request_t;
    
    // ----------------------TMU REQUEST REORGANIZATION----------------------
    typedef struct packed {
        // texture_header_t sub signals
        logic [4:0]  mip_0_log2_height;
        logic [4:0]  mip_0_log2_width;
        logic [31:0] base_addr;
        // Actual selected mip and its dimensions, not mip-zero dimensions.
        // log2_width/log2_height drive the per-mip Morton swizzle in addr_calc.
        // max_mip_level is only range-checked in simulation (mip_base_addr).
        // OPEN QUESTION (Alec): can the TMU drop max_mip_level from the request?
        logic [4:0] mip_level;
        logic [4:0]  max_mip_level;
        logic [4:0] log2_width, log2_height;
    } base_address_t;

    typedef struct packed {
        // texture_header_t sub signals
        // Opaque pass-through bits shown on the TMU diagram; no cache decoding.
        logic [16:0] reserved;
        logic warp_id;
        logic [4:0] rd;
        logic [2:0] quad_index;
        // for bilinear and trilinear, this is just TMU metadata, but if nearest filtering
        // it actually affect cache_operation
        filter_mode_e filter_mode;
        logic [7:0] lod_fraction; // Quad-wide trilinear fraction
        logic upper_mip; //lower(0)/upper(1) packet marker.
    } tmu_quad_metadata_t;

    typedef struct packed {
        tmu_quad_metadata_t tmu_quad_metadata;
        logic [7:0] u_frac, v_frac;
    } tmu_pixel_metadata_t;

    typedef struct packed {
        logic [3:0][15:0] x;
        logic [3:0][15:0] y;
    } pixel_taps_t;

    // ----------------------ADDR CALC----------------------
    typedef struct packed {
        logic [31:0] byte_addr;
        logic [31:0] line_addr;
        logic [6:0]  offset;
        logic [1:0]  bank;
        logic [2:0]  index;
        logic [19:0] tag;
        logic addr_error; //might not need
    } addr_calc_out_t;

    // One unique line, with a mask in ORIGINAL tap order: c00,c10,c01,c11.
    // An all-zero tap_mask disables the group. Group slots are not compacted.
    // line_addr is a full byte address with its low OFFSET_W bits zero.
    // Bank/index/tag are decoded from it at the tag-array boundary.
    typedef struct packed {
        logic [ADDR_W-1:0] line_addr;
        logic [LANES-1:0] tap_mask;
    } coalesced_line_t;

    // ONE PIXEL at ONE MIP, containing up to four unique-line groups.
    // Metadata and offsets are stored once, rather than repeated per line.
    // tap_mask: taps requested by the filter mode (nearest 0001, else 1111),
    // in original tap order. lines[g].tap_mask is the per-group subset.
    typedef struct packed {
        logic [BATCH_ID_W-1:0] batch_id;
        logic [1:0] pixel_id;
        tmu_pixel_metadata_t pixel_metadata;
        logic [LANES-1:0] tap_mask;
        logic [LANES-1:0] addr_error;
        logic [LANES-1:0][OFFSET_W-1:0] offset;
        coalesced_line_t [LANES-1:0] lines;
    } coalesced_addr_out_t;

    // ----------------------TAG ARRAY----------------------
    // Only these fields are consumed by tag lookup/allocation.
    // valid disables empty groups; it is distinct from channel req_valid.
    // tap_mask is forwarded unchanged by tag_array as bank_tap_mask.
    typedef struct packed {
        logic valid;
        logic [LANES-1:0] tap_mask;
        logic [BANK_W-1:0] bank;
        logic [INDEX_W-1:0] index;
        logic [TAG_W-1:0] tag;
    } tag_lookup_t;

    typedef struct packed {
        // hit means an allocated matching tag, including a pending fill.
        logic hit;
        // ready means the matching line's data has arrived. Not channel ready.
        logic ready;
        // Preserve the existing field name: matching way on a hit, reserved
        // allocation way on a new miss. Valid for each completed active group.
        logic [WAY_W-1:0] hit_way;
    } tag_out_t;

    // ----------------------FRAGMENT FIFO----------------------
    parameter integer FRAG_DEPTH=32;
    parameter integer FRAG_WIDTH=5;

    typedef struct packed {
        logic [BATCH_ID_W-1:0] batch_id;
        logic [1:0] pixel_id;
        tmu_pixel_metadata_t pixel_metadata;
        logic [LANES-1:0] used;
        logic [LANES-1:0] hit;
        logic [LANES-1:0] data_ready;
        logic [LANES-1:0] addr_error;
        logic [LANES-1:0][BANK_W-1:0] bank;
        logic [LANES-1:0][INDEX_W-1:0] idx;
        logic [LANES-1:0][WAY_W-1:0] hit_way;
        logic [LANES-1:0][OFFSET_W-1:0] offset;
        // Full texel byte address, available for backend revalidation/replay.
        logic [LANES-1:0][ADDR_W-1:0] addr;
    } frag_data_t;
    typedef frag_data_t frag_entry_t;

    // ----------------------MISS REQUEST FIFO----------------------
    // Packed as {miss_addr, miss_way} by miss_request_fifo. No extra fields are
    // needed for coalescing: a second request to a pending line HITS the
    // reserved tag (hit=1, ready=0) and never produces a second miss, so the
    // miss stream holds no duplicate in-flight line addresses.
    typedef struct packed {
        logic [ADDR_W-1:0] line_addr;
        logic [WAY_W-1:0] miss_way;
    } miss_req_entry_t;

    // ----------------------ROB----------------------
    parameter integer ROB_DEPTH=32;
    // The memory transaction id is the ROB slot index (miss_path diagram: 5 bits).
    localparam integer ROB_ID_W=(ROB_DEPTH>1)?$clog2(ROB_DEPTH):1;
    // valid: allocated; completed: full memory line received.
    // way: tag-array way reserved for this line; refill writes exactly it.
    typedef struct packed {
        logic valid;
        logic completed;
        logic [ADDR_W-1:0] line_addr;
        logic [WAY_W-1:0] way;
        logic [LINE_BITS-1:0] data;
    } rob_entry_t;

    // ----------------------T$ -> TMU RETURN----------------------
    // One transfer returns one whole quad at one mip (same granularity as the
    // request). Quad metadata is sent once; per-pixel fractions are kept.
    // texel_valid = tap requested AND address valid. Texels of invalid taps
    // are returned as zero; addr_error reports which taps faulted.
    typedef struct packed {
        tmu_quad_metadata_t tmu_quad_metadata;
        logic [3:0][7:0] u_frac, v_frac;
        logic [3:0][LANES-1:0] texel_valid;
        logic [3:0][LANES-1:0] addr_error;
        logic [3:0][LANES-1:0][TEXEL_BITS-1:0] texels;
    } texture_cache_return_t;

    parameter LANES_W = 2;
    parameter MORTON_W = 4; //number of bits in one texel's slot in tile
    parameter INDEX = 3; //the set in the tag bank

    
endpackage : cache_pkg
`endif
