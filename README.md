# Texture-Unit — Texture Cache (T$)

SystemVerilog RTL for the texture cache that services texel requests from the
texture mapping unit (TMU). One TMU transfer is a **quad** (four pixels) at one
mip level; each pixel carries up to four taps (`c00, c10, c01, c11`). The cache
turns those taps into Morton-swizzled byte addresses, coalesces taps that share
a 128 B line, looks them up in a 4-bank / 4-way tag array, queues the pixel in
a fragment FIFO, and reads texels from a 4-bank data array. Misses go through a
miss-request FIFO, memory, and a reorder buffer (ROB) before refilling the
arrays. A payload buffer re-assembles each quad and returns it to the TMU in
request order.

---

## Repository structure

```
.
├── src/                          RTL
│   ├── address_calculation.sv    address_calculation (per-pixel wrapper), addr_calc (per-mip
│   │                             Morton), coalesced_addrs (4-tap line coalescer)
│   ├── coalesced_fragment_adapter.sv  coalesced_addr_out_t -> tag_lookup_t[4] + frag_data_t
│   ├── tag_array.sv              tag_array (routing/stall, miss arbiter), tag_bank (4-way, tree-PLRU)
│   ├── data_array.sv             4-banked texel storage, 1 read or 1 line fill per bank/cycle
│   ├── frag_fifo.sv              fragment (pixel) FIFO between tag lookup and data read
│   ├── miss_request_fifo.sv      line-address + reserved-way queue toward memory
│   ├── reorder_buffer.sv         ROB for out-of-order memory returns
│   ├── miss_path.sv              miss FIFO + memory handshake + ROB + in-order refill
│   ├── payload_buffer.sv         quad re-assembly of data-array texels, return to the TMU
│   └── hit_path_temp.sv          cache top: TMU signal reorganisation, round-robin pixel
│                                 arbiter, mip_base_addr, all blocks above, read issue
├── interfaces/
│   ├── interfaces.vh             texture_cache_request_if (TMU -> T$), texture_cache_return_if
│   │                             (T$ -> TMU), mem_if (miss path <-> memory), includes tag_array_if
│   └── tag_array_if.sv           tag_array_if: frontend / miss_path / refill / tag_array modports
├── packages/
│   └── cache_pkg.sv              geometry parameters and every shared struct/enum
├── testbenches/                  one self-checking TB per module (see "Verification")
├── python models/
│   └── check_coalescing_model.py Boolean truth-table check of the coalescer equations
├── documentation/
│   ├── reference/                top_level_simplified.png, miss_path_simplified.png,
│   │                             mip_mapping&memory_storage.png
│   ├── hit_path/                 TMU_addr_calc.png, Addr_calc_coalescer.png,
│   │                             coalescer_tagarr_io.png, fragment_fifo_data_arr.png
│   ├── future work/              quadrupled_througput design.png  (next iteration)
│   └── proposed_patches.md       interface/package additions for tag_array & miss FIFO (applied)
├── Makefile, run.bash, run_uvm.bash, run_waves.bash   Questa / cocotb flow (see bottom)
└── README.md
```

---

## Current design

### Geometry (`packages/cache_pkg.sv`)

| Parameter | Value | Derived |
|---|---|---|
| `ADDR_W` | 32 | |
| `CACHE_BYTES` | 16 KiB | `SETS_PER_BANK = 8` |
| `LINE_BYTES` | 128 | `OFFSET_W = 7`, `LINE_BITS = 1024` |
| `WAYS` / `BANKS` / `LANES` | 4 / 4 / 4 | `WAY_W = BANK_W = 2`, `INDEX_W = 3`, `TAG_W = 20` |
| `TEXEL_BYTES` | 8 | `TEXEL_BITS = 64` |
| `FRAG_DEPTH`, `MISS_REQ_DEPTH`, `ROB_DEPTH` | 32 each | |

Byte address split: `{tag[31:12], index[11:9], bank[8:7], offset[6:0]}`.

