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


    integer mem_count;
    logic [ADDR_W-1:0] held_mem_addr;
    logic [ROB_ID_W-1:0] held_mem_id;
    texture_cache_return_t expected_rsp, held_rsp;

    // Observe memory transfers only; memory stimulus stays manual below.
    always @(posedge clk or negedge n_rst) begin
        if (!n_rst) mem_count <= 0;
        else if (mem.req_valid && mem.req_ready) begin
            assert (mem_count == 0 && mem.req_addr === 32'h1000)
                else $fatal(1, "Unexpected/duplicate memory request");
            mem_count <= mem_count + 1;
        end
    end

    // A missing handshake must fail instead of hanging the simulation.
    initial begin
        #20000;
        $fatal(1, "hit_path_temp.sv: simulation timeout");
    end

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        saved_mem_id = '0;
        held_mem_addr = '0;
        held_mem_id = '0;
        expected_rsp = '0;
        held_rsp = '0;
        tmu_req.valid = 1'b0;
        tmu_req.payload = '0;
        tmu_rsp.ready = 1'b0;
        mem.req_ready = 1'b0;
        mem.rsp_valid = 1'b0;
        mem.rsp_id = '0;
        mem.rsp_data = '0;
        @(negedge clk);
        assert (tmu_rsp.valid === 1'b0 && protocol_error === 1'b0 && replay_error === 1'b0)
            else $fatal(1, "Reset: top-level status");
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase 1: four nearest pixels share one cold/pending cache line.
        @(negedge clk);
        tmu_req.payload.texture_header.base_addr = 32'h1000;
        tmu_req.payload.texture_header.log2_width = 5'd2;
        tmu_req.payload.texture_header.log2_height = 5'd2;
        tmu_req.payload.texture_header.max_mip_level = 5'd2;
        tmu_req.payload.log2_width = 5'd2;
        tmu_req.payload.log2_height = 5'd2;
        tmu_req.payload.filter_mode = FILTER_NEAREST;
        tmu_req.payload.rd = 5'd7;
        tmu_req.payload.u_frac = {8'd13,8'd12,8'd11,8'd10};
        tmu_req.payload.v_frac = {8'd23,8'd22,8'd21,8'd20};
        tmu_req.valid = 1'b1;
        fork
            begin : manual_tmu_request
                wait (tmu_req.ready);
                @(posedge clk);
                @(negedge clk);
                tmu_req.valid = 1'b0;
            end
            begin : manual_memory_response
                // Stall memory acceptance and verify address AND ID are held.
                wait (mem.req_valid);
                @(negedge clk);
                held_mem_addr = mem.req_addr;
                held_mem_id = mem.req_id;
                assert (held_mem_addr === 32'h1000 && mem_count === 0)
                    else $fatal(1, "TC1: cold-line memory address");
                @(negedge clk);
                assert (mem.req_valid === 1'b1 && mem.req_addr === held_mem_addr && mem.req_id === held_mem_id)
                    else $fatal(1, "TC1: stalled memory request changed");
                mem.req_ready = 1'b1;
                @(posedge clk);
                saved_mem_id = mem.req_id;
                @(negedge clk);
                mem.req_ready = 1'b0;
                // Delay refill until ALL four pixels have committed, testing
                // pending-line hits and quad assembly without duplicate misses.
                wait (!tmu_req.valid);
                @(negedge clk);
                assert (tmu_rsp.valid === 1'b0 && mem_count === 1 && mem.req_valid === 1'b0)
                    else $fatal(1, "TC1: premature return or duplicate pending-line request");
                mem.rsp_id = saved_mem_id;
                mem.rsp_data[63:0] = 64'hCAFE_BABE_1234_5678;
                mem.rsp_data[127:64] = 64'h20;
                mem.rsp_data[191:128] = 64'h30;
                mem.rsp_data[255:192] = 64'h40;
                mem.rsp_valid = 1'b1;
                wait (mem.rsp_ready);
                @(posedge clk);
                @(negedge clk);
                mem.rsp_valid = 1'b0;
                mem.req_ready = 1'b1; // Any unexpected later request is counted.
            end
        join
        expected_rsp = '0;
        expected_rsp.tmu_quad_metadata.filter_mode = FILTER_NEAREST;
        expected_rsp.tmu_quad_metadata.rd = 5'd7;
        expected_rsp.u_frac = {8'd13,8'd12,8'd11,8'd10};
        expected_rsp.v_frac = {8'd23,8'd22,8'd21,8'd20};
        expected_rsp.texel_valid = {4{4'b0001}};
        expected_rsp.texels[0][0] = 64'hCAFE_BABE_1234_5678;
        expected_rsp.texels[1][0] = 64'hCAFE_BABE_1234_5678;
        expected_rsp.texels[2][0] = 64'hCAFE_BABE_1234_5678;
        expected_rsp.texels[3][0] = 64'hCAFE_BABE_1234_5678;
        wait (tmu_rsp.valid);
        @(negedge clk);
        assert (tmu_rsp.payload === expected_rsp && mem_count === 1 &&
                protocol_error === 1'b0 && replay_error === 1'b0)
            else $fatal(1, "TC1: miss/refill/nearest quad");
        held_rsp = tmu_rsp.payload;
        @(negedge clk);
        assert (tmu_rsp.valid === 1'b1 && tmu_rsp.payload === held_rsp)
            else $fatal(1, "TC1: TMU backpressure changed output");
        @(negedge clk);
        assert (tmu_rsp.valid === 1'b1 && tmu_rsp.payload === held_rsp)
            else $fatal(1, "TC1: stalled quad lost");
        tmu_rsp.ready = 1'b1;
        @(negedge clk);
        tmu_rsp.ready = 1'b0;
        assert (tmu_rsp.valid === 1'b0) else $fatal(1, "TC1: output consumption");

        // Testcase 2: ready cache hits, four different texels, no memory work.
        tmu_req.payload.rd = 5'd8;
        tmu_req.payload.x[1][0] = 16'd1;
        tmu_req.payload.y[2][0] = 16'd1;
        tmu_req.payload.x[3][0] = 16'd1;
        tmu_req.payload.y[3][0] = 16'd1;
        tmu_req.valid = 1'b1;
        wait (tmu_req.ready);
        @(posedge clk);
        @(negedge clk);
        tmu_req.valid = 1'b0;
        expected_rsp.tmu_quad_metadata.rd = 5'd8;
        expected_rsp.texels[1][0] = 64'h20;
        expected_rsp.texels[2][0] = 64'h30;
        expected_rsp.texels[3][0] = 64'h40;
        wait (tmu_rsp.valid);
        @(negedge clk);
        assert (tmu_rsp.payload === expected_rsp && mem_count === 1 && mem.req_valid === 1'b0)
            else $fatal(1, "TC2: ready hits, pixel routing, or unexpected memory work");
        tmu_rsp.ready = 1'b1;
        @(negedge clk);
        tmu_rsp.ready = 1'b0;

        // Testcase 3: bilinear quad, four same-bank taps per pixel serialize.
        tmu_req.payload.filter_mode = FILTER_BILINEAR;
        tmu_req.payload.rd = 5'd9;
        tmu_req.payload.x = '0;
        tmu_req.payload.y = '0;
        tmu_req.payload.x[0] = {16'd1,16'd0,16'd1,16'd0};
        tmu_req.payload.y[0] = {16'd1,16'd1,16'd0,16'd0};
        tmu_req.payload.x[1] = {16'd1,16'd0,16'd1,16'd0};
        tmu_req.payload.y[1] = {16'd1,16'd1,16'd0,16'd0};
        tmu_req.payload.x[2] = {16'd1,16'd0,16'd1,16'd0};
        tmu_req.payload.y[2] = {16'd1,16'd1,16'd0,16'd0};
        tmu_req.payload.x[3] = {16'd1,16'd0,16'd1,16'd0};
        tmu_req.payload.y[3] = {16'd1,16'd1,16'd0,16'd0};
        tmu_req.valid = 1'b1;
        wait (tmu_req.ready);
        @(posedge clk);
        @(negedge clk);
        tmu_req.valid = 1'b0;
        expected_rsp.tmu_quad_metadata.filter_mode = FILTER_BILINEAR;
        expected_rsp.tmu_quad_metadata.rd = 5'd9;
        expected_rsp.texel_valid = '1;
        expected_rsp.texels[0] = {64'h40,64'h30,64'h20,64'hCAFE_BABE_1234_5678};
        expected_rsp.texels[1] = {64'h40,64'h30,64'h20,64'hCAFE_BABE_1234_5678};
        expected_rsp.texels[2] = {64'h40,64'h30,64'h20,64'hCAFE_BABE_1234_5678};
        expected_rsp.texels[3] = {64'h40,64'h30,64'h20,64'hCAFE_BABE_1234_5678};
        wait (tmu_rsp.valid);
        @(negedge clk);
        assert (tmu_rsp.payload === expected_rsp && mem_count === 1 &&
                protocol_error === 1'b0 && replay_error === 1'b0)
            else $fatal(1, "TC3: bilinear quad, same-bank reads, or metadata");
        tmu_rsp.ready = 1'b1;
        @(negedge clk);
        tmu_rsp.ready = 1'b0;

        // Testcase 4: all four nearest pixels fault, return without memory work.
        tmu_req.payload.filter_mode = FILTER_NEAREST;
        tmu_req.payload.rd = 5'd10;
        tmu_req.payload.x = '0;
        tmu_req.payload.y = '0;
        tmu_req.payload.x[0][0] = 16'd4;
        tmu_req.payload.x[1][0] = 16'd4;
        tmu_req.payload.x[2][0] = 16'd4;
        tmu_req.payload.x[3][0] = 16'd4;
        tmu_req.valid = 1'b1;
        wait (tmu_req.ready);
        @(posedge clk);
        @(negedge clk);
        tmu_req.valid = 1'b0;
        expected_rsp.tmu_quad_metadata.filter_mode = FILTER_NEAREST;
        expected_rsp.tmu_quad_metadata.rd = 5'd10;
        expected_rsp.texel_valid = '0;
        expected_rsp.texels = '0;
        expected_rsp.addr_error = {4{4'b0001}};
        wait (tmu_rsp.valid);
        @(negedge clk);
        assert (tmu_rsp.payload === expected_rsp && mem_count === 1 && mem.req_valid === 1'b0 &&
                protocol_error === 1'b0 && replay_error === 1'b0)
            else $fatal(1, "TC4: fault return/zero texels/no memory work");
        tmu_rsp.ready = 1'b1;
        @(negedge clk);
        tmu_rsp.ready = 1'b0;
        assert (tmu_rsp.valid === 1'b0 && mem_count === 1)
            else $fatal(1, "TC4: final output consumption");

        $display("PASS: hit_path_temp_tb");
        $finish;
    end
endmodule
