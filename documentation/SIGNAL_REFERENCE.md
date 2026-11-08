# Signal reference: what was added on `TODO-fixes-by-claude`

This file lists every signal, port, parameter, struct field and interface member that was **added, renamed, retyped or removed**, one source file at a time. Signals that were already there and unchanged are not listed.

Conventions:
- **Dir** is relative to the module (in / out / internal). For interface members it names the modport that drives the signal.
- Widths use the default package geometry: `LANES = BANKS = WAYS = 4`, `ADDR_W = 32`, `LINE_BITS = 1024`, `TEXEL_BITS = 64`, `ROB_DEPTH = 32`.
- "TODO" means the TODO ID from `TODO_by_stage.md` that the item resolves.

---

## 1. `packages/cache_pkg.sv`

### Parameters
| Name | Value | Status | Meaning |
|---|---|---|---|
| `ROB_ID_W` | `$clog2(ROB_DEPTH)` = 5 | **new** localparam | Width of a memory transaction ID. The ID *is* the ROB slot index; 5 bits matches the miss-path diagram (R2). It replaces the old commented-out `ID_WIDTH = 32`. |
| `ID_WIDTH` | — | **removed** | Lived only in the dead, commented-out legacy package at the top of the file. That whole block was deleted. |

### `coalesced_addr_out_t` (one pixel after address calc + coalescing)
| Field | Width | Status | Meaning |
|---|---|---|---|
| `tap_mask` | `[LANES-1:0]` | **renamed** from `used` (C1) | Which taps the filter mode requests, in tap order c00, c10, c01, c11. Nearest = `0001`; bilinear/trilinear = `1111`. Not to be confused with `lines[g].tap_mask`, the per-group subset. Struct width is unchanged (243). |

### `tag_lookup_t` (one group's tag request)
| Field | Width | Status | Meaning |
|---|---|---|---|
| `tap_mask` | `[LANES-1:0]` | **new** (G1/C2) | Which taps belong to this line group. `tag_array` latches it and returns it unchanged as `bank_tap_mask`. It also has a sim check that a valid group never has an all-zero mask. The struct grew from 26 to **30 bits**. |

### `miss_req_entry_t` — **new struct** (M1/M2), 34 bits
| Field | Width | Meaning |
|---|---|---|
| `line_addr` | `[ADDR_W-1:0]` | Line-aligned miss address `{tag, index, bank, 7'b0}`. |
| `miss_way` | `[WAY_W-1:0]` | The way the tag array reserved for this line. Refill must write exactly this way. |

One `miss_request_fifo` entry. No coalescing fields are needed, because a second request to a pending line hits the reservation and never creates a second miss.

### `rob_entry_t` (now 1060 bits)
| Field | Width | Status | Meaning |
|---|---|---|---|
| `way` | `[WAY_W-1:0]` | **new** | Reserved way carried from the miss FIFO into the ROB, so the refill knows which way to fill in the tag and data arrays. The other fields (`valid`, `completed`, `line_addr`, `data`) are unchanged. |

### `texture_cache_return_t` — **new struct** (T2/P2), 1157 bits
One return to the TMU: a whole quad at one mip level, in the same order the requests arrived.

| Field | Width | Meaning |
|---|---|---|
| `tmu_quad_metadata` | `tmu_quad_metadata_t` (37) | Quad-wide pass-through: `reserved`, `warp_id`, `rd`, `quad_index`, `filter_mode`, `lod_fraction`, `upper_mip`. Sent once per quad. |
| `u_frac`, `v_frac` | `[3:0][7:0]` each | Per-pixel bilinear fractions, passed through unchanged. |
| `texel_valid` | `[3:0][LANES-1:0]` | `[pixel][tap]`: 1 = the texel was read from the cache. 0 = tap not requested (e.g. taps 1..3 under nearest), or the pixel faulted. |
| `addr_error` | `[3:0][LANES-1:0]` | `[pixel][tap]`: requested taps whose address faulted. Any fault rejects the **whole pixel**: all four of its taps return 0 with `texel_valid = 0`. |
| `texels` | `[3:0][LANES-1:0][63:0]` | `[pixel][tap]` texel data. Zero wherever `texel_valid = 0`. |

