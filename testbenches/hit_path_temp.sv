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
    parameter int QUADS_PER_PHASE = 150;

    logic clk = 0; always #5 clk = ~clk;
    logic n_rst = 0;
    logic protocol_error, replay_error;

    texture_cache_request_if tmu_req();
    texture_cache_return_if tmu_rsp();
    mem_if mem();

    hit_path_temp #(.READ_LATENCY(READ_LATENCY)) dut (
        .clk(clk), .n_rst(n_rst), .tmu_req(tmu_req), .tmu_rsp(tmu_rsp), .mem(mem),
        .protocol_error(protocol_error), .replay_error(replay_error));

    int errors = 0, checks = 0, quads_sent = 0, quads_back = 0, mem_reqs = 0;
    // coverage counters (reported in the PASS line)
    int cov_fault_pix = 0, cov_pending_hit = 0, cov_bank_serial = 0, cov_tmu_stall = 0;
    always @(posedge clk) if (n_rst) begin
        if (dut.tag_if.rsp_valid && dut.tag_if.rsp_ready &&
            |(dut.frag_in.hit & ~dut.frag_in.data_ready & dut.frag_in.used))
            cov_pending_hit++;                         // hit on a line still being filled
        if (dut.cur_valid && !dut.cur_free && |dut.issued) cov_bank_serial++;   // multi-cycle issue
        if (tmu_rsp.valid && !tmu_rsp.ready) cov_tmu_stall++;
    end

    // ------------------------------------------------------------------
    // Memory image: texel at byte address a (8-aligned) is a hash of a.
    // ------------------------------------------------------------------
    function automatic logic [TEXEL_BITS-1:0] texel_at(input logic [31:0] a);
        return {a ^ 32'hA5A5_0000, ~a + 32'h1234};
    endfunction
    function automatic logic [LINE_BITS-1:0] line_at(input logic [31:0] line_addr);
        logic [LINE_BITS-1:0] l;
        for (int k = 0; k < LINE_BYTES / TEXEL_BYTES; k++)
            l[TEXEL_BITS*k +: TEXEL_BITS] = texel_at(line_addr + 32'(k * TEXEL_BYTES));
        return l;
    endfunction

    // ------------------------------------------------------------------
    // Memory model
    // ------------------------------------------------------------------
    typedef struct { logic [ROB_ID_W-1:0] id; logic [31:0] addr; int due; } mreq_t;
    mreq_t outstanding [$];
    int cycle = 0;
    always @(posedge clk) cycle++;

    int pick;
    always @(negedge clk) begin
        mem.req_ready = n_rst && ($urandom_range(99) < 70);
        mem.rsp_valid = 0;
        if (n_rst && outstanding.size() > 0) begin
            pick = $urandom_range(outstanding.size() - 1);
            if (outstanding[pick].due <= cycle) begin
                mem.rsp_valid = 1;
                mem.rsp_id = outstanding[pick].id;
                mem.rsp_data = line_at(outstanding[pick].addr);
            end
        end
    end
    always @(posedge clk) if (n_rst) begin
        if (mem.rsp_valid && mem.rsp_ready) begin
            int idx [$];
            idx = outstanding.find_first_index(m) with (m.id == mem.rsp_id);
            if (idx.size() != 0) outstanding.delete(idx[0]);
        end
        if (mem.req_valid && mem.req_ready) begin
            mreq_t m;
            int dup_id [$], dup_addr [$];
            mem_reqs++;
            if (mem.req_addr[OFFSET_W-1:0] != '0) begin errors++; $error("unaligned memory request %h", mem.req_addr); end
            dup_id = outstanding.find_index(o) with (o.id == mem.req_id);
            dup_addr = outstanding.find_index(o) with (o.addr == mem.req_addr);
            if (dup_id.size() != 0) begin errors++; $error("memory id %0d reused while outstanding", mem.req_id); end
            if (dup_addr.size() != 0) begin errors++; $error("line %h requested twice", mem.req_addr); end
            m.id = mem.req_id; m.addr = mem.req_addr; m.due = cycle + 4 + $urandom_range(60);
            outstanding.push_back(m);
        end
    end

    // ------------------------------------------------------------------
    // Reference address model (independent of the RTL formulation)
    // ------------------------------------------------------------------
    function automatic int lvl(input int l0, input int level);
        return (l0 > level) ? l0 - level : 0;
    endfunction
    function automatic logic [35:0] morton_ref(input int x, y, lw, lh);
        logic [35:0] idx = '0;
        int pos = 0;
        for (int b = 0; b < 16; b++) begin
            if (b < lw) begin idx[pos] = x[b]; pos++; end
            if (b < lh) begin idx[pos] = y[b]; pos++; end
        end
        return idx;
    endfunction
    function automatic logic [31:0] mip_base(input logic [31:0] base, input int w0, h0, level);
        logic [31:0] a = base;
        for (int l = 0; l < level; l++) a += 32'(TEXEL_BYTES) << (lvl(w0, l) + lvl(h0, l));
        return a;
    endfunction

    // ------------------------------------------------------------------
    // TMU model
    // ------------------------------------------------------------------
    texture_cache_return_t expected [$];

    typedef struct { logic [31:0] base; int w0, h0, max_level; } tex_t;
    tex_t tex;

    task automatic make_quad(output texture_cache_request_t r, output texture_cache_return_t e);
        int level, lw, lh, x, y, tx, ty;
        bit fault_pix [4];
        logic [31:0] mbase;
        r = '0; e = '0;
        level = $urandom_range(tex.max_level);
        lw = lvl(tex.w0, level); lh = lvl(tex.h0, level);
        r.texture_header.base_addr = tex.base;
        r.texture_header.log2_width = 5'(tex.w0);
        r.texture_header.log2_height = 5'(tex.h0);
        r.texture_header.max_mip_level = 5'(tex.max_level);
        r.texture_header.reserved = 17'($urandom);
        r.mip_level = 5'(level);
        r.log2_width = 5'(lw);
        r.log2_height = 5'(lh);
        case ($urandom_range(2))
            0: r.filter_mode = FILTER_NEAREST;
            1: r.filter_mode = FILTER_BILINEAR;
            default: r.filter_mode = FILTER_TRILINEAR;
        endcase
        r.warp_id = 1'($urandom); r.rd = 5'($urandom); r.quad_index = 3'($urandom);
        r.lod_fraction = 8'($urandom); r.upper_mip = 1'($urandom);
        mbase = mip_base(tex.base, tex.w0, tex.h0, level);
        e.tmu_quad_metadata = '{r.texture_header.reserved, r.warp_id, r.rd, r.quad_index,
                                r.filter_mode, r.lod_fraction, r.upper_mip};
        // a 2x2 pixel quad around a random anchor, bilinear 2x2 footprint per pixel
        x = $urandom_range((1 << lw) - 1); y = $urandom_range((1 << lh) - 1);
        for (int p = 0; p < 4; p++) begin
            r.u_frac[p] = 8'($urandom); r.v_frac[p] = 8'($urandom);
            e.u_frac[p] = r.u_frac[p]; e.v_frac[p] = r.v_frac[p];
            fault_pix[p] = 0;
            for (int t = 0; t < 4; t++) begin
                tx = x + (p & 1) + (t & 1);
                ty = y + (p >> 1) + (t >> 1);
                // clamp like the TMU would, except for rare injected faults
                if ($urandom_range(99) == 0 && lw < 16) tx = (1 << lw);   // out of mip
                else if (tx >= (1 << lw)) tx = (1 << lw) - 1;
                if (ty >= (1 << lh)) ty = (1 << lh) - 1;
                r.x[p][t] = 16'(tx); r.y[p][t] = 16'(ty);
                if ((r.filter_mode != FILTER_NEAREST || t == 0) && tx >= (1 << lw)) begin
                    fault_pix[p] = 1; e.addr_error[p][t] = 1'b1;
                end
            end
            if (fault_pix[p]) cov_fault_pix++;
            for (int t = 0; t < 4; t++) begin
                if ((r.filter_mode == FILTER_NEAREST && t != 0) || fault_pix[p]) continue;
                e.texel_valid[p][t] = 1'b1;
                e.texels[p][t] = texel_at(mbase + 32'(morton_ref(r.x[p][t], r.y[p][t], lw, lh) << 3));
            end
        end
    endtask

    // TMU request driver: hold each quad until ready, random gaps.
    task automatic send_quads(input int n);
        texture_cache_request_t r;
        texture_cache_return_t e;
        for (int q = 0; q < n; q++) begin
            make_quad(r, e);
            expected.push_back(e);
            @(negedge clk);
            tmu_req.payload = r; tmu_req.valid = 1;
            @(posedge clk);
            while (!tmu_req.ready) @(posedge clk);
            quads_sent++;
            @(negedge clk);
            tmu_req.valid = 0;
            repeat ($urandom_range(2)) @(negedge clk);
        end
    endtask

    // TMU return consumer + scoreboard
    bit rsp_hold = 0;
    texture_cache_return_t rsp_held;
    always @(negedge clk) tmu_rsp.ready = ($urandom_range(99) < 75);
    always @(posedge clk) if (n_rst) begin
        if (rsp_hold && (!tmu_rsp.valid || tmu_rsp.payload !== rsp_held)) begin
            errors++; $error("return changed while stalled");
        end
        rsp_hold = tmu_rsp.valid && !tmu_rsp.ready;
        rsp_held = tmu_rsp.payload;
        if (tmu_rsp.valid && tmu_rsp.ready) begin
            checks++;
            if (expected.size() == 0) begin
                errors++; $error("return with no outstanding quad");
            end else begin
                if (tmu_rsp.payload !== expected[0]) begin
                    errors++;
                    $error("quad %0d mismatch", quads_back);
                    for (int p = 0; p < 4; p++) for (int t = 0; t < 4; t++)
                        if (tmu_rsp.payload.texels[p][t] !== expected[0].texels[p][t] ||
                            tmu_rsp.payload.texel_valid[p][t] !== expected[0].texel_valid[p][t] ||
                            tmu_rsp.payload.addr_error[p][t] !== expected[0].addr_error[p][t])
                            $display("  p%0d t%0d got %h v%0b e%0b exp %h v%0b e%0b", p, t,
                                     tmu_rsp.payload.texels[p][t], tmu_rsp.payload.texel_valid[p][t],
                                     tmu_rsp.payload.addr_error[p][t], expected[0].texels[p][t],
                                     expected[0].texel_valid[p][t], expected[0].addr_error[p][t]);
                end
                void'(expected.pop_front());
            end
            quads_back++;
        end
    end

    task automatic drain(input string phase);
        int c = 0;
        while ((expected.size() != 0 || outstanding.size() != 0) && c < 20000) begin
            @(posedge clk); c++;
        end
        if (expected.size() != 0) begin errors++; $error("[%s] %0d quads never returned", phase, expected.size()); end
        if (protocol_error) begin errors++; $error("[%s] protocol_error", phase); end
        if (replay_error) begin errors++; $error("[%s] replay_error", phase); end
    endtask

    task automatic reset_dut;
        @(negedge clk);
        n_rst = 0;
        tmu_req.valid = 0; tmu_req.payload = '0;
        outstanding.delete();
        repeat (2) @(negedge clk);
        n_rst = 1;
    endtask

    task automatic phase(input string name, input logic [31:0] base, input int w0, h0);
        tex.base = base; tex.w0 = w0; tex.h0 = h0;
        tex.max_level = (w0 > h0) ? w0 : h0;
        reset_dut();
        send_quads(QUADS_PER_PHASE);
        drain(name);
        $display("[%s] done: %0d quads back, %0d memory requests so far", name, quads_back, mem_reqs);
    endtask

    initial begin
        tmu_req.valid = 0; tmu_req.payload = '0;
        mem.rsp_valid = 0; mem.req_ready = 0;
        phase("square 32x32",    32'h0004_0000, 5, 5);
        phase("non-square 64x16", 32'h0010_C000, 6, 4);
        phase("tiny 4x4",        32'h7FFF_C000, 2, 2);

        if (errors == 0)
            $display("PASS hit_path_temp_tb: %0d quads, %0d checks, %0d memory requests | coverage: %0d faulted pixels, %0d pending-line hits, %0d multi-cycle issues, %0d TMU stall cycles",
                     quads_back, checks, mem_reqs, cov_fault_pix, cov_pending_hit, cov_bank_serial, cov_tmu_stall);
        else
            $fatal(1, "FAIL hit_path_temp_tb: %0d errors", errors);
        $finish;
    end
    initial begin #20000000; $fatal(1, "hit_path_temp_tb timeout"); end
endmodule
