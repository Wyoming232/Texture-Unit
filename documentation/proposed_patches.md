# Proposed patches (for review — not applied to RTL)

Minimal additions, inferred from how `src/tag_array.sv` and
`src/miss_request_fifo.sv` already use them, that make those modules (and
`tag_array_tb` / `miss_request_fifo_tb`) compile. The widths are the only
ones consistent with the RTL usage; the *names* are the RTL's.

Side effect to be aware of: adding `tap_mask` to `tag_lookup_t` makes it
30 bits, so `coalescer_tb` (`$bits(tag_lookup_t) != 26`) must be updated and
`coalesced_fragment_adapter` should start driving `tag_req[g].tap_mask =
coa_addr_out.lines[g].tap_mask`.

```diff
diff --git a/interfaces/tag_array_if.sv b/interfaces/tag_array_if.sv
--- a/interfaces/tag_array_if.sv
+++ b/interfaces/tag_array_if.sv
@@ -17,6 +17,12 @@ interface tag_array_if;
     // response from hit=0 to hit=1 before the miss request is retained.
     logic rsp_valid, rsp_ready;
     cache_pkg::tag_out_t [cache_pkg::LANES-1:0] rsp;
+    logic busy;
+
+    // Per-bank early results (used by tag_array.sv, inferred from usage).
+    logic [cache_pkg::BANKS-1:0] bank_result_valid, bank_result_ready;
+    cache_pkg::tag_out_t [cache_pkg::BANKS-1:0] bank_result;
+    logic [cache_pkg::BANKS-1:0][cache_pkg::LANES-1:0] bank_tap_mask;
 
     // Stream one newly allocated line to the miss path at a time, including
     // while other groups of this pixel still wait for a bank/set. Each tag
@@ -53,9 +59,10 @@ interface tag_array_if;
     );
 
     modport tag_array (
-        input req_valid, req, rsp_ready, miss_ready,
+        input req_valid, req, rsp_ready, miss_ready, bank_result_ready,
               fill_en, fill_bank, fill_idx, fill_way,
-        output req_ready, rsp_valid, rsp, fill_ready,
+        output req_ready, rsp_valid, rsp, fill_ready, busy,
+               bank_result_valid, bank_result, bank_tap_mask,
                miss_valid, miss_addr, miss_way
     );
 endinterface : tag_array_if
diff --git a/packages/cache_pkg.sv b/packages/cache_pkg.sv
--- a/packages/cache_pkg.sv
+++ b/packages/cache_pkg.sv
@@ -165,6 +165,7 @@ package cache_pkg;
     // valid disables empty groups; it is distinct from channel req_valid.
     typedef struct packed {
         logic valid;
+        logic [LANES-1:0] tap_mask;
         logic [BANK_W-1:0] bank;
         logic [INDEX_W-1:0] index;
         logic [TAG_W-1:0] tag;
@@ -201,8 +202,12 @@ package cache_pkg;
     } frag_data_t;
     typedef frag_data_t frag_entry_t;
 
-    // TODO : define structs for MISS REQ FIFO
     // ----------------------MISS REQUEST FIFO----------------------
+    // Packed as {miss_addr, miss_way} by miss_request_fifo.
+    typedef struct packed {
+        logic [ADDR_W-1:0] line_addr;
+        logic [WAY_W-1:0] miss_way;
+    } miss_req_entry_t;
     
     // ----------------------ROB----------------------
     parameter integer ROB_DEPTH=32;
```
