`include "packages/cache_pkg.sv"

import cache_pkg::*;

// Instantiated by hit_path_temp. base_addr is already mip-adjusted
// (mip_base_addr); log2_width/log2_height are the SELECTED mip's dimensions
// and select the Morton layout inside that mip (see addr_calc).
module address_calculation (
    // input logic clk,
    // input logic n_rst,
    // strictly combinational, these should not be necessary

    input logic [31:0] base_addr,
    input logic [4:0] log2_width, log2_height,
    input pixel_taps_t pixel_tap_sel,
    input tmu_pixel_metadata_t pixel_metadata_sel,

    // batch_id and pixel_id which allow us to unpack the FIFO entries correctly
    input logic [BATCH_ID_W-1:0] batch_id,
    input logic [1:0] pixel_id,
    
    output coalesced_addr_out_t coa_addr_out
);
    addr_calc_out_t addr0, addr1, addr2, addr3;
    // logic for TMU ready will be moved to t$ wrapper (currently hit_path_temp.sv)
    // logic ready_next;
    logic [3:0] used, addr_error;
    coalesced_line_t coa_addrs0, coa_addrs1, coa_addrs2, coa_addrs3;
    logic coalesce_0_1, coalesce_0_2, coalesce_0_3;
    logic coalesce_1_2, coalesce_1_3, coalesce_2_3;

    // ----------------ADDR_CALC----------------//
    addr_calc addr_calc_unit0 (.x(pixel_tap_sel.x[0]), .y(pixel_tap_sel.y[0]),
                              .log2_width(log2_width), .log2_height(log2_height),
                              .base_addr(base_addr), .addr_out(addr0));
    addr_calc addr_calc_unit1 (.x(pixel_tap_sel.x[1]), .y(pixel_tap_sel.y[1]),
                              .log2_width(log2_width), .log2_height(log2_height),
                              .base_addr(base_addr), .addr_out(addr1));
    addr_calc addr_calc_unit2 (.x(pixel_tap_sel.x[2]), .y(pixel_tap_sel.y[2]),
                              .log2_width(log2_width), .log2_height(log2_height),
                              .base_addr(base_addr), .addr_out(addr2));
    addr_calc addr_calc_unit3 (.x(pixel_tap_sel.x[3]), .y(pixel_tap_sel.y[3]),
                              .log2_width(log2_width), .log2_height(log2_height),
                              .base_addr(base_addr), .addr_out(addr3));
    
    // Nearest uses c00 only; bilinear and each trilinear mip use four taps.
    // The TMU must supply one of the three defined filter_mode_e values.
    assign used = (pixel_metadata_sel.tmu_quad_metadata.filter_mode
                   == FILTER_NEAREST) ? 4'b0001 : 4'b1111;
    assign addr_error = used & {addr3.addr_error, addr2.addr_error,
                               addr1.addr_error, addr0.addr_error};

    assign coalesce_0_1 = addr0.line_addr == addr1.line_addr;
    assign coalesce_0_2 = addr0.line_addr == addr2.line_addr;
    assign coalesce_0_3 = addr0.line_addr == addr3.line_addr;
    assign coalesce_1_2 = addr1.line_addr == addr2.line_addr;
    assign coalesce_1_3 = addr1.line_addr == addr3.line_addr;
    assign coalesce_2_3 = addr2.line_addr == addr3.line_addr;

    // ----------------COALESCER----------------//
    coalesced_addrs coalescer (
        .addr0(addr0), .addr1(addr1), .addr2(addr2), .addr3(addr3),
        .used(used & ~addr_error),
        .coa_0_1(coalesce_0_1), .coa_0_2(coalesce_0_2),
        .coa_0_3(coalesce_0_3), .coa_1_2(coalesce_1_2),
        .coa_1_3(coalesce_1_3), .coa_2_3(coalesce_2_3),
        .coa_addrs0(coa_addrs0), .coa_addrs1(coa_addrs1),
        .coa_addrs2(coa_addrs2), .coa_addrs3(coa_addrs3)
    );

    // single coalesced package
    always_comb begin
        coa_addr_out = '0;
        coa_addr_out.batch_id = batch_id;
        coa_addr_out.pixel_id = pixel_id;
        coa_addr_out.pixel_metadata = pixel_metadata_sel;
        coa_addr_out.tap_mask = used;
        coa_addr_out.addr_error = addr_error;
        coa_addr_out.offset = {addr3.offset, addr2.offset, addr1.offset, addr0.offset};
        coa_addr_out.lines = {coa_addrs3, coa_addrs2, coa_addrs1, coa_addrs0};
    end
endmodule

module addr_calc #(
    parameter int COORD_W = 16   // texel coordinate width supplied by the TMU
) (
    input  logic [COORD_W-1:0] x,
    input  logic [COORD_W-1:0] y,
    // Selected-mip dimensions: the mip is 2^log2_width x 2^log2_height texels.
    input  logic [4:0] log2_width,
    input  logic [4:0] log2_height,
    input  logic [31:0] base_addr,

    output addr_calc_out_t addr_out
);
    localparam int MORTON_BITS = 2*COORD_W;
    localparam int TEXEL_SHIFT = $clog2(cache_pkg::TEXEL_BYTES);
    localparam int SUM_W = ((MORTON_BITS+TEXEL_SHIFT > 32) ? MORTON_BITS+TEXEL_SHIFT : 32) + 1;

    logic [SUM_W-1:0] full_addr;
    logic [MORTON_BITS-1:0] morton_index;
    int unsigned lw, lh, sq;
    logic coord_error;

    // Morton (Z-order) index inside one 2^lw x 2^lh mip:
    //  - the low sq = min(lw, lh) bits of x and y are interleaved
    //    (x -> even bits, y -> odd bits), forming square Z-tiles;
    //  - the remaining (|lw-lh|) bits of the LONGER axis are appended above
    //    bit 2*sq, so successive square tiles are laid out along that axis.
    // For a square texture with lw = lh = COORD_W this is the plain 16/16
    // interleave used before. A mip occupies exactly 2^(lw+lh) texels, which
    // matches the per-level size summed by mip_base_addr.
    always_comb begin : morton_swizzle
        lw = (int'(log2_width)  > COORD_W) ? COORD_W : int'(log2_width);
        lh = (int'(log2_height) > COORD_W) ? COORD_W : int'(log2_height);
        sq = (lw < lh) ? lw : lh;
        morton_index = '0;
        for (int b = 0; b < COORD_W; b++) begin
            if (b < sq) begin
                morton_index[2*b]     = x[b];
                morton_index[2*b + 1] = y[b];
            end else if (b < lw && lw > lh) begin
                morton_index[sq + b] = x[b];
            end else if (b < lh && lh > lw) begin
                morton_index[sq + b] = y[b];
            end
        end
        // Coordinates must lie inside the selected mip, and the mip must be
        // addressable with COORD_W-bit coordinates.
        coord_error = (int'(log2_width) > COORD_W) || (int'(log2_height) > COORD_W);
        for (int b = 0; b < COORD_W; b++)
            if ((b >= lw && x[b]) || (b >= lh && y[b])) coord_error = 1'b1;
    end

    // This frontend retains the existing fixed 32-bit, 8-byte-texel geometry.
    assign full_addr = SUM_W'(base_addr) + (SUM_W'(morton_index) << TEXEL_SHIFT);
    assign addr_out.byte_addr = full_addr[31:0];
    assign addr_out.line_addr = {addr_out.byte_addr[31:7], 7'b0};
    assign addr_out.offset = addr_out.byte_addr[6:0];
    assign addr_out.bank = addr_out.byte_addr[8:7];
    assign addr_out.index = addr_out.byte_addr[11:9];
    assign addr_out.tag = addr_out.byte_addr[31:12];
    assign addr_out.addr_error = (|full_addr[SUM_W-1:32]) | (|base_addr[2:0]) | coord_error;

endmodule

module coalesced_addrs #()(
    input addr_calc_out_t addr0, addr1, addr2, addr3,
    input logic [3:0] used,
    input logic coa_0_1, coa_0_2, coa_0_3, coa_1_2, coa_1_3, coa_2_3,
    output coalesced_line_t coa_addrs0, coa_addrs1, coa_addrs2, coa_addrs3
);  
    // logic [5:0] coa_bus;

    // assign coa_bus = {coa_0_1, coa_0_2, coa_0_3, coa_1_2, coa_1_3, coa_2_3};

    // always_comb begin : coalescing
    //     // Request 0 always represents its line.
    //     coa_addrs0.line_addr = addr0.line_addr;
    //     coa_addrs0.valid0 = 1'b1;
    //     coa_addrs0.valid1 = coa_0_1;
    //     coa_addrs0.valid2 = coa_0_2;
    //     coa_addrs0.valid3 = coa_0_3;
    //     coa_addrs0.offset0 = addr0.offset;
    //     coa_addrs0.offset1 = addr1.offset;
    //     coa_addrs0.offset2 = addr2.offset;
    //     coa_addrs0.offset3 = addr3.offset;
    //     coa_addrs0.index = addr0.index;
    //     coa_addrs0.tag = addr0.tag;

    //     coa_addrs1.line_addr = addr1.line_addr;
    //     coa_addrs1.valid0 = 1'b0;

    //     // Request 1 represents its line only if it did not merge into 0.
    //     coa_addrs1.valid1 = !coa_0_1;
    //     coa_addrs1.valid2 = !coa_0_1 && coa_1_2;
    //     coa_addrs1.valid3 = !coa_0_1 && coa_1_3;
    //     coa_addrs1.offset0 = addr0.offset;
    //     coa_addrs1.offset1 = addr1.offset;
    //     coa_addrs1.offset2 = addr2.offset;
    //     coa_addrs1.offset3 = addr3.offset;
    //     coa_addrs1.index = addr1.index;
    //     coa_addrs1.tag = addr1.tag;

    //     coa_addrs2.line_addr = addr2.line_addr;
    //     coa_addrs2.valid0 = 1'b0;
    //     coa_addrs2.valid1 = 1'b0;
        
    //     // Request 2 represents its line only if neither earlier request matches.
    //     coa_addrs2.valid2 = !(coa_0_2 || coa_1_2);
    //     coa_addrs2.valid3 = !(coa_0_2 || coa_1_2) && coa_2_3;
    //     coa_addrs2.offset0 = addr0.offset;
    //     coa_addrs2.offset1 = addr1.offset;
    //     coa_addrs2.offset2 = addr2.offset;
    //     coa_addrs2.offset3 = addr3.offset;
    //     coa_addrs2.index = addr2.index;
    //     coa_addrs2.tag = addr2.tag;

    //     coa_addrs3.line_addr = addr3.line_addr;
    //     coa_addrs3.valid0 = 1'b0;
    //     coa_addrs3.valid1 = 1'b0;
    //     coa_addrs3.valid2 = 1'b0;

    //     // Request 3 survives only if none of the earlier requests matches.
    //     coa_addrs3.valid3 = !(coa_0_3 || coa_1_3 || coa_2_3);
    //     coa_addrs3.offset0 = addr0.offset;
    //     coa_addrs3.offset1 = addr1.offset;
    //     coa_addrs3.offset2 = addr2.offset;
    //     coa_addrs3.offset3 = addr3.offset;
    //     coa_addrs3.index = addr3.index;
    //     coa_addrs3.tag = addr3.tag;
    // end

    always_comb begin
        coa_addrs0 = '0;
        coa_addrs1 = '0;
        coa_addrs2 = '0;
        coa_addrs3 = '0;
        coa_addrs0.line_addr = addr0.line_addr;
        coa_addrs1.line_addr = addr1.line_addr;
        coa_addrs2.line_addr = addr2.line_addr;
        coa_addrs3.line_addr = addr3.line_addr;

        if (used[0]) begin
            coa_addrs0.tap_mask[0] = 1'b1;
            coa_addrs0.tap_mask[1] = used[1] && coa_0_1;
            coa_addrs0.tap_mask[2] = used[2] && coa_0_2;
            coa_addrs0.tap_mask[3] = used[3] && coa_0_3;
        end
        if (used[1] && !(used[0] && coa_0_1)) begin
            coa_addrs1.tap_mask[1] = 1'b1;
            coa_addrs1.tap_mask[2] = used[2] && coa_1_2;
            coa_addrs1.tap_mask[3] = used[3] && coa_1_3;
        end
        if (used[2] && !(used[0] && coa_0_2) && !(used[1] && coa_1_2)) begin
            coa_addrs2.tap_mask[2] = 1'b1;
            coa_addrs2.tap_mask[3] = used[3] && coa_2_3;
        end
        if (used[3] && !(used[0] && coa_0_3) && !(used[1] && coa_1_3)
                    && !(used[2] && coa_2_3))
            coa_addrs3.tap_mask[3] = 1'b1;
    end
endmodule