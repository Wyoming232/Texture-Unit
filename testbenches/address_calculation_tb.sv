/* Notes for TB
    Combinational block
    Inputs are driven like they would be through the TMU 
    TB will be reused once address calculation is added to the hit path, after which arbitration will be tested
    Testing address calc and coalescing (single pixel, 4 taps)
    
    send 4 taps, generate 4 addrs, coalesce into 1

    Batch_id, pixel_id, pixel_metadata just need to be saved for Frag entry

    Testcases (test functionality of each signal)
    Addr gen
    | What to test | `base_addr` | Tap coordinates `(x,y)` | Expected byte address / result |
    |---|---|---|---|
    | Zero | `0` | `(0,0)` | `0x00000000` |
    | X/Y interleaving | `0` | `(1,0)`; `(0,1)` | `0x08`; `0x10` |
    | Largest aligned offset within a line | `0` | `(3,3)` | `0x78`, offset = 120 |
    | All four banks | `0` | `(0,0)`; `(4,0)`; `(0,4)`; `(4,4)` | `0x000`; `0x080`; `0x100`; `0x180` → banks 0–3 |
    | Index boundary | `0` | `(7,7)`; `(8,0)` | `0x1F8`; `0x200` → index 0 then 1 |
    | Tag boundary | `0` | `(31,15)`; `(0,16)` | `0xFF8`; `0x1000` → tag 0 then 1 |
    | Base addition carrying into the next line | `0x78` | `(1,0)` | `0x80`, offset = 0 |
    | Largest valid byte address | `0` | `(0x7FFF,0x3FFF)` | `0xFFFFFFF8`, no error |
    | Coordinate-caused overflow | `0` | `(0,0x4000)`; `(0x8000,0)` | Error for each |
    | Base-addition overflow | `0xFFFFFFF8` | `(0,0)`; `(1,0)` | First valid; second errors |
    | Misaligned base | `1`, `2`, `4`, `7` | `(0,0)` | Error for each |
    (all rows above use a full 16/16 mip: log2_width = log2_height = 16)

    Mip-aware Morton (selected-mip log2_width/log2_height)
    | What to test | dims (w x h) | Tap `(x,y)` | Expected byte address / result |
    |---|---|---|---|
    | Diagram mip 0 (4x4) | 4x4 | `(0,1)`; `(2,0)`; `(0,2)`; `(3,3)` | texel 2, 4, 8, 15 -> `0x10`; `0x20`; `0x40`; `0x78` |
    | Wide (8x2): x bits above the square part are appended | 8x2 | `(5,1)` | texel 0b1011 = 11 -> `0x58` |
    | Tall (2x8): y bits appended | 2x8 | `(1,5)` | texel 0b1011 = 11 -> `0x58` |
    | 1x1 mip | 1x1 | `(0,0)` | `base` |
    | Coordinate outside mip | 8x2 | `(8,0)`; `(0,2)` | Error for each |
    | Mip wider than 16-bit coordinates | 2^17 x 1 | `(0,0)` | Error |
    | Random dims 0..16, in-range coordinates, random aligned base | | | matches morton_ref |
    
    Coalescing (lines 0, 1, 2, 3)
    - no coalescing
    - 2, 3 coalesce
    - 1, 3 coalesce
    - 1, 2 coalesce
    - 1, 2, 3 coalesce
    - 0, 1 coalesce
    - 0, 2 coalesce
    - 0, 3 coalesce
    - 0, 1 coalesce, 2, 3 coalesce
    - 0, 2 coalesce, 1, 3 coalesce
    - 0, 3 coalesce, 1, 2 coalesce
    - 0, 1, 2 coalesce
    - 0, 1, 3 coalesce
    - 0, 2, 3 coalesce
    - 0, 1, 2, 3 coalesce

    Additional testcases (added, to be reviewed; NOT implemented below)
    Addr gen
    | What to test | `base_addr` | Tap coordinates `(x,y)` | Expected byte address / result |
    |---|---|---|---|
    | Non-zero aligned base, bank/index/tag split preserved | `0x12345000` | `(4,4)` | `0x12345180` → bank 3, index 0, tag 0x12345 |
    | Base misaligned AND coordinate overflow | `1` | `(0x8000,0)` | Error (both causes at once, only one addr_error bit per tap) |
    | Top-bit coordinates together | `0` | `(0x7FFF,0x3FFF)` with `base_addr = 8` | `0x00000000` carry wraps → error |
    Coalescing / packaging
    - nearest filtering: used = 0001, only group 0 active even when taps 1..3 share the line of tap 0
    - nearest filtering: taps 1..3 hold overflowing coordinates → no addr_error (inactive taps must not fault)
    - bilinear: one tap errors → that tap is removed from `used & ~addr_error` so it joins NO group, other taps still coalesce
    - bilinear: all four taps error → all tap_masks zero, addr_error = 1111
    - two taps on same line but different offsets → one group, offset[] still per-tap
    - taps on same index, different bank → NOT coalesced (line_addr differs in bank bits)
    - taps on same bank/index, different tag → NOT coalesced
    - batch_id / pixel_id / pixel_metadata pass through unchanged for every pattern
*/