### Comment-only change
- `base_address_t`: the "ASK ALEC" TODO became a documented open question. `log2_width`/`log2_height` are now consumed by `addr_calc`. `max_mip_level` is only range-checked in simulation.

---

## 2. `interfaces/tag_array_if.sv`

These signals were already used by `tag_array.sv` but never declared, which is why it didn't compile (G2).

| Signal | Width | Driver (modport) | Meaning |
|---|---|---|---|
| `busy` | 1 | `tag_array` | A pixel is held in the tag engine: it was accepted and its response hasn't been taken yet (`= active`). |
| `bank_result_valid` | `[BANKS-1:0]` | `tag_array` | Per bank: one group's lookup result is available as an early result. A hit is offered immediately; a new miss only once the miss FIFO accepts it the same cycle. |
| `bank_result_ready` | `[BANKS-1:0]` | consumer (`frontend`) | Per bank: the consumer can take that early result. A new miss also needs this high ("reserved preparation capacity") before it is offered on the miss channel. `hit_path_temp` ties it to `'1` because it only uses the complete `rsp`. |
| `bank_result` | `tag_out_t [BANKS-1:0]` | `tag_array` | Per bank early result `{hit, ready, hit_way}`. |
| `bank_tap_mask` | `[BANKS-1:0][LANES-1:0]` | `tag_array` | The `tap_mask` of the group that produced `bank_result[b]`, so the consumer knows which taps it covers. |

Modport changes:
- `tag_array`: added `bank_result_ready` as input; added `busy`, `bank_result_valid`, `bank_result` and `bank_tap_mask` as outputs.
- `frontend`: added `bank_result_ready` as output; added `busy`, `bank_result_valid`, `bank_result` and `bank_tap_mask` as inputs.

---

## 3. `interfaces/interfaces.vh`

### `texture_cache_return_if` — **new interface** (T2/P2/X1): T$ → TMU
| Signal | Width | Driver | Meaning |
|---|---|---|---|
| `valid` | 1 | `sender` (cache) | `payload` holds a complete quad. Stays high, with `payload` held, until `ready`. |
| `ready` | 1 | `receiver` (TMU) | TMU accepts the quad this cycle. |
| `payload` | `texture_cache_return_t` | `sender` | See §1. |

Modports: `sender` (cache side, used by `hit_path_temp` as `tmu_rsp`) and `receiver` (TMU side).

### `mem_if` — **new interface** (X1): miss path ↔ memory, line granularity
| Signal | Width | Driver | Meaning |
|---|---|---|---|
| `req_valid` | 1 | `cache` | Line request available. `= miss FIFO tail valid && !rob_full`. Held until `req_ready`. |
| `req_ready` | 1 | `memory` | Memory accepts the request. On `req_valid && req_ready` the miss FIFO pops and the ROB allocates. |
| `req_addr` | `[ADDR_W-1:0]` | `cache` | Line-aligned address being fetched. |
| `req_id` | `[ROB_ID_W-1:0]` | `cache` | ROB slot that will receive the line. Memory must echo it on the return. |
| `rsp_valid` | 1 | `memory` | A full line is being returned. Returns may come back in any order. |
| `rsp_ready` | 1 | `cache` | Cache accepts the return. Always high after reset today. |
| `rsp_id` | `[ROB_ID_W-1:0]` | `memory` | Which request (ROB slot) this line answers. |
| `rsp_data` | `[LINE_BITS-1:0]` | `memory` | The 128 B line. Byte *j* is at `[8j +: 8]`. |

Modports: `cache` (used by `miss_path` and `hit_path_temp`) and `memory` (memory model / memory subsystem).

`texture_cache_request_if` is unchanged.

---

## 4. `src/address_calculation.sv`