### Hit path (one pixel in the frontend at a time)

```
TMU quad ──► signal reorganisation ──► round-robin pixel arbiter (pixel_id 0..3)
                 │                                  │
                 └─ mip_base_addr ──────────────────┤
                                                    ▼
                      address_calculation  (4 × addr_calc, per-mip Morton swizzle, + base)
                                                    ▼
                      coalesced_addrs      (taps on the same line -> one group, tap_mask)
                                                    ▼  coalesced_addr_out_t
                      coalesced_fragment_adapter    (tag_lookup_t[4]  |  frag_data_t)
                                                    ▼
                      tag_array (4 banks × 8 sets × 4 ways, tree-PLRU)
                        ├─ rsp (complete pixel) ──► fragment FIFO push = pixel_done
                        └─ miss_valid / miss_addr / miss_way ──► miss path
                                                    ▼
                      frag_fifo ──► read issue (line-ready mirror, per-bank tap select)
                                                    ▼
                      data_array (4 banks, 64-bit texel reads, cookie {pixel_id, tap})
                                                    ▼
                      payload_buffer (assemble quad) ──► texture_cache_return_if ──► TMU
```

* **Top-level handshake** (`hit_path_temp`): the selected pixel's tag request
  is issued once (`req_sent`); `pixel_done` = its complete response is pushed
  into the fragment FIFO; the arbiter then advances `pixel_id`, and
  `tmu_req.ready` pulses when pixel 3 is done. `batch_id` counts accepted
  quads. `bank_result_ready` is tied high because only the complete `rsp` is
  consumed. The request/return channels are the `texture_cache_request_if` /
  `texture_cache_return_if` interfaces (the separate `tmu_valid` /
  `tcache_ready` ports were removed in favour of the interface's own
  `valid`/`ready`).

* **Address calculation** (`addr_calc`): the selected mip is
  `2^log2_width × 2^log2_height` texels. The low `min(lw, lh)` bits of `x`/`y`
  are interleaved (x → even bits, y → odd bits); the remaining bits of the
  longer axis are appended above. The texel index is scaled by the 8 B texel
  size and added to the mip-adjusted base (`mip_base_addr`, which sums
  `2^(lw+lh)` texels per preceding level, i.e. the same per-mip size). For a
  full 16/16 mip this is the original plain interleave. `addr_error` flags a
  carry out of 32 bits, a base not aligned to 8 B, a coordinate outside the
  selected mip, or a mip wider than the 16-bit coordinates. Nearest filtering uses tap 0 only (`used = 0001`);
  bilinear/trilinear use all four (`used = 1111`). Erroring taps are removed
  from the coalescer's active set.
* **Coalescer** (`coalesced_addrs`): group *g* represents a line only if no
  earlier active tap shares it; `tap_mask` is in original tap order and an
  all-zero mask disables the group. Group slots are **not** compacted. The
  equations are cross-checked against an independent partition model in
  `python models/check_coalescing_model.py`.
* **Tag array** (`tag_array`): accepts one pixel (up to four unique lines)
  while `!active`; routes each group to its bank, serialising same-bank groups
  in ascending group order (`route_ptr` is cleared when a pixel is accepted). Each bank produces an
  early `bank_result` and the response `rsp[i]` corresponds to `req[i]`.
  `hit=1, ready=0` is a match on a line whose fill is still outstanding. A new
  miss *reserves* a way and is only committed when the miss descriptor
  `{tag,index,bank,0} + way` has been accepted on the single miss port
  (`miss_lock` holds the bank while backpressured). `rsp_valid` rises once
  every group has resolved. `tag_bank` is 4-way with 3-bit tree-PLRU; it
  prefers invalid ways and **never evicts a valid-but-not-ready line** — if a
  set is full of pending fills the bank stalls (`busy`) until a refill lands.
  This cannot deadlock: every reserved way already has its miss descriptor in
  the miss FIFO/ROB, and the refill depends only on memory (see Miss path).
