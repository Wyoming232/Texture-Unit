`include "packages/cache_pkg.sv"

module frag_fifo #(
    parameter int DEPTH = cache_pkg::FRAG_DEPTH,
    parameter int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk, n_rst,
    input logic valid_in,
    output logic ready_in,
    input cache_pkg::frag_data_t frag_in,
    output logic batch_committed,
    // TODO: connect pop to the future backend's accepted ownership transfer.
    input logic pop,
    output logic tail_valid,
    output cache_pkg::frag_data_t tail_data,
    output logic full, empty,
    output logic [COUNT_W-1:0] count
);
    import cache_pkg::*;

    frag_data_t frag_entries [DEPTH];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic push_fire, pop_fire;

    // TODO : ready is derived from registered count, so push+pop in the same cycle while
    // full performs the pop only (push refused). Add a bypass if full-throughput is required.
    assign full = count == COUNT_W'(DEPTH);
    assign empty = count == '0;
    assign ready_in = n_rst && !full;
    assign tail_valid = n_rst && !empty;
    assign push_fire = valid_in && ready_in;
    assign pop_fire = pop && tail_valid;
    // Per-pixel acceptance, even though batch_id is SHARED by the whole quad.
    assign batch_committed = push_fire;
    assign tail_data = tail_valid ? frag_entries[rd_ptr] : '0;

    function automatic logic [PTR_W-1:0] advance(input logic [PTR_W-1:0] ptr);
        return (ptr == PTR_W'(DEPTH-1)) ? '0 : ptr + 1'b1;
    endfunction

    always_ff @(posedge clk or negedge n_rst) begin : fifo_control
        if (!n_rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
        end else begin
            if (push_fire) wr_ptr <= advance(wr_ptr);
            if (pop_fire) rd_ptr <= advance(rd_ptr);
            case ({push_fire, pop_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
        end
    end

    // Valid/count state masks uninitialized payload storage after reset.
    always_ff @(posedge clk) begin : fifo_payload_write
        if (push_fire) frag_entries[wr_ptr] <= frag_in;
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1 || PTR_W < ((DEPTH > 1) ? $clog2(DEPTH) : 1) ||
            COUNT_W < $clog2(DEPTH+1)) $fatal(1, "Invalid frag_fifo parameters");
    end
`endif
endmodule