### `address_calculation` (per-pixel wrapper): new ports (A3/A4)
| Port | Width | Dir | Meaning |
|---|---|---|---|
| `log2_width` | 5 | in | log2 of the **selected** mip's width (`texture_cache_request_t.log2_width`). Fed to all four `addr_calc`. |
| `log2_height` | 5 | in | log2 of the selected mip's height. |

Changed output field: `coa_addr_out.tap_mask` is the renamed `coa_addr_out.used` (C1). The internal net `used` keeps its name.

### `addr_calc` (one tap): new parameter, ports and internals
| Name | Kind / width | Meaning |
|---|---|---|
| `COORD_W` | parameter, default 16 | Width of the TMU texel coordinates. `x`/`y` were hard-coded 16-bit before and are now `[COORD_W-1:0]` (A4). |
| `log2_width`, `log2_height` | in, 5 each | Selected-mip dimensions: the mip is `2^lw × 2^lh` texels. |
| `MORTON_BITS` | localparam = `2*COORD_W` | Width of `morton_index`. |
| `TEXEL_SHIFT` | localparam = `$clog2(TEXEL_BYTES)` = 3 | Shift that turns a texel index into a byte offset. Replaces the literal `3'b0`. |
| `SUM_W` | localparam = 36 at defaults | Width of the base + offset adder: one bit more than the widest operand, so a carry past bit 31 is visible. |
| `full_addr` | internal, `[SUM_W-1:0]` | Was a fixed `[35:0]`. `base_addr + (morton_index << TEXEL_SHIFT)`. |
| `morton_index` | internal, `[MORTON_BITS-1:0]` | Was assigned by a `genvar` loop; now assigned in `always_comb morton_swizzle`. The low `sq` bits of x/y are interleaved (x even, y odd). The remaining bits of the longer axis are appended starting at bit `2*sq`. |
| `lw`, `lh` | internal `int unsigned` | `log2_width`/`log2_height` clamped to `COORD_W`. |
| `sq` | internal `int unsigned` | `min(lw, lh)`: the size of the square Z-tile part. |
| `coord_error` | internal, 1 | Set when a coordinate bit is outside the mip (`x[b]` with `b ≥ lw`, or `y[b]` with `b ≥ lh`), or when the mip is wider than `COORD_W`. ORed into `addr_out.addr_error`. |

`addr_out.addr_error` now = carry past bit 31 | base not 8 B aligned | `coord_error`.

Also: the stray `coa_addrs` token at line 177 (introduced in `eddf2eb`) was removed. No signal change.

---

## 5. `src/coalesced_fragment_adapter.sv`
| Signal | Change | Meaning |
|---|---|---|
| `tag_req[g].tap_mask` | **newly driven** (C2) | `= coa_addr_out.lines[g].tap_mask`. |
| `frag_in.used` | source renamed | Now driven from `coa_addr_out.tap_mask` (was `.used`). `frag_data_t.used` itself kept its name. |

---

## 6. `src/tag_array.sv`
No new signals. One behaviour change on an existing register:
| Signal | Change | Meaning |
|---|---|---|
| `route_ptr[b]` | now cleared to 0 on `req_fire` (G3) | Same-bank groups of each new pixel are looked up in ascending group order, so way assignment no longer depends on history. |

The G4 deadlock TODO became a comment explaining why forward progress is guaranteed.

---

## 7. `src/frag_fifo.sv`
| Name | Kind | Meaning |
|---|---|---|
| `FULL_BYPASS` | **new** parameter `bit`, default `0` (F2) | 0: `ready_in = !full` (unchanged behaviour). 1: `ready_in = !full \|\| pop`, so a push and a pop in the same cycle both fire while full. This adds a combinational path from `pop` to `ready_in`. |
| `pop` | existing input, now documented (F1) | "The backend took ownership of `tail_data` this cycle." Driven by the read-issue stage in `hit_path_temp` (`frag_pop`). |

---

