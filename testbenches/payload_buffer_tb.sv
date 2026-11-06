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

    logic clk = 0; always #5 clk = ~clk;
    logic n_rst = 0;
    logic alloc_valid = 0, alloc_ready;
    frag_data_t alloc_frag = '0;
    logic [BANKS-1:0] wr_valid = '0;
    logic [BANKS-1:0][CW-1:0] wr_cookie = '0;
    logic [BANKS-1:0][TEXEL_BITS-1:0] wr_data = '0;
    logic rsp_valid, rsp_ready = 1;
    texture_cache_return_t rsp_payload;

    payload_buffer #(.COOKIE_W(CW)) dut (.*);

    int errors = 0, checks = 0, quads_out = 0;
    texture_cache_return_t expected [$];

    typedef struct { int pix, tap; logic [TEXEL_BITS-1:0] data; int due; } wr_t;
    wr_t writes [$];
    int cycle = 0;

    function automatic logic [TEXEL_BITS-1:0] texel(input int q, pix, tap);
        return {32'(q * 1000 + pix * 10 + tap), 32'hC0DE_0000 | 32'(q)};
    endfunction

    // Build one quad: fragments for pixels 0..3 and the expected return.
    task automatic make_quad(input int q, input logic [LANES-1:0] used, input logic [3:0][LANES-1:0] err,
                             output frag_data_t f [4], output texture_cache_return_t r);
        r = '0;
        for (int p = 0; p < 4; p++) begin
            f[p] = '0;
            f[p].batch_id = BATCH_ID_W'(q);
            f[p].pixel_id = 2'(p);
            f[p].used = used;
            f[p].addr_error = err[p] & used;
            f[p].pixel_metadata.tmu_quad_metadata.rd = 5'(q);
            f[p].pixel_metadata.tmu_quad_metadata.warp_id = q[0];
            f[p].pixel_metadata.tmu_quad_metadata.quad_index = 3'(q);
            f[p].pixel_metadata.tmu_quad_metadata.lod_fraction = 8'(q * 3);
            f[p].pixel_metadata.tmu_quad_metadata.reserved = 17'(q * 77);
            f[p].pixel_metadata.u_frac = 8'(q + p);
            f[p].pixel_metadata.v_frac = 8'(q * 2 + p);
            r.tmu_quad_metadata = f[p].pixel_metadata.tmu_quad_metadata;
            r.u_frac[p] = f[p].pixel_metadata.u_frac;
            r.v_frac[p] = f[p].pixel_metadata.v_frac;
            r.texel_valid[p] = (|f[p].addr_error) ? 4'b0 : used;
            r.addr_error[p] = f[p].addr_error;
            for (int t = 0; t < 4; t++)
                if (r.texel_valid[p][t]) r.texels[p][t] = texel(q, p, t);
        end
    endtask

    // ---- write driver: up to BANKS due writes per cycle, any order ----
    always @(negedge clk) begin
        int lane;
        wr_valid = '0;
        lane = 0;
        writes.shuffle();
        for (int i = 0; i < writes.size() && lane < BANKS; ) begin
            if (writes[i].due <= cycle) begin
                wr_valid[lane] = 1'b1;
                wr_cookie[lane] = {2'(writes[i].pix), 2'(writes[i].tap)};
                wr_data[lane] = writes[i].data;
                writes.delete(i);
                lane++;
            end else i++;
        end
    end
    always @(posedge clk) cycle++;

    // ---- output monitor ----
    texture_cache_return_t held;
    bit holding = 0;
    always @(posedge clk) if (n_rst) begin
        if (holding && rsp_valid && rsp_payload !== held) begin
            errors++; $error("output changed while stalled");
        end
        holding = rsp_valid && !rsp_ready;
        held = rsp_payload;
        if (rsp_valid && rsp_ready) begin
            checks++;
            if (expected.size() == 0) begin
                errors++; $error("unexpected return");
            end else begin
                if (rsp_payload !== expected[0]) begin
                    errors++; $error("quad %0d payload mismatch", quads_out);
                end
                void'(expected.pop_front());
            end
            quads_out++;
        end
    end

    // Allocate one pixel (waits for alloc_ready) and schedule its writes.
    task automatic alloc_pixel(input frag_data_t f, input int q, input int max_lat);
        alloc_frag = f; alloc_valid = 1; #1;
        while (!alloc_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        alloc_valid = 0;
        for (int t = 0; t < 4; t++)
            if (f.used[t] && !(|f.addr_error)) begin
                wr_t w;
                w.pix = int'(f.pixel_id); w.tap = t;
                w.data = texel(q, f.pixel_id, t);
                w.due = cycle + 1 + $urandom_range(max_lat);
                writes.push_back(w);
            end
    endtask

    task automatic send_quad(input int q, input logic [LANES-1:0] used,
                             input logic [3:0][LANES-1:0] err, input int max_lat);
        frag_data_t f [4];
        texture_cache_return_t r;
        make_quad(q, used, err, f, r);
        expected.push_back(r);
        for (int p = 0; p < 4; p++) alloc_pixel(f[p], q, max_lat);
    endtask

    task automatic wait_idle(input int limit);
        int c = 0;
        while ((expected.size() != 0 || writes.size() != 0) && c < limit) begin @(posedge clk); c++; end
        if (expected.size() != 0) begin errors++; $error("%0d quads never returned", expected.size()); end
        #1;
    endtask

    frag_data_t fq [4];
    texture_cache_return_t rq;
    logic [3:0][LANES-1:0] err;

    initial begin
        repeat (2) @(posedge clk); #1;
        if (rsp_valid !== 0 || alloc_ready !== 0) begin errors++; $error("outputs not quiet in reset"); end
        n_rst = 1; #1;
        if (!alloc_ready) begin errors++; $error("alloc_ready low after reset"); end

        // ---- directed ----
        send_quad(1, 4'b1111, '0, 6);          wait_idle(100);
        send_quad(2, 4'b0001, '0, 3);          wait_idle(100);
        err = '0; err[1] = 4'b0110; err[3] = 4'b1111;
        send_quad(3, 4'b1111, err, 4);         wait_idle(100);

        // ---- slot already in use ----
        make_quad(4, 4'b1111, '0, fq, rq);
        expected.push_back(rq);
        alloc_pixel(fq[0], 4, 2);
        alloc_frag = fq[0]; #1; checks++;
        if (alloc_ready) begin errors++; $error("alloc_ready high for an occupied slot"); end
        for (int p = 1; p < 4; p++) alloc_pixel(fq[p], 4, 2);
        wait_idle(100);

        // ---- TMU backpressure ----
        rsp_ready = 0;
        send_quad(5, 4'b1111, '0, 2);
        send_quad(6, 4'b1111, '0, 2);           // assembles behind the held quad
        repeat (10) @(posedge clk); #1;
        make_quad(7, 4'b1111, '0, fq, rq);
        alloc_frag = fq[0]; #1; checks++;
        if (alloc_ready) begin errors++; $error("third quad accepted while two are held"); end
        if (!rsp_valid) begin errors++; $error("held quad not presented"); end
        rsp_ready = 1;
        wait_idle(100);

        // ---- random ----
        fork
            begin
                for (int q = 10; q < 310; q++) begin
                    for (int p = 0; p < 4; p++) err[p] = ($urandom_range(9) == 0) ? 4'($urandom) : 4'b0;
                    send_quad(q, ($urandom_range(3) == 0) ? 4'b0001 : 4'b1111, err, 8);
                end
            end
            begin
                repeat (6000) begin @(negedge clk); rsp_ready = ($urandom_range(99) < 70); end
                rsp_ready = 1;
            end
        join
        wait_idle(1000);

        if (errors == 0)
            $display("PASS payload_buffer_tb: %0d checks, %0d quads", checks, quads_out);
        else
            $fatal(1, "FAIL payload_buffer_tb: %0d errors", errors);
        $finish;
    end
    initial begin #2000000; $fatal(1, "payload_buffer_tb timeout"); end
endmodule
