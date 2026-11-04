/*
   Miss Request FIFO
   Tag array miss
   - Miss req accepts line addr and miss_way only when !full
   - TODO : Might have to accept more than just line addr for the case when
   we coalesce tail end of the FIFO and Memory sends out of order return to
   the tail of ROB but also to middle of ROB, in which case we would have to fill both
   ROB entries.
   If we don't, that would result in eviction of the data after oldest entry
   and the data wont be present for younger entry
   - Asserts accepted to fragment entry preparation buffer (miss_accepted & hit & hit_way
   are control signals for fragment commit)
   Memory request
   - Memory handshakes with FIFO, whenever available,
    with MR FIFO which pops off FIFO tail
   - TODO : backend must be fleshed out more

   - Test simultaneous miss & memory handshake, ie push & pop simultaneously
   - Test memory free to accept when FIFO empty
   - Test simulataneous tag miss and memory available when MR FIFO empty
   - TODO : 2 options, we can bypass requests directly to memory, or wait until FIFO has
   4 entries to perform tail end coalescing (or just have a separate buffer tracking last 4 requests
   and if any match, then we dont send them)
*/