## 8. `src/miss_request_fifo.sv`
| Name | Kind | Meaning |
|---|---|---|
| `FULL_BYPASS` | **new** parameter `bit`, default `0` (M4) | Same meaning as in `frag_fifo`: `miss_ready = !full \|\| miss_pop`. |
| `miss_pop` | existing input, now documented (M3) | Must mean "memory accepted the request **and** the ROB allocated a slot". `miss_path` drives it as `mem.req_ready && !rob_full`. |
| `check_no_duplicate_miss` | **new** sim-only `always` block | `$error` if a pushed `miss_addr` already sits in the FIFO (not counting the entry popped that same cycle). That would mean a reservation was lost. |

---

## 9. `src/reorder_buffer.sv` (module renamed `top` → `reorder_buffer`, R1)

### Parameters
| Name | Status | Meaning |
|---|---|---|
| `DEPTH` | **new**, default `ROB_DEPTH` | Number of slots. Must be a power of two ≥ 2 (sim `$fatal`). |
| `PTR_WIDTH` | kept, now derived from `DEPTH` | Slot-index width. |
| `ROB_IDX_BITS` | **removed** | Duplicated `PTR_WIDTH`. Ports now use `PTR_WIDTH`. |

### Ports
| Port | Width | Dir | Status | Meaning |
|---|---|---|---|---|
| `miss_tail_way` | `[WAY_W-1:0]` | in | **new** | Reserved way of the miss being allocated. Stored in the entry. |
| `rob_count` | `[PTR_WIDTH:0]` | out | **new** | Number of allocated slots (`head_ptr - tail_ptr`). |
| `bad_return` | 1 | out | **new** | One-cycle pulse: a memory return hit a slot that is not allocated, or that already completed. The return is dropped. |
| `protocol_error` | 1 | out | **new** | Sticky until reset: some `bad_return` happened. |
| `miss_push`, `miss_tail_addr`, `rob_next_free_entry`, `mem_return_valid`, `transaction_id`, `tex_load_in`, `rob_return_ready`, `rob_pop`, `rob_tail_entry`, `rob_empty`, `rob_full` | — | — | kept | Same names as the miss-path diagram. `rob_return_ready` is now `n_rst` instead of a constant 1. `rob_tail_entry.way` is new (via the struct). |

### Internals
| Signal | Width | Status | Meaning |
|---|---|---|---|
| `entry_valid` | `[DEPTH-1:0]` | **new** | Per-slot allocated bit, reset to 0. Previously stored inside the non-reset payload RAM, so it read as X after reset. |
| `entry_completed` | `[DEPTH-1:0]` | **new** | Per-slot "line has returned" bit, reset to 0. |
| `head_idx`, `tail_idx` | `[PTR_WIDTH-1:0]` | **new** | `head_ptr`/`tail_ptr` without the wrap bit. |
| `return_ok` | 1 | **new** | `entry_valid[id] && !entry_completed[id]`: the return is legal. |
| `next_head_ptr`, `next_tail_ptr`, `head_entry` | — | **removed** | Folded into the sequential block. |

---

## 10. `src/miss_path.sv` — **new module** (M3, M6, R4, G4)

### Ports
| Port | Width / type | Dir | Meaning |
|---|---|---|---|
| `clk`, `n_rst` | 1 | in | Clock and async active-low reset. |
| `tag_miss` | `tag_array_if.miss_path` | modport | Miss descriptors from the tag array (`miss_valid/addr/way` in, `miss_ready` out). |
| `tag_refill` | `tag_array_if.refill` | modport | Marks the reserved way ready (`fill_en/bank/idx/way` out, `fill_ready` in). |
| `mem` | `mem_if.cache` | modport | Memory request and return channels (§3). |
| `data_fill_valid` | 1 | out | Write a returned line into the data array. Only asserted when the tag fill is also ready. |
| `data_fill_ready` | 1 | in | Data array accepts the line fill. |
| `data_fill_bank` | `[BANK_W-1:0]` | out | `line_addr[8:7]` of the ROB tail. |
| `data_fill_set` | `[SET_W-1:0]` | out | `line_addr[11:9]` of the ROB tail. |
| `data_fill_way` | `[WAY_W-1:0]` | out | Reserved way from the ROB tail. |
| `data_fill_line` | `[LINE_BITS-1:0]` | out | Returned line, forwarded on the same cycle it arrives if it lands on the tail. |
| `miss_req_empty`, `miss_req_full` | 1 each | out | Miss FIFO status (side outputs on the diagram). |
| `rob_empty`, `rob_full` | 1 each | out | ROB status. |
| `protocol_error` | 1 | out | Sticky ROB `protocol_error` (bad memory return). |

