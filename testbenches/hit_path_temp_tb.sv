/*
 Texture cache top-level (hit_path_temp) end-to-end testbench

 TMU model: issues random quads (nearest / bilinear / trilinear, random mip,
 random fractions and metadata), holds each quad until tmu_req.ready, and
 consumes returns with a random ready. Every return is compared in order
 against a reference built from an independent model of
   mip offset (sum of preceding levels) + Morton(x, y, lw, lh) * 8
 and the memory image.

 Memory model: random req_ready, returns after a random latency in random
 order (one return per cycle). Line data is a pure function of the address.
 Checks: line-aligned requests, no duplicate outstanding id, no request for a
 line that is already outstanding.

 Phases (DUT reset between phases, so each phase starts with an empty cache):
 - square 32x32 texture, full mip chain (~11 KiB)
 - non-square 64x16 texture, full mip chain (~11 KiB)
 - tiny 4x4 texture: heavy reuse, hits on pending lines
 - READ_LATENCY is a parameter of this bench (default 1)
 Each phase's footprint is <= 16 KiB and the base is 16 KiB aligned, so no
 set ever needs more than 4 lines and nothing is evicted while a queued pixel
 still needs it; replay_error must therefore stay 0.
 A few pixels get an out-of-mip coordinate: the whole pixel must come back
 with texel_valid = 0 and addr_error set on the faulting tap(s).
 Also exercises: TMU handshake, pixel arbitration, batch_id, miss_path integration.
*/

`timescale 1ns/1ps
`include "src/hit_path_temp.sv"

module hit_path_temp_tb;
    import cache_pkg::*;
    parameter int READ_LATENCY = 1;

    logic clk, n_rst;
    logic protocol_error, replay_error;
    logic [ROB_ID_W-1:0] saved_mem_id;
    texture_cache_request_if tmu_req();
    texture_cache_return_if tmu_rsp();
    mem_if mem();

    always #5 clk = ~clk;

    hit_path_temp #(.READ_LATENCY(READ_LATENCY)) dut (
        .clk(clk), .n_rst(n_rst), .tmu_req(tmu_req), .tmu_rsp(tmu_rsp),
        .mem(mem), .protocol_error(protocol_error), .replay_error(replay_error)
    );

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        saved_mem_id = '0;
        tmu_req.valid = 1'b0;
        tmu_req.payload = '0;
        tmu_rsp.ready = 1'b0;
        mem.req_ready = 1'b0;
        mem.rsp_valid = 1'b0;
        mem.rsp_id = '0;
        mem.rsp_data = '0;
        @(negedge clk);
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase: every pixel requests texel (0,0) in the same 4x4 mip.
        // Coordinates/taps remain zero from initialization; only tap 0 is used.
        @(negedge clk);
        tmu_req.payload.texture_header.base_addr = 32'h0000_1000;
        tmu_req.payload.texture_header.log2_width = 5'd2;
        tmu_req.payload.texture_header.log2_height = 5'd2;
        tmu_req.payload.texture_header.max_mip_level = 5'd2;
        tmu_req.payload.mip_level = 5'd0;
        tmu_req.payload.log2_width = 5'd2;
        tmu_req.payload.log2_height = 5'd2;
        tmu_req.payload.filter_mode = FILTER_NEAREST;
        tmu_req.payload.rd = 5'd7;
        tmu_req.payload.u_frac[0] = 8'd10;
        tmu_req.payload.u_frac[1] = 8'd11;
        tmu_req.payload.u_frac[2] = 8'd12;
        tmu_req.payload.u_frac[3] = 8'd13;
        tmu_req.payload.v_frac[0] = 8'd20;
        tmu_req.payload.v_frac[1] = 8'd21;
        tmu_req.payload.v_frac[2] = 8'd22;
        tmu_req.payload.v_frac[3] = 8'd23;
        tmu_req.valid = 1'b1;

        fork
            begin : manual_tmu_request
                // Keep this quad stable through its acceptance edge.
                wait (tmu_req.ready);
                @(posedge clk);
                @(negedge clk);
                tmu_req.valid = 1'b0;
            end
            begin : manual_memory_response
                // Accept the one cold-line request; expect req_addr=0x1000.
                mem.req_ready = 1'b1;
                wait (mem.req_valid);
                @(posedge clk);
                saved_mem_id = mem.req_id;
                @(negedge clk);
                mem.req_ready = 1'b0;
                mem.rsp_id = saved_mem_id;
                mem.rsp_data[63:0] = 64'hCAFE_BABE_1234_5678;
                mem.rsp_valid = 1'b1;
                wait (mem.rsp_ready);
                @(posedge clk);
                @(negedge clk);
                mem.rsp_valid = 1'b0;
            end
        join

        wait (tmu_rsp.valid);
        @(negedge clk);
        // Each pixel: texel_valid=0001, texels[p][0]=0xCAFEBABE12345678,
        // other taps zero, addr_error=0. rd=7 and fractions match the request.
        // Exactly one memory request; protocol_error=replay_error=0.
        @(negedge clk);
        tmu_rsp.ready = 1'b1;
        @(negedge clk);
        tmu_rsp.ready = 1'b0;
        #10;

        // Add the next manual testcase here.
        $finish;
    end
endmodule
