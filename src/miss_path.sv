`include "packages/cache_pkg.sv"
`include "interfaces/interfaces.vh"
`include "src/miss_request_fifo.sv"
`include "src/reorder_buffer.sv"

// Miss path (documentation/reference/miss_path_simplified.png):
//   tag_array miss channel -> miss_request_fifo -> memory request
//   memory return -> reorder_buffer -> in-order refill of tag + data arrays
//
// Memory request: mem.req_valid = miss FIFO tail valid && !rob_full.
//   miss_push (ROB allocate) = miss_pop (FIFO pop) = mem.req_valid && mem.req_ready.
//   The request id is the ROB slot being allocated.
// Refill: when the ROB tail is completed, write the line into the data array
//   AND mark the reserved tag way ready in the SAME cycle; pop the ROB only
//   when both sinks accept. A reader therefore never sees ready=1 before the
//   data is written.
// Forward progress (tag_array stall on a set full of pending ways): the
//   refill of the ROB tail depends only on (a) memory returning that line and
//   (b) the two fill ports, which accept any legal reserved slot. It never
//   waits on the tag lookup engine, the fragment FIFO or the TMU, so every
//   reserved way is eventually filled once memory responds.
module miss_path (
    input logic clk, n_rst,
    tag_array_if.miss_path tag_miss,
    tag_array_if.refill tag_refill,
    mem_if.cache mem,
    // data array line fill
    output logic data_fill_valid,
    input  logic data_fill_ready,
    output logic [cache_pkg::BANK_W-1:0] data_fill_bank,
    output logic [cache_pkg::SET_W-1:0] data_fill_set,
    output logic [cache_pkg::WAY_W-1:0] data_fill_way,
    output logic [cache_pkg::LINE_BITS-1:0] data_fill_line,
    // status (miss_path diagram side outputs)
    output logic miss_req_empty, miss_req_full,
    output logic rob_empty, rob_full,
    output logic protocol_error
);
    import cache_pkg::*;

    // ---------------- miss request FIFO ----------------
    logic miss_pop, miss_tail_valid;
    logic [ADDR_W-1:0] miss_tail_addr;
    logic [WAY_W-1:0] miss_tail_way;
    logic [$clog2(MISS_REQ_DEPTH+1)-1:0] miss_count;

    miss_request_fifo miss_fifo (
        .clk(clk), .n_rst(n_rst),
        .miss_valid(tag_miss.miss_valid), .miss_ready(tag_miss.miss_ready),
        .miss_addr(tag_miss.miss_addr), .miss_way(tag_miss.miss_way),
        .miss_pop(miss_pop), .miss_tail_valid(miss_tail_valid),
        .miss_tail_addr(miss_tail_addr), .miss_tail_way(miss_tail_way),
        .full(miss_req_full), .empty(miss_req_empty), .count(miss_count)
    );

    // ---------------- memory request ----------------
    logic [ROB_ID_W-1:0] rob_next_free_entry;
    logic mem_req_fire;
    assign mem.req_valid = miss_tail_valid && !rob_full;
    assign mem.req_addr = miss_tail_addr;
    assign mem.req_id = rob_next_free_entry;
    assign mem_req_fire = mem.req_valid && mem.req_ready;
    assign miss_pop = mem.req_ready && !rob_full;   // FIFO also requires tail valid

    // ---------------- reorder buffer ----------------
    rob_entry_t rob_tail_entry;
    logic rob_pop, bad_return;
    logic [ROB_ID_W:0] rob_count;

    reorder_buffer rob (
        .clk(clk), .n_rst(n_rst),
        .miss_push(mem_req_fire), .miss_tail_addr(miss_tail_addr), .miss_tail_way(miss_tail_way),
        .rob_next_free_entry(rob_next_free_entry),
        .mem_return_valid(mem.rsp_valid), .transaction_id(mem.rsp_id),
        .tex_load_in(mem.rsp_data), .rob_return_ready(mem.rsp_ready),
        .rob_pop(rob_pop), .rob_tail_entry(rob_tail_entry),
        .rob_empty(rob_empty), .rob_full(rob_full), .rob_count(rob_count),
        .bad_return(bad_return), .protocol_error(protocol_error)
    );

    // ---------------- refill (ROB tail -> tag + data arrays) ----------------
    logic refill_valid;
    assign refill_valid = rob_tail_entry.valid && rob_tail_entry.completed;

    assign tag_refill.fill_bank = rob_tail_entry.line_addr[OFFSET_W +: BANK_W];
    assign tag_refill.fill_idx  = rob_tail_entry.line_addr[OFFSET_W+BANK_W +: INDEX_W];
    assign tag_refill.fill_way  = rob_tail_entry.way;
    assign data_fill_bank = rob_tail_entry.line_addr[OFFSET_W +: BANK_W];
    assign data_fill_set  = rob_tail_entry.line_addr[OFFSET_W+BANK_W +: SET_W];
    assign data_fill_way  = rob_tail_entry.way;
    assign data_fill_line = rob_tail_entry.data;

    // Each sink is only offered the fill when the other also accepts.
    assign tag_refill.fill_en = refill_valid && data_fill_ready;
    assign data_fill_valid = refill_valid && tag_refill.fill_ready;
    assign rob_pop = refill_valid && data_fill_ready && tag_refill.fill_ready;

`ifndef SYNTHESIS
    // A completed tail whose way is not allocated-and-unfilled can never be
    // accepted by the tag array: that would stall the miss path forever.
    always @(posedge clk) begin : check_refill_target
        if (n_rst && refill_valid && data_fill_ready && !tag_refill.fill_ready)
            $error("miss_path: ROB tail %h way %0d has no reserved tag slot",
                   rob_tail_entry.line_addr, rob_tail_entry.way);
    end
`endif
endmodule