* **Refill** (`fill_en/fill_bank/fill_idx/fill_way`): marks exactly the
  reserved way ready; `fill_ready` is only high for an allocated, unfilled way.
* **Fragment FIFO** (`frag_fifo`): registered `count`-based FIFO of
  `frag_data_t` (metadata, per-tap bank/idx/way/offset/addr, hit/data_ready).
  `batch_committed` pulses per accepted pixel. With `FULL_BYPASS = 0`
  (default) `ready_in = !full`, so a push and pop in the same cycle while full
  performs the pop only; `FULL_BYPASS = 1` accepts both (comb pop→ready path).
  `pop` is the read-issue stage taking ownership of the tail pixel.
* **Read issue** (in `hit_path_temp`): a line-state mirror (ready bit + tag per
  bank/set/way, updated by miss allocations and refills) tells the stage when
  a pending line has landed, because the fragment's `data_ready` snapshot goes
  stale in the FIFO. Each bank issues the lowest pending tap that maps to it;
  same-bank taps serialise. A pixel with any `addr_error` issues no reads (the
  adapter already skipped its tag lookups).
* **Payload buffer** (`payload_buffer`): one assembly quad + one output quad.
  Texels arrive in any order (cookie `{pixel_id, tap}`); the quad is returned
  as one `texture_cache_return_t` once all four pixels are complete, held
  until `ready`. Unrequested taps and every tap of a faulted pixel return zero
  with `texel_valid = 0`; `addr_error` marks the faulting taps.
* **Data array** (`data_array`): per bank, one 64-bit texel read **or** one
  1024-bit line fill per cycle; a fill only blocks its own bank. Configurable
  `READ_LATENCY`, cookie pass-through, sticky `protocol_error` on malformed
  coordinates.

### Miss path

```
tag_array.miss_* ──► miss_request_fifo ──► memory (valid/ready, transaction_id = ROB slot)
                                               │
                 refill ◄── controller ◄── reorder_buffer ◄── mem return (t_load_in, id)
```

* **miss_path** (`miss_path.sv`): `mem.req_valid = miss FIFO tail valid &&
  !rob_full`; on `req_valid && req_ready` the FIFO pops and the ROB allocates
  the slot whose index is the request id. When the ROB tail is completed the
  line is written into the data array and the reserved tag way is marked
  ready in the same cycle; the ROB pops only when both accept. The refill
  never waits on the tag lookup engine, the fragment FIFO or the TMU.
* **miss_request_fifo**: same FIFO skeleton as `frag_fifo`, entries are
  `miss_req_entry_t {line_addr, miss_way}`; sim-only checks for line
  alignment and duplicate in-flight lines. **Decided:** no empty-FIFO bypass
  and no tail-end coalescing — the tag array already coalesces misses (a
  second request to a pending line hits the reservation), so duplicates
  cannot occur. `FULL_BYPASS` parameter as in `frag_fifo`.
* **reorder_buffer**: head/tail pointers with wrap bit; entries carry
  `line_addr` and the reserved `way`; memory returns are written by
  `transaction_id`; the tail is popped only when `valid && completed`; a
  return landing on the tail is forwarded combinationally. Returns to an
  unallocated or completed slot are dropped (`bad_return`, sticky
  `protocol_error`). No epoch (see Known gaps).

### Module status

| Module | RTL | Testbench | Notes |
|---|---|---|---|
| `addr_calc`, `coalesced_addrs`, `address_calculation` | done | `address_calculation_tb`, `coalescer_tb` | per-mip Morton |
| `coalesced_fragment_adapter` | done | covered by `coalescer_tb` | drives `tag_lookup_t.tap_mask` |
| `tag_array` / `tag_bank` | done, needs refactor | `tag_array_tb` | incl. explicit PLRU order tests |
| `data_array` | done | `data_array_tb` | |
| `frag_fifo` | done | `fragment_fifo_tb` | optional `FULL_BYPASS` |
| `miss_request_fifo` | done | `miss_request_fifo_tb` | optional `FULL_BYPASS` |
| `reorder_buffer` | done | `reorder_buffer_tb` | |
| `miss_path` | done | covered by `hit_path_temp` TB | |
| `payload_buffer` | done | `payload_buffer_tb` | |
| `hit_path_temp` (top) | done | `testbenches/hit_path_temp.sv` (end to end) | |