### Internals
| Signal | Width | Meaning |
|---|---|---|
| `miss_pop` | 1 | `mem.req_ready && !rob_full`. The FIFO additionally needs tail valid. |
| `miss_tail_valid`, `miss_tail_addr`, `miss_tail_way` | 1 / 32 / 2 | Miss FIFO tail. |
| `miss_count` | `$clog2(MISS_REQ_DEPTH+1)` | FIFO occupancy (unused, kept for debug). |
| `rob_next_free_entry` | `[ROB_ID_W-1:0]` | Slot the next request will get; drives `mem.req_id`. |
| `mem_req_fire` | 1 | `mem.req_valid && mem.req_ready`. This is the ROB `miss_push`. |
| `rob_tail_entry` | `rob_entry_t` | Oldest outstanding miss (with any same-cycle return forwarded). |
| `rob_pop` | 1 | `refill_valid && data_fill_ready && tag_refill.fill_ready`: both arrays accepted the refill. |
| `bad_return` | 1 | ROB pulse (unused here; the sticky version goes out as `protocol_error`). |
| `rob_count` | `[ROB_ID_W:0]` | ROB occupancy (debug). |
| `refill_valid` | 1 | `rob_tail_entry.valid && completed`: the tail line is ready to install. |

Driven interface signals:
- `tag_refill.fill_en = refill_valid && data_fill_ready`.
- `fill_bank/idx/way` come from the tail entry.
- `mem.req_valid = miss_tail_valid && !rob_full`.
- `mem.req_addr = miss_tail_addr`.

Sim check `check_refill_target`: `$error` if a completed tail has no allocated-but-unfilled tag slot. That case would stall the miss path forever.

---

## 11. `src/payload_buffer.sv` — **new module** (P1)

### Parameter
| Name | Default | Meaning |
|---|---|---|
| `COOKIE_W` | 4 | Data-array cookie width. It must hold `{pixel_id[1:0], tap[1:0]}` (sim `$fatal` if < 4). |

### Ports
| Port | Width / type | Dir | Meaning |
|---|---|---|---|
| `clk`, `n_rst` | 1 | in | Clock and reset. |
| `alloc_valid` | 1 | in | The read-issue stage wants to hand over a pixel (the frag FIFO tail). |
| `alloc_ready` | 1 | out | The slot `alloc_frag.pixel_id` is free in the assembly quad. Low while that pixel of the current quad is already present. This is how the next quad waits. |
| `alloc_frag` | `frag_data_t` | in | Pixel metadata, `used`, `addr_error`, `pixel_id`, `batch_id`. |
| `wr_valid` | `[BANKS-1:0]` | in | Data-array read responses (`rd_rsp_valid`). Up to 4 per cycle, in any order. |
| `wr_cookie` | `[BANKS-1:0][COOKIE_W-1:0]` | in | `{pixel_id, tap}` of each response. |
| `wr_data` | `[BANKS-1:0][63:0]` | in | Texel data. |
| `rsp_valid` | 1 | out | Output quad valid (→ `tmu_rsp.valid`). |
| `rsp_ready` | 1 | in | TMU took it (← `tmu_rsp.ready`). |
| `rsp_payload` | `texture_cache_return_t` | out | Output quad, held stable while stalled. |

