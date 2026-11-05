`timescale 1ns/1ps
`include "interfaces/interfaces.vh"
`include "src/address_calculation.sv"
`include "src/coalesced_fragment_adapter.sv"

module coalescer_contract_tb;
    import cache_pkg::*;
    logic [31:0] base_addr;
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;
    logic [BATCH_ID_W-1:0] batch_id;
    logic [1:0] pixel_id;
    coalesced_addr_out_t coa_addr_out;
    tag_out_t [LANES-1:0] tag_result;
    tag_lookup_t [LANES-1:0] tag_req;
    frag_data_t frag_in;
    tag_array_if tag_if();

    address_calculation dut (.*);
    coalesced_fragment_adapter adapter (.*);

    addr_calc_out_t [3:0] raw;
    logic [3:0] raw_used;
    coalesced_line_t [3:0] raw_coa;
    coalesced_addrs masked_dut (
        .addr0(raw[0]), .addr1(raw[1]), .addr2(raw[2]), .addr3(raw[3]),
        .used(raw_used),
        .coa_0_1(raw[0].line_addr == raw[1].line_addr),
        .coa_0_2(raw[0].line_addr == raw[2].line_addr),
        .coa_0_3(raw[0].line_addr == raw[3].line_addr),
        .coa_1_2(raw[1].line_addr == raw[2].line_addr),
        .coa_1_3(raw[1].line_addr == raw[3].line_addr),
        .coa_2_3(raw[2].line_addr == raw[3].line_addr),
        .coa_addrs0(raw_coa[0]), .coa_addrs1(raw_coa[1]),
        .coa_addrs2(raw_coa[2]), .coa_addrs3(raw_coa[3])
    );

    function automatic logic [35:0] ref_addr (
        input logic [15:0] x, y, input logic [31:0] base
    );
        logic [35:0] value;
        value = {4'b0, base};
        for (int bit_id = 0; bit_id < 16; bit_id++) begin
            if (x[bit_id]) value += 36'd8 << (2*bit_id);
            if (y[bit_id]) value += 36'd8 << (2*bit_id+1);
        end
        return value;
    endfunction

    task automatic check_packet(input filter_mode_e mode, input int pattern);
        logic [35:0] expected [4];
        logic [3:0] expected_used, seen;
        int first;
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = mode;
        for (int tap = 0; tap < 4; tap++) begin
            // High coordinate bits select four possible lines; low bits
            // produce different offsets even when the line identities match.
            pixel_tap_sel.x[tap] = 16'(((((pattern >> (2*tap)) & 3) << 2) | tap));
            pixel_tap_sel.y[tap] = 16'(tap);
            expected[tap] = ref_addr(pixel_tap_sel.x[tap], pixel_tap_sel.y[tap], base_addr);
        end
        #1;
        expected_used = (mode == FILTER_NEAREST) ? 4'b0001 : 4'b1111;
        if (coa_addr_out.used !== expected_used || coa_addr_out.addr_error !== 4'b0000)
            $fatal(1, "active mask/address error mismatch");
        if (coa_addr_out.pixel_metadata !== pixel_metadata_sel ||
            coa_addr_out.batch_id !== batch_id || coa_addr_out.pixel_id !== pixel_id ||
            frag_in.pixel_metadata !== pixel_metadata_sel ||
            frag_in.batch_id !== batch_id || frag_in.pixel_id !== pixel_id)
            $fatal(1, "metadata was lost");
        if (frag_in.used !== expected_used || frag_in.addr_error !== 4'b0000)
            $fatal(1, "fragment mask/error mismatch");

        seen = '0;
        for (int group = 0; group < 4; group++) begin
            if ((seen & coa_addr_out.lines[group].tap_mask) != 0)
                $fatal(1, "tap assigned to more than one group");
            seen |= coa_addr_out.lines[group].tap_mask;
            if (tag_req[group].valid !== (|coa_addr_out.lines[group].tap_mask))
                $fatal(1, "empty group was looked up or active group lost");
        end
        if (seen !== expected_used) $fatal(1, "coalescer did not partition active taps");

        for (int tap = 0; tap < 4; tap++) begin
            if (expected_used[tap]) begin
                first = -1;
                for (int earlier = 0; earlier < 4; earlier++)
                    if (expected_used[earlier] && first < 0 &&
                        expected[earlier][31:7] == expected[tap][31:7])
                        first = earlier;
                if (!coa_addr_out.lines[first].tap_mask[tap] ||
                    coa_addr_out.lines[first].line_addr !== {expected[tap][31:7],7'b0})
                    $fatal(1, "wrong line/representative for tap %0d pattern %0d", tap, pattern);
                if (tag_req[first].bank !== expected[tap][8:7] ||
                    tag_req[first].index !== expected[tap][11:9] ||
                    tag_req[first].tag !== expected[tap][31:12])
                    $fatal(1, "incorrect tag-only request");
                if (frag_in.addr[tap] !== expected[tap][31:0] ||
                    frag_in.offset[tap] !== expected[tap][6:0] ||
                    frag_in.bank[tap] !== expected[tap][8:7] ||
                    frag_in.idx[tap] !== expected[tap][11:9] ||
                    frag_in.hit[tap] !== tag_result[first].hit ||
                    frag_in.data_ready[tap] !== (tag_result[first].hit && tag_result[first].ready) ||
                    frag_in.hit_way[tap] !== tag_result[first].hit_way)
                    $fatal(1, "incorrect FIFO expansion for tap %0d", tap);
            end
        end
    endtask

    task automatic check_arbitrary_mask(input int pattern, input int mask);
        logic [3:0] expected_mask;
        int first;
        raw = '0;
        raw_used = 4'(mask);
        for (int tap = 0; tap < 4; tap++)
            raw[tap].line_addr = 32'(((pattern >> (2*tap)) & 3) * 128);
        #1;
        for (int group = 0; group < 4; group++) begin
            expected_mask = '0;
            for (int tap = 0; tap < 4; tap++) begin
                first = -1;
                for (int candidate = 0; candidate < 4; candidate++)
                    if (raw_used[candidate] && first < 0 &&
                        raw[candidate].line_addr == raw[tap].line_addr)
                        first = candidate;
                if (raw_used[tap] && first == group) expected_mask[tap] = 1'b1;
            end
            if (raw_coa[group].tap_mask !== expected_mask)
                $fatal(1, "partition mismatch: pattern=%0d mask=%0d group=%0d", pattern, mask, group);
        end
    endtask

    initial begin
        base_addr = 32'h12345000;
        batch_id = 8'hA5;
        pixel_id = 2'd3;
        pixel_tap_sel = '0;
        pixel_metadata_sel = '0;
        pixel_metadata_sel.tmu_quad_metadata.reserved = 17'h15555;
        pixel_metadata_sel.tmu_quad_metadata.warp_id = 1'b1;
        pixel_metadata_sel.tmu_quad_metadata.rd = 5'd29;
        pixel_metadata_sel.tmu_quad_metadata.quad_index = 3'd5;
        pixel_metadata_sel.tmu_quad_metadata.lod_fraction = 8'h9B;
        pixel_metadata_sel.tmu_quad_metadata.upper_mip = 1'b1;
        pixel_metadata_sel.u_frac = 8'h31;
        pixel_metadata_sel.v_frac = 8'hC7;
        tag_result = '0;
        raw = '0;
        raw_used = '0;
        for (int group = 0; group < 4; group++) begin
            tag_result[group].hit = (group != 2);
            tag_result[group].ready = (group == 1 || group == 3);
            tag_result[group].hit_way = 2'(group);
        end
        // TODO : tag_lookup_t width becomes 30 once tap_mask is added; update this check.
        if ($bits(coalesced_addr_out_t) != 243 || $bits(frag_data_t) != 263 ||
            $bits(tag_lookup_t) != 26)
            $fatal(1, "unexpected default contract widths");

        for (int pattern = 0; pattern < 256; pattern++) begin
            check_packet(FILTER_BILINEAR, pattern);
            check_packet(FILTER_TRILINEAR, pattern);
            check_packet(FILTER_NEAREST, pattern);
            for (int mask = 0; mask < 16; mask++) check_arbitrary_mask(pattern, mask);
        end

        // Inactive nearest taps can contain overflowing coordinates.
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_NEAREST;
        pixel_tap_sel = '1;
        pixel_tap_sel.x[0] = '0;
        pixel_tap_sel.y[0] = '0;
        #1;
        if (coa_addr_out.addr_error !== 0 || coa_addr_out.used !== 4'b0001)
            $fatal(1, "inactive nearest taps generated a fault");

        // Active overflow and misalignment must suppress ALL lookup groups.
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        pixel_tap_sel = '1;
        #1;
        if (coa_addr_out.addr_error !== 4'b1111) $fatal(1, "overflow not flagged");
        for (int group = 0; group < 4; group++)
            if (tag_req[group].valid) $fatal(1, "lookup issued on overflow");
        pixel_tap_sel = '0;
        base_addr = 32'h00000001;
        #1;
        if (coa_addr_out.addr_error !== 4'b1111) $fatal(1, "misalignment not flagged");
        for (int group = 0; group < 4; group++)
            if (tag_req[group].valid) $fatal(1, "lookup issued on misalignment");
        $display("PASS: 768 pixel cases, 4096 masked partitions, metadata and address faults");
        $finish;
    end
endmodule
