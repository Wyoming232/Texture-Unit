`include "packages/cache_pkg.sv"

import cache_pkg::*;

// TODO : module is named `top`; rename to reorder_buffer (reorder_buffer_tb instantiates reorder_buffer).
module top #(
    parameter PTR_WIDTH = $clog2(ROB_DEPTH),
    parameter ROB_IDX_BITS = $clog2(ROB_DEPTH)
)(  
    input logic clk, n_rst,
    input logic miss_push, mem_return_valid,
    input logic [ADDR_W-1:0] miss_tail_addr,
    input logic [LINE_BITS-1:0]tex_load_in,
    input logic rob_pop,
    input logic [ROB_IDX_BITS-1:0] transaction_id,
    output logic [ROB_IDX_BITS-1:0] rob_next_free_entry,
    output logic rob_empty, rob_full, rob_return_ready,
    output rob_entry_t rob_tail_entry
);
    
    rob_entry_t rob_entries [ROB_DEPTH - 1 : 0];
    rob_entry_t head_entry;

    // push on head pop off tail
    logic [PTR_WIDTH:0] head_ptr, tail_ptr, next_head_ptr, next_tail_ptr;
    logic push_fire, return_fire, pop_fire;

    assign rob_full =
        (head_ptr[PTR_WIDTH-1:0] == tail_ptr[PTR_WIDTH-1:0]) &&
        (head_ptr[PTR_WIDTH]    != tail_ptr[PTR_WIDTH]);
    assign rob_empty = head_ptr == tail_ptr;
    assign rob_return_ready = 1'b1;

    assign push_fire = miss_push && !rob_full;
    assign pop_fire = rob_pop && !rob_empty
                   && rob_tail_entry.valid
                   && rob_tail_entry.completed;
    assign return_fire = mem_return_valid && rob_return_ready;

    assign rob_next_free_entry = head_ptr[PTR_WIDTH-1:0];

    // initialize head entry and update tail ptr when controller accepts data
    always_comb begin
        next_head_ptr = head_ptr;
        next_tail_ptr = tail_ptr;

        head_entry = '0;
        head_entry.valid     = 1'b1;
        head_entry.completed = 1'b0;
        head_entry.line_addr = miss_tail_addr;

        if (push_fire) next_head_ptr = head_ptr + 1'b1;

        if (pop_fire) next_tail_ptr = tail_ptr + 1'b1;
    end
    
    always_comb begin : tail_output_logic
        rob_tail_entry = '0;

        if (!rob_empty) begin
            rob_tail_entry = rob_entries[tail_ptr[PTR_WIDTH-1:0]];

            if (return_fire &&
                transaction_id == tail_ptr[PTR_WIDTH-1:0]) begin
                rob_tail_entry.completed = 1'b1;
                rob_tail_entry.data      = tex_load_in;
            end
        end
    end

   // on mem_return_valid use transaction ID to index into the ROB and write returned tex_load_in
    // if the returned memory is at the tail of the FIFO, then we would want to make this data immediately present for the controller to consume
    always_ff @( posedge clk or negedge n_rst ) begin : head_ptr_update_fill_logic
        if(!n_rst) begin
            head_ptr <= '0;
            tail_ptr <= '0;
        end else begin
            if (push_fire) begin
                rob_entries[head_ptr[PTR_WIDTH-1:0]] <= head_entry;
                head_ptr <= next_head_ptr;
            end
            if(return_fire) begin
                rob_entries[transaction_id].data <= tex_load_in;
                rob_entries[transaction_id].completed <= 1'b1;
            end
            if (pop_fire) begin
                rob_entries[tail_ptr[PTR_WIDTH-1:0]].valid     <= 1'b0;
                rob_entries[tail_ptr[PTR_WIDTH-1:0]].completed <= 1'b0;
                tail_ptr <= next_tail_ptr;
            end
        end
    end
endmodule