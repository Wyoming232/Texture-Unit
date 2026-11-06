# Texture-Unit TODOs, grouped by pipeline stage

Source: `Wyoming232/Texture-Unit` @ `eddf2eb` ("TODOS"). Only real `TODO` comments are listed. The quoted one in `documentation/proposed_patches.md` and the description in `README.md:161` are left out.

## 0. TMU → T$ request (top-level wrapper / pixel arbiter)
| # | Location | TODO |
|---|---|---|
| T1 | `src/hit_path_temp.sv:8` | Does not compile: struct literals use `=`/`;` instead of `:`/`,`, `base_addr` is declared 1-bit, and `tmu_req.*` fields must be accessed through `tmu_req.payload`. |
| T2 | `src/hit_path_temp.sv:19` | Return IO (the T$ → TMU output ports) is not declared. |
| T3 | `src/hit_path_temp.sv:120` | Drive `pixel_done` from tag-array and fragment-FIFO completion. |
| T4 | `src/hit_path_temp.sv:160` (`round_robin_arbiter`) | Write the `pixel_done` logic in hit_path_temp. |
| T5 | `src/hit_path_temp.sv:180` (`round_robin_arbiter`) | Move `tmu_ready = (pixel_id==3) && pixel_done` up to hit_path_temp. |
| T6 | `src/hit_path_temp.sv:187` (`round_robin_arbiter`) | Pixel-done logic for the `pixel_id` counter (same topic as T3–T5). |
| T7 | `packages/cache_pkg.sv:101` (`base_address_t`) | Check with Alec whether `max_mip_level`, `log2_width`, `log2_height` are needed. The cache does not use them. |
| T8 | `src/hit_path_temp.sv:153` (`round_robin_arbiter`) | Pass `pixel_metadata_in` through the address-calculation wrapper. Also, the `tmu_pixel_info` type does not exist in the package. |

## 1. Address calculation (+ TB)
| # | Location | TODO |
|---|---|---|
| A1 | `src/address_calculation.sv:5` | Integrate into hit_path_temp. |
| A2 | `src/hit_path_temp.sv:123` | Instantiate the address-calculation wrapper (same task as A1). |
| A3 | `src/address_calculation.sv:6` | Update for mip scaling. |
| A4 | `src/address_calculation.sv:89` | Morton index is hard-coded for 16-bit x/y. Parameterize it for other texture sizes. |
| A5 | `testbenches/address_calculation_tb.sv:88` | TB counterpart of A4. The TB assumes 16-bit Morton. |

## 2. Coalescer → tag-lookup adapter (+ coalescer TB)
| # | Location | TODO |
|---|---|---|
| C1 | `packages/cache_pkg.sv:152` (`coalesced_addr_out_t`) | Rename `used` to `tap_mask`. |
| C2 | `src/coalesced_fragment_adapter.sv:25` | Drive `tag_req[g].tap_mask` from `lines[g].tap_mask` once `tag_lookup_t` has the field. |
| C3 | `testbenches/coalescer_tb.sv:302` | `$bits(tag_lookup_t)` becomes 30 once `tap_mask` is added. Update this check. |
| C4 | `testbenches/coalescer_tb.sv:424` | Same check as C3, repeated. |
| C5 | `testbenches/coalescer_tb.sv:539` | Same check as C3, repeated. |

## 3. Tag array (+ TB)
| # | Location | TODO |
|---|---|---|
| G1 | `packages/cache_pkg.sv:166` (`tag_lookup_t`) | `tag_array.sv` reads `req[g].tap_mask`, which the struct does not have. Adding it ties into C2–C5. |
| G2 | `interfaces/tag_array_if.sv:18` | `busy`, `bank_result`, `bank_tap_mask`, `bank_result_valid`, `bank_result_ready` are used but not declared. |
| G3 | `src/tag_array.sv:36` | `route_ptr` persists across pixels. Decide whether that is intended. |
| G4 | `src/tag_array.sv:216` | A set with all 4 ways allocated but unfilled stalls the bank until a refill. The controller must guarantee forward progress, or this deadlocks. |
| G5 | `testbenches/tag_array_tb.sv:34` | PLRU coverage gap: the way-2 commit bit (`lru[0]`) is never exercised. |
| G6 | `src/hit_path_temp.sv:127` | Tag-array section of the top: handshake signals and logic. |

## 3m. Miss path (branches off the tag array, returns as refill)
| # | Location | TODO |
|---|---|---|
| M1 | `packages/cache_pkg.sv:206` | `miss_req_entry_t {line_addr, miss_way}` is used by `miss_request_fifo.sv` but not defined. |
| M2 | `packages/cache_pkg.sv:207` | Define the miss-request-FIFO structs (same task as M1). |
| M3 | `src/miss_request_fifo.sv:13` | The future controller must qualify `miss_pop` with real downstream acceptance (ROB/tracker capacity, not just memory ready). |
| M4 | `src/miss_request_fifo.sv:29` | Push and pop in the same cycle while full only pops. Add a bypass if full throughput is needed. |
| M5 | `testbenches/miss_request_fifo_tb.sv:5` | An entry may need more than the line address if tail-end coalescing plus out-of-order returns must fill several ROB entries. |
| M6 | `testbenches/miss_request_fifo_tb.sv:16` | Flesh out the backend. |
| M7 | `testbenches/miss_request_fifo_tb.sv:21` | Design choice: bypass to memory vs. tail-end coalescing over the last 4 requests. |
| R1 | `src/reorder_buffer.sv:5` | The module is named `top`. Rename it to `reorder_buffer`. |
| R2 | `packages/cache_pkg.sv:22` | Decide `ID_WIDTH` (in the commented-out ROB block). |
| R3 | `testbenches/reorder_buffer_tb.sv:21` | `epoch_i` stale-fill-after-reset handling. Deferred ("don't do anything for now"). |
| R4 | `testbenches/reorder_buffer_tb.sv:25` | `mem_req_valid`. Deferred ("don't worry about it for now"). |
| R5 | `testbenches/reorder_buffer_tb.sv:35` | `logic rob_entry tail_entry` needs a width/type fix. |
| X1 | `interfaces/interfaces.vh:20` | Define the remaining FIFO/ROB/controller interfaces with their owners. |

## 4. Fragment FIFO (+ TB)
| # | Location | TODO |
|---|---|---|
| F1 | `src/frag_fifo.sv:13` | Connect `pop` to the future backend's accepted ownership transfer. |
| F2 | `src/frag_fifo.sv:26` | Push and pop in the same cycle while full only pops. Add a bypass if full throughput is needed (same issue as M4). |
| F3 | `src/hit_path_temp.sv:131` | Fragment-FIFO section of the top: handshake signals and logic. |

`testbenches/fragment_fifo_tb.sv` has no TODOs.

## 5. Data array (+ TB)
`src/data_array.sv` and `testbenches/data_array_tb.sv` have no TODOs.

## 6. Payload buffer (+ TB) → TMU
| # | Location | TODO |
|---|---|---|
| P1 | `src/hit_path_temp.sv:135` | "Probably want a buffer to hold data array outputs". No payload-buffer module or TB exists yet. |
| P2 | `src/hit_path_temp.sv:19` | Return IO to the TMU (same as T2; it closes the loop). |
