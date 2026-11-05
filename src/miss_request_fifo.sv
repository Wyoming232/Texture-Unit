`include "packages/cache_pkg.sv"

module miss_request_fifo #(
    parameter int DEPTH = cache_pkg::MISS_REQ_DEPTH,
    parameter int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    parameter int COUNT_W = $clog2(DEPTH + 1)
) (
    input logic clk, n_rst,
    input logic miss_valid,
    output logic miss_ready,
    input logic [cache_pkg::ADDR_W-1:0] miss_addr,
    input logic [cache_pkg::WAY_W-1:0] miss_way,
    // TODO: future controller qualifies pop with actual downstream acceptance.
    // Memory ready alone is insufficient without ROB/tracker capacity.
    input logic miss_pop,
    output logic miss_tail_valid,
    output logic [cache_pkg::ADDR_W-1:0] miss_tail_addr,
    output logic [cache_pkg::WAY_W-1:0] miss_tail_way,
    output logic full, empty,
    output logic [COUNT_W-1:0] count
);
    import cache_pkg::*;

    miss_req_entry_t miss_entries [DEPTH];
    miss_req_entry_t tail_entry;
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic push_fire, pop_fire;

    // TODO : ready is derived from registered count, so push+pop in the same cycle while
    // full performs the pop only (push refused). Add a bypass if full-throughput is required.
    assign full = count == COUNT_W'(DEPTH);
    assign empty = count == '0;
    assign miss_ready = n_rst && !full;
    assign miss_tail_valid = n_rst && !empty;
    assign push_fire = miss_valid && miss_ready;
    assign pop_fire = miss_pop && miss_tail_valid;
    assign tail_entry = miss_tail_valid ? miss_entries[rd_ptr] : '0;
    assign miss_tail_addr = tail_entry.line_addr;
    assign miss_tail_way = tail_entry.miss_way;

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

    always_ff @(posedge clk) begin : fifo_payload_write
        if (push_fire) begin
            miss_entries[wr_ptr] <= {miss_addr, miss_way};
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 1 || PTR_W < ((DEPTH > 1) ? $clog2(DEPTH) : 1) ||
            COUNT_W < $clog2(DEPTH+1)) $fatal(1, "Invalid miss FIFO parameters");
    end
    always @(posedge clk) begin : check_miss_alignment
        if (push_fire && miss_addr[OFFSET_W-1:0] != '0)
            $fatal(1, "Miss FIFO requires an aligned line address");
    end
`endif
endmodule
