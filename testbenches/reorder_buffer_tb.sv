/*
  Notes on the reorder buffer

  - holds outstanding misses and releases them in order
  - transaction id = slot index handed out at allocation (rob_next_free_entry)
  - memory may return in any order; only a completed TAIL can be popped
  - a return landing on the tail is forwarded the same cycle

  Decisions recorded from the old sketch of this TB:
  - epoch_i: not implemented. Returns to an unallocated or already-completed
    slot are dropped and flagged (bad_return pulse, sticky protocol_error).
    A pre-reset return reaching a slot re-allocated after reset cannot be
    detected; the memory subsystem is assumed to reset with the cache.
  - mem_req_valid: lives in miss_path (miss FIFO tail valid && !rob_full);
    the ROB only sees the accepted request as miss_push.
  - tail entry type is cache_pkg::rob_entry_t.

  Testcases
  - reset: empty, not full, count 0, no protocol_error
  - allocation hands out ids 0,1,2,... and carries line_addr + way
  - out-of-order returns: tail is not poppable until ITS line returns,
    younger completed entries are held
  - return on the tail + rob_pop in the same cycle: pops with forwarded data
  - full: miss_push refused, rob_full high, count = DEPTH
  - bad return to an unallocated slot and a duplicate return: dropped,
    bad_return pulses, protocol_error sticks, no state change
  - random push / return / pop traffic against a model (pointer wrap)
*/

`timescale 1ns/1ps
`include "src/reorder_buffer.sv"