### Resolved inconsistencies

The four items previously listed here (missing `tag_array_if` signals,
missing `tag_lookup_t.tap_mask`, missing `miss_req_entry_t`, history-dependent
`route_ptr`) are fixed; see `documentation/proposed_patches.md`.

### Known gaps / open questions

1. **Eviction before read (no replay).** A queued pixel's line can be evicted
   by a later pixel's miss once it is ready (`tag_bank` only protects pending
   lines). If the new line's refill lands before the queued pixel reads, the
   read returns the wrong texel. The read-issue stage detects this with the
   mirrored tag and raises sticky `replay_error`, but there is no replay or
   line-locking yet. Not reachable while the working set of in-flight pixels
   fits in the cache without conflicts (the end-to-end TB keeps it so).
2. **ROB epoch.** Not implemented; a memory return issued before a cache reset
   could land in a slot re-allocated after reset. Assumes memory resets with
   the cache.
3. **`max_mip_level`** is only range-checked in simulation; whether the TMU
   can drop it is an open question for Alec (`cache_pkg::base_address_t`).
4. **`hit_path_temp`** now contains the miss path too; consider renaming it to
   a cache-top name once the team agrees.

---

## Next iteration: quadrupling throughput

Reference: `documentation/future work/quadrupled_througput design.png`.

Today the frontend serialises a quad: the round-robin arbiter feeds **one
pixel per cycle** through a single `address_calculation` + coalescer into the
tag array, so a quad occupies the frontend for at least four cycles. The
future-work diagram replaces that with **four parallel batch lanes**:

```
req_0 ─► address calc ─► tex_req_0_0..3 ─► comparators ─► coalescer ─┐
req_1 ─► address calc ─► tex_req_1_0..3 ─► comparators ─► coalescer ─┤
req_2 ─► address calc ─► tex_req_2_0..3 ─► comparators ─► coalescer ─┼─► arbitration ─► tag array
req_3 ─► address calc ─► tex_req_3_0..3 ─► comparators ─► coalescer ─┘
```

Each lane *b* owns one pixel of the quad ("BATCH b"): its own four `addr_calc`
units, its own six line comparators and its own `coalesced_addrs`, producing
one `coalesced_addr_out_t` per pixel per cycle. The four coalesced pixels then
enter an arbitration stage in front of the tag array.

What the diagram shows (already supported by the current blocks):

* `address_calculation` is purely combinational and self-contained, so it can
  be instantiated four times unchanged; `batch_id`/`pixel_id` already travel
  with each `coalesced_addr_out_t`.
* `coalesced_addrs` is per pixel, so no cross-pixel merging is implied by the
  diagram.

What has to change downstream (not drawn — **these are implications, not
decisions**; treat as open design questions):

1. **Arbitration into the tag array.** `tag_array` accepts one pixel while
   `!active` and up to four groups, each tied to a bank. With four pixels per
   cycle (up to 16 unique lines) the arbiter must either (a) time-multiplex
   pixels into the existing engine (no throughput gain unless lookups overlap),
   or (b) issue groups from different pixels to different banks in the same
   cycle. Option (b) requires `pending`/`result_group`/`rsp_q` bookkeeping per
   pixel instead of the single `active` request, and a per-pixel
   `rsp_valid`.
2. **Miss port.** The single `miss_valid/miss_addr/miss_way` stream can retire
   one new miss per cycle; four pixels of misses would back up through
   `miss_lock`. Consider widening to one miss port per bank or deepening
   `miss_request_fifo` accept bandwidth.