### Internals
| Signal | Width | Meaning |
|---|---|---|
| `asm_q` | `texture_cache_return_t` | Assembly quad being filled. |
| `asm_seen` | `[3:0]` | Which pixels of the current quad have been allocated. |
| `asm_pending` | `[3:0][LANES-1:0]` | Texels still awaited, per `[pixel][tap]`. |
| `asm_complete` | 1 | All 4 pixels seen and nothing pending. |
| `transfer` | 1 | `asm_complete && (!rsp_valid \|\| rsp_ready)`: move the assembly quad to the output register and clear `asm_seen`. |
| `alloc_fire` | 1 | `alloc_valid && alloc_ready`. |
| `alloc_pix` | 2 | `alloc_frag.pixel_id`. |
| `alloc_fault` | `[LANES-1:0]` | `used & addr_error` of the incoming pixel. |
| `alloc_reads` | `[LANES-1:0]` | Texels that will actually arrive: `used`, or `0` if the pixel has any fault. This becomes both `asm_pending` and `texel_valid`. |
| `asm_batch` | `[BATCH_ID_W-1:0]` | Sim only: `batch_id` of pixel 0, used to check the quad doesn't change batch. |

Sim checks in `protocol_checks`:
- pixels must be allocated in order 0→3;
- `batch_id` must stay constant within a quad;
- `$error` on an unexpected or duplicate texel write.

---

## 12. `src/hit_path_temp.sv` — top level, rewritten

### Module `hit_path_temp`: parameter and ports
| Name | Width / type | Dir | Status | Meaning |
|---|---|---|---|---|
| `READ_LATENCY` | parameter, default 1 | — | **new** | Passed to `data_array`. |
| `tmu_req` | `texture_cache_request_if.addr_calc` | modport | kept | TMU quad request. Its own `valid`/`ready` are now used. |
| `tmu_valid` | — | — | **removed** | Duplicated `tmu_req.valid`. |
| `tcache_ready` | — | — | **removed** | Duplicated `tmu_req.ready`, which is now driven by the top. |
| `tmu_rsp` | `texture_cache_return_if.sender` | modport | **new** (T2/P2) | Quad returns to the TMU. |
| `mem` | `mem_if.cache` | modport | **new** | Memory port for the miss path. |
| `protocol_error` | 1 | out | **new** | Sticky: data array malformed request OR ROB bad return. |
| `replay_error` | 1 | out | **new** | Sticky: a queued pixel read a line whose tag no longer matches (evicted before read). There is no replay yet. See README "Known gaps". |

Driven interface outputs:
- `tmu_req.ready = tmu_req.valid && pixel_id == 3 && pixel_done` (T5).

### Internal signals by section

**TMU signal reorganisation** (T1)
| Signal | Width / type | Meaning |
|---|---|---|
| `req` | `texture_cache_request_t` | `= tmu_req.payload`. Shorthand; all fields go through it. |
| `base_info` | `base_address_t` | Packed mip descriptor for `mip_base_addr`. |
| `base_addr` | `[31:0]` | Mip-adjusted base address. Was mis-declared as 1 bit. |
| `tmu_quad_info` | `tmu_quad_metadata_t` | Quad pass-through metadata. Now also carries `texture_header.reserved` (was zeroed). |
| `tmu_pixel_info` | `tmu_pixel_metadata_t [3:0]` | Per-pixel metadata. `v_frac` now comes from `req.v_frac` (the old code wrongly copied `u_frac`). |
| `pixel_taps` | `pixel_taps_t [3:0]` | Per-pixel x/y of the 4 taps. |

**Pixel arbitration** (T3–T6, T8)
| Signal | Width / type | Meaning |
|---|---|---|
| `pixel_done` | 1 | `tag_if.rsp_valid && tag_if.rsp_ready`: the current pixel's complete tag response was pushed into the frag FIFO. Advances `pixel_id`. |
| `pixel_id` | 2 | Pixel currently in the frontend (0..3). |
| `pixel_tap_sel` | `pixel_taps_t` | Taps of the selected pixel. |
| `pixel_metadata_sel` | `tmu_pixel_metadata_t` | Metadata of the selected pixel. Flows through address calc into the fragment. |
| `batch_id` | `[BATCH_ID_W-1:0]` | Counts accepted quads; shared by its 4 pixels. Increments on `tmu_req.valid && tmu_req.ready`. |

