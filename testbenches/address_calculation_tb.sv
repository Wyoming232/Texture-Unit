/* Notes for TB
    Combinational block
    Inputs are driven like they would be through the TMU 
    TB will be reused once address calculation is added to the hit path, after which arbitration will be tested
    Testing address calc and coalescing (single pixel, 4 taps)
    
    send 4 taps, generate 4 addrs, coalesce into 1

    Batch_id, pixel_id, pixel_metadata just need to be saved for Frag entry

    Testcases (test functionality of each signal)
    Addr gen
    | What to test | `base_addr` | Tap coordinates `(x,y)` | Expected byte address / result |
    |---|---|---|---|
    | Zero | `0` | `(0,0)` | `0x00000000` |
    | X/Y interleaving | `0` | `(1,0)`; `(0,1)` | `0x08`; `0x10` |
    | Largest aligned offset within a line | `0` | `(3,3)` | `0x78`, offset = 120 |
    | All four banks | `0` | `(0,0)`; `(4,0)`; `(0,4)`; `(4,4)` | `0x000`; `0x080`; `0x100`; `0x180` → banks 0–3 |
    | Index boundary | `0` | `(7,7)`; `(8,0)` | `0x1F8`; `0x200` → index 0 then 1 |
    | Tag boundary | `0` | `(31,15)`; `(0,16)` | `0xFF8`; `0x1000` → tag 0 then 1 |
    | Base addition carrying into the next line | `0x78` | `(1,0)` | `0x80`, offset = 0 |
    | Largest valid byte address | `0` | `(0x7FFF,0x3FFF)` | `0xFFFFFFF8`, no error |
    | Coordinate-caused overflow | `0` | `(0,0x4000)`; `(0x8000,0)` | Error for each |
    | Base-addition overflow | `0xFFFFFFF8` | `(0,0)`; `(1,0)` | First valid; second errors |
    | Misaligned base | `1`, `2`, `4`, `7` | `(0,0)` | Error for each |
    
    Coalescing (lines 0, 1, 2, 3)
    - no coalescing
    - 2, 3 coalesce
    - 1, 3 coalesce
    - 1, 2 coalesce
    - 1, 2, 3 coalesce
    - 0, 1 coalesce
    - 0, 2 coalesce
    - 0, 3 coalesce
    - 0, 1 coalesce, 2, 3 coalesce
    - 0, 2 coalesce, 1, 3 coalesce
    - 0, 3 coalesce, 1, 2 coalesce
    - 0, 1, 2 coalesce
    - 0, 1, 3 coalesce
    - 0, 2, 3 coalesce
    - 0, 1, 2, 3 coalesce
/