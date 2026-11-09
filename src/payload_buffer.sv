`include "packages/cache_pkg.sv"

// Payload buffer: collects the texels of one quad (4 pixels x 4 taps) from
// the data array and returns the whole quad to the TMU in one transfer
// (texture_cache_return_t), in request order.
//
// - alloc: the read-issue stage took ownership of a fragment (pixel). Its
//   slot is pixel_id. alloc_ready is low while that slot already holds a
//   pixel of the quad being assembled, so the next quad's pixel 0 waits until
//   the current quad has moved to the output register.
// - wr: data-array responses, any order, cookie = {pixel_id, tap}. One write
//   per requested (used) tap of a pixel WITHOUT any addr_error. A faulted
//   pixel had no tag lookups at all (coalesced_fragment_adapter rejects the
//   whole pixel), so all its taps return zero with texel_valid = 0 and
//   addr_error marks the faulting taps.
// - Two registers: the assembly quad and the output quad (held stable until
//   rsp_ready), so a new quad can assemble while the TMU stalls.
module payload_buffer #(
    parameter int COOKIE_W = 4
) (
    input  logic clk, n_rst,
    input  logic alloc_valid,
    output logic alloc_ready,
    input  cache_pkg::frag_data_t alloc_frag,
    input  logic [cache_pkg::BANKS-1:0] wr_valid,
    input  logic [cache_pkg::BANKS-1:0][COOKIE_W-1:0] wr_cookie,
    input  logic [cache_pkg::BANKS-1:0][cache_pkg::TEXEL_BITS-1:0] wr_data,
    output logic rsp_valid,
    input  logic rsp_ready,
    output cache_pkg::texture_cache_return_t rsp_payload
);
    import cache_pkg::*;

    texture_cache_return_t asm_q;
    logic [3:0] asm_seen;
    logic [3:0][LANES-1:0] asm_pending;
    logic asm_complete, transfer, alloc_fire;
    logic [1:0] alloc_pix;
    logic [LANES-1:0] alloc_fault, alloc_reads;

    assign alloc_pix = alloc_frag.pixel_id;
    assign alloc_ready = n_rst && !asm_seen[alloc_pix];
    assign alloc_fire = alloc_valid && alloc_ready;
    assign alloc_fault = alloc_frag.used & alloc_frag.addr_error;
    assign alloc_reads = (|alloc_fault) ? '0 : alloc_frag.used;
    assign asm_complete = (&asm_seen) && !(|asm_pending);
    assign transfer = asm_complete && (!rsp_valid || rsp_ready);

    always_ff @(posedge clk or negedge n_rst) begin : quad_assembly
        if (!n_rst) begin
            asm_seen <= '0;
            asm_pending <= '0;
            asm_q <= '0;
            rsp_valid <= 1'b0;
            rsp_payload <= '0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;
            if (transfer) begin
                rsp_valid <= 1'b1;
                rsp_payload <= asm_q;
                asm_seen <= '0;
            end
            if (alloc_fire) begin
                asm_seen[alloc_pix] <= 1'b1;
                asm_pending[alloc_pix] <= alloc_reads;
                asm_q.texel_valid[alloc_pix] <= alloc_reads;
                asm_q.addr_error[alloc_pix] <= alloc_fault;
                asm_q.texels[alloc_pix] <= '0;
                asm_q.u_frac[alloc_pix] <= alloc_frag.pixel_metadata.u_frac;
                asm_q.v_frac[alloc_pix] <= alloc_frag.pixel_metadata.v_frac;
                asm_q.tmu_quad_metadata <= alloc_frag.pixel_metadata.tmu_quad_metadata;
            end
            for (int b = 0; b < BANKS; b++) begin
                if (wr_valid[b]) begin
                    asm_q.texels[wr_cookie[b][COOKIE_W-1 -: 2]][wr_cookie[b][1:0]] <= wr_data[b];
                    asm_pending[wr_cookie[b][COOKIE_W-1 -: 2]][wr_cookie[b][1:0]] <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial if (COOKIE_W < 4) $fatal(1, "payload_buffer: cookie must hold {pixel_id, tap}");
    logic [BATCH_ID_W-1:0] asm_batch;
    always @(posedge clk) if (n_rst) begin : protocol_checks
        if (alloc_fire && alloc_pix != 2'd0 && !asm_seen[alloc_pix - 2'd1])
            $error("payload_buffer: pixel %0d allocated before pixel %0d", alloc_pix, alloc_pix - 1);
        if (alloc_fire && alloc_pix != 2'd0 && alloc_frag.batch_id != asm_batch)
            $error("payload_buffer: batch_id changed inside a quad");
        if (alloc_fire) asm_batch <= alloc_frag.batch_id;
        for (int b = 0; b < BANKS; b++)
            if (wr_valid[b] && !asm_pending[wr_cookie[b][COOKIE_W-1 -: 2]][wr_cookie[b][1:0]])
                $error("payload_buffer: unexpected texel for pixel %0d tap %0d",
                       wr_cookie[b][COOKIE_W-1 -: 2], wr_cookie[b][1:0]);
    end
`endif
endmodule
