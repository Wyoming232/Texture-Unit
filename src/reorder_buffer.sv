`include "packages/cache_pkg.sv"

import cache_pkg::*;

// Holds outstanding line misses in issue order (miss_path_simplified.png).
// - Allocation: the miss FIFO tail is accepted by memory; the request's
//   transaction id IS the allocated slot (rob_next_free_entry).
// - Return: memory may answer in any order; the line is written into the slot
//   named by transaction_id. A return that lands on the tail is forwarded
//   combinationally so the refill can consume it in the same cycle.
// - Release: rob_pop frees the tail only when it is valid && completed.
// Stale returns: a return to a slot that is not allocated, or that already
// completed, is dropped and reported (bad_return pulse, sticky
// protocol_error). There is no epoch: the memory subsystem is assumed to be
// reset together with the cache, so no pre-reset return can reach a slot that
// was re-allocated after reset.
module reorder_buffer #(
    parameter int DEPTH = ROB_DEPTH,
    parameter int PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
)(
    input logic clk, n_rst,
    // allocation (miss_push = memory request handshake)
    input logic miss_push,
    input logic [ADDR_W-1:0] miss_tail_addr,
    input logic [WAY_W-1:0] miss_tail_way,
    output logic [PTR_WIDTH-1:0] rob_next_free_entry,
    // memory return
    input logic mem_return_valid,
    input logic [PTR_WIDTH-1:0] transaction_id,
    input logic [LINE_BITS-1:0] tex_load_in,
    output logic rob_return_ready,
    // refill controller
    input logic rob_pop,
    output rob_entry_t rob_tail_entry,
    output logic rob_empty, rob_full,
    output logic [PTR_WIDTH:0] rob_count,
    output logic bad_return,      // one-cycle pulse
    output logic protocol_error   // sticky until reset
);
    // Payload RAM (line_addr, way, data) is not reset; valid/completed are.
    rob_entry_t rob_entries [DEPTH];
    logic [DEPTH-1:0] entry_valid, entry_completed;

    // push on head, pop off tail; extra MSB distinguishes full from empty
    logic [PTR_WIDTH:0] head_ptr, tail_ptr;
    logic [PTR_WIDTH-1:0] head_idx, tail_idx;
    logic push_fire, return_fire, return_ok, pop_fire;

    assign head_idx = head_ptr[PTR_WIDTH-1:0];
    assign tail_idx = tail_ptr[PTR_WIDTH-1:0];
    assign rob_full = (head_idx == tail_idx) && (head_ptr[PTR_WIDTH] != tail_ptr[PTR_WIDTH]);
    assign rob_empty = head_ptr == tail_ptr;
    assign rob_count = head_ptr - tail_ptr;
    assign rob_return_ready = n_rst;
    assign rob_next_free_entry = head_idx;

    assign push_fire = n_rst && miss_push && !rob_full;
    assign return_fire = mem_return_valid && rob_return_ready;
    assign return_ok = entry_valid[transaction_id] && !entry_completed[transaction_id];
    assign bad_return = return_fire && !return_ok;
    assign pop_fire = rob_pop && !rob_empty && rob_tail_entry.valid && rob_tail_entry.completed;

    always_comb begin : tail_output_logic
        rob_tail_entry = '0;
        if (!rob_empty) begin
            rob_tail_entry = rob_entries[tail_idx];
            rob_tail_entry.valid = entry_valid[tail_idx];
            rob_tail_entry.completed = entry_completed[tail_idx];
            // forward a return that lands on the tail this cycle
            if (return_fire && return_ok && transaction_id == tail_idx) begin
                rob_tail_entry.completed = 1'b1;
                rob_tail_entry.data = tex_load_in;
            end
        end
    end

    always_ff @(posedge clk or negedge n_rst) begin : pointer_and_status
        if (!n_rst) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            entry_valid <= '0;
            entry_completed <= '0;
            protocol_error <= 1'b0;
        end else begin
            if (push_fire) begin
                entry_valid[head_idx] <= 1'b1;
                entry_completed[head_idx] <= 1'b0;
                head_ptr <= head_ptr + 1'b1;
            end
            if (return_fire && return_ok) entry_completed[transaction_id] <= 1'b1;
            if (bad_return) protocol_error <= 1'b1;
            // pop is last so it wins over a same-cycle forwarded return
            if (pop_fire) begin
                entry_valid[tail_idx] <= 1'b0;
                entry_completed[tail_idx] <= 1'b0;
                tail_ptr <= tail_ptr + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin : payload_write
        if (push_fire) begin
            rob_entries[head_idx].line_addr <= miss_tail_addr;
            rob_entries[head_idx].way <= miss_tail_way;
        end
        if (return_fire && return_ok) rob_entries[transaction_id].data <= tex_load_in;
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0 || PTR_WIDTH != $clog2(DEPTH))
            $fatal(1, "reorder_buffer: DEPTH must be a power of two >= 2");
    end
`endif
endmodule
