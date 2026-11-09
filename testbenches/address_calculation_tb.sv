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
`include "src/address_calculation.sv"

module address_calculation_tb;
    import cache_pkg::*;

    logic [31:0] base_addr;
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;
    logic [BATCH_ID_W-1:0] batch_id;
    logic [1:0] pixel_id;
    coalesced_addr_out_t coa_addr_out;

    address_calculation dut (
        .base_addr(base_addr),
        .pixel_tap_sel(pixel_tap_sel),
        .pixel_metadata_sel(pixel_metadata_sel),
        .batch_id(batch_id),
        .pixel_id(pixel_id),
        .coa_addr_out(coa_addr_out)
    );

    initial begin
        // Initial signal values. This DUT is combinational: no clock or reset.
        base_addr = '0;
        pixel_tap_sel = '0;
        pixel_metadata_sel = '0;
        batch_id = '0;
        pixel_id = '0;

        // Test 1: one address calculation, using only tap 0 (nearest).
        base_addr = 32'h0000_1000;
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_NEAREST;
        pixel_tap_sel.x[0] = 16'd3;
        pixel_tap_sel.y[0] = 16'd3;

        // Expected: dut.addr0.byte_addr = 0x1078, line_addr = 0x1000,
        // offset = 120, bank = 0, index = 0, tag = 1, addr_error = 0.
        // coa_addr_out.used = 0001, lines[0].tap_mask = 0001.
        #10;

        // Test 2: all four bilinear taps coalesce into one line.
        base_addr = 32'h0000_1000;
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        pixel_tap_sel.x[0] = 16'd0;
        pixel_tap_sel.y[0] = 16'd0;
        pixel_tap_sel.x[1] = 16'd1;
        pixel_tap_sel.y[1] = 16'd0;
        pixel_tap_sel.x[2] = 16'd0;
        pixel_tap_sel.y[2] = 16'd1;
        pixel_tap_sel.x[3] = 16'd1;
        pixel_tap_sel.y[3] = 16'd1;

        // Expected byte addresses (tap 0..3): 0x1000, 0x1008, 0x1010, 0x1018.
        // coa_addr_out.used = 1111, addr_error = 0000.
        // lines[0]: line_addr = 0x1000, tap_mask = 1111.
        // lines[1..3].tap_mask = 0000; offset[0..3] = 0, 8, 16, 24.
        #10;

        // Add more manual testcases here; inspect results in the waveform.
        $finish;
    end
endmodule