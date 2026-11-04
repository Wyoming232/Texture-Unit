/*
 Frontend
 - Fragment entry preparation buffer
    - Waits for all taps before entering
    - test 1, 2, 3, and 4 cycle entries
    - ready should be asserted when about to pass to FIFO
 - Tag array and FIFO interaction
    - Should not push when full
    - Should only push when hit or pseudo-hit(miss entry accepted in miss request FIFO)
 Backend
 - Payload preparation buffer
    - Wait for all entries in a batch to be ready before sending to TMU
    - Stall everything until ready
 - FIFO and data array interaction
    - Should not pop when empty
    - Should not pop until data is filled from ROB
 - Test same cycle push and pop
*/