**Address calculation** (A1/A2)
| Signal | Width / type | Meaning |
|---|---|---|
| `coa_addr_out` | `coalesced_addr_out_t` | Output of `address_calculation` for the selected pixel. Stays stable while that pixel is in the tag array. |

**Tag array** (G6)
| Signal | Width / type | Meaning |
|---|---|---|
| `tag_if` | `tag_array_if` instance | Shared by `tag_array`, the adapter wiring and `miss_path`. |
| `tag_req` | `tag_lookup_t [LANES-1:0]` | Adapter output → `tag_if.req`. |
| `frag_in` | `frag_data_t` | Adapter output: `coa_addr_out` + held `tag_if.rsp` = the pixel's complete fragment entry. |
| `req_sent` | 1 | The selected pixel's tag request has been accepted. Prevents a second lookup. Cleared on `pixel_done`. |
| `frag_ready_in` | 1 | Frag FIFO `ready_in` → `tag_if.rsp_ready`. |

Driven `tag_if` signals:
- `req_valid = tmu_req.valid && !req_sent`
- `req = tag_req`
- `bank_result_ready = '1`
- `rsp_ready = frag_ready_in`

**Fragment FIFO** (F1/F3)
| Signal | Width | Meaning |
|---|---|---|
| `frag_pop` | 1 | `frag_tail_valid && cur_free && pb_alloc_ready`: the read-issue stage takes the tail pixel. |
| `frag_tail_valid`, `frag_tail` | 1 / `frag_data_t` | FIFO tail. |
| `frag_batch_committed`, `frag_full`, `frag_empty`, `frag_count` | — | FIFO status outputs (debug). |

