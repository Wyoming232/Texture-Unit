`timescale 1ns/1ps
`include "src/address_calculation.sv"
`include "src/coalesced_fragment_adapter.sv"

module coalescer_contract_tb;
    import cache_pkg::*;

    logic [31:0] base_addr;
    logic [4:0] log2_width, log2_height;
    pixel_taps_t pixel_tap_sel;
    tmu_pixel_metadata_t pixel_metadata_sel;
    logic [BATCH_ID_W-1:0] batch_id;
    logic [1:0] pixel_id;
    coalesced_addr_out_t coa_addr_out;
    tag_out_t [LANES-1:0] tag_result;
    tag_lookup_t [LANES-1:0] tag_req;
    frag_data_t frag_in;

    address_calculation dut (
        .base_addr(base_addr), .log2_width(log2_width), .log2_height(log2_height),
        .pixel_tap_sel(pixel_tap_sel), .pixel_metadata_sel(pixel_metadata_sel),
        .batch_id(batch_id), .pixel_id(pixel_id), .coa_addr_out(coa_addr_out)
    );
    coalesced_fragment_adapter adapter (
        .coa_addr_out(coa_addr_out), .tag_result(tag_result),
        .tag_req(tag_req), .frag_in(frag_in)
    );


    initial begin
        base_addr = '0;
        log2_width = '0;
        log2_height = '0;
        pixel_tap_sel = '0;
        pixel_metadata_sel = '0;
        batch_id = '0;
        pixel_id = '0;
        tag_result = '0;

        // Testcase 1: four different offsets merge into one ready-hit group.
        base_addr = 32'h1000;
        log2_width = 5'd3;
        log2_height = 5'd3;
        pixel_metadata_sel.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        pixel_metadata_sel.u_frac = 8'd64;
        pixel_metadata_sel.v_frac = 8'd128;
        batch_id = 8'd1;
        pixel_id = 2'd2;
        pixel_tap_sel.x[1] = 16'd1;
        pixel_tap_sel.y[2] = 16'd1;
        pixel_tap_sel.x[3] = 16'd1;
        pixel_tap_sel.y[3] = 16'd1;
        tag_result[0] = '{hit:1'b1,ready:1'b1,hit_way:2'd2};
        #10;
        assert (coa_addr_out.lines[0] === coalesced_line_t'{line_addr:32'h1000,tap_mask:4'b1111} &&
                coa_addr_out.lines[1].tap_mask === 4'd0 &&
                coa_addr_out.lines[2].tap_mask === 4'd0 && coa_addr_out.lines[3].tap_mask === 4'd0 &&
                tag_req[0] === tag_lookup_t'{valid:1'b1,tap_mask:4'b1111,bank:2'd0,index:3'd0,tag:20'd1} &&
                {tag_req[3].valid,tag_req[2].valid,tag_req[1].valid} === 3'd0)
            else $fatal(1, "TC1: all-four coalescing and tag request");
        assert (frag_in.addr === {32'h1018,32'h1010,32'h1008,32'h1000} &&
                frag_in.offset === {7'd24,7'd16,7'd8,7'd0} &&
                frag_in.used === 4'b1111 && frag_in.hit === 4'b1111 &&
                frag_in.data_ready === 4'b1111 && frag_in.hit_way === {4{2'd2}} &&
                frag_in.addr_error === 4'd0 && frag_in.batch_id === batch_id &&
                frag_in.pixel_id === pixel_id && frag_in.pixel_metadata === pixel_metadata_sel)
            else $fatal(1, "TC1: group expansion, offsets and metadata");

        // Testcase 2: four unique lines, four banks, mixed tag outcomes.
        pixel_tap_sel = '0;
        pixel_tap_sel.x[1] = 16'd4;
        pixel_tap_sel.y[2] = 16'd4;
        pixel_tap_sel.x[3] = 16'd4;
        pixel_tap_sel.y[3] = 16'd4;
        tag_result[0] = '{hit:1'b0,ready:1'b0,hit_way:2'd0};
        tag_result[1] = '{hit:1'b1,ready:1'b0,hit_way:2'd1};
        tag_result[2] = '{hit:1'b1,ready:1'b1,hit_way:2'd2};
        tag_result[3] = '{hit:1'b1,ready:1'b1,hit_way:2'd3};
        #10;
        assert (coa_addr_out.lines[0].tap_mask === 4'b0001 &&
                coa_addr_out.lines[1].tap_mask === 4'b0010 &&
                coa_addr_out.lines[2].tap_mask === 4'b0100 &&
                coa_addr_out.lines[3].tap_mask === 4'b1000 &&
                {tag_req[3].valid,tag_req[2].valid,tag_req[1].valid,tag_req[0].valid} === 4'b1111 &&
                {tag_req[3].bank,tag_req[2].bank,tag_req[1].bank,tag_req[0].bank} === 8'b11_10_01_00 &&
                frag_in.addr === {32'h1180,32'h1100,32'h1080,32'h1000} &&
                frag_in.hit === 4'b1110 && frag_in.data_ready === 4'b1100 &&
                frag_in.hit_way === {2'd3,2'd2,2'd1,2'd0})
            else $fatal(1, "TC2: separate lines and mixed hit/ready results");

        // Testcase 3: interleaved pairs 02 + 13 keep original group slots.
        pixel_tap_sel = '0;
        pixel_tap_sel.x[1] = 16'd4;
        pixel_tap_sel.x[2] = 16'd1;
        pixel_tap_sel.x[3] = 16'd5;
        tag_result = '0;
        tag_result[0] = '{hit:1'b1,ready:1'b0,hit_way:2'd3};
        tag_result[1] = '{hit:1'b1,ready:1'b1,hit_way:2'd1};
        #10;
        assert (coa_addr_out.lines[0].tap_mask === 4'b0101 &&
                coa_addr_out.lines[1].tap_mask === 4'b1010 &&
                coa_addr_out.lines[2].tap_mask === 4'd0 && coa_addr_out.lines[3].tap_mask === 4'd0 &&
                {tag_req[3].valid,tag_req[2].valid,tag_req[1].valid,tag_req[0].valid} === 4'b0011 &&
                frag_in.addr === {32'h1088,32'h1008,32'h1080,32'h1000} &&
                frag_in.hit === 4'b1111 && frag_in.data_ready === 4'b1010 &&
                frag_in.hit_way === {2'd1,2'd3,2'd1,2'd3})
            else $fatal(1, "TC3: pair groups, pending hits and original tap mapping");

        // Testcase 4: one bad active tap suppresses ALL tag requests.
        pixel_tap_sel.x[2] = 16'd8; // Outside this 8x8 mip.
        #10;
        assert (coa_addr_out.addr_error === 4'b0100 && frag_in.addr_error === 4'b0100 &&
                frag_in.used === 4'b1111 &&
                {tag_req[3].valid,tag_req[2].valid,tag_req[1].valid,tag_req[0].valid} === 4'b0000 &&
                coa_addr_out.lines[0].tap_mask === 4'b0001 &&
                coa_addr_out.lines[1].tap_mask === 4'b1010 &&
                coa_addr_out.lines[2].tap_mask === 4'd0 && coa_addr_out.lines[3].tap_mask === 4'd0 &&
                frag_in.addr[2] === '0 && frag_in.hit[2] === 1'b0 &&
                frag_in.data_ready[2] === 1'b0 && frag_in.hit_way[2] === '0)
            else $fatal(1, "TC4: whole-pixel lookup rejection and faulted-tap exclusion");

        $display("PASS: coalescer_contract_tb");
        $finish;
    end
endmodule
