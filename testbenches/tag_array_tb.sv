/*
    Tag bank test
    - Miss to line 1
    - Hit line 1
    - 3x miss to lines 2, 3, 4 all mapping to the same index as 1
    - Miss to line 5, also mapping to line 1 leading in an eviction
    - Miss to line 1
    Tag array test
    Pixel reqest (4 taps)
    - All 4 taps hit diff banks
    - All 4 taps hit same bank
    - 3 taps hit one bank
    - 2 taps hit one bank and 1 tap per two other banks
    - 2 taps hit one bank and 2 taps hit another two banks
*/