**Line-state mirror** (needed because a fragment's `data_ready` goes stale while it waits in the FIFO)
| Signal | Width | Meaning |
|---|---|---|
| `line_ready` | `[BANKS][SETS_PER_BANK][WAYS]` bits | Mirror of the tag array's per-way ready bit. Cleared on a committed miss allocation, set on a refill. Reset to 0. |
| `line_tag` | `[TAG_W-1:0]` per bank/set/way | Tag written at miss allocation. Used to detect a line evicted before a queued pixel reads it. Not reset (masked by `line_ready`). |
| `miss_fire` | 1 | `tag_if.miss_valid && tag_if.miss_ready` (allocation committed). |
| `fill_fire` | 1 | `tag_if.fill_en && tag_if.fill_ready` (refill landed). |
| `miss_bank`, `miss_idx` | 2 / 3 | Bank and set decoded from `tag_if.miss_addr`. |

**Data-array read issue**
| Signal | Width | Meaning |
|---|---|---|
| `cur_valid` | 1 | The issue register holds a pixel. |
| `cur` | `frag_data_t` | The pixel whose reads are being issued. |
| `cur_pending` | `[LANES-1:0]` | Taps of `cur` not yet issued. Loaded as `used`, or `0` if the pixel faulted. |
| `cur_free` | 1 | `!cur_valid` or all pending taps issue this cycle; the next pixel may be popped. |
| `pb_alloc_ready` | 1 | Payload-buffer `alloc_ready` for the tail's `pixel_id`. |
| `tap_ok` | `[LANES-1:0]` | Tap is pending and its line is ready in the mirror. |
| `sel_tap` | `[BANKS-1:0][1:0]` | Per bank, the lowest ready pending tap mapping to it. Same-bank taps serialise. |
| `issued` | `[LANES-1:0]` | Taps whose read was accepted this cycle (`rd_valid && rd_ready`). |
| `stale_issue` | `[BANKS-1:0]` | An issued read's `line_tag` ≠ the tap's address tag. Sets `replay_error`. |
| `rd_valid`, `rd_ready`, `rd_set`, `rd_way`, `rd_byte_offset`, `rd_cookie` | per bank | Data-array read request. Cookie = `{cur.pixel_id, sel_tap[b]}`. |
| `rd_rsp_valid`, `rd_rsp_data`, `rd_rsp_cookie` | per bank | Data-array responses → payload buffer writes. |

**Data array / miss path glue**
| Signal | Width | Meaning |
|---|---|---|
| `data_fill_valid`, `data_fill_ready`, `data_fill_bank`, `data_fill_set`, `data_fill_way`, `data_fill_line` | see §10 | `miss_path` ↔ `data_array` fill port. |
| `data_protocol_error` | 1 | `data_array` sticky error. |
| `miss_req_empty`, `miss_req_full`, `rob_empty`, `rob_full` | 1 each | `miss_path` status (debug). |
| `miss_protocol_error` | 1 | `miss_path` sticky error (ROB bad return). |

**Sim-only** (T7)
| Signal | Meaning |
|---|---|
| `exp_lw`, `exp_lh` | Expected selected-mip dims `max(mip0 - level, 0)`. `check_mip_descriptor` raises `$error` if `log2_width/height` disagree, or if `mip_level > max_mip_level`. |

### Module `round_robin_arbiter`: ports retyped (T1/T8)
| Port | Old | New |
|---|---|---|
| `pixel_taps_in` | `pixel_taps_t [3:0]` followed by `;` (syntax error) | `cache_pkg::pixel_taps_t [3:0]` |
| `pixel_metadata_in` | `tmu_pixel_info [3:0]` (type didn't exist) | `cache_pkg::tmu_pixel_metadata_t [3:0]` |
| `pixel_tap_sel` | assigned as `pixel_taps_sel` (name mismatch) | name fixed |
| `pixel_metadata_sel` | declared as a 4-element array | single `tmu_pixel_metadata_t` |
| `tmu_ready` (commented out) | — | moved to the top level (T5) |

`mip_base_addr` is unchanged.

---

## 13. Testbench-only signals (summary)

These are not part of the design; they're listed here so they make sense when you see them in waveforms.

| File | Signals added | Purpose |
|---|---|---|
| `address_calculation_tb.sv` | `log2_width`, `log2_height` (DUT ports, set to 16); `ac_lw`, `ac_lh` (standalone `addr_calc` dims) | New ports. Mip-aware tests vary `ac_lw`/`ac_lh`. |
| `coalescer_tb.sv` | `log2_width`, `log2_height` (= 16) | New DUT ports. 16/16 keeps the plain-interleave reference valid. |
| `fragment_fifo_tb.sv` | `bp_*` (`bp_valid_in`, `bp_ready_in`, `bp_pop`, `bp_tail_data`, `bp_count`, …) | Second DUT instance `dut_bypass` with `DEPTH = 2, FULL_BYPASS = 1`. |
| `miss_request_fifo_tb.sv` | `bp_*` (`bp_valid`, `bp_ready`, `bp_addr`, `bp_way`, `bp_pop`, `bp_tail_*`, `bp_count`, …) | Same, for the miss FIFO. |
| `tag_array_tb.sv` | none (new task `plru_order`) | PLRU order tests. |
| `reorder_buffer_tb.sv` | full rewrite: DUT port mirrors plus `model[]`, `head`, `tail`, `size`, `exp_error`, `rid` | Reference model of slots. `rid` = picked return id. |
| `payload_buffer_tb.sv` | DUT port mirrors plus `writes[$]` (pending texel writes with due cycle), `expected[$]`, `held`/`holding` | Out-of-order write driver and in-order scoreboard. |
| `hit_path_temp.sv` (TB) | `tmu_req`, `tmu_rsp`, `mem` interface instances; `outstanding[$]` (memory model requests); `expected[$]`; `pick`; `cov_fault_pix`, `cov_pending_hit`, `cov_bank_serial`, `cov_tmu_stall` | TMU model, out-of-order memory model, scoreboard and coverage counters. |
