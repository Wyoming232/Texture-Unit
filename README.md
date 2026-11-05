# Texture-Unit — Texture Cache (T$)

SystemVerilog RTL for the texture cache that services texel requests from the
texture mapping unit (TMU). One TMU transfer is a **quad** (four pixels) at one
mip level; each pixel carries up to four taps (`c00, c10, c01, c11`). The cache
turns those taps into Morton-swizzled byte addresses, coalesces taps that share
a 128 B line, looks them up in a 4-bank / 4-way tag array, queues the pixel in
a fragment FIFO, and reads texels from a 4-bank data array. Misses go through a
miss-request FIFO, memory, and a reorder buffer (ROB) before refilling the
arrays.

---

## Repository structure

```
.
├── src/                          RTL
│   ├── address_calculation.sv    address_calculation (per-pixel wrapper), addr_calc (Morton),
│   │                             coalesced_addrs (4-tap line coalescer)
│   ├── coalesced_fragment_adapter.sv  coalesced_addr_out_t -> tag_lookup_t[4] + frag_data_t
│   ├── tag_array.sv              tag_array (routing/stall, miss arbiter), tag_bank (4-way, tree-PLRU)
│   ├── data_array.sv             4-banked texel storage, 1 read or 1 line fill per bank/cycle
│   ├── frag_fifo.sv              fragment (pixel) FIFO between tag lookup and data read
│   ├── miss_request_fifo.sv      line-address + reserved-way queue toward memory
│   ├── reorder_buffer.sv         ROB for out-of-order memory returns (module currently named `top`)
│   └── hit_path_temp.sv          WIP top-level wrapper: TMU signal reorganisation, round-robin
│                                 pixel arbiter, mip_base_addr. Does not compile yet.
├── interfaces/
│   ├── interfaces.vh             texture_cache_request_if (TMU -> T$), includes tag_array_if
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
│   └── proposed_patches.md       interface/package additions needed to compile tag_array & miss FIFO
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

### Hit path (one pixel per cycle)

```
TMU quad ──► signal reorganisation ──► round-robin pixel arbiter (pixel_id 0..3)
                 │                                  │
                 └─ mip_base_addr ──────────────────┤
                                                    ▼
                      address_calculation  (4 × addr_calc, Morton swizzle, + base)
                                                    ▼
                      coalesced_addrs      (taps on the same line -> one group, tap_mask)
                                                    ▼  coalesced_addr_out_t
                      coalesced_fragment_adapter    (tag_lookup_t[4]  |  frag_data_t)
                                                    ▼
                      tag_array (4 banks × 8 sets × 4 ways, tree-PLRU)
                        ├─ bank_result_valid / rsp  ──► fragment FIFO push
                        └─ miss_valid / miss_addr / miss_way ──► miss path
                                                    ▼
                      frag_fifo ──► data_array (4 banks, 64-bit texel reads) ──► TMU