3. **Fragment FIFO.** One push per cycle today; a quad per cycle needs four
   write ports or a per-pixel FIFO (four FIFOs indexed by `pixel_id`, with the
   backend payload-preparation buffer re-joining a batch).
4. **Data array.** Four banks give at most four texel reads per cycle; a
   bilinear quad needs up to 16. Either accept multi-cycle reads per quad
   (backend serialises) or add ports/banks. The existing 1-read-or-1-fill rule
   per bank also means refills steal read slots.
5. **Cross-pixel coalescing** is *not* in the diagram; adjacent pixels usually
   share lines, so an optional second-level comparator across the four lane
   outputs (before arbitration) would cut tag-array and data-array pressure.
   Deferred until the above is settled.
6. **TMU handshake.** `tmu_req.ready` currently releases the quad
   when pixel 3 commits; with four lanes the quad can be released after one
   acceptance cycle, which changes the `texture_cache_request_if` timing.

---

## Verification

All testbenches are self-checking (`$error` + final `PASS`/`$fatal`), include
their own sources via `` `include "src/..." `` so they compile standalone, and
keep their test plan as natural-language comments at the top of the file.
Candidate tests that are written down but **not yet implemented** are listed
under "Additional testcases" in each header.

| Testbench | DUT | Run |
|---|---|---|
| `address_calculation_tb.sv` | `addr_calc`, `address_calculation` | `make address_calculation.sim` |
| `coalescer_tb.sv` (module `coalescer_contract_tb`) | `address_calculation` + adapter | `make coalescer.sim` |
| `tag_array_tb.sv` | `tag_array` via `tag_array_if` | `make tag_array.sim` |
| `fragment_fifo_tb.sv` | `frag_fifo` | `make fragment_fifo.sim` |
| `miss_request_fifo_tb.sv` | `miss_request_fifo` | `make miss_request_fifo.sim` |
| `data_array_tb.sv` | `data_array` | `make data_array.sim` |
| `reorder_buffer_tb.sv` | `reorder_buffer` | `make reorder_buffer.sim` |
| `payload_buffer_tb.sv` | `payload_buffer` | `make payload_buffer.sim` |
| `hit_path_temp.sv` (module `hit_path_temp_tb`) | whole cache, TMU + out-of-order memory models | `make hit_path_temp.sim` |
| `python models/check_coalescing_model.py` | coalescer equations | `python3 "python models/check_coalescing_model.py"` |

`make check` runs every bench. All benches were also compiled and run with
Verilator 5.020 (`verilator --binary --timing -I. --top-module <tb>
packages/cache_pkg.sv testbenches/<tb>.sv`), elaborated with slang for LRM
conformance, and checked against hand-inserted RTL mutations.

---

## How to use the simulation flow (original notes)

Step 0:
  MAKE SURE YOU SSH WITH THE -X FLAG FOR GUI WAVES!!! Eg: `ssh -X asicfab`
  Copy these files into the directory where you intend to work on your project.

Step 1:
Run `make setup` or `make setup_all`

  `make setup`: sets up only what you need (python, testbenches, wrappers directories)

  `make setup_all`: sets up every directory to test spec (recommended if you dont already have existing directories)

2 OPTIONS FOR RUNNING SIM:

  `run_waves.bash`: your standard simulate and open Questa waves.
    `./run_waves.bash module_name_tb`
    This sets the module name to whatever you put as an argument and sets the
    source file to `testbenches/module_name_tb.sv`, so make sure the tb file is
    in the testbenches directory!!

  `run.bash`: the more involved cocotb testbench. Your cocotb testbench should
    be in the python directory; the wrapper for the testbench should be in the
    wrappers directory.
    `./run.bash example_wrapper example_stage_tb`
    This sets the wrapper to the file name in the first argument (no `.sv`) and
    the cocotb file to the second argument (must be in the python directory).
