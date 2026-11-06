`include "interfaces/interfaces.vh"
`include "packages/cache_pkg.sv"
`include "src/address_calculation.sv"
`include "src/tag_array.sv"
`include "src/data_array.sv"
`include "src/frag_fifo.sv"

// TODO : does not compile yet: struct literals use '=' / ';' instead of ':' / ',',
// base_addr is declared 1-bit, tmu_req.* fields must go through tmu_req.payload.
// this module is a wrapper containing address_calculation
module hit_path_temp (
    input logic clk, n_rst,
    // payload
    texture_cache_request_if.addr_calc tmu_req,
    // handshake signals
    input logic tmu_valid,
    output logic tcache_ready

    // TODO : RETURN IO
);

    // ----------------TMU->T$ SIGNAL REORGANIZATION----------------//
    // STARTING ADDRESS CALCULATION
    base_address_t base_info;
    always_comb begin : tmu_req_base_info
        base_info = '{
            mip_0_log2_height : tmu_req.texture_header.log2_height,
            mip_0_log2_width : tmu_req.texture_header.log2_width,
            max_mip_level : tmu_req.texture_header.max_mip_level,
            base_addr : tmu_req.texture_header.base_addr,
            mip_level : tmu_req.mip_level,
            log2_width: tmu_req.log2_width,
            log2_height: tmu_req.log2_height,
            default : '0
        };
    end
    logic base_addr;
    mip_base_addr base_addr_calc (.base_info(base_info), .mip_adjusted_base_addr(base_addr));

    // QUAD SPECIFIC FRAGMENT INFO; NO CONSUMPTION / PASS THROUGH
    tmu_quad_metadata_t tmu_quad_info;
    always_comb begin : tmu_req_quad_info
        tmu_quad_info = '{
            warp_id : tmu_req.warp_id,
            rd : tmu_req.rd,
            quad_index : tmu_req.quad_index,
            filter_mode : tmu_req.filter_mode,
            lod_fraction : tmu_req.lod_fraction,
            upper_mip : tmu_req.upper_mip,
            default : '0
        };
    end

    // PIXEL SPECIFIC FRAGMENT INFO; NO CONSUMPTION / PASS THROUGH
    tmu_pixel_metadata_t [3:0] tmu_pixel_info;
    always_comb begin : tmu_req_pixel_info
        tmu_pixel_info[0] = '{
            tmu_quad_metadata : tmu_quad_info,
            u_frac = tmu_req.u_frac[0];
            v_frac = tmu_req.u_frac[0];
            default : '0
        };
        tmu_pixel_info[1] = '{
            tmu_quad_metadata : tmu_quad_info,
            u_frac = tmu_req.u_frac[1];
            v_frac = tmu_req.u_frac[1];
            default : '0
        };
        tmu_pixel_info[2] = '{
            tmu_quad_metadata : tmu_quad_info,
            u_frac = tmu_req.u_frac[2];
            v_frac = tmu_req.u_frac[2];
            default : '0
        };
        tmu_pixel_info[3] = '{
            tmu_quad_metadata : tmu_quad_info,
            u_frac = tmu_req.u_frac[3];
            v_frac = tmu_req.u_frac[3];
            default : '0
        };
    end

    // TEXEL REQUEST INFO
    pixel_taps_t [3:0] pixel_taps;
    always_comb begin : tmu_req_pixel_taps
        pixel_taps[0] = '{
            x = tmu_req.x[0];
            y = tmu_req.y[0];
            default: '0
        };
        pixel_taps[1] = '{
            x = tmu_req.x[1];
            y = tmu_req.y[1];
            default: '0
        };
        pixel_taps[2] = '{
            x = tmu_req.x[2];
            y = tmu_req.y[2];
            default: '0
        };
        pixel_taps[3] = '{
            x = tmu_req.x[3];
            y = tmu_req.y[3];
            default: '0
        };
    end

    // ----------------ADDRESS_CALCULATION----------------//
    pixel_taps_t [3:0] pixel_taps_in;
    tmu_pixel_metadata_t [3:0] pixel_metadata_in;
    logic pixel_done;
    logic [1:0] pixel_id;
    // selected pixels taps and metadata
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;

    assign pixel_taps_in = pixel_taps;
    assign pixel_metadata_in = tmu_pixel_info;

    // TODO : Drive pixel_done from tag-array and Fragment FIFO completion.
    round_robin_arbiter arbiter (.*);

    // TODO : address calculation wrapper instantiation


    // ----------------TAG ARRAY----------------//
    // TODO : TMU HANDSHAKE SIGNALS AND LOGIC
    // TAG ARRAY INPUT 

    // ----------------FRAGMENT FIFO----------------//
    // TODO : TMU HANDSHAKE SIGNALS AND LOGIC
    // FRAGMENT ENTRY PREPARATION BUFFER


    // ----------------DATA ARRAY----------------//
    // TODO : TMU HANDSHAKE SIGNALS AND LOGIC
    // DATA ARRAY READ LOGIC
    // PAYLOAD PREPARATION BUFFER
    


endmodule

module round_robin_arbiter (
    input  logic clk,
    input  logic n_rst,

    // // TMU holds the entire quad stable until tmu_valid && tmu_ready.
    input  logic tmu_valid,
    // output logic tmu_ready,

    // // [pixel][tap][bit]; taps: c00, c10, c01, c11.
    // input  logic [3:0][3:0][15:0] x_in,
    // input  logic [3:0][3:0][15:0] y_in,
    input pixel_taps_t [3:0] pixel_taps_in;

    // TODO : make this pass through address calculation wrapper
    input tmu_pixel_info [3:0] pixel_metadata_in;

    // // Address calculation wrapper handshake.
    // output logic addr_valid,
    // input  logic addr_ready,

    // TODO : Write logic for this in HIT_PATH_TEMP
    input logic pixel_done,

    // Selected pixel and its four taps.
    output logic [1:0]       pixel_id,

    // output logic [3:0][15:0] x_out,
    // output logic [3:0][15:0] y_out,
    output pixel_taps_t pixel_tap_sel,

    // output logic [7:0]       u_frac_out,
    // output logic [7:0]       v_frac_out
    output tmu_pixel_info [3:0] pixel_metadata_sel
);

    assign pixel_taps_sel      = pixel_taps_in[pixel_id];
    assign pixel_metadata_sel  = pixel_metadata_in[pixel_id];

    // assign addr_valid = tmu_valid;

    // TODO : MOVE THIS TO THE HIT_PATH_TEMP
    // Release the TMU's quad only when pixel 3 is accepted.
    // assign tmu_ready = (pixel_id == 2'd3) && pixel_done;

    always_ff @(posedge clk or negedge n_rst) begin
        if (!n_rst)
            pixel_id <= 2'd0;
            // TODO : pixel done logic in HIT_PATH PAGE
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