module reorder_buffer_tb;
  import cache_pkg::*;
  localparam int DEPTH = ROB_DEPTH;
  localparam int PW = $clog2(DEPTH);

  logic clk = 0; always #5 clk = ~clk;
  logic n_rst = 0;
  logic miss_push = 0;
  logic [ADDR_W-1:0] miss_tail_addr = '0;
  logic [WAY_W-1:0] miss_tail_way = '0;
  logic [PW-1:0] rob_next_free_entry;
  logic mem_return_valid = 0;
  logic [PW-1:0] transaction_id = '0;
  logic [LINE_BITS-1:0] tex_load_in = '0;
  logic rob_return_ready;
  logic rob_pop = 0;
  rob_entry_t rob_tail_entry;
  logic rob_empty, rob_full;
  logic [PW:0] rob_count;
  logic bad_return, protocol_error;

  reorder_buffer dut (.*);

  // ---------------- reference model ----------------
  typedef struct {
    bit valid, completed;
    logic [ADDR_W-1:0] addr;
    logic [WAY_W-1:0] way;
    logic [LINE_BITS-1:0] data;
  } slot_t;
  slot_t model [DEPTH];
  int head = 0, tail = 0, size = 0;
  bit exp_error = 0;
  int errors = 0, checks = 0, pushes = 0, returns = 0, pops = 0, seq = 0;

  function automatic logic [LINE_BITS-1:0] make_line(input int salt);
    logic [LINE_BITS-1:0] l;
    for (int w = 0; w < LINE_BITS/32; w++) l[32*w +: 32] = 32'(salt * 32'h9E3779B1 + w);
    return l;
  endfunction

  task automatic check_status(input string where);
    checks++;
    if (rob_empty !== (size == 0) || rob_full !== (size == DEPTH) ||
        rob_count !== (PW+1)'(size) || rob_next_free_entry !== PW'(head) ||
        protocol_error !== exp_error) begin
      errors++;
      $error("[%s] empty=%0b full=%0b count=%0d next=%0d perr=%0b (model size %0d head %0d)",
             where, rob_empty, rob_full, rob_count, rob_next_free_entry, protocol_error,
             size, head);
    end
    if (size != 0 && (rob_tail_entry.valid !== 1'b1 ||
        rob_tail_entry.line_addr !== model[tail].addr || rob_tail_entry.way !== model[tail].way)) begin
      errors++; $error("[%s] tail entry addr %h way %0d expected %h %0d", where,
                       rob_tail_entry.line_addr, rob_tail_entry.way, model[tail].addr, model[tail].way);
    end
  endtask

  // One cycle. ret_id < 0 means no return this cycle.
  task automatic step(input bit do_push, input int ret_id, input bit do_pop, input string where);
    bit push_fire, ret_ok, pop_fire, tail_done;
    logic [LINE_BITS-1:0] ret_data, tail_data;
    miss_push = do_push;
    miss_tail_addr = {20'(seq * 13 + 5), 5'(seq), {OFFSET_W{1'b0}}};
    miss_tail_way = WAY_W'(seq);
    mem_return_valid = (ret_id >= 0);
    transaction_id = PW'(ret_id);
    ret_data = make_line(ret_id * 1000 + seq);
    tex_load_in = ret_data;
    rob_pop = do_pop;
    #1;
    push_fire = do_push && size < DEPTH;
    ret_ok = (ret_id >= 0) && model[ret_id].valid && !model[ret_id].completed;
    tail_done = size > 0 && (model[tail].completed || (ret_ok && ret_id == tail));
    tail_data = (ret_ok && ret_id == tail) ? ret_data : model[tail].data;
    pop_fire = do_pop && tail_done;
    checks++;
    if (bad_return !== ((ret_id >= 0) && !ret_ok)) begin
      errors++; $error("[%s] bad_return=%0b expected %0b", where, bad_return, (ret_id >= 0) && !ret_ok);
    end
    if (size > 0 && rob_tail_entry.completed !== tail_done) begin
      errors++; $error("[%s] tail completed=%0b expected %0b", where, rob_tail_entry.completed, tail_done);
    end
    if (pop_fire && rob_tail_entry.data !== tail_data) begin
      errors++; $error("[%s] popped data mismatch at slot %0d", where, tail);
    end
    @(posedge clk);
    if (ret_id >= 0 && !ret_ok) exp_error = 1;
    if (ret_ok) begin model[ret_id].completed = 1; model[ret_id].data = ret_data; returns++; end
    if (push_fire) begin
      model[head] = '{1, 0, miss_tail_addr, miss_tail_way, '0};
      head = (head + 1) % DEPTH; size++; pushes++; seq++;
    end
    if (pop_fire) begin
      model[tail].valid = 0; model[tail].completed = 0;
      tail = (tail + 1) % DEPTH; size--; pops++;
    end
    #1;
    miss_push = 0; mem_return_valid = 0; rob_pop = 0;
    check_status(where);
  endtask

  task automatic reset_rob;
    n_rst = 0;
    foreach (model[i]) model[i] = '{0, 0, '0, '0, '0};
    head = 0; tail = 0; size = 0; exp_error = 0;
    repeat (2) @(posedge clk); #1;
    n_rst = 1; #1;
    check_status("after reset");
  endtask

  // pick a random outstanding (allocated, not completed) slot, or -1
  function automatic int random_outstanding();
    int c [$];
    c.delete();   // explicit: do not rely on automatic re-initialization
    for (int i = 0; i < size; i++)
      if (!model[(tail + i) % DEPTH].completed) c.push_back((tail + i) % DEPTH);
    if (c.size() == 0) return -1;
    return c[$urandom_range(c.size() - 1)];
  endfunction

  // NOTE: assigned (not initialized) inside loops: a declaration initializer
  // in a static initial block would only run once.
  int rid;

  initial begin
    reset_rob();

    // ---- allocation ids and payload ----
    for (int i = 0; i < 4; i++) begin
      if (rob_next_free_entry !== PW'(i)) begin errors++; $error("id %0d expected %0d", rob_next_free_entry, i); end
      step(1, -1, 0, "alloc");
    end
    // ---- out-of-order returns: 2, 1, 3 -> tail (0) still blocked ----
    step(0, 2, 1, "ret 2, pop blocked");
    step(0, 1, 1, "ret 1, pop blocked");
    step(0, 3, 1, "ret 3, pop blocked");
    if (size != 4) begin errors++; $error("tail popped before its return"); end
    // ---- return on tail + pop same cycle (forwarding) ----
    step(0, 0, 1, "ret 0 + pop (forward)");
    if (size != 3) begin errors++; $error("forwarded tail was not popped"); end
    while (size > 0) step(0, -1, 1, "drain completed");

    // ---- full ----
    while (size < DEPTH) step(1, -1, 0, "fill");
    step(1, -1, 0, "push on full");
    if (size != DEPTH) begin errors++; $error("push accepted while full"); end
    // ---- duplicate / stale returns ----
    step(0, tail, 0, "return tail");
    step(0, tail, 0, "duplicate return");   // bad: already completed
    if (!protocol_error) begin errors++; $error("duplicate return not flagged"); end
    while (size > 0) begin
      rid = random_outstanding();
      step(0, rid, 1, "drain with returns");
    end
    step(0, 7, 0, "return to unallocated slot");

    // ---- random traffic (fresh reset clears the sticky error) ----
    reset_rob();
    for (int c = 0; c < 4000; c++) begin
      rid = ($urandom_range(99) < 45) ? random_outstanding() : -1;
      step(($urandom_range(99) < 40), rid, ($urandom_range(99) < 60), "random");
    end
    while (size > 0) begin
      rid = random_outstanding();
      step(0, rid, 1, "final drain");
    end
    if (protocol_error) begin errors++; $error("protocol_error during legal traffic"); end

    if (errors == 0)
      $display("PASS reorder_buffer_tb: %0d checks, %0d pushes, %0d returns, %0d pops",
               checks, pushes, returns, pops);
    else
      $fatal(1, "FAIL reorder_buffer_tb: %0d errors", errors);
    $finish;
  end
  initial begin #5000000; $fatal(1, "reorder_buffer_tb timeout"); end
endmodule
