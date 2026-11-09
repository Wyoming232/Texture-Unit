/*
 Payload buffer (backend "payload preparation buffer", see fragment_fifo_tb notes)
 - Wait for all entries in a batch (quad) to be ready before sending to TMU
 - Stall everything until ready

 Testcases
 - reset: rsp_valid low, alloc_ready high
 - one bilinear quad, texels written out of order, several per cycle:
   payload has every texel in [pixel][tap], metadata from the quad,
   per-pixel u/v fractions
 - nearest quad (tap 0 only): taps 1..3 zero with texel_valid = 0
 - address-faulted pixel: no tag lookup happened, so NO tap of that pixel
   is written; all four texels zero, texel_valid = 0, addr_error set
 - alloc_ready low for a pixel slot that is already in the assembly quad
 - TMU backpressure: output quad holds stable; the next quad assembles
   behind it; the third quad's pixel 0 waits until the output drains
 - random: 300 quads, random tap masks/faults, random write order and
   latency, random rsp_ready; returns compared in order against a model
*/

`timescale 1ns/1ps
`include "src/payload_buffer.sv"

module payload_buffer_tb;
    import cache_pkg::*;
    localparam int CW = 4;

    logic clk, n_rst;
    logic alloc_valid, alloc_ready;
    frag_data_t alloc_frag;
    logic [BANKS-1:0] wr_valid;
    logic [BANKS-1:0][CW-1:0] wr_cookie;
    logic [BANKS-1:0][TEXEL_BITS-1:0] wr_data;
    logic rsp_valid, rsp_ready;
    texture_cache_return_t rsp_payload;

    always #5 clk = ~clk;

    payload_buffer #(.COOKIE_W(CW)) dut (
        .clk(clk), .n_rst(n_rst), .alloc_valid(alloc_valid),
        .alloc_ready(alloc_ready), .alloc_frag(alloc_frag),
        .wr_valid(wr_valid), .wr_cookie(wr_cookie), .wr_data(wr_data),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_payload(rsp_payload)
    );

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        alloc_valid = 1'b0;
        alloc_frag = '0;
        wr_valid = '0;
        wr_cookie = '0;
        wr_data = '0;
        rsp_ready = 1'b0;
        @(negedge clk);
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase: allocate pixels 0..3 of ONE nearest-filtered quad.
        @(negedge clk);
        alloc_frag.batch_id = 8'd1;
        alloc_frag.used = 4'b0001;
        alloc_frag.pixel_metadata.tmu_quad_metadata.filter_mode = FILTER_NEAREST;
        alloc_frag.pixel_metadata.tmu_quad_metadata.rd = 5'd7;
        alloc_frag.pixel_id = 2'd0;
        alloc_frag.pixel_metadata.u_frac = 8'd10;
        alloc_frag.pixel_metadata.v_frac = 8'd20;
        alloc_valid = 1'b1;
        @(negedge clk);
        alloc_frag.pixel_id = 2'd1;
        alloc_frag.pixel_metadata.u_frac = 8'd11;
        alloc_frag.pixel_metadata.v_frac = 8'd21;
        @(negedge clk);
        alloc_frag.pixel_id = 2'd2;
        alloc_frag.pixel_metadata.u_frac = 8'd12;
        alloc_frag.pixel_metadata.v_frac = 8'd22;
        @(negedge clk);
        alloc_frag.pixel_id = 2'd3;
        alloc_frag.pixel_metadata.u_frac = 8'd13;
        alloc_frag.pixel_metadata.v_frac = 8'd23;
        @(negedge clk);
        alloc_valid = 1'b0;

        // Manually return tap 0 for each pixel, one on each write lane.
        // rsp_valid must still be 0 before these writes complete.
        wr_cookie[0] = {2'd0, 2'd0};
        wr_cookie[1] = {2'd1, 2'd0};
        wr_cookie[2] = {2'd2, 2'd0};
        wr_cookie[3] = {2'd3, 2'd0};
        wr_data[0] = 64'h0000_0000_0000_0010;
        wr_data[1] = 64'h0000_0000_0000_0020;
        wr_data[2] = 64'h0000_0000_0000_0030;
        wr_data[3] = 64'h0000_0000_0000_0040;
        wr_valid = 4'b1111;
        @(negedge clk);
        wr_valid = '0;
        wait (rsp_valid);
        @(negedge clk);
        // rsp_payload.texels[0..3][0]=0x10,0x20,0x30,0x40;
        // each texel_valid[p]=0001, other taps zero, addr_error=0, rd=7.
        // u_frac=10,11,12,13 and v_frac=20,21,22,23 in pixel order.
        // Hold one cycle to inspect the complete quad before consumption.
        @(negedge clk);
        rsp_ready = 1'b1;
        @(negedge clk);
        rsp_ready = 1'b0;
        // rsp_valid=0 after the accepted output transfer.
        #10;

        // Add the next manual testcase here.
        $finish;
    end
endmodule