```

* **Address calculation** (`addr_calc`): 16-bit `x`/`y` are bit-interleaved
  (x → even bits, y → odd bits) and scaled by the 8 B texel size, then added to
  the mip-adjusted base. `addr_error` flags a carry out of 32 bits or a base
  not aligned to 8 B. Nearest filtering uses tap 0 only (`used = 0001`);
  bilinear/trilinear use all four (`used = 1111`). Erroring taps are removed
  from the coalescer's active set.
* **Coalescer** (`coalesced_addrs`): group *g* represents a line only if no
  earlier active tap shares it; `tap_mask` is in original tap order and an
  all-zero mask disables the group. Group slots are **not** compacted. The
  equations are cross-checked against an independent partition model in
  `python models/check_coalescing_model.py`.
* **Tag array** (`tag_array`): accepts one pixel (up to four unique lines)
  while `!active`; routes each group to its bank, serialising same-bank groups
  (round-robin `route_ptr` per bank, see note below). Each bank produces an
  early `bank_result` and the response `rsp[i]` corresponds to `req[i]`.
  `hit=1, ready=0` is a match on a line whose fill is still outstanding. A new
  miss *reserves* a way and is only committed when the miss descriptor
  `{tag,index,bank,0} + way` has been accepted on the single miss port
  (`miss_lock` holds the bank while backpressured). `rsp_valid` rises once
  every group has resolved. `tag_bank` is 4-way with 3-bit tree-PLRU; it
  prefers invalid ways and **never evicts a valid-but-not-ready line** — if a
  set is full of pending fills the bank stalls (`busy`) until a refill lands.
* **Refill** (`fill_en/fill_bank/fill_idx/fill_way`): marks exactly the
  reserved way ready; `fill_ready` is only high for an allocated, unfilled way.
* **Fragment FIFO** (`frag_fifo`): registered `count`-based FIFO of
  `frag_data_t` (metadata, per-tap bank/idx/way/offset/addr, hit/data_ready).
  `batch_committed` pulses per accepted pixel. `ready_in = !full` is
  registered, so a push and pop in the same cycle while full performs the pop
  only.
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

* **miss_request_fifo**: same FIFO skeleton as `frag_fifo`, entries are
  `{line_addr, miss_way}`; sim-only assertion that pushed addresses are
  line-aligned. No bypass and no tail-end coalescing yet (open decision, see
  comments in `testbenches/miss_request_fifo_tb.sv`).
* **reorder_buffer**: head/tail pointers with wrap bit, memory returns are
  written by `transaction_id`, the tail is popped only when `valid &&
  completed`; a return landing on the tail is forwarded combinationally.
* **Controller / refill into tag+data arrays / TMU return path**: not written.

### Module status

| Module | RTL | Testbench | Notes |
|---|---|---|---|
| `addr_calc`, `coalesced_addrs`, `address_calculation` | done | `address_calculation_tb`, `coalescer_tb` | |
| `coalesced_fragment_adapter` | done | covered by `coalescer_tb` | does not drive `tag_lookup_t.tap_mask` (see inconsistencies) |
| `tag_array` / `tag_bank` | done, needs refactor | `tag_array_tb` | needs interface + package additions to compile |
| `data_array` | done | `data_array_tb` | |
| `frag_fifo` | done | `fragment_fifo_tb` | |
| `miss_request_fifo` | done | `miss_request_fifo_tb` | needs `miss_req_entry_t` in package |
| `reorder_buffer` | draft (module named `top`) | skeleton only | |
| `hit_path_temp` (top) | WIP, does not compile | skeleton only | struct-literal syntax, `base_addr` width, missing instantiations |
| controller, TMU return | not started | — | |

### Known inconsistencies (as of this commit)

These block compilation of `tag_array.sv` and `miss_request_fifo.sv` against
the checked-in package/interface. Minimal fixes inferred from usage are
proposed in `documentation/proposed_patches.md` for review.

1. `tag_array.sv` uses `tag_if.busy`, `bank_result`, `bank_tap_mask`,
   `bank_result_valid`, `bank_result_ready`; none exist in `tag_array_if.sv`.
2. `tag_array.sv` reads `req[g].tap_mask`, but `cache_pkg::tag_lookup_t` has
   no `tap_mask` field (and `coalescer_tb` asserts `$bits(tag_lookup_t) == 26`;
   `coalesced_fragment_adapter` would also need to populate it).
3. `miss_request_fifo.sv` uses `miss_req_entry_t`, which is only a TODO in
   `cache_pkg.sv`.
4. Same-bank groups in `tag_array` are looked up starting from the bank's
   persistent `route_ptr`, not from group 0 — harmless for correctness
   (`rsp[i]` ↔ `req[i]` holds) but worth knowing when reading waveforms.

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
6. **TMU handshake.** `tcache_ready`/`tmu_ready` currently releases the quad
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
| `address_calculation_tb.sv` | `addr_calc`, `address_calculation` | `./run_waves.bash address_calculation_tb` |
| `coalescer_tb.sv` (module `coalescer_contract_tb`) | `address_calculation` + adapter | compile with Questa directly |
| `tag_array_tb.sv` | `tag_array` via `tag_array_if` | `./run_waves.bash tag_array_tb` (after patches) |
| `fragment_fifo_tb.sv` | `frag_fifo` | `./run_waves.bash fragment_fifo_tb` |
| `miss_request_fifo_tb.sv` | `miss_request_fifo` | `./run_waves.bash miss_request_fifo_tb` (after patch) |
| `data_array_tb.sv` | `data_array` | compile `packages/cache_pkg.sv` first |
| `reorder_buffer_tb.sv` | `reorder_buffer` | skeleton, not runnable |
| `python models/check_coalescing_model.py` | coalescer equations | `python3 "python models/check_coalescing_model.py"` |

The four TBs above were also compiled and run with Verilator 5.020
(`verilator --binary --timing -I. --top-module <tb> testbenches/<tb>.sv`) and
checked against hand-inserted RTL mutations.

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