`timescale 1ns/1ps
`include "interfaces/interfaces.vh"
`include "src/address_calculation.sv"

module address_calculation_tb;
    import cache_pkg::*;

    // --------------------------- DUT: full pixel path ---------------------------
    logic [31:0] base_addr;
    logic [4:0] log2_width, log2_height;
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;
    logic [BATCH_ID_W-1:0] batch_id;
    logic [1:0] pixel_id;
    coalesced_addr_out_t coa_addr_out;

    address_calculation dut (.*);

    // --------------------------- DUT: single addr_calc ---------------------------
    logic [15:0] ac_x, ac_y;
    logic [4:0] ac_lw = 5'd16, ac_lh = 5'd16;
    logic [31:0] ac_base;
    addr_calc_out_t ac_out;
    addr_calc single (.x(ac_x), .y(ac_y), .log2_width(ac_lw), .log2_height(ac_lh),
                      .base_addr(ac_base), .addr_out(ac_out));

    int errors = 0;
    int checks = 0;

    // ------------------------------- ADDR GEN -------------------------------
    // Drives one tap through a standalone addr_calc and checks every decoded
    // field against the byte address given in the table above.
    task automatic check_addr(input string name, input logic [31:0] base,
                              input logic [15:0] x, y,
                              input logic [31:0] exp_byte, input bit exp_err);
        ac_base = base; ac_x = x; ac_y = y;
        #1;
        checks++;
        if (ac_out.addr_error !== exp_err) begin
            errors++;
            $error("[%s] addr_error=%0b expected %0b", name, ac_out.addr_error, exp_err);
        end
        if (!exp_err) begin
            if (ac_out.byte_addr !== exp_byte ||
                ac_out.line_addr !== {exp_byte[31:7], 7'b0} ||
                ac_out.offset !== exp_byte[6:0] ||
                ac_out.bank !== exp_byte[8:7] ||
                ac_out.index !== exp_byte[11:9] ||
                ac_out.tag !== exp_byte[31:12]) begin
                errors++;
                $error("[%s] byte=%h line=%h off=%0d bank=%0d idx=%0d tag=%h (expected byte %h)",
                       name, ac_out.byte_addr, ac_out.line_addr, ac_out.offset,
                       ac_out.bank, ac_out.index, ac_out.tag, exp_byte);
            end
        end
    endtask

    // Independent reference: walk the coordinate bits from LSB up and append
    // x then y while each axis still has bits in the mip. This yields the
    // square interleave for b < min(lw,lh) and appends the longer axis above.
    function automatic logic [35:0] morton_ref(input logic [15:0] x, y, input int lw, lh);
        logic [35:0] idx = '0;
        int pos = 0;
        for (int b = 0; b < 16; b++) begin
            if (b < lw) begin idx[pos] = x[b]; pos++; end
            if (b < lh) begin idx[pos] = y[b]; pos++; end
        end
        return idx;
    endfunction

    task automatic check_mip_addr(input string name, input int lw, lh,
                                  input logic [31:0] base, input logic [15:0] x, y,
                                  input bit exp_err);
        logic [35:0] full;
        ac_lw = 5'(lw); ac_lh = 5'(lh);
        full = {4'b0, base} + (morton_ref(x, y, lw, lh) << 3);
        // A carry past bit 31 is an error even for in-range coordinates.
        check_addr(name, base, x, y, full[31:0], exp_err || (|full[35:32]));
        ac_lw = 5'd16; ac_lh = 5'd16;
    endtask

    // ------------------------------- COALESCING -------------------------------
    // line_sel[tap] picks one of four distinct lines for that tap. Low x bits
    // carry the tap number so taps on the same line still get distinct offsets.
    // x bit 2 -> byte 128 (line 1), x bit 3 -> byte 512 (line 4): both move the
    // line address, so line_sel k maps to a unique line for k = 0..3.
    function automatic logic [3:0] expected_group_mask(input int line_sel [4],
                                                       input logic [3:0] used,
                                                       input int group);
        logic [3:0] mask = '0;
        int first;
        for (int tap = 0; tap < 4; tap++) begin
            if (!used[tap]) continue;
            first = -1;
            for (int cand = 0; cand < 4; cand++)
                if (used[cand] && first < 0 && line_sel[cand] == line_sel[tap])
                    first = cand;
            if (first == group) mask[tap] = 1'b1;
        end
        return mask;
    endfunction

    task automatic check_coalesce(input string name, input int line_sel [4]);
        logic [3:0] exp_mask, seen;
        logic [31:0] exp_line [4];
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        for (int tap = 0; tap < 4; tap++) begin
            pixel_tap_sel.x[tap] = 16'((line_sel[tap] << 2) | tap);
            pixel_tap_sel.y[tap] = 16'(0);
        end
        #1;
        checks++;
        for (int tap = 0; tap < 4; tap++) begin
            // Morton: x[0]->bit3, x[1]->bit5, x[2]->bit7, x[3]->bit9 of byte addr
            exp_line[tap] = 32'((((line_sel[tap] & 1) != 0) ? 128 : 0) +
                                (((line_sel[tap] & 2) != 0) ? 512 : 0)) + base_addr;
            exp_line[tap] = {exp_line[tap][31:7], 7'b0};
        end
        if (coa_addr_out.tap_mask !== 4'b1111 || coa_addr_out.addr_error !== 4'b0000) begin
            errors++;
            $error("[%s] tap_mask=%b addr_error=%b", name, coa_addr_out.tap_mask, coa_addr_out.addr_error);
        end
        seen = '0;
        for (int group = 0; group < 4; group++) begin
            exp_mask = expected_group_mask(line_sel, 4'b1111, group);
            if (coa_addr_out.lines[group].tap_mask !== exp_mask) begin
                errors++;
                $error("[%s] group %0d tap_mask=%b expected %b", name, group,
                       coa_addr_out.lines[group].tap_mask, exp_mask);
            end
            if (coa_addr_out.lines[group].line_addr !== exp_line[group]) begin
                errors++;
                $error("[%s] group %0d line_addr=%h expected %h", name, group,
                       coa_addr_out.lines[group].line_addr, exp_line[group]);
            end
            if ((seen & exp_mask) != 0) begin
                errors++;
                $error("[%s] tap assigned to more than one group", name);
            end
            seen |= coa_addr_out.lines[group].tap_mask;
        end
        if (seen !== 4'b1111) begin
            errors++;
            $error("[%s] taps lost in coalescing: seen=%b", name, seen);
        end
        // Offsets are stored per tap regardless of grouping.
        for (int tap = 0; tap < 4; tap++)
            if (coa_addr_out.offset[tap] !== 7'((tap & 1) * 8 + ((tap >> 1) & 1) * 32)) begin
                errors++;
                $error("[%s] offset[%0d]=%0d", name, tap, coa_addr_out.offset[tap]);
            end
        // Metadata must be passed through untouched.
        if (coa_addr_out.batch_id !== batch_id || coa_addr_out.pixel_id !== pixel_id ||
            coa_addr_out.pixel_metadata !== pixel_metadata_sel) begin
            errors++;
            $error("[%s] metadata was lost", name);
        end
    endtask

    initial begin
        // Fixed metadata for the fragment entry
        base_addr = '0;
        log2_width = 5'd16;
        log2_height = 5'd16;
        batch_id = 8'h3C;
        pixel_id = 2'd1;
        pixel_tap_sel = '0;
        pixel_metadata_sel = '0;
        pixel_metadata_sel.tmu_quad_metadata.warp_id = 1'b1;
        pixel_metadata_sel.tmu_quad_metadata.rd = 5'd17;
        pixel_metadata_sel.tmu_quad_metadata.quad_index = 3'd6;
        pixel_metadata_sel.tmu_quad_metadata.lod_fraction = 8'h5A;
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        pixel_metadata_sel.u_frac = 8'h11;
        pixel_metadata_sel.v_frac = 8'hEE;

        // ---------------- Addr gen table ----------------
        check_addr("zero",            32'h0,        16'd0, 16'd0, 32'h00000000, 0);
        check_addr("interleave x",    32'h0,        16'd1, 16'd0, 32'h00000008, 0);
        check_addr("interleave y",    32'h0,        16'd0, 16'd1, 32'h00000010, 0);
        check_addr("max line offset", 32'h0,        16'd3, 16'd3, 32'h00000078, 0);
        check_addr("bank 0",          32'h0,        16'd0, 16'd0, 32'h00000000, 0);
        check_addr("bank 1",          32'h0,        16'd4, 16'd0, 32'h00000080, 0);
        check_addr("bank 2",          32'h0,        16'd0, 16'd4, 32'h00000100, 0);
        check_addr("bank 3",          32'h0,        16'd4, 16'd4, 32'h00000180, 0);
        check_addr("index 0 top",     32'h0,        16'd7, 16'd7, 32'h000001F8, 0);
        check_addr("index 1",         32'h0,        16'd8, 16'd0, 32'h00000200, 0);
        check_addr("tag 0 top",       32'h0,        16'd31, 16'd15, 32'h00000FF8, 0);
        check_addr("tag 1",           32'h0,        16'd0, 16'd16, 32'h00001000, 0);
        check_addr("base carry",      32'h78,       16'd1, 16'd0, 32'h00000080, 0);
        check_addr("largest valid",   32'h0,        16'h7FFF, 16'h3FFF, 32'hFFFFFFF8, 0);
        check_addr("y overflow",      32'h0,        16'd0, 16'h4000, 32'h0, 1);
        check_addr("x overflow",      32'h0,        16'h8000, 16'd0, 32'h0, 1);
        check_addr("base ovf ok",     32'hFFFFFFF8, 16'd0, 16'd0, 32'hFFFFFFF8, 0);
        check_addr("base ovf err",    32'hFFFFFFF8, 16'd1, 16'd0, 32'h0, 1);
        check_addr("misaligned 1",    32'h1, 16'd0, 16'd0, 32'h0, 1);
        check_addr("misaligned 2",    32'h2, 16'd0, 16'd0, 32'h0, 1);
        check_addr("misaligned 4",    32'h4, 16'd0, 16'd0, 32'h0, 1);
        check_addr("misaligned 7",    32'h7, 16'd0, 16'd0, 32'h0, 1);

        // ---------------- Mip-aware Morton ----------------
        ac_lw = 5'd2; ac_lh = 5'd2;
        check_addr("4x4 (0,1)",       32'h0, 16'd0, 16'd1, 32'h10, 0);
        check_addr("4x4 (2,0)",       32'h0, 16'd2, 16'd0, 32'h20, 0);
        check_addr("4x4 (0,2)",       32'h0, 16'd0, 16'd2, 32'h40, 0);
        check_addr("4x4 (3,3)",       32'h0, 16'd3, 16'd3, 32'h78, 0);
        ac_lw = 5'd3; ac_lh = 5'd1;
        check_addr("8x2 (5,1)",       32'h0, 16'd5, 16'd1, 32'h58, 0);
        check_addr("8x2 x out",       32'h0, 16'd8, 16'd0, 32'h0, 1);
        check_addr("8x2 y out",       32'h0, 16'd0, 16'd2, 32'h0, 1);
        ac_lw = 5'd1; ac_lh = 5'd3;
        check_addr("2x8 (1,5)",       32'h0, 16'd1, 16'd5, 32'h58, 0);
        ac_lw = 5'd0; ac_lh = 5'd0;
        check_addr("1x1",             32'h40, 16'd0, 16'd0, 32'h40, 0);
        ac_lw = 5'd17; ac_lh = 5'd0;
        check_addr("dims > 16 bits",  32'h0, 16'd0, 16'd0, 32'h0, 1);
        ac_lw = 5'd16; ac_lh = 5'd16;
        for (int i = 0; i < 2000; i++) begin
            int lw, lh;
            logic [15:0] rx, ry;
            lw = $urandom_range(16); lh = $urandom_range(16);
            rx = 16'($urandom) & 16'((32'd1 << lw) - 1);
            ry = 16'($urandom) & 16'((32'd1 << lh) - 1);
            // keep base + texture inside 32 bits: base < 2^31, texture < 2^30 for lw+lh <= 27
            check_mip_addr("random mip", lw, lh,
                           (lw + lh <= 27) ? {1'b0, 28'($urandom), 3'b0} : 32'h0, rx, ry, 0);
        end

        // ---------------- Coalescing ----------------
        // line_sel per tap; equal values share a line.
        check_coalesce("none",           '{0, 1, 2, 3});
        check_coalesce("2,3",            '{0, 1, 2, 2});
        check_coalesce("1,3",            '{0, 1, 2, 1});
        check_coalesce("1,2",            '{0, 1, 1, 3});
        check_coalesce("1,2,3",          '{0, 1, 1, 1});
        check_coalesce("0,1",            '{0, 0, 2, 3});
        check_coalesce("0,2",            '{0, 1, 0, 3});
        check_coalesce("0,3",            '{0, 1, 2, 0});
        check_coalesce("0,1 + 2,3",      '{0, 0, 2, 2});
        check_coalesce("0,2 + 1,3",      '{0, 1, 0, 1});
        check_coalesce("0,3 + 1,2",      '{0, 1, 1, 0});
        check_coalesce("0,1,2",          '{0, 0, 0, 3});
        check_coalesce("0,1,3",          '{0, 0, 2, 0});
        check_coalesce("0,2,3",          '{0, 1, 0, 0});
        check_coalesce("0,1,2,3",        '{0, 0, 0, 0});

        if (errors == 0)
            $display("PASS address_calculation_tb: %0d checks", checks);
        else
            $fatal(1, "FAIL address_calculation_tb: %0d errors in %0d checks", errors, checks);
        $finish;
    end
endmodule
